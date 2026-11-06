import AppKit
import Combine
import Darwin
import DirDeskCore
import MijiCore

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

final class PendingMijiHost: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MijiIndexHost?
    private var preferences = IndexingPreferences()
    func configure(_ preferences: IndexingPreferences) {
        lock.lock(); self.preferences = preferences; value?.configure(preferences); lock.unlock()
    }
    func store(_ host: MijiIndexHost) {
        lock.lock(); value = host; host.configure(preferences); lock.unlock()
    }
    func remove(_ host: MijiIndexHost) { lock.lock(); if value === host { value = nil }; lock.unlock() }
    func take() -> MijiIndexHost? { lock.lock(); defer { lock.unlock() }; let host = value; value = nil; return host }
}

typealias MijiHostFactory = @Sendable (URL, Bool, [String], URL) throws -> MijiIndexHost

/// Wumi's single Miji index host. UI sessions share the backend, never a second full-disk index.
@MainActor
final class LightningSearchService: ObservableObject {
    static let shared = LightningSearchService()
    static let watchedFoldersKey = "dirdesk-lightning-watched-v1"
    static let ignoredFoldersKey = "dirdesk-lightning-ignored-v1"
    static let defaultWatchedFolders = ["/"]
    static let defaultIgnoredFolders = [
        "/Volumes", "~/Library/CloudStorage", "~/Library/Biome", "~/Library/Caches", "~/Library/Logs", "~/Library/Metadata",
        "/Library/Caches", "/System/Library/Caches", "/private/var", "/private/tmp",
    ]
    static let mappedFoldersKey = "dirdesk-miji-folders-mapped-v1"
    static let pendingFoldersKey = "dirdesk-miji-folders-pending-v1"
    static let indexingPreferencesKey = "dirdesk-miji-indexing-v1"
    @Published private(set) var indexingPreferences: IndexingPreferences
    @Published private(set) var roots: [IndexedRoot] = []
    static let resultLimit = 20_000
    @Published private(set) var status = LightningIndexStatus()
    @Published private(set) var isStarted = false
    @Published private(set) var indexGeneration = 0
    @Published private(set) var contentGeneration = 0
    @Published private(set) var watchedFolders: [String]
    @Published private(set) var ignoredFolders: [String]
    @Published private(set) var hasFullDiskAccess: Bool?
    private(set) var engine: MijiSearchBackend?
    private var host: MijiIndexHost?
    private let setupQueue = DispatchQueue(label: "wumi.miji.host", qos: .utility)
    private let shutdownFlag = LightningFlag()
    private var indexFlag = LightningFlag()
    private let pendingHost = PendingMijiHost()
    private var catalogRefresh: Task<Void, Never>?
    private var pendingContentChange = false
    private let defaults: UserDefaults
    private let hostFactory: MijiHostFactory
    private var interactionResume: Task<Void, Never>?
    private var interactionDeadline = ContinuousClock.now

    /// One timer for an input burst. Merely keeping a window in front never pauses the index.
    func userDidInteract() {
        guard let host, !Self.isReadOnly else { return }
        interactionDeadline = .now + .milliseconds(350)
        host.setUserActive(true)
        guard interactionResume == nil else { return }
        interactionResume = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let deadline = self.interactionDeadline
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                if ContinuousClock.now >= self.interactionDeadline { break }
            }
            guard !Task.isCancelled else { return }
            self.interactionResume = nil
            self.host?.setUserActive(false)
        }
    }

    init(defaults: UserDefaults = .standard,
         hostFactory: @escaping MijiHostFactory = {url,readOnly,ignored,helper in
             try MijiIndexHost(databaseURL:url,readOnly:readOnly,ignoredPaths:ignored,extractionWorker:helper)
         }) {
        self.defaults = defaults;self.hostFactory = hostFactory
        indexingPreferences = defaults.data(forKey: Self.indexingPreferencesKey).flatMap { try? JSONDecoder().decode(IndexingPreferences.self, from: $0) } ?? IndexingPreferences()
        watchedFolders = defaults.stringArray(forKey: Self.watchedFoldersKey) ?? Self.defaultWatchedFolders
        ignoredFolders = defaults.stringArray(forKey: Self.ignoredFoldersKey) ?? Self.defaultIgnoredFolders
        pendingHost.configure(indexingPreferences)
    }
    nonisolated static var databaseURL: URL {
        if let path = UserDefaults.standard.string(forKey: "WumiSearchDatabase"), !path.isEmpty {
            return URL(fileURLWithPath: expandingTilde(path))
        }
        return ApplicationSupport.directory.appendingPathComponent("DirDesk/Miji/index.sqlite")
    }
    nonisolated static var isReadOnly: Bool { UserDefaults.standard.bool(forKey: "WumiSearchReadOnly") }
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

    func startIfAllowed() {
        if Self.isReadOnly {
            // This opt-in harness prepares its scratch catalog before loading the host.
            if UserDefaults.standard.string(forKey: "DirDeskSnapshotAction") == "mijiAcceptance" { return }
            ensureStarted()
            return
        }
        guard !UserDefaults.standard.bool(forKey: "DirDeskSnapshotHidden") else { return }
        Task {
            let granted = await Self.checkFullDiskAccess()
            hasFullDiskAccess = granted
            if granted { ensureStarted() }
        }
    }

    func ensureStarted() {
        guard !isStarted, !shutdownFlag.isSet else { return }
        if UserDefaults.standard.bool(forKey: "DirDeskSnapshotHidden") {
            guard Self.isReadOnly, UserDefaults.standard.string(forKey: "WumiSearchDatabase") != nil else { return }
        }
        launch()
    }
    var isBusy: Bool {
        if isStarted, engine == nil { return true }
        switch status.stage { case .indexing, .loadingSnapshot: return true; default: return false }
    }
    func rebuildIndex() {
        guard !Self.isReadOnly else { return }
        guard let host else { ensureStarted(); return }
        engine?.discardTemporaryIndexes()
        host.rebuildIndex()
    }
    func shutdown() {
        guard !shutdownFlag.isSet else { return }
        let hosts = detachHosts()
        setupQueue.sync { hosts.forEach { $0.shutdown() } }
    }
    func stopForTermination(completion: @escaping () -> Void) {
        let hosts = detachHosts()
        setupQueue.async {
            hosts.forEach { $0.shutdown() }
            // AppKit waits in a nested run loop for terminateLater. A test or menu
            // can call terminate from a main-queue block, so enqueue on the run loop.
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking], block: completion)
        }
    }
    private func detachHosts() -> [MijiIndexHost] {
        shutdownFlag.set(); indexFlag.set()
        interactionResume?.cancel(); interactionResume = nil
        catalogRefresh?.cancel(); catalogRefresh = nil
        host?.onStatus = nil
        host?.onCatalogChange = nil
        host?.onContentChange = nil
        let hosts = [host, pendingHost.take()].compactMap { $0 }
        host = nil; engine = nil
        return hosts
    }
    private func launch(updateRoots: Bool = false) {
        catalogRefresh?.cancel(); catalogRefresh = nil; pendingContentChange = false
        isStarted = true; indexFlag.set()
        let cancel = LightningFlag(); indexFlag = cancel
        let previous = host; previous?.onStatus = nil; previous?.onCatalogChange = nil; previous?.onContentChange = nil
        host = nil; engine = nil; status = LightningIndexStatus(stage: .loadingSnapshot)
        let target = Self.databaseURL, readOnly = Self.isReadOnly
        let watched = watchedFolders.map(Self.expandingTilde)
        let ignored = Self.savedIgnoredFolders(defaults: defaults, folders: ignoredFolders).map(Self.expandingTilde) + [Self.snapshotURL.deletingLastPathComponent().path]
        let folderSnapshot = (watchedFolders, ignoredFolders)
        let applyFolders = updateRoots || foldersNeedApplication
        let preferences = indexingPreferences
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/miji-extract")
        let shutdown = shutdownFlag
        let handoff = pendingHost, makeHost = hostFactory
        setupQueue.async { [weak self] in
            previous?.shutdown()
            guard !cancel.isSet, !shutdown.isSet else { return }
            do {
                let new = try makeHost(target, readOnly, ignored, helper)
                guard !cancel.isSet, !shutdown.isSet else { new.shutdown(); return }
                handoff.store(new)
                guard !cancel.isSet, !shutdown.isSet else { handoff.remove(new); new.shutdown(); return }
                try new.start(watchedFolders: watched, ignoredFolders: ignored, updateRoots: applyFolders, preferences: preferences)
                let roots = try new.roots()
                guard !cancel.isSet, !shutdown.isSet else { handoff.remove(new); new.shutdown(); return }
                Task { @MainActor [weak self] in
                    guard let self, !cancel.isSet, !shutdown.isSet else { handoff.remove(new); new.shutdown(); return }
                    handoff.remove(new)
                    self.host = new; self.engine = new.engine; self.status = new.status; self.roots = roots
                    if !readOnly && applyFolders { self.didApplyFolders(watched: folderSnapshot.0, ignored: folderSnapshot.1) }
                    self.contentGeneration += 1
                    self.indexGeneration += 1
                    new.onCatalogChange = { [weak self, weak observedHost = new] in
                        Task { @MainActor in
                            guard let self, let observedHost, self.host === observedHost else { return }
                            self.catalogDidChange()
                        }
                    }
                    new.onContentChange = { [weak self, weak observedHost = new] in
                        Task { @MainActor in
                            guard let self, let observedHost, self.host === observedHost else { return }
                            self.catalogDidChange(contentChanged: true)
                        }
                    }
                    new.onStatus = { [weak self, weak observedHost = new] status in
                        Task { @MainActor in
                            // Every observer of the service redraws on a publish, so skip repeats.
                            guard let self, let observedHost, self.host === observedHost, self.status != status else { return }
                            self.status = status
                        }
                    }
                    self.catalogDidChange()
                }
            } catch {
                handoff.take()?.shutdown()
                Task { @MainActor [weak self] in
                    guard let self, !cancel.isSet, !shutdown.isSet else { return }
                    self.status = LightningIndexStatus(stage: .failed(error.localizedDescription), lastError: error.localizedDescription)
                    self.isStarted = false
                }
            }
        }
    }

    /// Explicit saved exclusions are an upgrade contract; absent legacy keys keep
    /// the migrated Miji catalog's defaults instead of applying Wumi's old defaults.
    static func savedIgnoredFolders(defaults: UserDefaults, folders: [String]) -> [String] {
        defaults.bool(forKey: mappedFoldersKey) || defaults.object(forKey: ignoredFoldersKey) != nil ? folders : []
    }
    var foldersNeedApplication: Bool { defaults.bool(forKey: Self.pendingFoldersKey) }
    func didApplyFolders(watched: [String], ignored: [String]) {
        guard watched == watchedFolders, ignored == ignoredFolders else { return }
        defaults.set(false, forKey: Self.pendingFoldersKey)
    }
    /// Roots must be published before the query generation that depends on them.
    /// Body notifications share this coalescer; metadata-only changes keep cached FTS hits.
    func catalogDidChange(contentChanged: Bool = false) {
        guard let observedHost = host else { return }
        pendingContentChange = pendingContentChange || contentChanged
        guard catalogRefresh == nil else { return }
        catalogRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, self.host === observedHost else { return }
            let queue = self.setupQueue
            let updatedRoots: [IndexedRoot]? = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: try? observedHost.roots()) }
            }
            guard !Task.isCancelled, self.host === observedHost else { return }
            self.catalogRefresh = nil
            if let updatedRoots, self.roots != updatedRoots { self.roots = updatedRoots }
            if self.pendingContentChange { self.pendingContentChange = false; self.contentGeneration += 1 }
            self.indexGeneration += 1
        }
    }

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

    func updateFolders(watched: [String], ignored: [String]) {
        guard watched != watchedFolders || ignored != ignoredFolders || !defaults.bool(forKey: Self.mappedFoldersKey) || foldersNeedApplication else { return }
        defaults.set(true, forKey: Self.mappedFoldersKey)
        defaults.set(true, forKey: Self.pendingFoldersKey)
        watchedFolders = watched; ignoredFolders = ignored
        defaults.set(watched, forKey: Self.watchedFoldersKey)
        defaults.set(ignored, forKey: Self.ignoredFoldersKey)
        if isStarted { launch(updateRoots: true) }
    }

    func updateIndexingPreferences(_ value: IndexingPreferences) {
        indexingPreferences = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.indexingPreferencesKey) }
        pendingHost.configure(value)
        host?.configure(value)
    }
    func refreshRoots() {
        guard let current = host else { return }
        setupQueue.async { [weak self] in
            let roots = (try? current.roots()) ?? []
            Task { @MainActor in guard let self, self.host === current else { return }; self.roots = roots }
        }
    }
    func setRootEnabled(id: String, enabled: Bool) {
        host?.setRootEnabled(id: id, enabled: enabled) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.status.lastError = error.localizedDescription }
                self.refreshRoots()
            }
        }
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
