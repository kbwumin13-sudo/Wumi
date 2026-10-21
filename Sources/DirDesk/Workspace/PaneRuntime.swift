import AppKit
import Combine
import DirDeskCore

/// Live state of one browser pane: destination, loaded items, derived rows, selection and history.
@MainActor
final class PaneRuntime: ObservableObject, Identifiable {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// Why the last load failed, for the pane's state view.
    enum LoadFailure: Equatable {
        case accessDenied, notDirectory, unavailable, spotlight
    }

    /// One displayed row in list-style views: a group header or an item at a depth (inline-expanded folders).
    enum Row: Hashable, Sendable {
        case group(FileGroup.ID, title: String, count: Int)
        case item(FileItem, depth: Int)

        var item: FileItem? {
            if case .item(let item, _) = self { return item }
            return nil
        }
    }

    let id: UUID
    @Published private(set) var history: NavigationHistory
    @Published var viewConfiguration: ViewConfiguration {
        didSet {
            guard oldValue != viewConfiguration else { return }
            if !applyingFolderDisplay { folderDisplayChanged(from: oldValue) }
            // Entering a folder sorts its items once they are loaded, not the previous folder's items now.
            if !enteringFolder { rebuildRows() }
            onStateChange?()
        }
    }
    /// Grouping and folders-first that folders without remembered rules return to.
    private(set) var folderDisplayBaseline: FolderDisplayBaseline
    private var applyingFolderDisplay = false
    private var enteringFolder = false
    private var defaultSorting: (key: FileSortKey, ascending: Bool)
    private var defaultsObserver: AnyCancellable?
    @Published var searchText: String = "" { didSet { if oldValue != searchText { rebuildRows() } } }
    @Published var searchMode: SearchInputMode = .keyword
    @Published var searchRecursively = true
    @Published private(set) var items: [FileItem] = []
    /// Changes only when a successful directory read replaces its contents (including same-URL reloads).
    @Published private(set) var directoryContentRevision = 0
    @Published private(set) var rows: [Row] = []
    @Published private(set) var groups: [FileGroup] = []
    @Published private(set) var loadState: LoadState = .idle
    private(set) var loadFailure: LoadFailure?
    /// Metadata of the current folder itself, loaded off the main thread with its contents.
    @Published private(set) var directoryItem: FileItem?
    /// True while the current rows revision is being derived. Small, pure-memory updates remain synchronous.
    @Published private(set) var isRebuildingRows = false
    @Published private(set) var hasPendingSelection = false
    @Published private(set) var truncated = false
    @Published var selectedIDs: Set<FileIdentity> = [] {
        didSet {
            if !applyingSelection {
                pendingSelection = []
                pendingSelectionActions = []
                selectionRevision += 1
                selectionTask?.cancel()
                selectionTask = nil
            }
            if oldValue != selectedIDs { onSelectionChange?() }
        }
    }
    @Published private(set) var expandedPaths: Set<String> = []
    @Published var renamingID: FileIdentity?
    @Published var operationMessage: String?
    /// Result of a finished operation shown in the status bar ("Processed 0 items, 1 failed…") until dismissed.
    @Published var operationResult: OperationResult?

    struct OperationResult: Equatable {
        var summary: String
        var details: [String]
        /// "…" after the summary when the details say more (failures); none for a plain confirmation.
        var showsEllipsis = true
    }

    private var childrenCache: [String: [FileItem]] = [:]
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var loadCancellation: PaneLoadCancellation?
    private var tagsTask: Task<Void, Never>?
    private lazy var cloudObservation = CloudStatusObservation(
        urls: { [weak self] in self?.cloudRefreshURLs() ?? [] },
        receive: { [weak self] in self?.applyCloudStatuses($0) }
    )
    private var childrenTasks: [String: Task<Void, Never>] = [:]
    private var childrenRevisions: [String: Int] = [:]
    private var nextChildrenRevision = 0
    private var rowsTask: Task<Void, Never>?
    private var rowsRevision = 0
    private var measuredDirectorySizes: [String: Int64] = [:]
    private var sizeSortingTask: Task<Void, Never>?
    private var sizeRowsTask: Task<Void, Never>?
    private var sizeSortingAttempted: Set<String> = []
    private var sizeSortingVisiblePaths: Set<String> = []
    private var sizeSortingCurrentPath: String?
    private var sizeObservationActive = false
    private var awaitingLoadedRows = false
    private var displayedChildren: [String: [FileItem]] = [:]
    /// Canonical parent paths are populated by background loads; selection's synchronous path never does IO.
    private var resolvedParents: [String: String] = [:]
    private var selectionTask: Task<Void, Never>?
    private var selectionRevision = 0
    private var applyingSelection = false
    private var pendingSelection: Set<FileIdentity> = [] {
        didSet {
            let pending = !pendingSelection.isEmpty
            if hasPendingSelection != pending { hasPendingSelection = pending }
        }
    }
    private enum PendingSelectionAction { case all, invert }
    private var pendingSelectionActions: [PendingSelectionAction] = []
    /// First visible item of the list, kept by the list view and saved with the session.
    var scrollAnchorPath: String?
    /// Restored from a saved session; the list scrolls to it once after its first load, then clears it.
    var pendingScrollAnchor: String?
    var onStateChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onDirectoriesChanged: (() -> Void)?

    init(state: BrowserPaneState) {
        id = state.id
        history = state.history
        viewConfiguration = state.viewConfiguration
        searchText = state.searchText
        searchMode = state.searchMode
        searchRecursively = state.searchRecursively
        pendingSelection = Set(state.selectedIdentities)
        hasPendingSelection = !pendingSelection.isEmpty
        expandedPaths = Set(state.expandedPaths)
        folderDisplayBaseline = state.folderDisplayBaseline ?? FolderDisplayBaseline(state.viewConfiguration)
        pendingScrollAnchor = state.scrollAnchor
        scrollAnchorPath = state.scrollAnchor
        defaultSorting = Self.currentDefaultSorting()
        defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.defaultSortingMayHaveChanged() }
    }

    convenience init(directory: URL, configuration: ViewConfiguration) {
        self.init(state: BrowserPaneState(destination: .directory(directory), viewConfiguration: configuration))
    }

    deinit {
        loadCancellation?.cancel()
        loadTask?.cancel()
        tagsTask?.cancel()
        rowsTask?.cancel()
        selectionTask?.cancel()
        sizeSortingTask?.cancel()
        sizeRowsTask?.cancel()
        for task in childrenTasks.values { task.cancel() }
    }

    var state: BrowserPaneState {
        var state = BrowserPaneState(id: id, destination: history.current ?? .directory(URL(fileURLWithPath: NSHomeDirectory())),
                                     viewConfiguration: viewConfiguration)
        state.history = history
        state.searchText = searchText
        state.searchMode = searchMode
        state.searchRecursively = searchRecursively
        state.selectedIdentities = Array(pendingSelection.isEmpty ? selectedIDs : pendingSelection)
        state.expandedPaths = Array(expandedPaths).sorted()
        state.folderDisplayBaseline = folderDisplayBaseline
        state.scrollAnchor = scrollAnchorPath
        return state
    }

    var destination: PaneDestination? { history.current }
    var currentDirectory: URL? { history.current?.directoryURL }

    var title: String {
        switch history.current {
        case .directory(let url): PathUtilities.displayName(for: url)
        case .allSubfiles(let url): LF("All Subfiles of %@", PathUtilities.displayName(for: url))
        case .recent: L("Recent")
        case .tag(let name): name
        case nil: ""
        }
    }

    var selectedItems: [FileItem] {
        let all = items + childrenCache.values.flatMap { $0 }
        var seen = Set<FileIdentity>()
        return all.filter { selectedIDs.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// Directories this pane needs change notifications for.
    var watchedPaths: Set<String> {
        guard loadState != .idle, let directory = currentDirectory else { return [] }
        var paths = Set([directory.path] + expandedPaths)
        if ICloudDriveDirectory.isRoot(directory) {
            paths.insert(directory.deletingLastPathComponent().path)
            for item in items where item.presentationRole == .navigationAlias {
                paths.insert(item.url.path)
                paths.insert(item.url.deletingLastPathComponent().path)
            }
        }
        return paths
    }

    // MARK: Navigation

    func navigate(to destination: PaneDestination, record: Bool = true) {
        if record { history.visit(destination) }
        scrollAnchorPath = nil
        pendingScrollAnchor = nil
        enterFolderDisplay(for: destination)
        pendingSelection = []
        pendingSelectionActions = []
        selectedIDs = []
        expandedPaths = []
        childrenCache = [:]
        resolvedParents = [:]
        searchText = ""
        renamingID = nil
        load()
        onStateChange?()
        onDirectoriesChanged?()
    }

    func open(_ url: URL) {
        navigate(to: .directory(url.standardizedFileURL))
    }

    func goBack() {
        guard let destination = history.goBack() else { return }
        _ = destination
        navigate(to: history.current!, record: false)
    }

    func goForward() {
        guard let destination = history.goForward() else { return }
        _ = destination
        navigate(to: history.current!, record: false)
    }

    func goUp() {
        guard let directory = currentDirectory, directory.path != "/" else { return }
        let child = directory
        open(ICloudDriveDirectory.browsingParent(of: directory))
        pendingSelection = [FileIdentity(fallbackPath: child.path)]
    }

    var canGoUp: Bool { (currentDirectory?.path ?? "/") != "/" }

    // MARK: Loading

    /// Invalidate every descendant job before a new load, even when the destination has no directory URL.
    private func beginLoad() -> (generation: Int, cancellation: PaneLoadCancellation) {
        stopSizeSorting()
        measuredDirectorySizes.removeAll()
        sizeSortingAttempted.removeAll()
        FolderSizes.shared.invalidate(in: currentDirectory)
        loadGeneration += 1
        loadCancellation?.cancel()
        loadTask?.cancel()
        tagsTask?.cancel()
        tagsTask = nil
        cloudObservation.stop()
        cancelChildrenLoads()
        rowsRevision += 1
        rowsTask?.cancel()
        rowsTask = nil
        isRebuildingRows = false
        selectionTask?.cancel()
        selectionTask = nil
        awaitingLoadedRows = false
        let cancellation = PaneLoadCancellation()
        loadCancellation = cancellation
        loadFailure = nil
        return (loadGeneration, cancellation)
    }

    func load(preservingSelection: Bool = false) {
        let (generation, cancellation) = beginLoad()
        if case .recent(let filter) = destination {
            let visits = LibraryModel.shared.recent
            loadVirtual(generation: generation) { try Self.recentItems(filter: filter, visits: visits, cancellation: cancellation) }
            return
        }
        if case .allSubfiles(let root) = destination {
            loadVirtual(generation: generation) { try Self.allSubfiles(of: root) }
            return
        }
        if case .tag(let name) = destination {
            let legacyLabel = FinderTagCatalog.colorLabel(named: name)
            loadVirtual(generation: generation, failure: { error in
                (error as? SpotlightQuery.QueryError) == .timedOut
                    ? L("Spotlight took too long to answer. Try again in a moment.") : L("Spotlight couldn't search for this tag.")
            }) {
                let paths = try PaneBackgroundQuery.paths(matching: SpotlightQuery.tagQuery(name: name, legacyLabel: legacyLabel),
                                                         homeOnly: false, limit: 5000, timeout: 10, cancellation: cancellation)
                var found: [FileItem] = []
                for path in paths {
                    try Task.checkCancellation()
                    if let item = DirectoryLoader.item(at: URL(fileURLWithPath: path)) { found.append(item) }
                }
                return found
            }
            return
        }
        guard let directory = currentDirectory else {
            loadTask = nil
            items = []
            directoryItem = nil
            loadState = .loaded
            rebuildRows()
            return
        }
        if !preservingSelection || loadState == .idle {
            loadState = .loading
            directoryItem = nil
        }
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let isNetwork = (try? directory.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false
            let policy: DirectoryLoadingPolicy = isNetwork ? .network : .local
            guard !Task.isCancelled else { return }
            let folder = DirectoryLoader.item(at: directory)
            guard !Task.isCancelled else { return }
            PathUtilities.prefetchDisplayNames(PathUtilities.ancestors(of: directory))
            let result = Result { try DirectoryLoader.load(directory: directory, policy: policy, isCancelled: { Task.isCancelled }) }
            guard !Task.isCancelled else { return }
            let loadedItems = (try? result.get().items) ?? []
            let parents = Self.resolveParents(for: loadedItems.map(\.url))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration, !cancellation.isCancelled else { return }
                self.loadTask = nil
                self.directoryItem = folder
                self.resolvedParents.merge(parents) { _, new in new }
                switch result {
                case .success(let loaded):
                    self.items = loaded.items
                    if ICloudDriveDirectory.isRoot(directory) { self.onDirectoriesChanged?() }
                    self.directoryContentRevision += 1
                    self.truncated = loaded.truncated
                    self.loadFailure = nil
                    // Mark loaded only after this revision's rows have been published.
                    self.awaitingLoadedRows = true
                case .failure(let error):
                    self.items = []
                    self.truncated = false
                    self.loadFailure = Self.failure(for: error)
                    self.loadState = .failed(Self.message(for: error))
                    let nsError = error as NSError
                    ApplicationErrorLog.shared.record(message: Self.message(for: error), source: .directory, domain: nsError.domain, code: nsError.code)
                }
                self.rebuildRows()
                if case .success(let loaded) = result, loaded.tagsPending { self.fillTagsLater(loaded.items, generation: generation) }
            }
        }
        for path in expandedPaths { loadChildren(of: path) }
    }

    func reload() { load(preservingSelection: true) }

    /// Waits through superseded loads and revisions, including expanded children and deferred tags.
    /// Callers that need an exact rows snapshot (tests, rename-after-creation) can await this on MainActor.
    func waitForRows() async {
        while !Task.isCancelled {
            if let task = loadTask { await task.value; continue }
            if let task = childrenTasks.values.first { await task.value; continue }
            if let task = tagsTask { await task.value; continue }
            if let task = rowsTask { await task.value; continue }
            if let task = selectionTask { await task.value; continue }
            return
        }
    }

    /// Very large folders arrive without Finder tags; cancellation reaches the reader and merging stays off-main.
    private func fillTagsLater(_ loaded: [FileItem], generation: Int) {
        tagsTask?.cancel()
        tagsTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            var tagged = loaded
            DirectoryLoader.fillTags(&tagged, isCancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            let result = tagged
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.tagsTask = nil
                self.items = result
                self.rebuildRows()
            }
        }
    }

    /// Loads a virtual destination from a cancellable background query.
    private func loadVirtual(generation: Int,
                             failure message: @escaping (Error) -> String = { _ in L("Recent items could not be loaded.") },
                             _ query: @escaping @Sendable () throws -> [FileItem]) {
        loadState = .loading
        directoryItem = nil
        if case .tag = destination {
            items = []
            rebuildRows()
        }
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let result = Result { try query() }
            guard !Task.isCancelled else { return }
            let parents = Self.resolveParents(for: ((try? result.get()) ?? []).map(\.url))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                self.loadTask = nil
                self.resolvedParents.merge(parents) { _, new in new }
                switch result {
                case .success(let found):
                    self.items = found
                    self.truncated = false
                    self.awaitingLoadedRows = true
                case .failure(let error):
                    self.items = []
                    self.loadFailure = .spotlight
                    self.loadState = .failed(message(error))
                }
                self.rebuildRows()
            }
        }
        for path in expandedPaths { loadChildren(of: path) }
    }

    /// Every file below `root` (folders themselves are skipped), bounded like the original's flattened view.
    nonisolated static func allSubfiles(of root: URL, limit: Int = 100_000, maximumDepth: Int = 64) throws -> [FileItem] {
        try Task.checkCancellation()
        let keys = DirectoryLoader.keys(for: root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else { return [] }
        var result: [FileItem] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if enumerator.level > maximumDepth { enumerator.skipDescendants(); continue }
            let item = DirectoryLoader.makeItem(url: url, values: try? url.resourceValues(forKeys: Set(keys)))
            if item.isBrowsableFolder { continue }
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }

    /// macOS Last Used dates merged with items opened in DirDesk, newest first, within the filter's range.
    nonisolated static func recentItems(filter: RecentDateFilter, visits: [RecentActivityRecord],
                                        cancellation: PaneLoadCancellation = PaneLoadCancellation()) throws -> [FileItem] {
        let interval = filter.interval()
        var seen = Set<String>()
        var result: [FileItem] = []
        for visit in visits where interval.contains(visit.accessedAt) {
            try Task.checkCancellation()
            let path = visit.url.standardizedFileURL.path
            guard seen.insert(path).inserted, let item = DirectoryLoader.item(at: visit.url) else { continue }
            var copy = item
            copy.lastOpenedDate = max(copy.lastOpenedDate ?? .distantPast, visit.accessedAt)
            result.append(copy)
        }
        try Task.checkCancellation()
        let start = Int(interval.start.timeIntervalSinceNow)
        let end = Int(interval.end.timeIntervalSinceNow)
        let expression = "kMDItemLastUsedDate >= $time.now(\(start)) && kMDItemLastUsedDate <= $time.now(\(max(end, 0) + 60))"
            + " && kMDItemContentTypeTree != \"com.apple.application\""
        let paths = (try? PaneBackgroundQuery.paths(matching: expression, homeOnly: true, limit: 2000, cancellation: cancellation)) ?? []
        try Task.checkCancellation()
        for path in paths where seen.insert(path).inserted {
            try Task.checkCancellation()
            if let item = DirectoryLoader.item(at: URL(fileURLWithPath: path)) { result.append(item) }
        }
        return result
    }

    /// Called by the watcher hub when one of `watchedPaths` changed on disk.
    func directoryChanged(_ path: String) {
        guard loadState != .idle else { return }
        if path == currentDirectory?.path || (currentDirectory.map(ICloudDriveDirectory.isRoot) == true && watchedPaths.contains(path)) {
            load(preservingSelection: true)
        } else if expandedPaths.contains(path) {
            loadChildren(of: path)
        }
    }

    private func restorePendingSelection(clearUnmatched: Bool = false) {
        guard loadState == .loaded, !pendingSelection.isEmpty else { return }
        let requested = pendingSelection
        if rows.count <= 256 {
            let candidates = rows.compactMap(\.item)
            let urls = candidates.map(\.url) + requested.map { URL(fileURLWithPath: $0.fallbackPath) }
            if Self.hasResolvedParents(for: urls, in: resolvedParents) {
                finishPendingSelection(requested, matched: Self.matchSelection(requested, candidates: candidates, parents: resolvedParents),
                                       clearUnmatched: clearUnmatched)
                return
            }
        }
        selectionTask?.cancel()
        let revision = selectionRevision
        let rowsVersion = rowsRevision
        let generation = loadGeneration
        let known = resolvedParents
        let snapshot = rows
        selectionTask = Task.detached(priority: .userInitiated) { [weak self] in
            let candidates = snapshot.compactMap(\.item)
            let urls = candidates.map(\.url) + requested.map { URL(fileURLWithPath: $0.fallbackPath) }
            let parents = Self.resolveParents(for: urls, known: known)
            guard !Task.isCancelled else { return }
            let matched = Self.matchSelection(requested, candidates: candidates, parents: parents)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration, rowsVersion == self.rowsRevision,
                      revision == self.selectionRevision else { return }
                self.selectionTask = nil
                self.resolvedParents.merge(parents) { _, new in new }
                self.finishPendingSelection(requested, matched: matched, clearUnmatched: clearUnmatched)
            }
        }
    }

    private func finishPendingSelection(_ requested: Set<FileIdentity>, matched: Set<FileIdentity>, clearUnmatched: Bool) {
        guard requested == pendingSelection else { return }
        if !matched.isEmpty {
            applyingSelection = true
            selectedIDs = matched
            applyingSelection = false
        }
        // A request made before the next reload must survive an empty match (duplicate/paste callers do this).
        if (!matched.isEmpty || clearUnmatched), loadTask == nil && childrenTasks.isEmpty && !awaitingLoadedRows {
            pendingSelection = []
        }
    }

    nonisolated private static func matchSelection(_ requested: Set<FileIdentity>, candidates: [FileItem],
                                                   parents: [String: String]) -> Set<FileIdentity> {
        let paths = Set(requested.map { cachedComparablePath(URL(fileURLWithPath: $0.fallbackPath), parents: parents) })
        return Set(candidates.filter { requested.contains($0.id) || paths.contains(cachedComparablePath($0.url, parents: parents)) }.map(\.id))
    }

    static func failure(for error: Error) -> LoadFailure {
        switch error as? DirectoryLoaderError {
        case .accessDenied: .accessDenied
        case .notDirectory: .notDirectory
        case .unavailable, nil: .unavailable
        }
    }

    static func message(for error: Error) -> String {
        switch error as? DirectoryLoaderError {
        case .accessDenied: L("Allow access to this folder to view its files.")
        case .notDirectory: L("The destination is not a folder.")
        case .unavailable, nil: L("This folder moved, disappeared, or is no longer accessible.")
        }
    }

    // MARK: Inline expansion (list view disclosure triangles)

    func isExpanded(_ item: FileItem) -> Bool { expandedPaths.contains(item.url.path) }

    func toggleExpansion(_ item: FileItem) {
        guard item.isBrowsableFolder else { return }
        if expandedPaths.contains(item.url.path) {
            expandedPaths = expandedPaths.filter { $0 != item.url.path && !$0.hasPrefix(item.url.path + "/") }
            cancelChildrenLoads(keeping: expandedPaths)
            rebuildRows()
        } else {
            expandedPaths.insert(item.url.path)
            loadChildren(of: item.url.path)
        }
        onStateChange?()
        onDirectoriesChanged?()
    }

    func collapseAll() {
        expandedPaths = []
        cancelChildrenLoads()
        rebuildRows()
        onDirectoriesChanged?()
    }

    private func cancelChildrenLoads(keeping paths: Set<String> = []) {
        for path in Array(childrenTasks.keys) where !paths.contains(path) {
            childrenTasks.removeValue(forKey: path)?.cancel()
            childrenRevisions.removeValue(forKey: path)
        }
    }

    private func loadChildren(of path: String) {
        guard expandedPaths.contains(path), loadState != .idle else { return }
        // At most one job per expanded path; a watcher reload supersedes the previous snapshot.
        childrenTasks.removeValue(forKey: path)?.cancel()
        nextChildrenRevision += 1
        let revision = nextChildrenRevision
        childrenRevisions[path] = revision
        let generation = loadGeneration
        let url = URL(fileURLWithPath: path, isDirectory: true)
        stopSizeSorting()
        let prefix = path + "/"
        measuredDirectorySizes = measuredDirectorySizes.filter {
            $0.key != path && !$0.key.hasPrefix(prefix) && !path.hasPrefix($0.key + "/")
        }
        sizeSortingAttempted = sizeSortingAttempted.filter {
            $0 != path && !$0.hasPrefix(prefix) && !path.hasPrefix($0 + "/")
        }
        FolderSizes.shared.invalidate(in: url)
        childrenTasks[path] = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            let loaded = (try? DirectoryLoader.load(directory: url, policy: DirectoryLoadingPolicy(maximumItems: 2000, batchSize: 400),
                                                   isCancelled: { Task.isCancelled }))?.items ?? []
            guard !Task.isCancelled else { return }
            let parents = Self.resolveParents(for: loaded.map(\.url))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration, self.childrenRevisions[path] == revision,
                      self.expandedPaths.contains(path) else { return }
                self.childrenTasks.removeValue(forKey: path)
                self.childrenRevisions.removeValue(forKey: path)
                self.resolvedParents.merge(parents) { _, new in new }
                self.childrenCache[path] = loaded
                self.directoryContentRevision += 1
                self.rebuildRows()
            }
        }
    }

    // MARK: Derived rows

    func kindText(_ item: FileItem) -> String {
        FileKindDescriber.describe(item, folderTitle: L("Folder"), aliasTitle: L("Alias"), fileTitle: L("File"))
    }

    /// Sorted, filtered top-level items. Large revisions publish asynchronously together with `rows`.
    private(set) var displayItems: [FileItem] = []

    func children(of item: FileItem) -> [FileItem]? { displayedChildren[item.url.path] }

    func rebuildRows() {
        rowsRevision += 1
        let revision = rowsRevision
        let generation = loadGeneration
        rowsTask?.cancel()
        rowsTask = nil
        selectionTask?.cancel()
        selectionTask = nil
        // Don't let a partial first tree consume a restored scroll anchor or drop a saved child selection.
        if (pendingScrollAnchor != nil || !pendingSelection.isEmpty), !childrenTasks.isEmpty {
            isRebuildingRows = true
            return
        }
        let input = PaneRowDerivation(items: items, children: childrenCache, expandedPaths: expandedPaths,
                                      configuration: viewConfiguration, searchText: searchText, locale: Localizer.shared.locale,
                                      folderTitle: L("Folder"), aliasTitle: L("Alias"), fileTitle: L("File"),
                                      directorySizes: measuredDirectorySizes)
        if input.canRunSynchronously, let output = try? input.build() {
            publishRows(output, revision: revision, generation: generation)
            return
        }
        isRebuildingRows = true
        rowsTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let output = try? input.build(), !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration, revision == self.rowsRevision else { return }
                self.rowsTask = nil
                self.publishRows(output, revision: revision, generation: generation)
            }
        }
    }

    private func publishRows(_ output: PaneRowDerivation.Output, revision: Int, generation: Int) {
        guard generation == loadGeneration, revision == rowsRevision else { return }
        displayItems = output.displayItems
        displayedChildren = output.children
        groups = output.groups
        rows = output.rows
        if awaitingLoadedRows {
            awaitingLoadedRows = false
            loadState = .loaded
        }
        if loadState == .loaded && loadTask == nil && childrenTasks.isEmpty {
            let kept = selectedIDs.intersection(output.visibleIDs)
            if kept != selectedIDs {
                applyingSelection = true
                selectedIDs = kept
                applyingSelection = false
            }
        }
        if !pendingSelectionActions.isEmpty {
            let actions = pendingSelectionActions
            pendingSelectionActions = []
            pendingSelection = []
            selectionRevision += 1
            selectionTask?.cancel()
            selectionTask = nil
            var selection = selectedIDs
            for action in actions {
                switch action {
                case .all: selection = output.visibleIDs
                case .invert: selection = output.visibleIDs.subtracting(selection)
                }
            }
            selectedIDs = selection
        } else {
            restorePendingSelection(clearUnmatched: true)
        }
        isRebuildingRows = false
        cloudObservation.refresh()
        updateSizeSorting()
    }

    func recordDirectorySize(_ item: FileItem, state: FolderSizeState) {
        guard state.finished, state.measurement.isComplete,
              measuredDirectorySizes[item.url.path] != state.measurement.bytes else { return }
        measuredDirectorySizes[item.url.path] = state.measurement.bytes
        if viewConfiguration.sortKey == .size, sizeRowsTask == nil {
            sizeRowsTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self else { return }
                self.sizeRowsTask = nil
                self.rebuildRows()
            }
        }
    }

    func stopSizeSorting() {
        sizeSortingTask?.cancel()
        sizeSortingTask = nil
        sizeRowsTask?.cancel()
        sizeRowsTask = nil
        sizeSortingCurrentPath = nil
    }

    func setSizeObservationActive(_ active: Bool) {
        guard active != sizeObservationActive else { return }
        sizeObservationActive = active
        if active {
            // A view can disappear between measurement and the coalesced rows commit.
            if loadState == .loaded, viewConfiguration.sortKey == .size { rebuildRows() }
            else { updateSizeSorting() }
        } else { stopSizeSorting() }
    }

    private func updateSizeSorting() {
        guard sizeObservationActive, loadState == .loaded, viewConfiguration.sortKey == .size else { stopSizeSorting(); return }
        // An explicit size sort also needs off-screen folders, otherwise scrolling would change its answer.
        let folders = rows.compactMap(\.item).filter(FolderSizes.needsMeasurement)
        sizeSortingVisiblePaths = Set(folders.map { $0.url.path })
        if let current = sizeSortingCurrentPath, !sizeSortingVisiblePaths.contains(current) {
            sizeSortingTask?.cancel()
            sizeSortingTask = nil
            sizeSortingCurrentPath = nil
        }
        guard sizeSortingTask == nil else { return }
        let candidates = folders.filter { !sizeSortingAttempted.contains($0.url.path) }
        guard !candidates.isEmpty else { return }
        let generation = loadGeneration
        sizeSortingTask = Task { [weak self] in
            for (index, item) in candidates.enumerated() {
                guard !Task.isCancelled, let self, generation == self.loadGeneration else { return }
                guard self.sizeSortingVisiblePaths.contains(item.url.path) else { continue }
                self.sizeSortingCurrentPath = item.url.path
                for await state in FolderSizes.shared.updates(for: item) {
                    guard !Task.isCancelled, generation == self.loadGeneration else { return }
                    self.recordDirectorySize(item, state: state)
                    if state.finished { self.sizeSortingAttempted.insert(item.url.path) }
                }
                guard !Task.isCancelled, generation == self.loadGeneration else { return }
                self.sizeSortingCurrentPath = nil
                if index % 64 == 0 { await Task.yield() }
            }
            guard !Task.isCancelled, let self, generation == self.loadGeneration else { return }
            self.sizeSortingTask = nil
            self.updateSizeSorting()
        }
    }

    /// Observe only pending/active items in the displayed rows, without enumerating their directories again.
    private func cloudRefreshURLs() -> [URL] {
        guard loadState == .loaded else { return [] }
        var paths = Set<String>()
        return rows.compactMap { row in
            guard let item = row.item, item.cloudStatus?.needsStatusRefresh == true,
                  paths.insert(item.url.standardizedFileURL.path).inserted else { return nil }
            return item.url
        }
    }

    /// A status-only update preserves the current selection, preview revision and icon requests.
    private func applyCloudStatuses(_ statuses: [String: FileCloudStatus]) {
        guard !statuses.isEmpty else { return }
        func patch(_ source: [FileItem]) -> [FileItem]? {
            var result = source
            var changed = false
            for index in result.indices where result[index].cloudStatus?.needsStatusRefresh == true {
                guard let status = statuses[result[index].url.standardizedFileURL.path],
                      status != result[index].cloudStatus else { continue }
                result[index].cloudStatus = status
                changed = true
            }
            return changed ? result : nil
        }
        var changed = false
        if let updated = patch(items) { items = updated; changed = true }
        for path in expandedPaths {
            if let children = childrenCache[path], let updated = patch(children) {
                childrenCache[path] = updated
                changed = true
            }
        }
        if changed { rebuildRows() }
    }

    // MARK: View configuration helpers

    func setSort(_ key: FileSortKey) {
        if viewConfiguration.sortKey == key {
            viewConfiguration.sortAscending.toggle()
        } else {
            viewConfiguration.sortKey = key
            viewConfiguration.sortAscending = key == .name || key == .kind || key == .fileExtension || key == .tags
        }
    }

    func selectAll() {
        if isRebuildingRows { pendingSelectionActions.append(.all); return }
        selectedIDs = Set(rows.compactMap { $0.item?.id })
    }

    func invertSelection() {
        if isRebuildingRows { pendingSelectionActions.append(.invert); return }
        let all = Set(rows.compactMap { $0.item?.id })
        selectedIDs = all.subtracting(selectedIDs)
    }

    func select(urls: [URL]) {
        selectionRevision += 1
        selectionTask?.cancel()
        selectionTask = nil
        pendingSelectionActions = []
        pendingSelection = Set(urls.map { FileIdentity(fallbackPath: $0.path) })
        guard !isRebuildingRows else { return }
        restorePendingSelection()
    }

    /// Resolves only parent directories, so a symlink still matches itself. Must run off MainActor.
    nonisolated private static func resolveParents(for urls: [URL], known: [String: String] = [:]) -> [String: String] {
        var parents = known
        for url in urls {
            if Task.isCancelled { break }
            let parent = url.standardizedFileURL.deletingLastPathComponent().path
            if parents[parent] == nil {
                parents[parent] = URL(fileURLWithPath: parent, isDirectory: true).resolvingSymlinksInPath().path
            }
        }
        return parents
    }

    nonisolated private static func hasResolvedParents(for urls: [URL], in parents: [String: String]) -> Bool {
        urls.allSatisfy { parents[$0.standardizedFileURL.deletingLastPathComponent().path] != nil }
    }

    nonisolated private static func cachedComparablePath(_ url: URL, parents: [String: String]) -> String {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().path
        return ((parents[parent] ?? parent) as NSString).appendingPathComponent(standardized.lastPathComponent)
    }

    // MARK: Folder sorting and grouping

    private static func currentDefaultSorting() -> (key: FileSortKey, ascending: Bool) {
        let configuration = AppModel.shared.defaultViewConfiguration
        return (configuration.sortKey, configuration.sortAscending)
    }

    private func standardRules() -> FolderDisplayRules {
        .standard(sortKey: defaultSorting.key, ascending: defaultSorting.ascending, baseline: folderDisplayBaseline)
    }

    private func rememberedRules(for destination: PaneDestination?) -> FolderDisplayRules? {
        guard case .directory(let url)? = destination, FolderDisplayStore.shared.isEnabled else { return nil }
        return FolderDisplayStore.shared.rules(for: url)
    }

    private func setFolderDisplay(_ rules: FolderDisplayRules) {
        var configuration = viewConfiguration
        rules.apply(to: &configuration)
        applyingFolderDisplay = true
        viewConfiguration = configuration
        applyingFolderDisplay = false
    }

    /// Entering a folder: its remembered rules, or the default sorting with the pane's grouping. Sorting changed
    /// in the previous folder ends here.
    private func enterFolderDisplay(for destination: PaneDestination) {
        guard case .directory = destination else { return }
        enteringFolder = true
        setFolderDisplay(rememberedRules(for: destination) ?? standardRules())
        enteringFolder = false
    }

    /// A manual change of sorting, grouping or folders-first. With remembering on it is stored for this folder
    /// (and forgotten once it matches the standard rules again); otherwise grouping and folders-first carry over
    /// to the next folders, sorting does not.
    private func folderDisplayChanged(from old: ViewConfiguration) {
        let rules = FolderDisplayRules(viewConfiguration)
        guard rules != FolderDisplayRules(old), case .directory(let url)? = destination else { return }
        if FolderDisplayStore.shared.isEnabled {
            if rules == standardRules() {
                FolderDisplayStore.shared.forget(url)
            } else {
                FolderDisplayStore.shared.remember(rules, for: url)
            }
        } else {
            folderDisplayBaseline = FolderDisplayBaseline(viewConfiguration)
        }
    }

    /// Settings › General › Default file sorting applies at once to folders without remembered rules.
    private func defaultSortingMayHaveChanged() {
        let current = Self.currentDefaultSorting()
        guard current.key != defaultSorting.key || current.ascending != defaultSorting.ascending else { return }
        let previous = standardRules()
        defaultSorting = current
        guard rememberedRules(for: destination) == nil else { return }
        // Only a folder still showing the previous default follows; a temporary sort the user chose stays.
        let shown = FolderDisplayRules(viewConfiguration)
        guard shown.sortKey == previous.sortKey, shown.ascending == previous.ascending else { return }
        var rules = shown
        rules.sortKey = current.key
        rules.ascending = current.ascending
        setFolderDisplay(rules)
    }
}
