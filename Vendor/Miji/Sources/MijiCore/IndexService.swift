import Foundation
import AppKit
import CoreServices
import IOKit.ps
import os

public struct IndexProgress: Sendable {
    public var phase: String
    public var detail: String
    public var processed: Int
    public var busy: Bool
    public init(phase: String = "准备就绪", detail: String = "", processed: Int = 0, busy: Bool = false) { self.phase=phase; self.detail=detail; self.processed=processed; self.busy=busy }
}
public struct IndexingPreferences: Codable, Sendable {
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
    public var onIndexChange: ((IndexChange) -> Void)?
    private let lock = NSLock()
    // Background QoS runs on efficiency cores with throttled disk I/O, so indexing
    // yields to whatever the user is doing.
    private let work = DispatchQueue(label: "local.miji.index", qos: .background)
    private let control = DispatchQueue(label: "local.miji.control", qos: .utility)
    private let log = Logger(subsystem: "local.miji", category: "index")
    private var running = false
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
    private var scanSessions: [String:FileScanSession] = [:]
    // Whether the last progress report said "busy"; a quiet run must still clear it.
    private var announcedBusy = false
    private var timer: DispatchSourceTimer?
    private var debounce: DispatchWorkItem?
    private var persistWork: DispatchWorkItem?
    private var stateDirty = false
    private var lastPersisted: Data?
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
    private let contentClock: () -> TimeInterval
    // Only accessed on work. Keep both roots and content kinds moving, even
    // when a slow image consumes the entire time slice by itself.
    private var contentLaneCursor = 0
    private let contentBatchLimit = 6
    private let contentBatchSeconds: TimeInterval = 0.25
    public convenience init(database: SearchDatabase, ignoredPaths: [String] = [], extractionWorker: URL? = nil) {
        self.init(database:database,ignoredPaths:ignoredPaths,extractor: { url,cancelled in
            let ext=url.pathExtension.lowercased()
            if let extractionWorker, FileKind.classify(extension:ext) == .image || ["pdf","pages","numbers","key","keynote"].contains(ext) {
                return try IsolatedContentExtractor.extract(url:url,executable:extractionWorker,cancelled:cancelled)
            }
            return try ContentExtractor.extract(url:url,cancelled:cancelled)
        })
    }
    init(database: SearchDatabase, ignoredPaths: [String] = [], extractor: @escaping (URL, @escaping () -> Bool) throws -> ExtractedContent,
         contentClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         watchEvents: Bool = true, stateURL: URL? = nil, fullRescanCooldown: TimeInterval = 30 * 60,
         resources: (() -> IndexResourceState)? = nil, resourceCheckInterval: TimeInterval = 5) {
        self.database = database
        let inboxURL=stateURL ?? database.url.appendingPathExtension("incremental.json")
        self.stateURL=inboxURL
        var state=IncrementalIndexState.read(inboxURL)
        state.migrateInterruptedScans()
        self.state=state
        self.watchEvents=watchEvents
        self.ignoredPaths = ignoredPaths + [inboxURL.path,inboxURL.appendingPathExtension("tmp").path]
        self.extractor = extractor
        self.contentClock = contentClock
        self.fullRescanCooldown = fullRescanCooldown
        self.resources = resources ?? IndexResourceState.current
        self.resourceCheckInterval = resourceCheckInterval
    }
    private func locked<T>(_ block: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try block() }
    public func configure(_ preferences: IndexingPreferences) {
        let rescan=locked { () -> Bool in
            let changed=self.preferences.includeHidden != preferences.includeHidden || self.preferences.excludeDevelopmentCaches != preferences.excludeDevelopmentCaches
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
        locked { stopped=true }
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
        work.sync {}
        locked {
            persistWork?.cancel();persistWork=nil
            if stateDirty { try? persistState() }
        }
    }
    public func setPaused(_ value: Bool) {
        locked { paused=value }
        if value { emit("已暂停","搜索现有索引仍然可用") } else { wakeWork() }
    }
    /// Finish the current valid extraction, then yield metadata and content work
    /// while the user is typing. No completed result is discarded to yield.
    public func setUserActive(_ value: Bool) { locked { userActive=value }; if !value { wakeWork() } }
    func setSystemSleeping(_ value: Bool) { locked { sleeping=value }; if !value { wakeWork() } }
    /// Explicit refresh remains a full reconciliation, with storm coalescing.
    public func requestScan() { locked { fullRequested=true }; wakeWork() }
    public func requestIncrementalUpdate() { wakeWork() }
    private func resourcesMayHaveChanged() {
        refreshResources(force:true)
        wakeWork()
    }
    private func wakeWork() {
        let delay=locked { () -> TimeInterval? in
            requested=true
            guard !running, !stopped, !paused, !sleeping, !userActive, mutations == 0 else { return nil }
            running=true
            return fullRequested ? max(0,nextScanAfter.timeIntervalSinceNow) : 0
        }
        if let delay { work.asyncAfter(deadline:.now()+delay) { [weak self] in self?.run() } }
    }
    public func mutate(_ action: @escaping (SearchDatabase) throws -> Void, completion: @escaping (Error?) -> Void = {_ in}) {
        locked { mutations += 1 }
        work.async { [weak self] in
            guard let self else { return }
            var failure:Error?
            do {
                let before=try self.database.roots()
                try action(self.database)
                let after=try self.database.roots()
                // A disabled root has no active watcher. Re-enabling it must
                // reconcile changes made while it was outside the stream.
                for root in after where root.enabled && before.contains(where:{$0.id == root.id && !$0.enabled}) {
                    try self.locked {
                        self.state.requestFull(rootID:root.id,immediate:true,reason:"重新启用索引位置")
                        try self.persistState()
                    }
                }
                for id in Set(before.map(\.id) + after.map(\.id)) where before.first(where:{$0.id == id}) != after.first(where:{$0.id == id}) {
                    self.onIndexChange?(IndexChange(rootID:id,relativePaths:[""],fullRescan:true))
                }
            } catch { failure=error }
            self.locked { self.mutations -= 1 }
            completion(failure);self.onChange?();self.wakeWork()
        }
    }
    private var interrupted: Bool { locked { stopped || paused || sleeping || mutations > 0 } }
    private var yielding: Bool { interrupted || locked { userActive } }
    private var contentInterrupted: Bool { interrupted || locked { resourceState.constrained } }
    private func emit(_ phase: String, _ detail: String = "", count: Int = 0, busy: Bool = false) {
        locked { announcedBusy=busy }
        onProgress?(IndexProgress(phase:phase,detail:detail,processed:count,busy:busy))
    }
    /// Caller holds the lock. Identical states are not rewritten.
    private func persistState() throws {
        state.compactPending(above:512)
        announceRequests()
        let data=try state.encoded()
        stateDirty=false
        guard data != lastPersisted else { return }
        try IncrementalIndexState.write(data,to:stateURL)
        lastPersisted=data
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
    var isRunning: Bool { locked { running } }

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
            // FSEvents may coalesce/reorder IDs within one callback. Test
            // against the checkpoint from before this batch, not an ID
            // advanced by another path in the same callback.
            let cursors=state.roots.mapValues(\.cursor)
            var scopes:[String:[String]]=[:]
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
                        scopes[id,default:[]].append(IndexRelativePath.packageScope(relative))
                    }
                    // RootChanged can carry ID 0; never move a cursor back.
                    state.roots[id]?.cursor=max(checkpoint.cursor,event.id)
                }
                if recovery && !matched {
                    // A recovery event that names no root at all: reconcile every root.
                    for id in state.roots.keys { requestFull(id,immediate:false,reason:event.recoveryDescription) }
                }
            }
            for (id,paths) in scopes {state.enqueue(paths,rootID:id)}
            announceRequests()
            persistSoon()
        }
        control.async { [weak self] in
            guard let self, self.debounce == nil, !self.locked({self.stopped}) else { return }
            let item=DispatchWorkItem { [weak self] in
                guard let self else { return };self.debounce=nil;self.wakeWork()
            }
            // FSEvents already batches for a second; one run per second is enough.
            self.debounce=item;self.control.asyncAfter(deadline:.now()+1,execute:item)
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
        let currentID=FSEventsGetCurrentEventId()
        let ids=Set(roots.map(\.id))
        scanSessions=scanSessions.filter {ids.contains($0.key)}
        let manualFull=locked { () -> Bool in
            if fullRequested && Date() >= nextScanAfter { fullRequested=false;return true }
            return false
        }
        var refreshed:[IndexedRoot]=[]
        for existing in roots {
            let root=VolumeIdentity.refreshed(existing)
            if root != existing { changed=true }
            try database.saveRoot(root)
            refreshed.append(root)
        }
        try locked {
            state.roots=state.roots.filter { ids.contains($0.key) }
            for root in refreshed {
                let existing=roots.first { $0.id == root.id }
                if let old=state.roots[root.id] {
                    if old.path != root.path || old.cursor > currentID || (existing?.isOnline == false && root.isOnline) {
                        state.roots[root.id]?.path=root.path
                        state.roots[root.id]?.cursor=currentID
                        requestFull(root.id,immediate:true,reason:old.path != root.path ? "索引位置路径变化" : old.cursor > currentID ? "文件事件编号重置" : "索引位置重新连接")
                    }
                } else {
                    // First installation/migration has no replay cursor. Seed
                    // before scanning, so events during the scan are durable.
                    state.roots[root.id] = .init(path:root.path,cursor:currentID,pending:[])
                    requestFull(root.id,immediate:true,reason:"首次建立索引")
                }
                if manualFull {
                    requestFull(root.id,immediate:true,reason:"手动重建索引")
                    // An explicit rebuild restarts a whole scan that is already running.
                    if state.roots[root.id]?.inFlight == [""] {
                        state.roots[root.id]?.inFlight=[]
                        state.roots[root.id]?.runningFull=nil
                        scanSessions.removeValue(forKey:root.id)
                    }
                }
            }
            try persistState()
        }
        updateWatchers(refreshed)
        return (refreshed,changed)
    }
    /// Decides this root's next scopes: an unfinished batch first, then a due
    /// whole-root scan, then the path inbox. Paths waiting when a whole-root scan
    /// starts stay queued: the scan may be abandoned before it reaches them.
    private func nextScopes(for root: IndexedRoot, constrained: Bool) throws -> [String] {
        try locked { () throws -> [String] in
            // Fold the inbox first: an overflowing one turns into a whole-root request here.
            if state.roots[root.id]?.inFlight.isEmpty == true { state.foldPending(root.id); announceRequests() }
            guard var entry=state.roots[root.id] else { return [] }
            if !entry.inFlight.isEmpty {
                // Drain arrivals saved behind this batch afterwards. New arrivals
                // still use the normal debounce, so a file changing during
                // extraction cannot busy-loop.
                if !entry.pending.isEmpty { requested=true }
                return entry.inFlight
            }
            let now=Date().timeIntervalSince1970
            if let full=entry.fullRescan,
               full.immediate || (!constrained && entry.lastFullScan.map { now-$0 >= fullRescanCooldown } ?? true) {
                entry.fullRescan=nil
                entry.runningFull=full
                entry.inFlight=[""]
                if !entry.pending.isEmpty { requested=true }
                state.roots[root.id]=entry
                try persistState()
                log.notice("whole-root scan started for \(root.path, privacy: .public): \(full.reason, privacy: .public)")
                return [""]
            }
            guard !entry.pending.isEmpty else { return [] }
            entry.inFlight=entry.pending
            entry.pending=[]
            state.roots[root.id]=entry
            try persistState()
            return entry.inFlight
        }
    }
    /// A bounded slice shared by startup, scan checkpoints and the final drain.
    /// The deadline is checked between files: cancelling an otherwise valid OCR
    /// for scheduling would discard its work and repeatedly starve that file.
    private func drainContent(roots: [IndexedRoot], preferences prefs: IndexingPreferences) throws -> Bool {
        // Includes metadata validation and database encoding, not just Vision.
        try autoreleasepool { try drainContentBatch(roots:roots,preferences:prefs) }
    }
    private func drainContentBatch(roots: [IndexedRoot], preferences prefs: IndexingPreferences) throws -> Bool {
        var lanes: [(root: IndexedRoot, kind: FileKind)] = []
        for root in roots where root.enabled && root.isOnline {
            if prefs.documents && (!root.isExternal || prefs.externalDocuments) { lanes.append((root,.document)) }
            if prefs.images && (!root.isExternal || prefs.externalImages) { lanes.append((root,.image)) }
            if prefs.documents && (!root.isExternal || prefs.externalDocuments) { lanes.append((root,.code)) }
        }
        guard !lanes.isEmpty else { return false }
        let deadline=contentClock() + contentBatchSeconds
        var handled=false, attempts=0, emptyLanes=0
        var offlineRoots=Set<String>()
        while !yielding && !contentInterrupted && attempts < contentBatchLimit && emptyLanes < lanes.count {
            // Empty-lane lookups must not turn a time slice into a false idle
            // result while another kind/root still has pending work.
            if attempts > 0 && contentClock() >= deadline { break }
            let lane=lanes[contentLaneCursor % lanes.count]
            contentLaneCursor=(contentLaneCursor + 1) % lanes.count
            let root=VolumeIdentity.refreshed(lane.root)
            guard !offlineRoots.contains(root.id), root.isOnline,
                  let file=try database.pendingFiles(rootID:root.id,limit:1,kind:lane.kind).first else {
                emptyLanes += 1; continue
            }
            emptyLanes=0; attempts += 1
            if contentInterrupted { break }
            emit(lane.kind == .image ? "正在识别图片" : "正在提取文档",file.name,busy:true)
            // onProgress may synchronously pause, stop or enqueue a mutation.
            if yielding { break }
            let url=URL(fileURLWithPath:root.path).appendingPathComponent(file.relativePath)
            do {
                let content=try autoreleasepool { try extractor(url,{ self.contentInterrupted }) }
                if contentInterrupted { break }
                guard VolumeIdentity.refreshed(root).isOnline else {
                    offlineRoots.insert(root.id); wakeWork(); continue
                }
                if try !FileSignature.read(url).matches(file) {
                    try database.failContent(file:file,message:"文件正在修改，将在下次扫描后重试")
                    handled=true; receiveEvents([FileChangeEvent(path:url.path)]); onChange?(); continue
                }
                _ = try database.completeContent(file:file,content:content)
                handled=true
            } catch {
                if contentInterrupted { break }
                if !VolumeIdentity.refreshed(root).isOnline {
                    offlineRoots.insert(root.id); wakeWork(); continue
                }
                try database.failContent(file:file,message:error.localizedDescription)
                handled=true
            }
            onChange?()
        }
        return handled
    }
    /// Scans one scope to completion, suspension (yielding) or abandonment (power constraints).
    private func scan(scope: String, root: IndexedRoot, roots: [IndexedRoot], preferences prefs: IndexingPreferences) throws {
        let options=ScanOptions(includeHidden:prefs.includeHidden,excludeDevelopmentCaches:prefs.excludeDevelopmentCaches)
        let session:FileScanSession
        if let live=scanSessions[root.id],!live.finished,live.matches(root:root,scope:scope,options:options) {session=live}
        else {
            session=try FileScanner(database:database,ignoredPaths:ignoredPaths).session(root:root,relativePath:scope,options:options)
            scanSessions[root.id]=session
        }
        let whole=scope.isEmpty
        // Only automatic reconciliations give way to battery, Low Power Mode and heat.
        let deferrable=whole && !(locked { state.roots[root.id]?.runningFull?.immediate } ?? true)
        let phase=whole ? "正在建立文件目录" : "正在更新文件目录", detail=whole ? root.name : scope
        emit(phase,detail,count:session.checkpoint.count,busy:true)
        var contentFailure:Error?
        let change=IndexChange(rootID:root.id,relativePaths:[scope],fullRescan:whole)
        let result=try session.advance(cancelled:{
            self.yielding || contentFailure != nil || (deferrable && self.refreshResources(force:false).constrained)
        }) { count in
            guard !self.yielding,contentFailure == nil else { return }
            self.emit(phase,detail,count:count,busy:true)
            // The committed ID journal makes a batch refresh
            // bounded even while the first whole-root scan runs.
            self.onIndexChange?(IndexChange(rootID:root.id,relativePaths:[scope],fullRescan:false))
            self.onChange?()
            if !self.refreshResources(force:false).constrained {
                do { _=try self.drainContent(roots:roots,preferences:prefs) } catch { contentFailure=error }
            }
            if !self.yielding && contentFailure == nil { self.emit(phase,detail,count:count,busy:true) }
        }
        if let contentFailure { throw contentFailure }
        autoreleasepool { self.onIndexChange?(change);self.onChange?() }
        if session.finished {
            try locked {
                // Incoming events go to a separate inbox while this scope is
                // inFlight. A long first scan can finish even under continuous
                // file changes.
                state.roots[root.id]?.inFlight.removeAll { $0 == scope }
                if !result.complete {
                    // Retry unreadable children once; a scope that itself cannot be
                    // read waits for its next event instead of retrying every run.
                    let retry=result.preservingPaths.filter { $0 != scope }
                    let pending=state.roots[root.id]?.pending ?? []
                    state.roots[root.id]?.pending=IndexRelativePath.coalescing(pending + retry)
                }
                if whole {
                    state.roots[root.id]?.lastFullScan=Date().timeIntervalSince1970
                    state.roots[root.id]?.runningFull=nil
                }
                try persistState()
            }
            scanSessions.removeValue(forKey:root.id)
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
            scanSessions.removeValue(forKey:root.id)
            let summary=locked { resourceState.summary }
            log.notice("whole-root scan deferred for \(root.path, privacy: .public) after \(result.count) items: \(summary, privacy: .public)")
        }
        if !result.errors.isEmpty && !yielding { emit("部分位置无法读取",result.errors[0]) }
        if whole { locked { nextScanAfter=Date().addingTimeInterval(rescanInterval) } }
    }
    private func run() {
        let activity=ProcessInfo.processInfo.beginActivity(options:.background,reason:"在本机建立文件全文和图片索引")
        defer {
            ProcessInfo.processInfo.endActivity(activity)
            let restart=locked { () -> Bool in
                running=false
                return requested && !paused && !stopped && !sleeping && !userActive && mutations == 0
            }
            if restart { wakeWork() }
        }
        do {
            var didWork=false
            while !yielding {
                locked { requested=false }
                let prefs=locked { preferences }
                let refreshed=try refreshRoots(preferences:prefs)
                let roots=refreshed.roots
                if refreshed.changed { didWork=true }
                let constrained=refreshResources(force:true).constrained
                // Continue an existing content backlog before directory work.
                if !constrained, try drainContent(roots:roots,preferences:prefs) { didWork=true }
                for root in roots where root.enabled && root.isOnline {
                    if yielding { return }
                    for scope in try nextScopes(for:root,constrained:constrained) {
                        if yielding { return }
                        didWork=true
                        try scan(scope:scope,root:root,roots:roots,preferences:prefs)
                    }
                }
                if yielding { return }
                // Drain bounded batches with a fresh autorelease pool each time.
                // Dirty events arriving during extraction interrupt only at a
                // batch boundary, never invalidate an otherwise valid result.
                while !yielding {
                    let handled=try drainContent(roots:roots,preferences:prefs)
                    if handled { didWork=true }
                    if locked({requested}) { break }
                    if !handled {
                        // A quiet heartbeat must not announce a catalog change, but it
                        // still clears a "busy" left by a run that yielded midway.
                        if didWork || locked({announcedBusy}) { emit("索引已更新","新增或修改文件后会自动更新") }
                        if didWork { onChange?() }
                        return
                    }
                }
                if !locked({requested}) { return }
            }
        } catch { emit("索引遇到问题",error.localizedDescription);onChange?() }
    }
}
