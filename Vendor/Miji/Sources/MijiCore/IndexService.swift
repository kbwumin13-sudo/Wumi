import Foundation
import AppKit
import CoreServices
import Darwin
import IOKit.ps
import os

public struct IndexProgress: Sendable {
    public var phase: String
    public var detail: String
    public var processed: Int
    public var busy: Bool
    public init(phase: String = "准备就绪", detail: String = "", processed: Int = 0, busy: Bool = false) { self.phase=phase; self.detail=detail; self.processed=processed; self.busy=busy }
}
public struct IndexingPreferences: Codable, Sendable, Equatable {
    public var images = true
    public var documents = true
    public var externalImages = true
    public var externalDocuments = true
    public var retainOffline = true
    public var includeHidden = true
    public var excludeDevelopmentCaches = false
    public var autoAddExternal = true
    public var ignoredExternalVolumes: [String] = []
    public init() {}
}

/// Conditions under which heavy background work (content extraction, automatic
/// whole-root rescans) waits. Ordinary change tracking continues regardless.
struct IndexResourceState: Equatable {
    var lowPower = false
    var thermal = false
    var battery = false
    var constrained: Bool { lowPower || thermal || battery }
    var summary: String {
        var parts: [String] = []
        if battery { parts.append("使用电池") }
        if lowPower { parts.append("低电量模式") }
        if thermal { parts.append("温度过高") }
        return parts.isEmpty ? "电源正常" : parts.joined(separator:"、")
    }
    static func current() -> IndexResourceState {
        let info=ProcessInfo.processInfo
        var state=IndexResourceState()
        state.lowPower=info.isLowPowerModeEnabled
        state.thermal=info.thermalState == .serious || info.thermalState == .critical
        if let blob=IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type=IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() {
            state.battery=(type as String) == kIOPSBatteryPowerValue
        }
        return state
    }
}

public final class IndexService: @unchecked Sendable {
    public let database: SearchDatabase
    public var onProgress: ((IndexProgress) -> Void)?
    public var onChange: (() -> Void)?
    public var onContentChange: (() -> Void)?
    public var onIndexChange: ((IndexChange) -> Void)?
    private let lock = NSLock()
    // Background QoS runs on efficiency cores with throttled disk I/O, so indexing
    // yields to whatever the user is doing.
    private let work = DispatchQueue(label: "local.miji.index", qos: .background)
    private let control = DispatchQueue(label: "local.miji.control", qos: .utility)
    private let log = Logger(subsystem: "local.miji", category: "index")
    private var running = false
    private var executing = false
    private var scheduledWork: DispatchWorkItem?
    private var scheduleGeneration = 0
    private let scheduling: IndexWorkScheduling
    private var requested = false
    private var fullRequested = false
    private var userActive = false
    private var sleeping = false
    private var state: IncrementalIndexState
    private let stateURL: URL
    private let watchEvents: Bool
    private var watchedPaths: [String] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var processObservers: [NSObjectProtocol] = []
    private var paused = false
    private var stopped = false
    private var mutations = 0
    private var preferences = IndexingPreferences()
    private var watcher: FileWatcher?
    // Only used on work. A suspended session keeps its enumerator within this process.
    private var scanSessions: [String:[String:FileScanSession]] = [:]
    private var localTurn = Set<String>()
    private var rootCursor = 0
    private var priorityTurn = true
    // Whether the last progress report said "busy"; a quiet run must still clear it.
    private var announcedBusy = false
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var persistWork: DispatchWorkItem?
    private var stateDirty = false
    private var lastPersisted: Data?
    private var unfoldedPendingRoots = Set<String>()
    private let ignoredPaths: [String]
    private var nextScanAfter = Date.distantPast
    private let rescanInterval: TimeInterval = 10
    /// Automatic whole-root rescans wait this long after the previous whole scan completed.
    let fullRescanCooldown: TimeInterval
    private let resources: () -> IndexResourceState
    private let resourceCheckInterval: TimeInterval
    private var resourceState = IndexResourceState()
    private var lastResourceCheck: TimeInterval = -.infinity
    private let extractor: (URL, @escaping () -> Bool) throws -> ExtractedContent
    // Accessed only by the single heavy worker.
    private let extractionReuse: ExtractionReuse?
    private static let heavyDocumentExtensions = ["pdf","pages","numbers","key","keynote","rtfd","doc","ppt","xls","docx","pptx","xlsx","epub"]
    static let heavyDocumentExtensionsSQL = heavyDocumentExtensions.map { "'" + $0 + "'" }.joined(separator:",")
    private static func isHeavy(_ file: FileRecord) -> Bool {
        file.kind == .image || Self.heavyDocumentExtensions.contains(file.fileExtension)
    }
    private enum ContentLane: CaseIterable { case light, heavy }
    private struct ContentPath: Hashable {
        var rootID: String
        var path: String
    }
    private struct ContentPool: Hashable {
        var rootID: String
        var lane: ContentLane
        var kind: FileKind
    }
    private struct FreshContent {
        var first: TimeInterval
        var ready: TimeInterval
    }
    private struct ContentClaim {
        var key: ContentPath
        var root: IndexedRoot
        var file: FileRecord
        var epoch: UInt64
    }
    private enum ExtractionResult {
        case done(Data), failed(String), changed, interrupted
    }
    private let lightWorker = DispatchQueue(label:"local.miji.index.light-content", qos:.background)
    private let heavyWorker = DispatchQueue(label:"local.miji.index.heavy-content", qos:.background)
    // The writer queue owns these claims. The lock protects only epoch and
    // lifecycle flags consulted by the workers, and the durable event inbox.
    private let extractionJobs = DispatchGroup()
    private var claims: [ContentLane:ContentClaim] = [:]
    private var contentEpoch: UInt64 = 0
    private var activeClaims = 0
    private var freshContent: [ContentPath:FreshContent] = [:]
    private var freshRuns: [ContentLane:Int] = [:]
    private var contentCursors: [ContentLane:Int] = [:]
    private var contentWake: DispatchWorkItem?
    private var contentWakeDeadline: TimeInterval?
    // Keep the first pending row in range until it changes state. This avoids
    // scanning the other lane's prefix again after each completion.
    private var pendingLowerBounds: [ContentPool:Int64] = [:]
    private var rootsNeedRefresh = true
    private var currentRoots: [IndexedRoot] = []
    public convenience init(database: SearchDatabase, ignoredPaths: [String] = [], extractionWorker: URL? = nil) {
        self.init(database:database,ignoredPaths:ignoredPaths,extractor: { url,cancelled in
            let ext=url.pathExtension.lowercased()
            if let extractionWorker, FileKind.classify(extension:ext) == .image || Self.heavyDocumentExtensions.contains(ext) {
                return try IsolatedContentExtractor.extract(url:url,executable:extractionWorker,cancelled:cancelled)
            }
            return try ContentExtractor.extract(url:url,cancelled:cancelled)
        },reuseHeavyInputs:true)
    }
    init(database: SearchDatabase, ignoredPaths: [String] = [], extractor: @escaping (URL, @escaping () -> Bool) throws -> ExtractedContent,
         watchEvents: Bool = true, stateURL: URL? = nil, fullRescanCooldown: TimeInterval = 30 * 60,
         resources: (() -> IndexResourceState)? = nil, resourceCheckInterval: TimeInterval = 5,
         scheduling: IndexWorkScheduling = IndexWorkScheduling(), reuseHeavyInputs: Bool = false) {
        self.database = database
        self.scheduling = scheduling
        let inboxURL=stateURL ?? database.url.appendingPathExtension("incremental.json")
        self.stateURL=inboxURL
        var state=IncrementalIndexState.read(inboxURL)
        state.migrateInterruptedScans()
        self.state=state
        self.watchEvents=watchEvents
        self.ignoredPaths = ignoredPaths + [inboxURL.path,inboxURL.appendingPathExtension("tmp").path]
        self.extractor = extractor
        self.extractionReuse = reuseHeavyInputs ? ExtractionReuse() : nil
        self.fullRescanCooldown = fullRescanCooldown
        self.resources = resources ?? IndexResourceState.current
        self.resourceCheckInterval = resourceCheckInterval
    }
    private func locked<T>(_ block: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try block() }
    public func configure(_ preferences: IndexingPreferences) {
        let rescan=locked { () -> Bool in
            let changed=self.preferences.includeHidden != preferences.includeHidden || self.preferences.excludeDevelopmentCaches != preferences.excludeDevelopmentCaches
            if self.preferences != preferences { contentEpoch &+= 1 }
            self.preferences=preferences
            return changed
        }
        if rescan { requestScan() } else { wakeWork() }
    }
    public func start() {
        control.async { [weak self] in
            guard let self, self.timer == nil, !self.locked({self.stopped}) else { return }
            let timer=DispatchSource.makeTimerSource(queue:self.control)
            timer.schedule(deadline:.now()+30,repeating:30,leeway:.seconds(10))
            // Probe mount/root changes, power state and due rescans, and continue
            // pending extraction. This heartbeat never enumerates a root by itself.
            timer.setEventHandler { [weak self] in self?.wakeWork() }
            self.timer=timer;timer.resume()
            let center=NSWorkspace.shared.notificationCenter
            self.workspaceObservers=[
                center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:nil) { [weak self] _ in self?.setSystemSleeping(true) },
                center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:nil) { [weak self] _ in self?.setSystemSleeping(false) },
                center.addObserver(forName:NSWorkspace.didMountNotification,object:nil,queue:nil) { [weak self] _ in self?.wakeWork() },
                center.addObserver(forName:NSWorkspace.didUnmountNotification,object:nil,queue:nil) { [weak self] _ in self?.wakeWork() }
            ]
            let process=NotificationCenter.default
            self.processObservers=[
                process.addObserver(forName:.NSProcessInfoPowerStateDidChange,object:nil,queue:nil) { [weak self] _ in self?.resourcesMayHaveChanged() },
                process.addObserver(forName:ProcessInfo.thermalStateDidChangeNotification,object:nil,queue:nil) { [weak self] _ in self?.resourcesMayHaveChanged() }
            ]
        }
        wakeWork()
    }
    public func stop() {
        locked {
            stopped=true
            contentEpoch &+= 1
            scheduledWork?.cancel();scheduledWork=nil
            scheduleGeneration += 1
            if !executing { running=false }
        }
        control.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel();self.timer=nil;self.watcher=nil;self.debounce?.cancel();self.debounce=nil
            for observer in self.workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            for observer in self.processObservers { NotificationCenter.default.removeObserver(observer) }
            self.workspaceObservers=[];self.processObservers=[]
        }
    }
    /// Host shutdown barrier: callbacks and helper cancellation complete before releasing ownership.
    public func stopAndWait() {
        stop()
        control.sync {}
        // First close submissions on the writer. Workers enqueue completion
        // before leaving the group, so the second writer barrier joins those too.
        work.sync { contentWake?.cancel();contentWake=nil;contentWakeDeadline=nil }
        extractionJobs.wait()
        work.sync {}
        locked {
            persistWork?.cancel();persistWork=nil
            if stateDirty { try? persistState() }
        }
    }
    public func setPaused(_ value: Bool) {
        locked {
            if value && !paused { contentEpoch &+= 1 }
            paused=value
        }
        if value { emit("已暂停","搜索现有索引仍然可用") } else { wakeWork() }
    }
    /// Finish the current valid extraction, then yield metadata and content work
    /// while the user is typing. No completed result is discarded to yield.
    public func setUserActive(_ value: Bool) {
        locked {
            userActive=value
            if value, scheduledWork != nil {
                scheduledWork?.cancel();scheduledWork=nil
                scheduleGeneration += 1
                if !executing {running=false}
            }
        }
        if !value {wakeWork()}
    }
    func setSystemSleeping(_ value: Bool) {
        locked {
            if value && !sleeping { contentEpoch &+= 1 }
            sleeping=value
        }
        if !value { wakeWork() }
    }
    /// Explicit refresh remains a full reconciliation, with storm coalescing.
    public func requestScan() { locked { fullRequested=true }; wakeWork() }
    public func requestIncrementalUpdate() { wakeWork() }
    private func resourcesMayHaveChanged() {
        refreshResources(force:true)
        wakeWork()
    }
    private var canRunLocked: Bool { !stopped && !paused && !sleeping && !userActive && mutations == 0 }
    /// Caller holds lock. A generation also invalidates already submitted timer
    /// callbacks, including injected schedulers that cannot cancel their timer.
    private func prepareRunLocked(after delay: TimeInterval) -> (TimeInterval, DispatchWorkItem) {
        scheduledWork?.cancel()
        scheduleGeneration += 1
        let generation=scheduleGeneration
        let item=DispatchWorkItem { [weak self] in
            guard let self else { return }
            let begin=self.locked { () -> Bool in
                guard generation == self.scheduleGeneration else { return false }
                self.scheduledWork=nil
                guard self.canRunLocked else { self.running=false;return false }
                self.executing=true
                return true
            }
            if begin { self.run() }
        }
        scheduledWork=item;running=true
        return (delay,item)
    }
    private func enqueue(_ plan: (TimeInterval, DispatchWorkItem)?) {
        if let (delay,item)=plan { scheduling.enqueue(work,delay,item) }
    }
    private func wakeWork(refreshRoots: Bool = true) {
        let plan=locked { () -> (TimeInterval, DispatchWorkItem)? in
            guard !stopped else {return nil}
            if refreshRoots {rootsNeedRefresh=true}
            requested=true
            guard !executing,canRunLocked else { return nil }
            if !refreshRoots && scheduledWork != nil {return nil}
            // An event or manual request can bring forward a delayed refresh.
            return prepareRunLocked(after:0)
        }
        enqueue(plan)
    }
    public func mutate(_ action: @escaping (SearchDatabase) throws -> Void, completion: @escaping (Error?) -> Void = {_ in}) {
        // Submit under the lifecycle lock so stopAndWait cannot pass a
        // writer barrier while an accepted mutation is still being enqueued.
        let accepted=locked { () -> Bool in
            guard !stopped else {return false}
            mutations += 1
            contentEpoch &+= 1
            work.async { [weak self] in self?.performMutation(action,completion:completion) }
            return true
        }
        if !accepted { completion(SearchDatabaseError(message:"索引已停止")) }
    }
    private func performMutation(_ action: (SearchDatabase) throws -> Void, completion: (Error?) -> Void) {
        var failure:Error?
        do {
            let before=try database.roots()
            try action(database)
            let after=try database.roots()
            // A disabled root has no active watcher. Re-enabling it must
            // reconcile changes made while it was outside the stream.
            for root in after where root.enabled && before.contains(where:{$0.id == root.id && !$0.enabled}) {
                try locked {
                    state.requestFull(rootID:root.id,immediate:true,reason:"重新启用索引位置")
                    try persistState()
                }
            }
            for id in Set(before.map(\.id) + after.map(\.id)) where before.first(where:{$0.id == id}) != after.first(where:{$0.id == id}) {
                onIndexChange?(IndexChange(rootID:id,relativePaths:[""],fullRescan:true))
            }
        } catch { failure=error }
        locked { mutations -= 1 }
        completion(failure);onChange?();wakeWork()
    }
    private var interrupted: Bool { locked { stopped || paused || sleeping || mutations > 0 } }
    private var yielding: Bool { interrupted || locked { userActive } }
    private func emit(_ phase: String, _ detail: String = "", count: Int = 0, busy: Bool = false) {
        locked { announcedBusy=busy }
        onProgress?(IndexProgress(phase:phase,detail:detail,processed:count,busy:busy))
    }
    /// Caller holds the lock. Identical states are not rewritten.
    private func persistState() throws {
        // Claiming or finishing a path only removes entries. Re-folding
        // thousands of otherwise unchanged paths on every checkpoint can
        // keep the writer busy through an entire startup replay.
        for rootID in unfoldedPendingRoots where (state.roots[rootID]?.pending.count ?? 0) > 512 {
            foldPending(rootID)
        }
        announceRequests()
        let data=try state.encoded()
        stateDirty=true
        if data != lastPersisted {
            try IncrementalIndexState.write(data,to:stateURL)
            lastPersisted=data
        }
        stateDirty=false
    }
    /// Caller holds the lock. Only appending scopes can introduce overlap.
    private func enqueueScopes(_ paths: [String], rootID: String) {
        state.enqueue(paths,rootID:rootID)
        unfoldedPendingRoots.insert(rootID)
    }
    private func foldPending(_ rootID: String) {
        guard unfoldedPendingRoots.remove(rootID) != nil else {return}
        state.foldPending(rootID)
    }
    /// Caller holds the lock. Event checkpoints are written in batches: a crash
    /// before the write replays those events from the older durable cursor.
    private func persistSoon() {
        stateDirty=true
        guard persistWork == nil else { return }
        let item=DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.locked {
                self.persistWork=nil
                if self.stateDirty { try? self.persistState() }
            }
        }
        persistWork=item
        control.asyncAfter(deadline:.now()+30,execute:item)
    }
    @discardableResult
    private func refreshResources(force: Bool) -> IndexResourceState {
        let now=ProcessInfo.processInfo.systemUptime
        if !force, let cached=locked({ now-lastResourceCheck < resourceCheckInterval ? resourceState : nil }) { return cached }
        let value=resources()
        let changed=locked { () -> Bool in
            lastResourceCheck=now
            defer { resourceState=value }
            if value.constrained && !resourceState.constrained { contentEpoch &+= 1 }
            return resourceState != value
        }
        if changed {
            log.notice("background work \(value.constrained ? "deferred" : "resumed", privacy: .public): \(value.summary, privacy: .public)")
        }
        return value
    }
    /// Caller holds the lock.
    private func requestFull(_ rootID: String, immediate: Bool, reason: String) {
        state.requestFull(rootID:rootID,immediate:immediate,reason:reason)
        announceRequests()
    }
    /// Caller holds the lock. Logs whole-root requests, including ones made by state folding.
    private func announceRequests() {
        for request in state.announcements {
            let path=state.roots[request.rootID]?.path ?? request.rootID
            log.notice("whole-root rescan requested for \(path, privacy: .public) (\(request.immediate ? "immediate" : "deferred", privacy: .public)): \(request.reason, privacy: .public)")
        }
        state.announcements.removeAll()
    }

    /// Internal for fixtures: the inbox including changes not yet written, and whether a run is queued or active.
    var currentState: IncrementalIndexState { locked { state } }
    var isRunning: Bool { locked { running || activeClaims > 0 } }
    /// Lets the manually scheduled fixtures observe publication of a launched slice.
    func waitForContentSlice() {
        extractionJobs.wait()
        work.sync {}
    }

    /// Called by the watcher, and exposed internally for deterministic fixtures.
    /// Event IDs are checkpointed only together with their durable dirty scopes.
    func receiveEvents(_ events: [FileChangeEvent]) {
        // Resolve each root and each event path once, before taking the lock:
        // resolution walks the file system, and the scan checks the lock per file.
        let rootPaths=locked { state.roots.mapValues(\.path) }.mapValues(IndexPathFilter.canonicalPath)
        let filter=IndexPathFilter(ignoredPaths:ignoredPaths)
        let resolved=events.map { event -> (event: FileChangeEvent, path: String, ignored: Bool) in
            let path=IndexPathFilter.canonicalPath(event.path)
            return (event,path,filter.ignores(canonical:path))
        }
        locked {
            guard !stopped else {return}
            rootsNeedRefresh=true
            // FSEvents may coalesce/reorder IDs within one callback. Test
            // against the checkpoint from before this batch, not an ID
            // advanced by another path in the same callback.
            let cursors=state.roots.mapValues(\.cursor)
            var scopes:[String:[String]]=[:]
            var priority:[String:[String]]=[:]
            for (event,path,ignored) in resolved {
                let recovery=event.requiresFullScan
                var matched=false
                for (id,checkpoint) in state.roots {
                    if event.id > 0 && event.id <= (cursors[id] ?? 0) && !recovery { continue }
                    let rootPath=rootPaths[id] ?? IndexPathFilter.canonicalPath(checkpoint.path)
                    if event.idsWrapped {
                        matched=true
                        requestFull(id,immediate:false,reason:event.recoveryDescription)
                    } else if recovery || (event.mustScanSubDirs && !ignored) {
                        // Dropped events and coalesced subtrees name the directory
                        // to rescan; FSEvents reports each watched root separately.
                        if let relative=IndexRelativePath.from(canonical:path,canonicalRoot:rootPath) {
                            matched=true
                            if relative.isEmpty { requestFull(id,immediate:false,reason:event.recoveryDescription) }
                            else { scopes[id,default:[]].append(IndexRelativePath.packageScope(relative)) }
                        } else if recovery, IndexRelativePath.from(canonical:rootPath,canonicalRoot:path) != nil {
                            // The event names an ancestor of this root.
                            matched=true
                            requestFull(id,immediate:false,reason:event.recoveryDescription)
                        }
                    } else if !event.historyDone, !ignored,
                              let relative=IndexRelativePath.from(canonical:path,canonicalRoot:rootPath), !relative.isEmpty {
                        // An event for the root directory itself only concerns its own
                        // metadata; added and removed children report their own paths.
                        let scope=IndexRelativePath.packageScope(relative)
                        scopes[id,default:[]].append(scope)
                        if event.isExactFile {priority[id,default:[]].append(scope)}
                    }
                    // RootChanged can carry ID 0; never move a cursor back.
                    state.roots[id]?.cursor=max(checkpoint.cursor,event.id)
                }
                if recovery && !matched {
                    // A recovery event that names no root at all: reconcile every root.
                    for id in state.roots.keys { requestFull(id,immediate:false,reason:event.recoveryDescription) }
                }
            }
            for (id,paths) in scopes {enqueueScopes(paths,rootID:id)}
            for (id,paths) in priority {
                // Keep the remaining paths in the regular inbox if the small
                // priority queue fills during a bulk update.
                var queue=state.roots[id]?.priority ?? []
                var known=Set(queue)
                for path in paths where queue.count < 128 && known.insert(path).inserted {queue.append(path)}
                state.roots[id]?.priority=queue
            }
            announceRequests()
            persistSoon()
        }
        control.async { [weak self] in
            guard let self, self.debounce == nil, !self.locked({self.stopped}) else { return }
            let item=DispatchWorkItem { [weak self] in
                guard let self else { return };self.debounce=nil;self.wakeWork()
            }
            // The stream already batches for 500 ms. Coalesce adjacent
            // callbacks without adding a second of latency to each change.
            self.debounce=item;self.control.asyncAfter(deadline:.now()+0.2,execute:item)
        }
    }
    private func updateWatchers(_ roots: [IndexedRoot]) {
        guard watchEvents else { return }
        let paths=roots.filter { $0.enabled && $0.isOnline }.map(\.path).sorted()
        let since=locked { state.roots.values.map(\.cursor).min() ?? FSEventsGetCurrentEventId() }
        control.async { [weak self] in
            guard let self, !self.locked({self.stopped}), self.watchedPaths != paths || (self.watcher == nil && !paths.isEmpty) else { return }
            self.watchedPaths=paths
            self.watcher=FileWatcher(paths:paths,ignoredPaths:self.ignoredPaths,since:since,events:{ [weak self] in self?.receiveEvents($0) })
            if !paths.isEmpty && self.watcher?.isWatching != true {
                self.receiveEvents(paths.map { FileChangeEvent(path:$0,flags:UInt32(kFSEventStreamEventFlagUserDropped)) })
            }
        }
    }
    /// Returns the current roots and whether their identity or availability changed.
    private func refreshRoots(preferences prefs: IndexingPreferences) throws -> (roots: [IndexedRoot], changed: Bool) {
        var roots=try database.roots()
        var changed=false
        if prefs.autoAddExternal {
            for url in VolumeIdentity.externalVolumes() {
                if let candidate=try? VolumeIdentity.root(for:url),
                   !prefs.ignoredExternalVolumes.contains(candidate.volumeUUID ?? candidate.path),
                   !roots.contains(where:{$0.volumeUUID == candidate.volumeUUID && $0.isExternal}) {
                    try database.saveRoot(candidate);roots.append(candidate);changed=true
                }
            }
        }
        let ids=Set(roots.map(\.id))
        scanSessions=scanSessions.filter {ids.contains($0.key)}
        localTurn.formIntersection(ids)
        let manualFull=locked { () -> Bool in
            if fullRequested && Date() >= nextScanAfter {
                fullRequested=false
                nextScanAfter=Date().addingTimeInterval(rescanInterval)
                return true
            }
            return false
        }
        var refreshed:[IndexedRoot]=[]
        for existing in roots {
            let root=VolumeIdentity.refreshed(existing)
            if root != existing { changed=true }
            if root != existing {try database.saveRoot(root)}
            refreshed.append(root)
        }
        try locked {
            let oldRootCount=state.roots.count
            state.roots=state.roots.filter { ids.contains($0.key) }
            unfoldedPendingRoots.formIntersection(ids)
            var stateChanged=state.roots.count != oldRootCount || manualFull
            for root in refreshed {
                // An event batch can advance the cursor while mount probing
                // runs; read the event clock under the same lock.
                let currentID=FSEventsGetCurrentEventId()
                let existing=roots.first { $0.id == root.id }
                if let old=state.roots[root.id] {
                    if old.path != root.path || old.cursor > currentID || (existing?.isOnline == false && root.isOnline) {
                        stateChanged=true
                        state.roots[root.id]?.path=root.path
                        state.roots[root.id]?.cursor=currentID
                        scanSessions.removeValue(forKey:root.id)
                        requestFull(root.id,immediate:true,reason:old.path != root.path ? "索引位置路径变化" : old.cursor > currentID ? "文件事件编号重置" : "索引位置重新连接")
                    }
                } else {
                    // First installation/migration has no replay cursor. Seed
                    // before scanning, so events during the scan are durable.
                    stateChanged=true
                    state.roots[root.id] = .init(path:root.path,cursor:currentID,pending:[])
                    requestFull(root.id,immediate:true,reason:"首次建立索引")
                }
                if manualFull {
                    requestFull(root.id,immediate:true,reason:"手动重建索引")
                    // An explicit rebuild restarts a whole scan that is already running.
                    if state.roots[root.id]?.inFlight.contains("") == true {
                        state.roots[root.id]?.inFlight.removeAll { $0.isEmpty }
                        state.roots[root.id]?.runningFull=nil
                        scanSessions[root.id]?.removeValue(forKey:"")
                    }
                }
            }
            // Ordinary events retain their 30-second checkpoint batching.
            // A continuation with unchanged roots must not compact/encode and
            // flush that dirty inbox on every metadata time slice.
            if changed || stateChanged { try persistState() }
        }
        updateWatchers(refreshed)
        return (refreshed,changed)
    }
    /// Claim one exact change before advancing a broad traversal. Also record
    /// it in inFlight so an older Wumi can still replay it after a downgrade.
    private func nextPriorityScope(for root: IndexedRoot) throws -> String? {
        let candidate=locked {state.roots[root.id]?.priorityInFlight ?? state.roots[root.id]?.priority?.first}
        guard let path=candidate else {return nil}
        var info=stat()
        let absolute=URL(fileURLWithPath:root.path).appendingPathComponent(path).path
        let exact=lstat(absolute,&info) == 0 ? (info.st_mode & S_IFMT) != S_IFDIR : errno == ENOENT || errno == ENOTDIR
        return try locked {
            guard var entry=state.roots[root.id] else {return nil}
            if !exact {
                // The event became a directory or an unreadable path. Let
                // the ordinary sliced scanner reconcile it.
                entry.priority?.removeAll { $0 == path }
                if entry.priorityInFlight == path {
                    entry.priorityInFlight=nil
                    entry.inFlight.removeAll { $0 == path }
                    scanSessions[root.id]?.removeValue(forKey:path)
                }
                if !entry.pending.contains(path) {
                    entry.pending.append(path)
                    unfoldedPendingRoots.insert(root.id)
                }
            } else if entry.priorityInFlight != path {
                entry.priority?.removeAll { $0 == path }
                entry.pending.removeAll { $0 == path }
                // The exact event can replace a directory whose traversal
                // has already passed its own entry.
                scanSessions[root.id]?.removeValue(forKey:path)
                if !entry.inFlight.contains(path) {entry.inFlight.append(path)}
                entry.priorityInFlight=path
            }
            if entry.priority?.isEmpty == true {entry.priority=nil}
            state.roots[root.id]=entry
            try persistState()
            return exact ? path : nil
        }
    }
    /// At most one whole and one local session per root. Alternate them so
    /// neither an automatic whole scan nor a continuous event stream can starve
    /// the other. Pending paths remain durable until their own session completes.
    private func nextScope(for root: IndexedRoot, constrained: Bool, allowWhole: Bool = true) throws -> String? {
        try locked {
            // A live local session already owns its scope; do not repeatedly
            // sort a large inbox while just resuming that session.
            let priority=state.roots[root.id]?.priorityInFlight
            if state.roots[root.id]?.inFlight.contains(where:{ !$0.isEmpty && $0 != priority }) != true {
                foldPending(root.id);announceRequests()
            }
            guard var entry=state.roots[root.id] else { return nil }
            var changed=false
            let now=Date().timeIntervalSince1970
            if !entry.inFlight.contains(""), let full=entry.fullRescan,
               full.immediate || (!constrained && entry.lastFullScan.map { now-$0 >= fullRescanCooldown } ?? true) {
                entry.fullRescan=nil;entry.runningFull=full;entry.inFlight.append("");changed=true
                localTurn.insert(root.id)
                log.notice("whole-root scan started for \(root.path, privacy: .public): \(full.reason, privacy: .public)")
            }
            if !entry.inFlight.contains(where:{ !$0.isEmpty && $0 != entry.priorityInFlight }), !entry.pending.isEmpty {
                entry.inFlight.append(entry.pending.removeFirst());changed=true
            }
            state.roots[root.id]=entry
            if changed { try persistState() }
            let local=entry.inFlight.first { !$0.isEmpty && $0 != entry.priorityInFlight }
            if let local, !allowWhole || !entry.inFlight.contains("") || localTurn.contains(root.id) {
                localTurn.remove(root.id)
                return local
            }
            if allowWhole, entry.inFlight.contains("") { localTurn.insert(root.id);return "" }
            return nil
        }
    }
    private func hasMetadataWork(roots: [IndexedRoot], constrained: Bool) -> Bool {
        locked {
            let now=Date().timeIntervalSince1970
            return roots.contains { root in
                guard root.enabled,root.isOnline,let entry=state.roots[root.id] else { return false }
                if !entry.inFlight.isEmpty || !entry.pending.isEmpty || !(entry.priority ?? []).isEmpty { return true }
                guard let full=entry.fullRescan else { return false }
                return full.immediate || (!constrained && entry.lastFullScan.map { now-$0 >= fullRescanCooldown } ?? true)
            }
        }
    }
    private func prioritizeContent(root: IndexedRoot, scope: String, now: TimeInterval) throws {
        let key=ContentPath(rootID:root.id,path:scope)
        guard try database.pendingFile(rootID:root.id,path:scope) != nil else {
            freshContent.removeValue(forKey:key)
            return
        }
        if freshContent[key] == nil && freshContent.count >= 4096 {return}
        let first=freshContent[key]?.first ?? now
        freshContent[key]=FreshContent(first:first,ready:min(now+0.25,first+1))
    }

    private func contentAllowed(_ kind: FileKind, root: IndexedRoot, preferences: IndexingPreferences) -> Bool {
        guard root.enabled && root.isOnline else {return false}
        if kind == .image {return preferences.images && (!root.isExternal || preferences.externalImages)}
        return preferences.documents && (!root.isExternal || preferences.externalDocuments)
    }

    private func selectContent(lane: ContentLane, preferences: IndexingPreferences, now: TimeInterval) throws -> (IndexedRoot, FileRecord)? {
        let roots=Dictionary(uniqueKeysWithValues:currentRoots.map { ($0.id,$0) })
        var fresh: (IndexedRoot, FileRecord)?
        for (key, time) in freshContent.sorted(by:{ $0.value.first < $1.value.first }) where time.ready <= now {
            guard let root=roots[key.rootID], let file=try database.pendingFile(rootID:key.rootID,path:key.path) else {
                freshContent.removeValue(forKey:key)
                continue
            }
            if Self.isHeavy(file) == (lane == .heavy), contentAllowed(file.kind,root:root,preferences:preferences) {
                fresh=(root,file)
                break
            }
        }
        let freshRun=freshRuns[lane,default:0]
        if let fresh, freshRun < 3 {freshRuns[lane]=freshRun+1;return fresh}

        let kinds:[FileKind]=lane == .heavy ? [.image,.document] : [.document,.code]
        let pools=currentRoots.flatMap { root in
            kinds.filter {contentAllowed($0,root:root,preferences:preferences)}.map { (root,$0) }
        }
        for _ in pools {
            let cursor=contentCursors[lane,default:0] % pools.count
            contentCursors[lane]=(cursor+1)%pools.count
            let (root,kind)=pools[cursor]
            let pool=ContentPool(rootID:root.id,lane:lane,kind:kind)
            var after=pendingLowerBounds[pool,default:0]
            guard after != Int64.max else {continue}
            var firstPage=true
            while true {
                let pending=try database.pendingFiles(rootID:root.id,limit:32,kind:kind,heavy:lane == .heavy,afterID:after)
                if firstPage {
                    pendingLowerBounds[pool]=pending.first.map { $0.id-1 } ?? Int64.max
                    firstPage=false
                }
                if let row=pending.first(where:{freshContent[ContentPath(rootID:root.id,path:$0.relativePath)] == nil}) {
                    freshRuns[lane]=0
                    return (root,row)
                }
                guard let last=pending.last, pending.count == 32 else {break}
                after=last.id
            }
        }
        if fresh != nil {freshRuns[lane]=1}
        return fresh
    }

    private func launchContent(preferences: IndexingPreferences, epoch: UInt64) throws {
        let now=ProcessInfo.processInfo.systemUptime
        for lane in ContentLane.allCases where claims[lane] == nil && !yielding {
            guard let (root,file)=try selectContent(lane:lane,preferences:preferences,now:now) else {continue}
            let key=ContentPath(rootID:root.id,path:file.relativePath)
            let claim=ContentClaim(key:key,root:root,file:file,epoch:epoch)
            let accepted=locked { () -> Bool in
                guard canCommit(claim), !userActive else {return false}
                activeClaims += 1
                return true
            }
            guard accepted else {return}
            claims[lane]=claim
            let worker=lane == .heavy ? heavyWorker : lightWorker
            emit(file.kind == .image ? "正在识别图片" : "正在提取文档",file.name,busy:true)
            extractionJobs.enter()
            worker.async {
                defer {self.extractionJobs.leave()}
                let result=autoreleasepool { self.extract(claim) }
                self.work.async {
                    autoreleasepool { self.finishContent(lane:lane,claim:claim,result:result) }
                }
            }
        }
        let next=freshContent.values.lazy.map(\.ready).filter{$0 > now}.min()
        if next != contentWakeDeadline {
            contentWake?.cancel()
            contentWake=nil
            contentWakeDeadline=next
            if let next {
                let item=DispatchWorkItem { [weak self] in
                    self?.contentWakeDeadline=nil
                    self?.wakeWork(refreshRoots:false)
                }
                contentWake=item
                work.asyncAfter(deadline:.now()+max(0,next-now),execute:item)
            }
        }
    }

    private func claimCancelled(_ claim: ContentClaim) -> Bool {
        locked { !canCommit(claim) }
    }

    // Called with the lifecycle lock held.
    private func canCommit(_ claim: ContentClaim) -> Bool {
        contentEpoch == claim.epoch && !stopped && !paused && !sleeping && mutations == 0 && !resourceState.constrained
    }

    private enum ChangeStamp: Equatable {
        case present(device: Int32,inode: UInt64,seconds: Int,nanoseconds: Int)
        case inaccessible(Int32)

        var disappeared: Bool { self == .inaccessible(ENOENT) || self == .inaccessible(ENOTDIR) }
    }

    private func stamp(_ url: URL) -> ChangeStamp {
        var info=stat()
        guard lstat(url.path,&info) == 0 else {return .inaccessible(errno)}
        return .present(device:info.st_dev,inode:info.st_ino,seconds:info.st_ctimespec.tv_sec,nanoseconds:info.st_ctimespec.tv_nsec)
    }

    private func extract(_ claim: ContentClaim) -> (ExtractionResult, ChangeStamp?) {
        let url=URL(fileURLWithPath:claim.root.path).appendingPathComponent(claim.key.path)
        guard !claimCancelled(claim) else {return (.interrupted,nil)}
        let before=stamp(url)
        do {
            guard try FileSignature.read(url).matches(claim.file) else {return (.changed,before)}
            let reuse = Self.isHeavy(claim.file) ? extractionReuse : nil
            let key = reuse == nil ? nil : ExtractionReuse.key(url,file:claim.file,cancelled:{self.claimCancelled(claim)})
            if let key, let raw=reuse?.get(key) {
                guard stamp(url) == before else {return (.changed,before)}
                return (.done(raw),before)
            }
            guard !claimCancelled(claim) else {return (.interrupted,nil)}
            let content=try extractor(url,{ self.claimCancelled(claim) })
            guard !claimCancelled(claim) else {return (.interrupted,nil)}
            guard stamp(url) == before, try FileSignature.read(url).matches(claim.file) else {return (.changed,before)}
            let raw=try JSONEncoder().encode(content)
            if let key, content.warning == nil {reuse?.save(raw,for:key)}
            return (.done(raw),before)
        } catch {
            guard !claimCancelled(claim) else {return (.interrupted,nil)}
            let after=stamp(url)
            if after != before || after.disappeared {return (.changed,before)}
            return (.failed(error.localizedDescription),before)
        }
    }

    private func finishContent(lane: ContentLane, claim: ContentClaim, result: (ExtractionResult, ChangeStamp?)) {
        defer {
            claims.removeValue(forKey:lane)
            locked {activeClaims -= 1}
            wakeWork(refreshRoots:false)
        }
        guard !claimCancelled(claim) else {return}
        let current=VolumeIdentity.refreshed(claim.root)
        guard current.isOnline, current.path == claim.root.path else {
            locked { rootsNeedRefresh=true }
            return
        }
        let url=URL(fileURLWithPath:current.path).appendingPathComponent(claim.key.path)
        do {
            var changed=false
            switch result.0 {
            case .interrupted: return
            case .changed:
                recheckChangedContent(claim,url:url)
                return
            case .done(let raw):
                guard stamp(url) == result.1 else {recheckChangedContent(claim,url:url);return}
                guard !claimCancelled(claim) else {return}
                changed=try database.completeContent(file:claim.file,raw:raw,requirePending:true)
            case .failed(let message):
                guard stamp(url) == result.1 else {recheckChangedContent(claim,url:url);return}
                guard !claimCancelled(claim) else {return}
                changed=try database.failPendingContent(file:claim.file,message:message)
            }
            if changed {
                freshContent.removeValue(forKey:claim.key)
                onContentChange?()
                onChange?()
            }
        } catch {emit("索引遇到问题",error.localizedDescription)}
    }

    private func recheckChangedContent(_ claim: ContentClaim, url: URL) {
        // Put the rescan ahead of another extraction attempt against the
        // obsolete row. The scan will submit the latest stable signature.
        let now=ProcessInfo.processInfo.systemUptime
        freshContent[claim.key]=FreshContent(first:freshContent[claim.key]?.first ?? now,ready:now+1)
        receiveEvents([FileChangeEvent(path:url.path,flags:FileChangeEvent.exactFileFlag)])
    }

    /// Scans one scope to completion, suspension (yielding) or abandonment (power constraints).
    private func scan(scope: String, root: IndexedRoot, preferences prefs: IndexingPreferences, deadline: TimeInterval, maximumItems: Int, priority: Bool = false) throws -> Int {
        let options=ScanOptions(includeHidden:prefs.includeHidden,excludeDevelopmentCaches:prefs.excludeDevelopmentCaches)
        let session:FileScanSession
        if let live=scanSessions[root.id]?[scope],!live.finished,live.matches(root:root,scope:scope,options:options) {session=live}
        else {
            guard let current=try database.indexedRoot(id:root.id) else {return 0}
            session=try FileScanner(database:database,ignoredPaths:ignoredPaths).session(root:current,relativePath:scope,options:options)
            scanSessions[root.id,default:[:]][scope]=session
        }
        let whole=scope.isEmpty
        if !whole, locked({ state.roots[root.id]?.inFlight.contains("") == true }) {
            // A local scope may be chosen before the whole scan's first turn.
            // Create its bookkeeping now so its later prune sees this scope too.
            if scanSessions[root.id]?[""]?.matches(root:root,scope:"",options:options) != true {
                scanSessions[root.id,default:[:]][""]=try FileScanner(database:database,ignoredPaths:ignoredPaths).session(root:root,relativePath:"",options:options)
            }
            scanSessions[root.id]?[""]?.preserveReconciledScope(scope)
        }
        if priority, let sessions=scanSessions[root.id] {
            for (other,active) in sessions where other != scope && IndexRelativePath.contains(other,scope) {
                active.preserveReconciledScope(scope)
            }
        }
        // Only automatic reconciliations give way to battery, Low Power Mode and heat.
        let deferrable=whole && !(locked { state.roots[root.id]?.runningFull?.immediate } ?? true)
        let phase=whole ? "正在建立文件目录" : "正在更新文件目录", detail=whole ? root.name : scope
        emit(phase,detail,count:session.checkpoint.count,busy:true)
        let change=IndexChange(rootID:root.id,relativePaths:[scope],fullRescan:whole)
        var announcedWrites=session.writes.inserted+session.writes.updated+session.writes.metadataWrites
        var announcedContentInvalidations=session.writes.contentInvalidations
        let initialWrites=session.writes
        func announceContentInvalidations() {
            guard session.writes.contentInvalidations != announcedContentInvalidations else {return}
            announcedContentInvalidations=session.writes.contentInvalidations
            onContentChange?()
        }
        // A later scan error must not hide a preceding committed batch's invalidation.
        defer {
            announceContentInvalidations()
            if session.writes.inserted != initialWrites.inserted || session.writes.updated != initialWrites.updated {
                pendingLowerBounds=pendingLowerBounds.filter { $0.key.rootID != root.id }
            }
        }
        let previousPruned=session.pruned
        let result=try session.advance(cancelled:{
            self.yielding || (deferrable && self.refreshResources(force:false).constrained)
        },shouldYield:{ self.scheduling.now() >= deadline },maximumItems:maximumItems) { count in
            guard !self.yielding else { return }
            self.emit(phase,detail,count:count,busy:true)
            announceContentInvalidations()
            // An unchanged rescan confirms seen IDs without changing the
            // catalog. Avoid waking every search view for those checkpoints.
            let writes=session.writes.inserted+session.writes.updated+session.writes.metadataWrites
            if writes != announcedWrites {
                announcedWrites=writes
                self.onIndexChange?(IndexChange(rootID:root.id,relativePaths:[scope],fullRescan:false))
                self.onChange?()
            }
        }
        let committedWrites=session.writes.inserted+session.writes.updated+session.writes.metadataWrites
        if committedWrites != announcedWrites || session.pruned != previousPruned {
            autoreleasepool { self.onIndexChange?(change);self.onChange?() }
        }
        if !session.rootAvailable {
            locked {rootsNeedRefresh=true}
        }
        if session.finished {
            try locked {
                // Incoming events go to a separate inbox while this scope is
                // inFlight. A long first scan can finish even under continuous
                // file changes.
                state.roots[root.id]?.inFlight.removeAll { $0 == scope }
                if state.roots[root.id]?.priorityInFlight == scope {state.roots[root.id]?.priorityInFlight=nil}
                if !result.complete {
                    // Retry unreadable children once; a scope that itself cannot be
                    // read waits for its next event instead of retrying every run.
                    let retry=result.preservingPaths.filter { $0 != scope }
                    if !retry.isEmpty {enqueueScopes(retry,rootID:root.id)}
                }
                if whole {
                    state.roots[root.id]?.lastFullScan=Date().timeIntervalSince1970
                    state.roots[root.id]?.runningFull=nil
                }
                try persistState()
            }
            scanSessions[root.id]?.removeValue(forKey:scope)
            if !whole {try prioritizeContent(root:root,scope:scope,now:ProcessInfo.processInfo.systemUptime) }
            let seconds=ProcessInfo.processInfo.systemUptime-session.startedAt
            let writes=session.writes
            if whole {
                log.notice("whole-root scan finished for \(root.path, privacy: .public): \(result.count) items in \(Int(seconds))s, inserted \(writes.inserted), updated \(writes.updated), unchanged \(writes.unchanged), metadata \(writes.metadataWrites), pruned \(session.pruned), errors \(result.errors.count)")
            } else {
                log.debug("scope scan finished: \(result.count) items, inserted \(writes.inserted), updated \(writes.updated), pruned \(session.pruned)")
            }
        } else if deferrable && !yielding && refreshResources(force:false).constrained {
            // Abandoned rather than suspended: a later scan restarts from the root,
            // and its prune relies on IDs seen within one session.
            try locked {
                let request=state.roots[root.id]?.runningFull
                state.roots[root.id]?.inFlight.removeAll { $0.isEmpty }
                state.roots[root.id]?.runningFull=nil
                requestFull(root.id,immediate:false,reason:request?.reason ?? "电源受限时中止的整盘扫描")
                try persistState()
            }
            scanSessions[root.id]?.removeValue(forKey:scope)
            let summary=locked { resourceState.summary }
            log.notice("whole-root scan deferred for \(root.path, privacy: .public) after \(result.count) items: \(summary, privacy: .public)")
        }
        if !result.errors.isEmpty && !yielding { emit("部分位置无法读取",result.errors[0]) }
        if whole && session.finished { locked { nextScanAfter=Date().addingTimeInterval(rescanInterval) } }
        return session.visitedLastAdvance
    }
    private func run() {
        let activity=ProcessInfo.processInfo.beginActivity(options:.background,reason:"在本机建立文件全文和图片索引")
        var continuation=false
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            let plan=locked { () -> (TimeInterval, DispatchWorkItem)? in
                executing=false;running=false
                guard canRunLocked else { return nil }
                if continuation || requested { return prepareRunLocked(after:scheduling.continuationDelay) }
                if fullRequested { return prepareRunLocked(after:max(scheduling.continuationDelay,nextScanAfter.timeIntervalSinceNow)) }
                return nil
            }
            enqueue(plan)
        }
        do {
            guard !yielding else { return }
            let (prefs,refresh)=locked { () -> (IndexingPreferences,Bool) in
                requested=false
                let refresh=rootsNeedRefresh || (fullRequested && Date() >= nextScanAfter)
                rootsNeedRefresh=false
                return (preferences,refresh)
            }
            if refresh {
                pendingLowerBounds.removeAll()
                let refreshed=try refreshRoots(preferences:prefs)
                currentRoots=refreshed.roots
                if refreshed.changed {onChange?()}
            }
            let roots=currentRoots
            let constrained=refreshResources(force:refresh).constrained
            let deadline=scheduling.now()+scheduling.metadataSeconds
            let eligible=roots.filter { $0.enabled && $0.isOnline }
            // Share one deadline and item budget across all roots and scopes.
            // Completed small scopes can drain within the same slice; they do
            // not each pay the continuation delay. Missing scopes cost one item
            // too, so deletion-only queues cannot bypass the global bound.
            var remainingItems=max(1,scheduling.metadataItems)
            // Bound priority work independently and share the ordinary slice
            // budget, leaving time for a primary scan even under event storms.
            let priorityRoots=locked {
                eligible.filter { root in
                    guard let entry=state.roots[root.id] else {return false}
                    return entry.priorityInFlight != nil || !(entry.priority ?? []).isEmpty
                }
            }
            if !priorityRoots.isEmpty {
                let priorityLimit=remainingItems == 1 ? (priorityTurn ? 1 : 0) : min(4,remainingItems/2)
                priorityTurn.toggle()
                for turn in 0..<priorityLimit where !yielding && scheduling.now() < deadline {
                    let root=priorityRoots[(rootCursor+turn)%priorityRoots.count]
                    if let scope=try nextPriorityScope(for:root) {
                        let count=try scan(scope:scope,root:root,preferences:prefs,deadline:deadline,maximumItems:1,priority:true)
                        remainingItems -= max(1,count)
                    }
                }
            }
            var advancedWhole=Set<String>()
            let hasLocalWork=locked {
                eligible.contains { root in
                    guard let entry=state.roots[root.id] else { return false }
                    return !entry.pending.isEmpty || entry.inFlight.contains(where:{ !$0.isEmpty })
                }
            }
            var remainingWholeItems=hasLocalWork ? max(1,remainingItems/2) : remainingItems
            // Rotate the starting root independently of how many cheap scopes
            // happen to fit, so the same whole root cannot win every slice.
            let nextSliceRoot=eligible.isEmpty ? 0 : (rootCursor+1) % eligible.count
            var idleRoots=0
            while !eligible.isEmpty && !yielding && remainingItems > 0 && idleRoots < eligible.count && scheduling.now() < deadline {
                let index=rootCursor % eligible.count
                let root=eligible[index]
                rootCursor=(index+1) % eligible.count
                guard let scope=try nextScope(for:root,constrained:constrained,allowWhole:remainingWholeItems > 0 && !advancedWhole.contains(root.id)) else {
                    idleRoots += 1
                    continue
                }
                idleRoots=0
                // The whole-work quota is shared by every root, leaving room
                // for many local scopes even when several full scans are live.
                let limit=scope.isEmpty ? min(remainingItems,remainingWholeItems) : remainingItems
                let count=try scan(scope:scope,root:root,preferences:prefs,deadline:deadline,maximumItems:limit)
                remainingItems -= max(1,count)
                if scope.isEmpty {
                    remainingWholeItems -= max(1,count)
                    advancedWhole.insert(root.id)
                }
            }
            rootCursor=nextSliceRoot
            // Start at most one claim per lane. The writer remains free to
            // publish directory changes while an expensive helper runs.
            if !yielding && !constrained {
                let claimPolicy=locked { (preferences,contentEpoch) }
                try launchContent(preferences:claimPolicy.0,epoch:claimPolicy.1)
            }
            continuation=hasMetadataWork(roots:roots,constrained:refreshResources(force:false).constrained)
            let waitingForContent = !constrained && (!claims.isEmpty || contentWakeDeadline != nil)
            if !continuation && !waitingForContent && !yielding {
                if locked({announcedBusy}) { emit("索引已更新","新增或修改文件后会自动更新") }
            }
        } catch {
            locked {rootsNeedRefresh=true}
            emit("索引遇到问题",error.localizedDescription)
            onChange?()
        }
    }
}
