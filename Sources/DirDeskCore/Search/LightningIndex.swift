import CoreServices
import Darwin
import Foundation

public enum LightningIndexLimit: String, Equatable, Sendable {
    case entries, elapsedTime, memory
}

/// Index stages, following the original `GlobalFileIndexStage`.
public enum LightningIndexStage: Equatable, Sendable {
    case idle
    case loadingSnapshot
    case indexing
    case ready
    /// Usable, but the crawl stopped at a limit and some locations are missing.
    case limited(LightningIndexLimit)
    case failed(String)

    public var isSearchable: Bool {
        switch self {
        case .ready, .limited: true
        default: false
        }
    }
}

public struct LightningIndexStatus: Equatable, Sendable {
    public var stage: LightningIndexStage
    /// Searchable items (watched roots and everything below them).
    public var indexedCount: Int
    /// A background update or rebuild is running while the previous index stays searchable.
    public var isUpdating: Bool
    /// The most recent non-fatal problem, e.g. "The search index could not be saved."
    public var lastError: String?
    /// Folders the last crawl could not read (permissions, privacy protection).
    public var unreadableFolderCount: Int

    public init(stage: LightningIndexStage = .idle, indexedCount: Int = 0, isUpdating: Bool = false, lastError: String? = nil,
                unreadableFolderCount: Int = 0) {
        self.stage = stage
        self.indexedCount = indexedCount
        self.isUpdating = isUpdating
        self.lastError = lastError
        self.unreadableFolderCount = unreadableFolderCount
    }
}

public struct LightningIndexConfiguration: Equatable, Sendable {
    /// Watched roots. Nested roots are merged into the outer one.
    public var roots: [URL]
    /// Absolute paths skipped together with their contents (`~` is expanded).
    public var excludedPaths: [String]
    /// Names skipped anywhere, together with their contents.
    public var excludedNames: Set<String>
    /// Folders that are indexed themselves but whose contents are not (node_modules, .git internals).
    public var contentsExcludedNames: Set<String>
    public var includesHiddenFiles: Bool
    /// Index the contents of packages such as .app bundles. Off by default, like Finder.
    public var descendsIntoPackages: Bool
    public var maximumEntries: Int
    public var maximumElapsedTime: Duration
    /// Limit on the estimated memory held by the index arrays.
    public var maximumMemoryBytes: Int
    public var crawlThreadCount: Int
    /// FSEvents coalescing latency in seconds.
    public var eventLatency: TimeInterval
    /// Save the snapshot after live updates at most this often; nil saves only on request.
    public var autosaveInterval: TimeInterval?

    public init(roots: [URL], excludedPaths: [String] = [], excludedNames: Set<String> = Self.defaultExcludedNames,
                contentsExcludedNames: Set<String> = ["node_modules", ".git"], includesHiddenFiles: Bool = true,
                descendsIntoPackages: Bool = false, maximumEntries: Int = 2_000_000, maximumElapsedTime: Duration = .seconds(600),
                maximumMemoryBytes: Int = 512 << 20, crawlThreadCount: Int = min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 8),
                eventLatency: TimeInterval = 0.5, autosaveInterval: TimeInterval? = 600) {
        self.roots = roots
        self.excludedPaths = excludedPaths
        self.excludedNames = excludedNames
        self.contentsExcludedNames = contentsExcludedNames
        self.includesHiddenFiles = includesHiddenFiles
        self.descendsIntoPackages = descendsIntoPackages
        self.maximumEntries = maximumEntries
        self.maximumElapsedTime = maximumElapsedTime
        self.maximumMemoryBytes = maximumMemoryBytes
        self.crawlThreadCount = crawlThreadCount
        self.eventLatency = eventLatency
        self.autosaveInterval = autosaveInterval
    }

    public static let defaultExcludedNames: Set<String> = [
        ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
    ]

    /// The home folder, without ~/Library and the Trash.
    public static var `default`: LightningIndexConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LightningIndexConfiguration(roots: [home], excludedPaths: [
            home.appendingPathComponent("Library").path, home.appendingPathComponent(".Trash").path,
        ])
    }

    /// Whether the contents of `.git` folders are indexed (the folders themselves always are).
    public var indexesGitInternals: Bool {
        get { !contentsExcludedNames.contains(".git") }
        set {
            if newValue { contentsExcludedNames.remove(".git") } else { contentsExcludedNames.insert(".git") }
        }
    }
}

/// The in-memory file-name index behind Lightning Search.
///
/// Built by crawling the watched roots, kept current through FSEvents and persisted to a compressed
/// snapshot. Searches copy the storage (copy-on-write, O(1)) and never wait for a crawl; live updates
/// are applied in short critical sections after their disk I/O is done.
public final class LightningIndex: @unchecked Sendable {
    public let configuration: LightningIndexConfiguration
    public let snapshotURL: URL?
    /// Canonical (`realpath`) roots, nested ones removed.
    public let rootPaths: [String]
    let rules: LightningCrawlRules
    private let fingerprint: UInt64

    private let storageLock = NSLock()
    private var storage = LightningStorage()
    /// Serializes builds, snapshot I/O and live updates.
    private let updateLock = NSRecursiveLock()
    private let stateLock = NSLock()
    private var currentStatus = LightningIndexStatus()
    private var handler: (@Sendable (LightningIndexStatus) -> Void)?
    private var appliedEventID: UInt64 = 0
    private var stopped = false
    private var stream: LightningEventStream?
    private var pendingEvents: [LightningFileEvent] = []
    private var drainScheduled = false
    private var lastSave = ContinuousClock.now
    private var rankCache: (identity: UInt64, generation: UInt64, ranks: [UInt32])?
    private let queue = DispatchQueue(label: "com.kbwumin13.dirdesk.lightning-index", qos: .utility)

    public init(configuration: LightningIndexConfiguration = .default, snapshotURL: URL? = nil) {
        self.configuration = configuration
        self.snapshotURL = snapshotURL
        let canonicalRoots = configuration.roots.map { Self.canonicalPath($0.path) }.sorted()
        var roots: [String] = []
        for root in canonicalRoots where !roots.contains(where: { Self.isPath(root, inside: $0) }) {
            roots.append(root)
        }
        rootPaths = roots
        let home = NSHomeDirectory()
        let excluded = Set(configuration.excludedPaths.map { path -> String in
            let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
            return Self.canonicalPath(expanded)
        })
        rules = LightningCrawlRules(excludedPaths: excluded, excludedNames: configuration.excludedNames,
                                    contentsExcludedNames: configuration.contentsExcludedNames,
                                    includesHiddenFiles: configuration.includesHiddenFiles,
                                    descendsIntoPackages: configuration.descendsIntoPackages)
        var description = "v1|" + roots.joined(separator: "\u{1}") + "|" + excluded.sorted().joined(separator: "\u{1}")
        description += "|" + configuration.excludedNames.sorted().joined(separator: "\u{1}")
        description += "|" + configuration.contentsExcludedNames.sorted().joined(separator: "\u{1}")
        description += "|\(configuration.includesHiddenFiles)|\(configuration.descendsIntoPackages)"
        fingerprint = Self.hash(description)
    }

    deinit {
        stream?.stop()
    }

    // MARK: Status

    public var status: LightningIndexStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentStatus
    }

    /// Called on a background thread whenever the status changes, sometimes while the index holds its
    /// update lock: keep it short and never wait synchronously for the main thread inside it.
    public var statusHandler: (@Sendable (LightningIndexStatus) -> Void)? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return handler }
        set { stateLock.lock(); handler = newValue; stateLock.unlock() }
    }

    /// Number of searchable items.
    public var count: Int {
        storageLock.lock()
        defer { storageLock.unlock() }
        return storage.searchableCount
    }

    /// The FSEvents id the index is current to; live updates resume after it.
    public var lastEventID: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return appliedEventID
    }

    private func updateStatus(_ change: (inout LightningIndexStatus) -> Void) {
        stateLock.lock()
        var status = currentStatus
        change(&status)
        let changed = status != currentStatus
        currentStatus = status
        let handler = self.handler
        stateLock.unlock()
        if changed { handler?(status) }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    // MARK: Storage access

    /// A copy-on-write snapshot for one search.
    func snapshot() -> LightningStorage {
        storageLock.lock()
        defer { storageLock.unlock() }
        return storage
    }

    private func read<R>(_ body: (LightningStorage) -> R) -> R {
        storageLock.lock()
        defer { storageLock.unlock() }
        return body(storage)
    }

    private func mutate<R>(_ body: (inout LightningStorage) -> R) -> R {
        storageLock.lock()
        defer { storageLock.unlock() }
        return body(&storage)
    }

    /// Replaces the whole storage (used by builds, snapshot loads and tests).
    func install(_ newStorage: LightningStorage, stage: LightningIndexStage, eventID: UInt64) {
        mutate { $0 = newStorage }
        stateLock.lock()
        appliedEventID = eventID
        rankCache = nil
        stateLock.unlock()
        let count = newStorage.searchableCount
        updateStatus {
            $0.stage = stage
            $0.indexedCount = count
            $0.isUpdating = false
        }
    }

    /// Folder ranks in path order (folders sorted by name, depth first), cached per storage generation.
    /// Sorting by path compares the rank of the parent folder first, then the name.
    func folderRanks(for storage: LightningStorage) -> [UInt32] {
        stateLock.lock()
        if let cache = rankCache, cache.identity == storage.identity, cache.generation == storage.generation,
           cache.ranks.count == storage.count {
            stateLock.unlock()
            return cache.ranks
        }
        stateLock.unlock()
        let ranks = Self.computeFolderRanks(storage)
        stateLock.lock()
        rankCache = (storage.identity, storage.generation, ranks)
        stateLock.unlock()
        return ranks
    }

    static func computeFolderRanks(_ storage: LightningStorage) -> [UInt32] {
        var ranks = [UInt32](repeating: .max, count: storage.count)
        var next: UInt32 = 0
        storage.withView { view in
            func sortedFolders(_ children: [Int32]) -> [Int32] {
                children.filter { view.flags[Int($0)] & LightningEntryFlag.directory != 0 && view.flags[Int($0)] & LightningEntryFlag.dead == 0 }
                    .sorted { a, b in
                        let order = LightningBytes.compare(view.folded(Int(a)), view.folded(Int(b)))
                        if order != 0 { return order < 0 }
                        let raw = LightningBytes.compare(view.raw(Int(a)), view.raw(Int(b)))
                        return raw != 0 ? raw < 0 : a < b
                    }
            }
            var stack = Array(sortedFolders(storage.topLevel).reversed())
            while let folder = stack.popLast() {
                ranks[Int(folder)] = next
                next += 1
                stack.append(contentsOf: sortedFolders(storage.children(of: folder)).reversed())
            }
        }
        return ranks
    }

    // MARK: Lifecycle

    /// Loads the snapshot (or builds the index) and starts watching, on a background queue.
    public func start() {
        stateLock.lock()
        stopped = false
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let status = self.prepare(isCancelled: { [weak self] in self?.isStopped ?? true })
            guard !self.isStopped, status.stage.isSearchable else { return }
            self.startWatching()
        }
    }

    /// Stops watching and cancels a running build. The index stays searchable.
    public func stop() {
        stateLock.lock()
        stopped = true
        let stream = self.stream
        self.stream = nil
        stateLock.unlock()
        stream?.stop()
    }

    /// Loads a valid snapshot or crawls the roots, then saves a fresh snapshot. Runs synchronously.
    /// A corrupt snapshot is moved aside (`.corrupt`) and replaced.
    @discardableResult
    public func prepare(isCancelled: () -> Bool = { false }) -> LightningIndexStatus {
        updateLock.lock()
        defer { updateLock.unlock() }
        if let snapshotURL, FileManager.default.fileExists(atPath: snapshotURL.path) {
            do {
                try loadSnapshot()
                return status
            } catch LightningSnapshotError.corrupt {
                let aside = URL(fileURLWithPath: snapshotURL.path + ".corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: snapshotURL, to: aside)
            } catch {
                // Incompatible or unreadable: rebuild and overwrite.
            }
        }
        let result = rebuild(isCancelled: isCancelled)
        if snapshotURL != nil, result.stage.isSearchable {
            try? saveSnapshot()
        }
        return status
    }

    /// Crawls every root into a new storage and swaps it in. The previous index stays searchable meanwhile.
    @discardableResult
    public func rebuild(isCancelled: () -> Bool = { false }) -> LightningIndexStatus {
        updateLock.lock()
        defer { updateLock.unlock() }
        let previousStage = status.stage
        let hadIndex = previousStage.isSearchable
        updateStatus {
            if hadIndex { $0.isUpdating = true } else { $0.stage = .indexing; $0.indexedCount = 0 }
        }
        let startEventID = LightningEventStream.currentEventID
        let started = ContinuousClock.now
        let (rootStorage, jobs) = makeRootStorage()
        let crawler = LightningCrawler(
            storage: rootStorage, jobs: jobs, rules: rules,
            limits: LightningCrawlLimits(maximumEntries: configuration.maximumEntries,
                                         deadline: started + configuration.maximumElapsedTime,
                                         maximumMemoryBytes: configuration.maximumMemoryBytes),
            threadCount: configuration.crawlThreadCount)
        var lastReport = ContinuousClock.now
        let (built, outcome) = crawler.run(isCancelled: isCancelled) { [weak self] count in
            let now = ContinuousClock.now
            guard now - lastReport > .milliseconds(250) else { return }
            lastReport = now
            if !hadIndex { self?.updateStatus { $0.indexedCount = count } }
        }
        switch outcome {
        case .cancelled:
            updateStatus {
                if hadIndex { $0.isUpdating = false } else { $0.stage = .idle }
            }
            return status
        case _ where jobs.isEmpty && !rootPaths.isEmpty:
            install(built, stage: .failed("Search index unavailable"), eventID: startEventID)
        case .completed:
            install(built, stage: .ready, eventID: startEventID)
        case let .limited(limit):
            install(built, stage: .limited(limit), eventID: startEventID)
        }
        let unreadable = crawler.unreadableDirectories
        updateStatus { $0.unreadableFolderCount = unreadable }
        return status
    }

    private func makeRootStorage() -> (LightningStorage, [LightningCrawler.Job]) {
        var storage = LightningStorage()
        var jobs: [LightningCrawler.Job] = []
        for root in rootPaths {
            var info = stat()
            guard lstat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            let entry = Self.addRootChain(root, info: info, to: &storage)
            jobs.append(LightningCrawler.Job(index: entry, path: root, device: info.st_dev))
        }
        return (storage, jobs)
    }

    /// Adds the synthetic ancestors of `root` (shared between roots) and the root entry itself.
    private static func addRootChain(_ root: String, info: stat, to storage: inout LightningStorage) -> Int32 {
        let modified = seconds(info.st_mtimespec), created = seconds(info.st_birthtimespec)
        if root == "/" {
            return storage.append(name: "", parent: -1, flags: LightningEntryFlag.root | LightningEntryFlag.directory,
                                  modified: modified, created: created)
        }
        let components = root.split(separator: "/").map(String.init)
        var parent: Int32 = -1
        for component in components.dropLast() {
            if let existing = storage.child(of: parent, named: Array(component.utf8)) {
                parent = existing
            } else {
                parent = storage.append(name: component, parent: parent,
                                        flags: LightningEntryFlag.ancestor | LightningEntryFlag.directory)
            }
        }
        let name = components.last ?? ""
        var flags = LightningEntryFlag.root | LightningEntryFlag.directory
        if name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0 { flags |= LightningEntryFlag.hidden }
        return storage.append(name: name, parent: parent, flags: flags, modified: modified, created: created)
    }

    // MARK: Snapshot

    /// Loads the snapshot at `snapshotURL`. Throws `LightningSnapshotError`; the current index is kept on failure.
    public func loadSnapshot() throws {
        guard let snapshotURL else { throw LightningSnapshotError.missing }
        updateLock.lock()
        defer { updateLock.unlock() }
        let previous = status.stage
        if !previous.isSearchable { updateStatus { $0.stage = .loadingSnapshot } }
        do {
            let (loaded, header) = try LightningSnapshot.read(from: snapshotURL)
            guard header.fingerprint == fingerprint, header.roots == rootPaths,
                  header.volumeUUIDs == rootPaths.map(LightningEventStream.volumeUUID(for:)) else {
                throw LightningSnapshotError.incompatible
            }
            install(loaded, stage: header.limit.map { .limited($0) } ?? .ready, eventID: header.lastEventID)
            lastSave = ContinuousClock.now
        } catch {
            if !previous.isSearchable { updateStatus { $0.stage = previous } }
            throw error
        }
    }

    /// Writes the index to `snapshotURL` (compacting first). Safe to call while searches run.
    public func saveSnapshot() throws {
        guard let snapshotURL else { return }
        updateLock.lock()
        defer { updateLock.unlock() }
        if read({ $0.deadCount > 0 }) {
            mutate { $0 = $0.compacted() }
        }
        let current = snapshot()
        let stage = status.stage
        var limit: LightningIndexLimit?
        if case let .limited(reason) = stage { limit = reason }
        let header = LightningSnapshotHeader(fingerprint: fingerprint, lastEventID: lastEventID, savedAt: Date().timeIntervalSince1970,
                                             limit: limit, roots: rootPaths,
                                             volumeUUIDs: rootPaths.map(LightningEventStream.volumeUUID(for:)))
        do {
            try LightningSnapshot.write(current, header: header, to: snapshotURL)
            lastSave = ContinuousClock.now
            if status.lastError != nil { updateStatus { $0.lastError = nil } }
        } catch {
            updateStatus { $0.lastError = "The search index could not be saved." }
            throw error
        }
    }

    // MARK: Live updates

    /// Starts the FSEvents stream, resuming after `lastEventID` when the index came from a snapshot or a crawl.
    public func startWatching() {
        let since = lastEventID
        // The data volume's mount point is only skipped by the crawl; its events still arrive (see `normalizedEventPath`).
        let exclusions = rules.excludedPaths.filter { path in
            path != LightningCrawlRules.dataVolumePath && rootPaths.contains { Self.isPath(path, inside: $0) }
        }.sorted()
        let stream = LightningEventStream(paths: rootPaths, exclusions: exclusions, since: since == 0 ? nil : since,
                                          latency: configuration.eventLatency) { [weak self] events in
            self?.enqueue(events)
        }
        stateLock.lock()
        let previous = self.stream
        self.stream = stream
        stateLock.unlock()
        previous?.stop()
        stream?.start()
    }

    private func enqueue(_ events: [LightningFileEvent]) {
        stateLock.lock()
        pendingEvents.append(contentsOf: events)
        let schedule = !drainScheduled
        drainScheduled = true
        stateLock.unlock()
        guard schedule else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let events = self.pendingEvents
            self.pendingEvents = []
            self.drainScheduled = false
            self.stateLock.unlock()
            self.apply(events)
            self.autosaveIfDue()
        }
    }

    private func autosaveIfDue() {
        guard let interval = configuration.autosaveInterval, snapshotURL != nil else { return }
        updateLock.lock()
        defer { updateLock.unlock() }
        if ContinuousClock.now - lastSave > .seconds(interval) { try? saveSnapshot() }
    }

    /// Applies file-system changes synchronously. Paths that disappeared are removed with their
    /// contents, new folders are crawled, and lost-event flags rescan the affected subtree.
    public func apply(_ events: [LightningFileEvent]) {
        updateLock.lock()
        defer { updateLock.unlock() }
        guard status.stage.isSearchable, !events.isEmpty else { return }
        updateStatus { $0.isUpdating = true }
        var newestID = lastEventID
        var rescans: [String] = []
        var items: [(path: String, structural: Bool)] = []
        for event in events {
            newestID = max(newestID, event.eventID)
            let path = Self.normalizedEventPath(event.path)
            let flags = event.flags
            if flags.subtracting(.historyDone).isEmpty { continue }
            if !flags.isDisjoint(with: LightningFileEvent.Flags.recovery) {
                // Lost events (or a root moved): rescan the subtree, or every root it contains.
                if rootPaths.contains(where: { Self.isPath(path, inside: $0) }) {
                    rescans.append(path)
                } else {
                    rescans.append(contentsOf: rootPaths.filter { Self.isPath($0, inside: path) })
                }
                continue
            }
            guard let root = rootPaths.first(where: { Self.isPath(path, inside: $0) }) else { continue }
            if path != root, rules.ignoresChanges(at: path, root: root) { continue }
            let structural = !flags.isDisjoint(with: LightningFileEvent.Flags.structural)
            if path == root {
                if structural { rescans.append(root) }
                continue
            }
            items.append((path, structural))
            if structural, flags.contains(.itemIsDirectory), !flags.isDisjoint(with: [.itemCreated, .itemRenamed]) {
                // A folder that appeared may bring contents along: reconcile its whole subtree.
                rescans.append(path)
            }
        }
        rescans = Self.outermost(rescans)
        let rescanned = Set(rescans)
        var dirty: Set<String> = []
        for path in rescans { rescan(path, dirty: &dirty) }
        var seen: Set<String> = []
        var perFolder: [String: Int] = [:]
        items = items.filter { item in
            !Self.isCovered(item.path, by: rescanned) && seen.insert(item.path).inserted
        }
        for item in items { perFolder[Self.parentPath(item.path), default: 0] += 1 }
        for item in items {
            let folder = Self.parentPath(item.path)
            if perFolder[folder, default: 0] > 16 {
                // Many changes in one folder: one listing is cheaper than resolving each path.
                dirty.insert(folder)
            } else {
                applyItem(item.path, structural: item.structural, dirty: &dirty)
            }
        }
        for directory in dirty.sorted(by: { $0.count < $1.count }) where !Self.isCovered(directory, by: rescanned) {
            reconcile(directory)
        }
        if read({ $0.needsCompaction }) {
            mutate { $0 = $0.compacted() }
        }
        stateLock.lock()
        appliedEventID = max(appliedEventID, newestID)
        stateLock.unlock()
        let count = read { $0.searchableCount }
        updateStatus {
            $0.isUpdating = false
            $0.indexedCount = count
        }
    }

    /// Applies one changed path without listing its folder when the change is unambiguous.
    private func applyItem(_ path: String, structural: Bool, dirty: inout Set<String>) {
        let parentPath = Self.parentPath(path)
        let name = Array((path as NSString).lastPathComponent.utf8)
        let folded = LightningText.fold(string: (path as NSString).lastPathComponent)
        var info = stat()
        let exists = lstat(path, &info) == 0
        let lookup = read { storage -> (parent: Int32, exact: Int32?, similar: Int32?, flags: UInt8)? in
            guard let parent = storage.lookup(path: parentPath),
                  storage.flags[Int(parent)] & LightningEntryFlag.directory != 0 else { return nil }
            var exact: Int32?, similar: Int32?
            for child in storage.children(of: parent) {
                if storage.rawName(child).elementsEqual(name) {
                    exact = child
                } else if folded.elementsEqual(storage.foldedName(child)) {
                    similar = child
                }
            }
            return (parent, exact, similar, exact.map { storage.flags[Int($0)] } ?? 0)
        }
        guard let lookup else {
            if exists { dirty.insert(parentPath) }
            return
        }
        guard exists else {
            if let exact = lookup.exact {
                mutate { $0.removeSubtree(exact) }
            } else if lookup.similar != nil {
                dirty.insert(parentPath)
            }
            return
        }
        if lookup.exact == nil, lookup.similar != nil {
            // Probably a case-only rename: list the folder to learn the stored name.
            dirty.insert(parentPath)
            return
        }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        let isSymlink = info.st_mode & S_IFMT == S_IFLNK
        let hidden = name.first == 0x2E || info.st_flags & UInt32(UF_HIDDEN) != 0
        var flags: UInt8 = hidden ? LightningEntryFlag.hidden : 0
        if isDirectory {
            flags |= LightningEntryFlag.directory
            if LightningPackages.isPackage(name: name) { flags |= LightningEntryFlag.package }
        }
        if isSymlink { flags |= LightningEntryFlag.symlink }
        let size = isDirectory ? 0 : Int64(info.st_size)
        let modified = Self.seconds(info.st_mtimespec), created = Self.seconds(info.st_birthtimespec)
        if let exact = lookup.exact {
            let kindMask = LightningEntryFlag.directory | LightningEntryFlag.symlink
            if lookup.flags & kindMask == flags & kindMask {
                mutate { $0.updateMetadata(exact, size: size, modified: modified, created: created, flags: flags) }
                return
            }
            mutate { $0.removeSubtree(exact) }
        }
        if hidden, !rules.includesHiddenFiles { return }
        if rules.excludedNames.contains(name) || rules.excludedPaths.contains(path) { return }
        guard read({ $0.count }) < configuration.maximumEntries else {
            updateStatus { $0.stage = .limited(.entries) }
            return
        }
        let descend = isDirectory && (flags & LightningEntryFlag.package == 0 || rules.descendsIntoPackages)
            && !rules.contentsExcludedNames.contains(name)
        let subtree = descend ? crawlContents(of: path, device: info.st_dev) : nil
        mutate { storage in
            let entry = name.withUnsafeBufferPointer {
                storage.append(name: $0, parent: lookup.parent, flags: flags, size: size, modified: modified, created: created)
            }
            if let subtree { storage.splice(subtree, under: entry) }
        }
    }

    /// Re-lists one folder and applies the differences to its direct children.
    private func reconcile(_ directoryPath: String) {
        guard let root = rootPaths.first(where: { Self.isPath(directoryPath, inside: $0) }) else { return }
        var path = directoryPath
        var entry = read { $0.lookup(path: path) }
        while entry == nil, path != root {
            path = Self.parentPath(path)
            entry = read { $0.lookup(path: path) }
        }
        guard let entry, read({ $0.flags[Int(entry)] & LightningEntryFlag.directory != 0 }) else { return }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            if path != root {
                reconcile(Self.parentPath(path))
            } else {
                mutate { $0.removeChildren(of: entry) }
            }
            return
        }
        var listing = LightningListing()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: LightningDirectoryReader.bufferSize, alignment: 16)
        let error = LightningDirectoryReader.read(path, into: &listing, buffer: buffer)
        buffer.deallocate()
        guard error == 0 else { return }
        var existing = read { storage -> [[UInt8]: (Int32, UInt8)] in
            var children: [[UInt8]: (Int32, UInt8)] = [:]
            for child in storage.children(of: entry) {
                children[Array(storage.rawName(child))] = (child, storage.flags[Int(child)])
            }
            return children
        }
        let excludedHere = rules.excludedChildren[path]
        var removals: [Int32] = []
        var updates: [(Int32, Int64, Double, Double, UInt8)] = []
        var additions: [(listingIndex: Int, flags: UInt8, descend: Bool)] = []
        let kindMask = LightningEntryFlag.directory | LightningEntryFlag.symlink
        for index in 0..<listing.count {
            let name = Array(listing.name(index))
            if rules.excludedNames.contains(name) || excludedHere?.contains(name) == true { continue }
            let hidden = listing.hidden[index]
            if hidden, !rules.includesHiddenFiles { continue }
            var flags: UInt8 = hidden ? LightningEntryFlag.hidden : 0
            var descend = false
            switch listing.kind[index] {
            case .directory:
                flags |= LightningEntryFlag.directory
                let package = LightningPackages.isPackage(name: name)
                if package { flags |= LightningEntryFlag.package }
                descend = (!package || rules.descendsIntoPackages) && listing.device[index] == info.st_dev
                    && !rules.contentsExcludedNames.contains(name)
            case .symlink:
                flags |= LightningEntryFlag.symlink
            case .file, .other:
                break
            }
            if let (child, childFlags) = existing.removeValue(forKey: name) {
                if childFlags & kindMask == flags & kindMask {
                    updates.append((child, listing.size[index], listing.modified[index], listing.created[index], flags))
                    continue
                }
                removals.append(child)
            }
            additions.append((index, flags, descend))
        }
        removals.append(contentsOf: existing.values.map(\.0))
        let room = configuration.maximumEntries - read { $0.count }
        if additions.count > room {
            additions = Array(additions.prefix(max(room, 0)))
            updateStatus { $0.stage = .limited(.entries) }
        }
        var subtrees: [Int: LightningStorage] = [:]
        let prefix = path == "/" ? "/" : path + "/"
        for addition in additions where addition.descend {
            let childPath = prefix + String(decoding: listing.name(addition.listingIndex), as: UTF8.self)
            subtrees[addition.listingIndex] = crawlContents(of: childPath, device: info.st_dev)
        }
        mutate { storage in
            for child in removals { storage.removeSubtree(child) }
            for (child, size, modified, created, flags) in updates {
                storage.updateMetadata(child, size: size, modified: modified, created: created, flags: flags)
            }
            for addition in additions {
                let index = addition.listingIndex
                let added = listing.names.withUnsafeBufferPointer { names in
                    storage.append(name: UnsafeBufferPointer(rebasing: names[listing.nameStart[index]..<(listing.nameStart[index] + listing.nameCount[index])]),
                                   parent: entry, flags: addition.flags, size: listing.size[index],
                                   modified: listing.modified[index], created: listing.created[index])
                }
                if let subtree = subtrees[index] { storage.splice(subtree, under: added) }
            }
        }
    }

    /// Replaces the subtree at `path` with a fresh crawl (or removes it when it is gone).
    private func rescan(_ path: String, dirty: inout Set<String>) {
        guard let root = rootPaths.first(where: { Self.isPath(path, inside: $0) }) else { return }
        var info = stat()
        let exists = lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
        if path == root {
            guard exists else {
                if let entry = read({ $0.lookup(path: root) }) { mutate { $0.removeChildren(of: entry) } }
                return
            }
            let subtree = crawlContents(of: root, device: info.st_dev)
            let hidden = (root as NSString).lastPathComponent.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0
            mutate { storage in
                let entry = storage.lookup(path: root) ?? Self.addRootChain(root, info: info, to: &storage)
                storage.removeChildren(of: entry)
                if let subtree { storage.splice(subtree, under: entry) }
                storage.updateMetadata(entry, size: 0, modified: Self.seconds(info.st_mtimespec),
                                       created: Self.seconds(info.st_birthtimespec),
                                       flags: LightningEntryFlag.directory | (hidden ? LightningEntryFlag.hidden : 0))
            }
            return
        }
        if rules.ignoresChanges(at: path, root: root) { return }
        guard exists, let entry = read({ storage -> Int32? in
            guard let entry = storage.lookup(path: path), storage.rawName(entry).elementsEqual(Array((path as NSString).lastPathComponent.utf8)),
                  storage.flags[Int(entry)] & LightningEntryFlag.directory != 0 else { return nil }
            return entry
        }) else {
            // Gone, new, renamed or replaced by a file: the parent listing settles it.
            dirty.insert(Self.parentPath(path))
            return
        }
        let isPackage = read { $0.flags[Int(entry)] & LightningEntryFlag.package != 0 }
        let name = Array((path as NSString).lastPathComponent.utf8)
        guard (!isPackage || rules.descendsIntoPackages), !rules.contentsExcludedNames.contains(name) else { return }
        let subtree = crawlContents(of: path, device: info.st_dev)
        mutate { storage in
            storage.removeChildren(of: entry)
            if let subtree { storage.splice(subtree, under: entry) }
        }
    }

    /// Crawls the contents of `path` into a separate storage whose entry 0 stands for `path` itself.
    private func crawlContents(of path: String, device: dev_t) -> LightningStorage? {
        var temporary = LightningStorage()
        let anchor = temporary.append(name: "", parent: -1, flags: LightningEntryFlag.directory)
        let room = configuration.maximumEntries - read { $0.count }
        guard room > 0 else { return nil }
        let crawler = LightningCrawler(
            storage: temporary, jobs: [LightningCrawler.Job(index: anchor, path: path, device: device)], rules: rules,
            limits: LightningCrawlLimits(maximumEntries: room + 1, deadline: ContinuousClock.now + configuration.maximumElapsedTime,
                                         maximumMemoryBytes: configuration.maximumMemoryBytes),
            threadCount: configuration.crawlThreadCount)
        let (result, outcome) = crawler.run(isCancelled: { false }, progress: { _ in })
        if case let .limited(limit) = outcome { updateStatus { $0.stage = .limited(limit) } }
        return result.count > 1 ? result : nil
    }

    // MARK: Paths

    static func canonicalPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        guard let resolved = realpath(standardized, nil) else { return standardized }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isPath(_ path: String, inside root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    static func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func normalizedEventPath(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        // Watching "/" reports changes on the data volume below its mount point; the index lists those items at
        // their firmlinked locations (/Users, /Applications, /private …).
        let data = LightningCrawlRules.dataVolumePath
        if result.hasPrefix(data + "/") { result = String(result.dropFirst(data.count)) }
        return result
    }

    /// Drops paths nested inside another path of the list.
    static func outermost(_ paths: [String]) -> [String] {
        var selected: Set<String> = []
        var result: [String] = []
        for path in Set(paths).sorted(by: { $0.count < $1.count }) where !isCovered(path, by: selected) {
            selected.insert(path)
            result.append(path)
        }
        return result
    }

    /// Whether `path` or one of its ancestors is in `paths` (an ancestor walk, not a scan of the set).
    static func isCovered(_ path: String, by paths: Set<String>) -> Bool {
        guard !paths.isEmpty else { return false }
        if paths.contains("/") { return true }
        var current = path
        while current.count > 1 {
            if paths.contains(current) { return true }
            current = parentPath(current)
        }
        return false
    }

    static func seconds(_ time: timespec) -> Double {
        Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    private static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        return value
    }
}

extension LightningStorage {
    /// Appends every entry of `other` except its anchor (entry 0) below `anchor`.
    mutating func splice(_ other: LightningStorage, under anchor: Int32) {
        guard other.count > 1 else { return }
        let extensionMap = extensionMap(from: other)
        var indexMap = [Int32](repeating: -1, count: other.count)
        indexMap[0] = anchor
        for index in 1..<other.count where other.flags[index] & LightningEntryFlag.dead == 0 {
            let otherParent = other.parent[index]
            let mappedParent = otherParent >= 0 ? indexMap[Int(otherParent)] : anchor
            guard mappedParent >= 0 else { continue }
            indexMap[index] = appendCopy(of: index, from: other, parent: mappedParent, extensionMap: extensionMap)
        }
    }
}
