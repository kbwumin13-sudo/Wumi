import AppKit
import Combine
import DirDeskCore
import PDFKit
import MijiCore
import Darwin

private final class MijiSearchTicket: @unchecked Sendable {
    private let lock = NSLock()
    let snapshot: MijiSearchSnapshot?
    let background: Bool
    let startedAt = Date()
    init(snapshot: MijiSearchSnapshot? = nil, background: Bool = false) {
        self.snapshot = snapshot; self.background = background
    }
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Owned by one serial queue. The connection is query-only and never initializes a schema.
private final class MijiSearchReader: @unchecked Sendable {
    private var database: SearchDatabase?
    func open(_ url: URL) throws -> SearchDatabase {
        if let database, database.url == url { return database }
        let reader = try SearchDatabase(url: url, readOnly: true)
        database = reader
        return reader
    }
}

/// A path: term is relative to its indexed root and matches substrings in Miji.
/// Check the absolute directory boundary as well, expanding candidates until the
/// scoped top-N is full or the engine is exhausted (never filter a fixed top-N).
private struct MijiSearchPlan {
    var query: String
    var options: SearchOptions
    var directory: String?

    func contains(_ hit: SearchHit) -> Bool {
        guard let directory else { return true }
        return hit.path.hasPrefix(directory)
    }

    static func make(query: String, options: SearchOptions, folder: URL?, roots: [IndexedRoot]) -> [Self] {
        guard let folder else { return [Self(query: query, options: options)] }
        let path = folder.standardizedFileURL.path
        let prefix = path == "/" ? "/" : path + "/"
        // Re-quote parsed terms: an unfinished user quote must not swallow the scope.
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let text = QueryParser.parse(query).terms.map {
            ($0.isExcluded ? "-" : "") + ($0.field == .text ? "" : $0.field.rawValue + ":") + quote($0.value)
        }.joined(separator: " ")
        return roots.compactMap { root in
            // Pausing indexing retains searchable rows; the folder boundary still applies.
            guard options.rootID == nil || options.rootID == root.id else { return nil }
            let rootPath = URL(fileURLWithPath: root.path).standardizedFileURL.path
            let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
            var scoped = options
            scoped.rootID = root.id
            if path == rootPath || rootPath.hasPrefix(prefix) {
                return Self(query: text, options: scoped, directory: prefix)
            }
            guard path.hasPrefix(rootPrefix) else { return nil }
            let relative = String(path.dropFirst(rootPrefix.count)) + "/"
            return Self(query: text + " path:" + quote(relative), options: scoped, directory: prefix)
        }
    }
}

/// Miji's native name + supplementary search session on Wumi's single index host.
@MainActor
final class MijiSearchModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var hits: [SearchHit] = []
    @Published var selectedID: Int64? { didSet { if selectedID != oldValue { loadPreview() } } }
    @Published var kind: FileKind? { didSet { if kind != oldValue { scheduleSearch() } } }
    @Published var rootID: String? { didSet { if rootID != oldValue { scheduleSearch() } } }
    @Published var scope = SearchScope.all { didSet { if scope != oldValue { scheduleSearch() } } }
    @Published var sort = SearchSort.relevance { didSet { if sort != oldValue { scheduleSearch() } } }
    @Published var context: URL? { didSet { if context != oldValue { scheduleSearch() } } }
    @Published var currentFolderOnly: Bool { didSet { if currentFolderOnly != oldValue { scheduleSearch() } } }
    @Published private(set) var roots: [IndexedRoot] = []
    private var rootPaths: [String: String] = [:]
    @Published private(set) var statistics = IndexStatistics()
    @Published private(set) var progress = IndexProgress()
    @Published private(set) var searching = false
    @Published private(set) var refreshing = false
    @Published private(set) var searchMilliseconds: Double = 0
    @Published var message: String?
    @Published private(set) var previewText = ""
    @Published private(set) var previewWarning: String?
    @Published var focusSearch = UUID()
    var onReveal: (URL) -> Void
    var onDismiss: () -> Void = {}
    var onChooseDestination: ([URL], Bool) -> Void = { FileOpenRouter.chooseDestination(for:$0,move:$1) }
    var onStageFiles: ([URL]) -> Void = { FileTransitStore.shared.add($0) }

    @Published private(set) var currentSnapshot: MijiSearchSnapshot?
    @Published private(set) var displayedSnapshot: MijiSearchSnapshot?
    @Published private(set) var searchPhase = MijiSearchPhase.idle
    @Published private(set) var firstBatchMilliseconds: Double?
    @Published private(set) var completedMilliseconds: Double?
    @Published private(set) var searchError: String?
    @Published private(set) var searchLimited = false
    private var generation: UInt64 = 0
    var onlineOnly: Bool {
        get { !service.indexingPreferences.retainOffline }
        set { var value = service.indexingPreferences; value.retainOffline = !newValue; service.updateIndexingPreferences(value) }
    }

    private let localPreviewURL: @Sendable (SearchHit) -> URL?
    private let service = LightningSearchService.shared
    private let searchQueue = DispatchQueue(label: "wumi.miji.native-search", qos: .userInitiated)
    private let contentQueue = DispatchQueue(label: "wumi.miji.native-content", qos: .utility)
    private let previewQueue = DispatchQueue(label: "wumi.miji.native-preview", qos: .utility)
    private let searchReader = MijiSearchReader()
    private let contentReader = MijiSearchReader()
    private let previewReader = MijiSearchReader()
    private var subscriptions: Set<AnyCancellable> = []
    private var searchWork: DispatchWorkItem?
    private var searchTicket: MijiSearchTicket?
    private var previewTicket: MijiSearchTicket?
    /// A session searches only while its container shows it and its window is really
    /// on screen. SwiftUI keeps the views of an ordered-out panel alive without calling
    /// onDisappear, so the window's own visibility is tracked separately.
    private var searchVisible: Bool { requestedVisible && windowVisible }
    private var requestedVisible = false
    /// Unknown until a hosting window reports; a session without a view counts as visible.
    private var windowVisible = true
    // While only the window is away, results stay; these record what to catch up on.
    private var resumeSearchWhenShown = false
    private var catalogChangedWhileHidden = false
    /// The container closed the session, so its results were cleared.
    private var clearedWhileHidden = false
    @Published var previewMode = MijiSearchPreviewMode.automatic {didSet {loadPreview()}}
    var previewEnabled: Bool {
        get {previewMode != .hidden}
        set {previewMode = newValue ? .shown : .hidden}
    }
    var previewVisible: Bool {searchPresented && MijiSearchPreviewPolicy.showsPane(mode:previewMode,hits:hits)}
    @Published var gridEnabled = false
    @Published private(set) var searchPresented = false
    @Published private(set) var previewLoading = false
    @Published private(set) var previewPage:Int?
    @Published private(set) var previewLine:Int?
    @Published private(set) var previewPDF:PDFDocument?
    @Published private(set) var previewLocalURL:URL?
    @Published var resultAreaWidth:CGFloat = 700
    var gridColumns:Int {max(1,Int((resultAreaWidth-24)/180))}
    private var previewKey:String?
    private var previewQuery=""
    private var refreshAfterSearch = false
    private var catalogRefreshWork: DispatchWorkItem?
    private var lastCatalogRefresh = Date.distantPast
    /// Content matches of the last complete search, reused when index changes refresh filenames.
    private var supplementaryCache: (request: String, hits: [SearchHit], limited: Bool)?
    static let catalogRefreshInterval: TimeInterval = 2

    init(context: URL? = nil, currentFolderOnly: Bool = false,
         localPreviewURL: @escaping @Sendable (SearchHit) -> URL? = { MijiPreviewResolver.localURL(for:$0) }, onReveal: @escaping (URL) -> Void = { _ in }) {
        self.localPreviewURL = localPreviewURL
        self.context = context
        self.currentFolderOnly = currentFolderOnly
        self.onReveal = onReveal
        service.$indexGeneration.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            guard self.searchVisible else {
                if self.requestedVisible { self.catalogChangedWhileHidden = true }
                return
            }
            if self.searching || self.searchWork != nil { self.refreshAfterSearch = true }
            else { self.scheduleCatalogRefresh() }
        }.store(in: &subscriptions)
        service.$contentGeneration.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else {return}
            self.supplementaryCache=nil;self.previewKey=nil
            guard self.searchVisible else {
                if self.requestedVisible {self.catalogChangedWhileHidden=true}
                return
            }
            if self.searching || self.searchWork != nil {self.refreshAfterSearch=true}
            else {self.scheduleCatalogRefresh()}
        }.store(in:&subscriptions)
        service.$roots.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self, self.roots != $0 else { return }
            let paths = Dictionary($0.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
            let pathsChanged = self.rootPaths != paths
            self.rootPaths = paths
            self.roots = $0
            if pathsChanged {
                // Mount identities are request conditions; invalidate before an A-B-A remount.
                // Hidden sessions invalidate now; scheduleSearch defers actual work until shown.
                self.scheduleSearch(preserveResults: true)
            }
        }.store(in: &subscriptions)
        service.$status.receive(on: DispatchQueue.main).sink { [weak self] status in
            guard let self, self.searchVisible else { return }
            self.apply(status)
        }.store(in: &subscriptions)
        service.$indexingPreferences.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.scheduleSearch()
        }.store(in: &subscriptions)
    }

    deinit { searchWork?.cancel(); searchTicket?.cancel(); previewTicket?.cancel(); catalogRefreshWork?.cancel() }

    var selected: SearchHit? { hits.first { $0.id == selectedID } }
    static func panelHeight(query: String, resultCount: Int) -> CGFloat {
        query.isEmpty ? 100 : CGFloat(150 + min(7, max(2, resultCount)) * 59)
    }
    static let previewWidth: CGFloat = 440
    var panelHeight: CGFloat {query.isEmpty ? 100 : (previewVisible || gridEnabled ? 563 : Self.panelHeight(query:query,resultCount:hits.count))}
    var panelWidth:CGFloat {!query.isEmpty && previewVisible ? 1060 : 800}

    /// The container shows or closes the session. Closing clears its results, as before.
    func setSearchVisible(_ visible: Bool) {
        let wasVisible = searchVisible
        requestedVisible = visible
        searchPresented = searchVisible
        if !visible {
            guard wasVisible || !clearedWhileHidden else { return }
            suspendPreview()
            clearedWhileHidden = true; resumeSearchWhenShown = false; catalogChangedWhileHidden = false
            scheduleSearch()
        } else if searchVisible && !wasVisible {
            focusSearch = UUID()
            becameVisible()
        }
    }

    /// Reported by the hosting window: false while it is ordered out, minimized,
    /// fully covered, on another Space, or while the app is hidden. Results and
    /// selection stay; work stops until the window is back.
    func setWindowVisible(_ visible: Bool) {
        let wasVisible = searchVisible
        windowVisible = visible
        searchPresented = searchVisible
        guard searchVisible != wasVisible else { return }
        if searchVisible { becameVisible(); return }
        if searching || searchWork != nil { resumeSearchWhenShown = true }
        if previewQuery != query {previewTicket?.cancel();previewKey=nil}
        searchWork?.cancel(); searchWork = nil
        searchTicket?.cancel(); searching = false; refreshing = false
        catalogRefreshWork?.cancel(); catalogRefreshWork = nil
        suspendPreview()
    }

    private func becameVisible() {
        service.ensureStarted(); apply(service.status)
        // The filename index may have been paged out while hidden; read it in while the user types.
        if let names = service.engine?.names { searchQueue.async { names.prefetch() } }
        if clearedWhileHidden || (hits.isEmpty && !query.isEmpty) {
            clearedWhileHidden = false; resumeSearchWhenShown = false; catalogChangedWhileHidden = false
            scheduleSearch()
        } else if resumeSearchWhenShown {
            resumeSearchWhenShown = false; catalogChangedWhileHidden = false
            scheduleSearch(preserveResults: true)
        } else if catalogChangedWhileHidden {
            catalogChangedWhileHidden = false
            scheduleCatalogRefresh()
        }
        loadPreview()
    }

    private func apply(_ status: LightningIndexStatus) {
        if statistics.files != status.indexedCount { statistics = IndexStatistics(files: status.indexedCount) }
        let phase: String
        switch status.stage {
        case .loadingSnapshot: phase = "正在加载文件目录"
        case .indexing: phase = "正在更新索引"
        case .failed(let reason): phase = reason
        default: phase = status.isUpdating ? "正在更新索引" : "准备就绪"
        }
        let busy = service.isBusy || status.isUpdating
        if progress.phase != phase || progress.processed != status.indexedCount || progress.busy != busy {
            progress = IndexProgress(phase: phase, processed: status.indexedCount, busy: busy)
        }
    }

    func refresh() { scheduleSearch(preserveResults: true) }

    /// Index changes refresh filename results at most every two seconds while the
    /// session is visible. Metadata changes reuse content matches; committed content
    /// changes invalidate that cache and share the same visible, rate-limited refresh.
    private func scheduleCatalogRefresh() {
        guard catalogRefreshWork == nil else { return }
        let wait = max(0, lastCatalogRefresh.addingTimeInterval(Self.catalogRefreshInterval).timeIntervalSinceNow)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.catalogRefreshWork = nil
            guard self.searchVisible else { return }
            if self.searching || self.searchWork != nil { self.refreshAfterSearch = true; return }
            self.lastCatalogRefresh = Date()
            self.scheduleSearch(preserveResults: true, namesOnly: true)
        }
        catalogRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func scheduleSearch(preserveResults: Bool = false, namesOnly: Bool = false) {
        let sameRequest = currentSnapshot == makeSnapshot(generation: generation)
        let background = preserveResults && completedMilliseconds != nil && displayedSnapshot != nil && displayedSnapshot == currentSnapshot && sameRequest
        if previewQuery != query {previewTicket?.cancel();previewKey=nil}
        searchWork?.cancel(); searchWork = nil
        searchTicket?.cancel(); searching = false; refreshAfterSearch = false
        if !namesOnly { catalogRefreshWork?.cancel(); catalogRefreshWork = nil }
        refreshing = background
        if !background {
            generation &+= 1
            currentSnapshot = makeSnapshot(generation: generation)
            searchError = nil; firstBatchMilliseconds = nil; completedMilliseconds = nil; searchLimited = false
            searchPhase = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .searching
            suspendPreview()
            if !preserveResults { selectedID = nil; searchMilliseconds = 0 }
        }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hits = []; selectedID = nil; searchMilliseconds = 0; displayedSnapshot = nil
            return
        }
        guard searchVisible, let engine = service.engine else {
            if !requestedVisible { hits=[]; selectedID=nil; displayedSnapshot=nil; searchPhase = .idle }
            else if !windowVisible { resumeSearchWhenShown = true }
            return
        }
        let typedQuery = query
        let options = SearchOptions(kind: kind, rootID: rootID, scope: scope, sort: sort,
                                    onlineOnly: !service.indexingPreferences.retainOffline, limit: 500)
        let request = [query, kind?.rawValue ?? "", rootID ?? "", "\(scope)", "\(sort)", context?.path ?? "",
                       "\(currentFolderOnly)", "\(options.onlineOnly)"].joined(separator: "\u{1f}")
        // A filename refresh keeps the content matches of the same request; without
        // them (or for content-only scope) it has nothing cheaper to offer.
        let cachedSupplementary = namesOnly ? supplementaryCache.flatMap { $0.request == request ? $0.hits : nil } : nil
        if namesOnly && cachedSupplementary == nil {
            scheduleSearch(preserveResults: true)
            return
        }
        // A new input request invalidates old rows during debounce; an execution
        // refreshing the same request keeps its committed rows and preview usable.
        searching = true
        let ticket = MijiSearchTicket(snapshot: currentSnapshot, background: background)
        let cachedLimited = namesOnly ? (supplementaryCache?.limited ?? false) : false
        searchTicket = ticket
        let plans = MijiSearchPlan.make(query: query, options: options,
                                       folder: currentFolderOnly ? context : nil, roots: roots)
        let contentRevision=service.contentGeneration
        let typedAt = Date(), reader = searchReader, contentReader = contentReader
        // Capture the already shared engine; do not load, refresh or replace its names.
        let names = engine.names, databaseURL = engine.databaseURL
        let work = DispatchWorkItem { [weak self] in
            guard let self, !ticket.isCancelled else { return }
            self.searchWork = nil; self.searching = true
            self.searchQueue.async { [weak self] in
                do {
                    guard !ticket.isCancelled else { return }
                    let database = try reader.open(databaseURL)
                    var first: [SearchHit] = []
                    if options.scope != .content {
                        for plan in plans {
                            var candidateOptions = plan.options; candidateOptions.scope = .name
                            let exclusions = options.scope == .all && QueryParser.parse(plan.query).terms.contains { $0.field == .text && $0.isExcluded }
                            var examined = 0, scoped: [SearchHit] = []
                            repeat {
                                let ids = try names.search(plan.query, options: candidateOptions, cancelled: { ticket.isCancelled })
                                let batch = try database.nameHits(ids: Array(ids.dropFirst(examined)), query: plan.query,
                                                                  verifyContentExclusions: exclusions, cancelled: { ticket.isCancelled })
                                scoped += batch.filter { plan.contains($0) }
                                if scoped.count >= options.limit || ids.count < candidateOptions.limit { break }
                                examined = ids.count; candidateOptions.limit *= 2
                            } while !ticket.isCancelled
                            first += scoped.prefix(options.limit)
                        }
                    }
                    let nameHits = Self.merge(first, [], query: typedQuery, options: options)
                    if let cachedSupplementary {
                        // Re-read the cached content matches by ID: deleted files drop out,
                        // renamed or moved ones show where they are now, offline ones follow
                        // the offline setting and the folder boundary still applies.
                        let rows = try database.nameHits(ids: cachedSupplementary.map(\.id), query: "", cancelled: { ticket.isCancelled })
                        let current = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        let refreshed = cachedSupplementary.compactMap { hit -> SearchHit? in
                            guard let row = current[hit.id], !options.onlineOnly || row.root.isOnline,
                                  plans.contains(where: { $0.contains(row) }) else { return nil }
                            return SearchHit(file: row.file, root: row.root, snippet: hit.snippet, matchedIn: hit.matchedIn, labels: hit.labels, contentRelevance: hit.contentRelevance)
                        }
                        let result = Self.merge(nameHits, refreshed, query: typedQuery, options: options)
                        DispatchQueue.main.async {
                            self?.publish(result, ticket: ticket, elapsed: nil, finished: true, preserveResults: true, limited: cachedLimited)
                        }
                        return
                    }
                    let finished = options.scope == .name
                    DispatchQueue.main.async {
                        if finished { self?.cacheSupplementary([], request: request, contentRevision: contentRevision, ticket: ticket) }
                        self?.publish(nameHits, ticket: ticket, elapsed: Date().timeIntervalSince(typedAt) * 1000, finished: finished, preserveResults: preserveResults)
                    }
                    guard !finished, !ticket.isCancelled else { return }
                    // Miji keeps supplementary content work off the name-search lane.
                    // A new filename query must not wait behind an earlier body search.
                    self?.contentQueue.async { [weak self] in
                    do {
                        guard !ticket.isCancelled else { return }
                        let database = try contentReader.open(databaseURL)
                        var supplementary: [SearchHit] = []
                        var limited = false
                        for plan in plans {
                            var candidateOptions = plan.options
                            let previous = supplementary
                            repeat {
                                var batchBudgetExhausted = false, batchTruncated = false
                                let extra = try database.searchSupplementary(plan.query, options: candidateOptions, cancelled: { ticket.isCancelled }, onPartial: { partial in
                                    let result = Self.merge(nameHits, previous + partial.filter { plan.contains($0) }, query: typedQuery, options: options)
                                    DispatchQueue.main.async {
                                        self?.publish(result, ticket: ticket, elapsed: nil, finished: false, preserveResults: preserveResults)
                                    }
                                }, onMetrics: { batchBudgetExhausted = $0.budgetExhausted; batchTruncated = $0.resultTruncated })
                                let scoped = extra.filter { plan.contains($0) }
                                if batchBudgetExhausted || scoped.count >= options.limit || extra.count < candidateOptions.limit {
                                    limited = limited || batchBudgetExhausted || batchTruncated
                                    supplementary += scoped.prefix(options.limit)
                                    break
                                }
                                candidateOptions.limit *= 2
                            } while !ticket.isCancelled
                        }
                        let result = Self.merge(nameHits, supplementary, query: typedQuery, options: options)
                        DispatchQueue.main.async {
                            self?.cacheSupplementary(supplementary, request: request, contentRevision: contentRevision, ticket: ticket, limited: limited)
                            self?.publish(result, ticket: ticket, elapsed: nameHits.isEmpty ? Date().timeIntervalSince(typedAt) * 1000 : nil, finished: true, preserveResults: preserveResults, limited: limited)
                        }
                        } catch {
                            DispatchQueue.main.async { self?.searchFailed(error, ticket: ticket) }
                        }
                    }
                } catch {
                    DispatchQueue.main.async { self?.searchFailed(error, ticket: ticket) }
                }
            }
        }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    private func searchFailed(_ error: Error, ticket: MijiSearchTicket) {
        guard !ticket.isCancelled, searchTicket === ticket, ticket.snapshot == currentSnapshot else { return }
        searching = false; refreshing = false
        if !(error is CancellationError) { searchError = error.localizedDescription; searchPhase = .failed; message = error.localizedDescription }
        if refreshAfterSearch { refreshAfterSearch = false; scheduleCatalogRefresh() }
    }

    private func cacheSupplementary(_ hits: [SearchHit], request: String, contentRevision: Int, ticket: MijiSearchTicket, limited: Bool = false) {
        guard !ticket.isCancelled, searchTicket === ticket, ticket.snapshot == currentSnapshot else { return }
        guard contentRevision == service.contentGeneration else {
            supplementaryCache=nil;refreshAfterSearch=true;return
        }
        supplementaryCache = (request, hits, limited)
    }

    nonisolated private static func merge(_ names: [SearchHit], _ extra: [SearchHit], query: String, options: SearchOptions) -> [SearchHit] {
        func unique(_ values: [SearchHit]) -> [SearchHit] { var ids = Set<Int64>(); return values.filter { ids.insert($0.id).inserted } }
        return SearchResultMerger.merge(nameResults: unique(names), contentResults: unique(extra), scope: options.scope, sort: options.sort, limit: options.limit, query: query)
    }

    private func publish(_ result: [SearchHit], ticket: MijiSearchTicket, elapsed: Double?, finished: Bool, preserveResults: Bool, limited: Bool = false) {
        guard !ticket.isCancelled, searchVisible, searchTicket === ticket, ticket.snapshot == currentSnapshot else { return }
        // A catalog refresh commits one complete result set. Its name-only phase
        // must not remove a selected content hit while supplementary work is pending.
        guard !preserveResults || finished else { return }
        let previousSelection = selected
        hits = result; searching = !finished; displayedSnapshot = ticket.snapshot
        refreshing = ticket.background && !finished
        searchPhase = finished ? .complete : .supplementing
        if !ticket.background {
            if firstBatchMilliseconds == nil { firstBatchMilliseconds = ticket.startedAt.timeIntervalSinceNow * -1000 }
            if finished { completedMilliseconds = ticket.startedAt.timeIntervalSinceNow * -1000 }
        }
        if finished { searchError = nil; searchLimited = limited }
        if let elapsed { searchMilliseconds = elapsed }
        if !result.contains(where: { $0.id == selectedID }) { selectedID = result.first?.id }
        let keepPreview = ticket.background && previousSelection.map { selectedID == $0.id && isCurrentResult($0) } == true
        loadPreview(keepingCurrentPreview: keepPreview)
        if finished, refreshAfterSearch { refreshAfterSearch = false; scheduleCatalogRefresh() }
    }

    func setPreviewVisible(_ visible:Bool) {previewEnabled=visible}
    private func suspendPreview() {
        previewTicket?.cancel();previewKey=nil;clearPreview();MijiPreviewThumbnails.clear()
    }
    func showPDFMatch() {
        guard let hit=selected,isCurrentResult(hit),let document=previewPDF,let page=previewPage else{return}
        let terms=MijiPreviewResolver.terms(in:query),title=selected?.file.name ?? "PDF"
        onDismiss()
        MijiPDFReaderController.shared.show(document:document,page:page,terms:terms,title:title)
    }
    private func loadPreview(keepingCurrentPreview: Bool = false) {
        guard searchVisible,previewVisible,let hit=selected,isCurrentResult(hit),MijiSearchPreviewPolicy.hasContent(hit),let engine=service.engine else {
            previewTicket?.cancel();previewKey=nil;clearPreview();return
        }
        let key="\(hit.id)|\(hit.path)|\(hit.file.inode)|\(hit.file.modified)|\(hit.file.size)|\(hit.file.contentState)|\(hit.file.contentError ?? "")|\(hit.root.isOnline)|\(query)|\(hit.matchedIn)|\(hit.snippet)|\(hit.labels)"
        guard key != previewKey else{return}
        let retain = keepingCurrentPreview && (!previewText.isEmpty || previewPDF != nil || previewLocalURL != nil)
        previewTicket?.cancel();previewKey=key;previewQuery=query
        if !retain { clearPreview() }
        let ticket=MijiSearchTicket();previewTicket=ticket;previewLoading = !retain
        let query=query
        let reader=previewReader,url=engine.databaseURL
        let resolveLocalURL=localPreviewURL
        previewQueue.async { [weak self] in
            guard !ticket.isCancelled else{return}
            let content=try? reader.open(url).storedContent(fileID:hit.id)
            var resolution=MijiPreviewResolver.resolve(hit:hit,content:content,query:query,cancelled:{ticket.isCancelled})
            guard !ticket.isCancelled else{return}
            let localURL=resolveLocalURL(hit)
            if (hit.file.kind == .code || hit.file.fileExtension.lowercased()=="pdf"),let url=localURL,
               let signature=try? FileSignature.read(url),!signature.matches(hit.file) {
                resolution.page=nil;resolution.line=nil
                resolution.warning=[resolution.warning,"文件已变化，正文为上次索引内容；位置将在索引更新后恢复"].compactMap{$0}.joined(separator:"；")
            }
            var document:PDFDocument?
            if hit.file.fileExtension.lowercased()=="pdf",let url=localURL {
                let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize
                if let size,size<=64*1024*1024 {
                    document=PDFDocument(url:url)
                    if document?.isLocked == true {document=nil;resolution.warning="PDF 已加密，无法显示原文预览"}
                    else if document == nil {resolution.warning="PDF 无法读取，显示已索引内容"}
                } else {resolution.warning="PDF 较大，使用快速查看打开原文件"}
            }
            DispatchQueue.main.async {
                guard let self,!ticket.isCancelled,self.searchVisible,self.selectedID==hit.id,self.isCurrentResult(hit) else { return }
                self.previewText=resolution.text;self.previewWarning=resolution.warning
                self.previewLocalURL=localURL;self.previewPage=resolution.page;self.previewLine=resolution.line;self.previewPDF=document;self.previewLoading=false
            }
        }
    }
    private func clearPreview() {
        previewText="";previewWarning=nil;previewPage=nil;previewLine=nil;previewPDF=nil;previewLocalURL=nil;previewLoading=false
    }
    func moveSelection(_ step: Int) {
        guard let first=hits.first,isCurrentResult(first) else { return }
        let current = hits.firstIndex { $0.id == selectedID } ?? (step > 0 ? -1 : hits.count)
        selectedID = hits[min(max(current + step, 0), hits.count - 1)].id
    }
    private func makeSnapshot(generation: UInt64) -> MijiSearchSnapshot {
        MijiSearchSnapshot(generation:generation,query:query,kind:kind,rootID:rootID,scope:scope,sort:sort,onlineOnly:onlineOnly,limit:500,contextPath:context?.standardizedFileURL.path,currentFolderOnly:currentFolderOnly,rootPaths:rootPaths)
    }
    var searchStatus: MijiSearchStatus {
        MijiSearchStatus(phase:searchPhase,count:displayedSnapshot == currentSnapshot ? hits.count : 0,
                     milliseconds:completedMilliseconds ?? firstBatchMilliseconds,
                     timing:completedMilliseconds != nil ? .complete : (firstBatchMilliseconds != nil ? .firstBatch : nil),error:searchError,isLimited:searchLimited)
    }
    var activeFilters: [MijiSearchFilter] {
        var result: [MijiSearchFilter] = []
        if let kind { result.append(MijiSearchFilter(id:.kind,label:kind.title)) }
        if let rootID { result.append(MijiSearchFilter(id:.root,label:roots.first { $0.id == rootID }?.name ?? "指定位置")) }
        if scope != .all { result.append(MijiSearchFilter(id:.scope,label:scope == .name ? "仅文件名" : "仅内容")) }
        if sort != .relevance { result.append(MijiSearchFilter(id:.sort,label:sort == .modified ? "最近修改" : sort == .size ? "按大小" : "按名称")) }
        if onlineOnly { result.append(MijiSearchFilter(id:.onlineOnly,label:"仅在线")) }
        if currentFolderOnly { result.append(MijiSearchFilter(id:.currentFolder,label:"当前目录")) }
        return result
    }
    func removeFilter(_ id: MijiSearchFilterID) {
        switch id {
        case .kind: kind=nil
        case .root: rootID=nil
        case .scope: scope = .all
        case .sort: sort = .relevance
        case .currentFolder: currentFolderOnly=false
        case .onlineOnly: onlineOnly=false
        }
    }
    func resetInterfaceFilters() {
        kind=nil; rootID=nil; scope = .all; sort = .relevance; currentFolderOnly=false
        if onlineOnly { onlineOnly=false }
    }
    private static func volumeName(_ root: IndexedRoot) -> String {
        let parts=URL(fileURLWithPath:root.path).pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : (root.isExternal ? root.name : "这台 Mac")
    }
    func resultLocation(_ hit: SearchHit) -> MijiResultLocation {
        let parent=URL(fileURLWithPath:hit.path).deletingLastPathComponent()
        let label=parent.path == "/" ? "/" : parent.lastPathComponent
        let volume=Self.volumeName(hit.root)
        return MijiResultLocation(short:"\(label) · \(volume)",fullPath:hit.path)
    }
    func resultAvailability(_ hit: SearchHit) -> MijiResultAvailability {
        let volume=Self.volumeName(hit.root)
        let contentMessage=hit.file.contentError ?? (selectedID == hit.id ? previewWarning : nil)
        let state: MijiResultAvailabilityState
        let text: String?
        if !hit.root.isOnline { state = .diskOffline; text="磁盘「\(volume)」未连接 · 可查看已索引内容" }
        else if localPreviewURL(hit) == nil {
            state = .fileUnavailable
            text = FileManager.default.fileExists(atPath:hit.path)
                ? "原文尚未下载或不可读取 · 仍可定位或打开原文件"
                : "磁盘在线，但文件已移动、删除或无法访问"
        }
        else if hit.file.contentState == "error" { state = .extractionFailed; text="内容提取失败 · 文件名仍可搜索" }
        else if selectedID == hit.id && !previewLoading && !previewText.isEmpty && hit.file.fileExtension.lowercased() == "pdf" && previewPDF == nil { state = .indexedOnly; text="原文不可预览 · 显示已索引内容" }
        else if contentMessage != nil { state = .partial; text="仅有部分已索引内容或位置受限" }
        else { state = .available; text=nil }
        return MijiResultAvailability(state:state,message:text,volumeName:volume,contentMessage:contentMessage)
    }
    func isCurrentResult(_ hit: SearchHit, snapshot: MijiSearchSnapshot? = nil) -> Bool {
        guard let current=currentSnapshot, displayedSnapshot == current,
              current == makeSnapshot(generation:generation),
              snapshot == nil || snapshot == current else { return false }
        if let root=roots.first(where: { $0.id==hit.root.id }), root.path != hit.root.path { return false }
        return hits.contains { $0.id == hit.id && $0.file.rootID == hit.file.rootID && $0.path == hit.path && $0.file.inode == hit.file.inode && $0.file.modified == hit.file.modified && $0.file.size == hit.file.size }
    }
    /// One gate for every keyboard, row, menu, Quick Look and preview action.
    func canPerformFileAction(_ action: MijiFileAction, hit: SearchHit? = nil, snapshot: MijiSearchSnapshot? = nil) -> Bool {
        guard let hit=hit ?? selected else {return false}
        return operationFailure(hit,for:action,snapshot:snapshot) == nil
    }
    private func operationFailure(_ hit: SearchHit, for action: MijiFileAction, snapshot: MijiSearchSnapshot?) -> String? {
        guard isCurrentResult(hit,snapshot:snapshot) else { return "搜索条件已变化，请等待当前结果返回后再操作。" }
        if action == .copyPath { return nil }
        let currentRoot=roots.first { $0.id == hit.root.id } ?? hit.root
        guard currentRoot.isOnline else { return "请连接磁盘「\(Self.volumeName(currentRoot))」后再操作此文件。" }
        // Metadata only: never download a provider placeholder or enumerate a package.
        var info = stat()
        guard lstat(hit.path, &info) == 0 else { return "文件已移动或删除：\(hit.file.name)。" }
        let mode = info.st_mode & S_IFMT
        let documentPackage = hit.file.isDirectory != false && hit.file.kind == .document &&
            FileKind.classify(extension: hit.file.fileExtension, isDirectory: true) == .document
        let directory = hit.file.isDirectory ?? (hit.file.kind == .folder || hit.file.kind == .application)
        let regular = !directory && !documentPackage && hit.file.kind != .other
        if mode == S_IFLNK || (directory && mode != S_IFDIR) || (regular && mode != S_IFREG) {
            return "文件类型已变化，请等待索引更新后再操作：\(hit.file.name)。"
        }
        // Document packages use a composite signature, not the directory's own inode.
        if !(documentPackage && mode == S_IFDIR), hit.file.inode != 0,
           hit.file.inode != Int64(bitPattern: UInt64(info.st_ino)) {
            return "文件已替换，请等待索引更新后再操作：\(hit.file.name)。"
        }
        // Reveal is metadata-only. Opening is an explicit request handled by
        // Wumi's cloud-aware router; neither requires a preview download.
        if !action.requiresLocalContent {
            return FileManager.default.fileExists(atPath:hit.path) ? nil : "文件已移动或删除：\(hit.file.name)。"
        }
        guard localPreviewURL(hit) != nil else { return "磁盘在线，但文件已移动、删除、尚未下载或无法读取：\(hit.file.name)。" }
        return nil
    }
    @discardableResult
    func validateResult(_ hit: SearchHit, for action: MijiFileAction, snapshot: MijiSearchSnapshot? = nil) -> Bool {
        if let failure=operationFailure(hit,for:action,snapshot:snapshot) { message=failure;return false }
        return true
    }
    func fileOperationURL(for hit: SearchHit, action: MijiFileAction, snapshot: MijiSearchSnapshot? = nil) -> URL? {
        validateResult(hit,for:action,snapshot:snapshot) ? URL(fileURLWithPath:hit.path) : nil
    }
    func performFileAction(_ action: MijiFileAction, hit: SearchHit? = nil, snapshot: MijiSearchSnapshot? = nil,
                           line: Int? = nil, pasteboard: NSPasteboard = .general) {
        guard let hit=hit ?? selected, validateResult(hit,for:action,snapshot:snapshot) else { return }
        let url=URL(fileURLWithPath:hit.path)
        switch action {
        case .copyPath:
            pasteboard.clearContents(); pasteboard.setString(hit.path,forType:.string)
        case .copyFile:
            pasteboard.clearContents(); pasteboard.writeObjects([url as NSURL])
        case .copyReference: LightningSearchActions.copy([url],to:pasteboard)
        case .cutReference: LightningSearchActions.cut([url],to:pasteboard)
        case .copyTo: onChooseDestination([url],false)
        case .sendTo: onChooseDestination([url],true)
        case .stageFile: onStageFiles([url])
        case .reveal: onDismiss(); onReveal(url)
        case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .open, .openAtLine:
            if hit.file.kind == .code, let line=line ?? (hit.id == selectedID ? previewLine : nil), MijiCodeFileOpener.open(url,line:line) { onDismiss(); return }
            onDismiss(); FileOpenRouter.open(url)
        case .quickLook: NotificationCenter.default.post(name:.dirDeskShowSuperPreview,object:url)
        case .preview: break // URL consumers call fileOperationURL after this same gate.
        }
    }
    func openSelected() { performFileAction(.open) }
    func revealSelected() { performFileAction(.reveal) }
    func copySelectedPath() { performFileAction(.copyPath) }
    func copySelectedFile(to pasteboard:NSPasteboard = .general) { performFileAction(.copyFile,pasteboard:pasteboard) }
    func revealSelectedInFinder() { performFileAction(.revealInFinder) }
    func previewSelected() { performFileAction(.quickLook) }
}
