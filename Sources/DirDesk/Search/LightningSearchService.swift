import AppKit
import Combine
import Darwin
import DirDeskCore

/// A flag shared with background work (search cancellation, shutdown). Safe to read from any thread.
final class LightningFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Owns the Lightning Search index and engine for the whole app and publishes the index status.
///
/// Crawling the disk reads Desktop, Documents and Downloads, which makes macOS ask for access. The
/// index therefore starts at launch only when Full Disk Access is already granted, and otherwise the first
/// time Lightning Search opens. Index objects are created off the main thread because resolving watched
/// paths can touch protected folders.
@MainActor
final class LightningSearchService: ObservableObject {
    static let shared = LightningSearchService()

    static let watchedFoldersKey = "dirdesk-lightning-watched-v1"
    static let ignoredFoldersKey = "dirdesk-lightning-ignored-v1"
    /// The original's defaults: the whole startup disk, minus other volumes, caches, logs and system scratch space.
    static let defaultWatchedFolders = ["/"]
    static let defaultIgnoredFolders = [
        "/Volumes", "~/Library/CloudStorage", "~/Library/Biome", "~/Library/Caches", "~/Library/Logs", "~/Library/Metadata",
        "/Library/Caches", "/System/Library/Caches", "/private/var", "/private/tmp",
    ]
    /// Rows listed per search; further matches are only counted.
    static let resultLimit = 20_000

    @Published private(set) var status = LightningIndexStatus()
    /// The index has been asked to start: it loads its snapshot or crawls, then keeps watching for changes.
    @Published private(set) var isStarted = false
    /// Changes whenever a new index object is installed (first start, changed folders).
    @Published private(set) var indexGeneration = 0
    @Published private(set) var watchedFolders: [String]
    @Published private(set) var ignoredFolders: [String]
    /// nil until the first check has finished.
    @Published private(set) var hasFullDiskAccess: Bool?

    private(set) var index: LightningIndex?
    private(set) var engine: LightningSearchEngine?
    private let shutdownFlag = LightningFlag()
    /// Cancels background work of the current index once it is replaced.
    private var indexFlag = LightningFlag()

    private init() {
        let defaults = UserDefaults.standard
        watchedFolders = defaults.stringArray(forKey: Self.watchedFoldersKey) ?? Self.defaultWatchedFolders
        ignoredFolders = defaults.stringArray(forKey: Self.ignoredFoldersKey) ?? Self.defaultIgnoredFolders
    }

    /// `~/Library/Application Support/DirDesk/LightningIndex/index.snapshot`.
    nonisolated static var snapshotURL: URL {
        ApplicationSupport.directory.appendingPathComponent("DirDesk/LightningIndex/index.snapshot")
    }

    nonisolated static func configuration(watched: [String], ignored: [String]) -> LightningIndexConfiguration {
        let roots = watched.map { URL(fileURLWithPath: expandingTilde($0), isDirectory: true) }
        // The index never lists its own snapshot folder, even when ~/Library is watched.
        let excluded = ignored.map(expandingTilde) + [snapshotURL.deletingLastPathComponent().path]
        // A whole disk holds a few million names; about 75 bytes each in the index.
        return LightningIndexConfiguration(roots: roots, excludedPaths: excluded, maximumEntries: 4_000_000,
                                           maximumMemoryBytes: 768 << 20)
    }

    nonisolated static func expandingTilde(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst() }
        return path
    }

    // MARK: Lifecycle

    /// Call at launch: starts the index only when Full Disk Access is granted, so no privacy prompt appears.
    func startIfAllowed() {
        Task {
            let granted = await Self.checkFullDiskAccess()
            hasFullDiskAccess = granted
            if granted { ensureStarted() }
        }
    }

    /// Starts the index if it is not running yet: it loads the saved snapshot or crawls the watched folders.
    func ensureStarted() {
        // Hidden snapshot runs (see `DebugSnapshot`) only render windows; crawling would make macOS ask a
        // throwaway copy for access to Desktop, Documents and Downloads.
        guard !isStarted, !UserDefaults.standard.bool(forKey: "DirDeskSnapshotHidden") else { return }
        launch(rebuild: false)
    }

    /// Crawls the watched folders again. The current index stays searchable while the new one is built.
    func rebuildIndex() {
        guard !isBusy else { return }
        guard let index, isStarted else {
            launch(rebuild: true)
            return
        }
        engine?.discardTemporaryIndexes()
        Self.rebuild(index, cancel: indexFlag, shutdown: shutdownFlag)
    }

    /// A crawl or snapshot load is running and the index cannot be searched yet.
    var isBusy: Bool {
        if isStarted, index == nil { return true }
        switch status.stage {
        case .indexing, .loadingSnapshot: return true
        default: return false
        }
    }

    /// Call from `applicationWillTerminate`: stops watching and saves the index for the next launch.
    func shutdown() {
        shutdownFlag.set()
        indexFlag.set()
        guard let index else { return }
        index.stop()
        // An unfinished first crawl has nothing worth saving; a snapshot of it would load as an empty index.
        if index.status.stage.isSearchable { try? index.saveSnapshot() }
    }

    private func launch(rebuild: Bool) {
        isStarted = true
        indexFlag.set()
        let cancel = LightningFlag()
        indexFlag = cancel
        let configuration = Self.configuration(watched: watchedFolders, ignored: ignoredFolders)
        let snapshot = Self.snapshotURL
        let shutdown = shutdownFlag
        Task {
            let index = await Task.detached(priority: .utility) {
                LightningIndex(configuration: configuration, snapshotURL: snapshot)
            }.value
            guard !cancel.isSet, !shutdown.isSet else { return }
            install(index)
            if rebuild {
                Self.rebuild(index, cancel: cancel, shutdown: shutdown)
            } else {
                index.start()
            }
        }
    }

    private nonisolated static func rebuild(_ index: LightningIndex, cancel: LightningFlag, shutdown: LightningFlag) {
        DispatchQueue.global(qos: .utility).async {
            let result = index.rebuild(isCancelled: { cancel.isSet || shutdown.isSet })
            guard result.stage.isSearchable, !cancel.isSet, !shutdown.isSet else { return }
            try? index.saveSnapshot()
            guard !cancel.isSet else { return }
            // Restarts the change stream from the new crawl.
            index.startWatching()
        }
    }

    private func install(_ newIndex: LightningIndex) {
        if let old = index {
            old.statusHandler = nil
            old.stop()
        }
        index = newIndex
        engine = LightningSearchEngine(index: newIndex)
        let token = ObjectIdentifier(newIndex)
        newIndex.statusHandler = { _ in
            Task { @MainActor in LightningSearchService.shared.indexStatusChanged(token) }
        }
        status = newIndex.status
        indexGeneration += 1
    }

    private func indexStatusChanged(_ token: ObjectIdentifier) {
        guard let index, ObjectIdentifier(index) == token else { return }
        let current = index.status
        if current != status { status = current }
    }

    // MARK: Folders

    enum FolderListError: Error, Equatable {
        case invalidPath, empty
    }

    /// One absolute path per line (`~` allowed). Blank lines are ignored; trailing slashes and repeats removed.
    static func parseFolderList(_ text: String, allowsEmpty: Bool) -> Result<[String], FolderListError> {
        var paths: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var path = line.trimmingCharacters(in: .whitespaces)
            if path.isEmpty { continue }
            guard path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") else { return .failure(.invalidPath) }
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            if !paths.contains(path) { paths.append(path) }
        }
        if paths.isEmpty, !allowsEmpty { return .failure(.empty) }
        return .success(paths)
    }

    /// Saves the folder lists. Changed lists replace the index; a running index rebuilds right away.
    func updateFolders(watched: [String], ignored: [String]) {
        guard watched != watchedFolders || ignored != ignoredFolders else { return }
        watchedFolders = watched
        ignoredFolders = ignored
        UserDefaults.standard.set(watched, forKey: Self.watchedFoldersKey)
        UserDefaults.standard.set(ignored, forKey: Self.ignoredFoldersKey)
        guard isStarted else { return }
        // The snapshot was written for the old folders; the new index cannot use it and crawls instead.
        launch(rebuild: true)
    }

    // MARK: Full Disk Access

    func refreshFullDiskAccess() {
        Task { hasFullDiskAccess = await Self.checkFullDiskAccess() }
    }

    nonisolated static func checkFullDiskAccess() async -> Bool {
        await Task.detached(priority: .utility) { probeFullDiskAccess() }.value
    }

    /// Approximate: these locations are readable only with Full Disk Access, and reading them never prompts.
    nonisolated static func probeFullDiskAccess() -> Bool {
        let descriptor = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY | O_CLOEXEC)
        if descriptor >= 0 {
            close(descriptor)
            return true
        }
        let home = NSHomeDirectory() as NSString
        for folder in ["Library/Safari", "Library/Mail"] {
            if (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(folder))) != nil { return true }
        }
        return false
    }
}

// MARK: - Status text

enum LightningStatusText {
    /// One line for the search window's status bar.
    static func summary(_ status: LightningIndexStatus, isStarted: Bool) -> String {
        guard isStarted else { return L("Index is not ready") }
        let count = LF("Indexed: %lld", Int64(status.indexedCount))
        switch status.stage {
        case .idle:
            return L("Index is not ready")
        case .loadingSnapshot:
            return L("Loading Search Index…")
        case .indexing:
            return L("Building Search Index…") + " · " + count
        case .ready:
            return status.isUpdating ? L("Updating in the background · Search is available") + " · " + count : count
        case .limited:
            return count + " · " + L("Index resource limit reached. Choose fewer watched folders.")
        case .failed:
            return L("Search index unavailable")
        }
    }

    enum Tone {
        case ready, busy, problem, idle
    }

    /// The search window's status indicator: a colored dot and a short state ("Ready" once the index can be searched).
    static func indicator(_ status: LightningIndexStatus, isStarted: Bool) -> (text: String, tone: Tone) {
        guard isStarted else { return (L("Index is not ready"), .idle) }
        switch status.stage {
        case .idle:
            return (L("Index is not ready"), .idle)
        case .loadingSnapshot:
            return (L("Loading Search Index…"), .busy)
        case .indexing:
            return (L("Building Search Index…") + " · " + LF("Indexed: %lld", Int64(status.indexedCount)), .busy)
        case .ready:
            return (status.isUpdating ? L("Updating in the background · Search is available") : L("Ready"), .ready)
        case .limited:
            return (L("Index resource limit reached. Choose fewer watched folders."), .problem)
        case .failed:
            return (L("Search index unavailable"), .problem)
        }
    }

    static func errorText(_ message: String) -> String {
        switch message {
        case "The search index could not be saved.": L("The search index could not be saved.")
        case "Search index unavailable": L("Search index unavailable")
        default: message
        }
    }

    /// Localized text for the engine's syntax error messages.
    static func syntaxMessage(_ error: LightningSyntaxError) -> String {
        switch error.message {
        case LightningSyntaxError.unknownFilter: L("Only supported filters are listed. Unknown filters report an error.")
        case LightningSyntaxError.missingValue: L("Missing value")
        case LightningSyntaxError.invalidRegularExpression: L("Invalid regular expression.")
        case LightningSyntaxError.invalidSize: L("Enter a nonnegative file size.")
        case LightningSyntaxError.invalidDate: L("Enter a date as YYYY-MM-DD.")
        case LightningSyntaxError.reversedRange: L("The end of the range must not be before the start.")
        case LightningSyntaxError.unknownType: L("Unknown file type")
        case LightningSyntaxError.invalidFolder: L("Choose a folder or enter an absolute path.")
        default: error.message
        }
    }

    static func issueMessage(_ kind: LightningVisualIssue.Kind) -> String {
        switch kind {
        case .emptyCondition: L("Complete or disable the empty condition.")
        case .missingComparison: L("Choose a comparison for this condition.")
        case .invalidSize: L("Enter a nonnegative file size.")
        case .invalidDate: L("Enter a date as YYYY-MM-DD.")
        case .reversedRange: L("The end of the range must not be before the start.")
        case .invalidRegularExpression: L("Invalid regular expression.")
        case .invalidFolder: L("Choose a folder or enter an absolute path.")
        case .tooManyConditions: L("Use at most 32 conditions and 4 group levels.")
        }
    }
}
