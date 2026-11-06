import AppKit
import Combine
import DirDeskCore
import PDFKit
import MijiCore

private final class MijiSearchTicket: @unchecked Sendable {
    private let lock = NSLock()
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
            guard root.enabled, options.rootID == nil || options.rootID == root.id else { return nil }
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
    @Published private(set) var statistics = IndexStatistics()
    @Published private(set) var progress = IndexProgress()
    @Published private(set) var searching = false
    @Published private(set) var searchMilliseconds: Double = 0
    @Published var message: String?
    @Published private(set) var previewText = ""
    @Published private(set) var previewWarning: String?
    @Published var focusSearch = UUID()
    var onReveal: (URL) -> Void
    var onDismiss: () -> Void = {}

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
    @Published var previewEnabled = true {didSet {loadPreview()}}
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
    private var supplementaryCache: (request: String, hits: [SearchHit])?
    static let catalogRefreshInterval: TimeInterval = 2

    init(context: URL? = nil, currentFolderOnly: Bool = false, onReveal: @escaping (URL) -> Void = { _ in }) {
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
        service.$roots.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self, self.roots != $0 else { return }
            self.roots = $0
            if self.searchVisible, self.currentFolderOnly {
                if self.searching || self.searchWork != nil { self.refreshAfterSearch = true }
                else { self.scheduleSearch(preserveResults: true) }
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
    var panelHeight: CGFloat {query.isEmpty ? 100 : (previewEnabled || gridEnabled ? 563 : Self.panelHeight(query:query,resultCount:hits.count))}
    var panelWidth:CGFloat {!query.isEmpty && previewEnabled ? 1060 : 800}

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
        searchTicket?.cancel(); searching = false
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
    /// session is visible. Content matches come from the last complete search; only a
    /// new query, filter or scope runs the content search again.
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
            self.loadPreview()
        }
        catalogRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func scheduleSearch(preserveResults: Bool = false, namesOnly: Bool = false) {
        if previewQuery != query {previewTicket?.cancel();previewKey=nil}
        searchWork?.cancel(); searchWork = nil
        searchTicket?.cancel(); searching = false; refreshAfterSearch = false
        if !namesOnly { catalogRefreshWork?.cancel(); catalogRefreshWork = nil }
        if !preserveResults { hits = []; selectedID = nil; searchMilliseconds = 0 }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hits = []; selectedID = nil; searchMilliseconds = 0
            return
        }
        guard searchVisible, let engine = service.engine else { return }
        let options = SearchOptions(kind: kind, rootID: rootID, scope: scope, sort: sort,
                                    onlineOnly: !service.indexingPreferences.retainOffline, limit: 500)
        let request = [query, kind?.rawValue ?? "", rootID ?? "", "\(scope)", "\(sort)", context?.path ?? "",
                       "\(currentFolderOnly)", "\(options.onlineOnly)"].joined(separator: "\u{1f}")
        // A filename refresh keeps the content matches of the same request; without
        // them (or for content-only scope) it has nothing cheaper to offer.
        let cachedSupplementary = namesOnly ? supplementaryCache.flatMap { $0.request == request ? $0.hits : nil } : nil
        if namesOnly && (cachedSupplementary == nil || options.scope == .content) {
            if options.scope == .content { return }
            scheduleSearch(preserveResults: true)
            return
        }
        // The debounce is part of the active request. No previous row remains actionable
        // while a new query or filter is waiting to execute.
        searching = true
        let ticket = MijiSearchTicket()
        searchTicket = ticket
        let plans = MijiSearchPlan.make(query: query, options: options,
                                       folder: currentFolderOnly ? context : nil, roots: roots)
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
                    let nameHits = Self.merge(first, [], options: options)
                    if let cachedSupplementary {
                        // Re-read the cached content matches by ID: deleted files drop out,
                        // renamed or moved ones show where they are now, offline ones follow
                        // the offline setting and the folder boundary still applies.
                        let rows = try database.nameHits(ids: cachedSupplementary.map(\.id), query: "", cancelled: { ticket.isCancelled })
                        let current = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        let refreshed = cachedSupplementary.compactMap { hit -> SearchHit? in
                            guard let row = current[hit.id], !options.onlineOnly || row.root.isOnline,
                                  plans.contains(where: { $0.contains(row) }) else { return nil }
                            return SearchHit(file: row.file, root: row.root, snippet: hit.snippet, matchedIn: hit.matchedIn, labels: hit.labels)
                        }
                        let result = Self.merge(nameHits, refreshed, options: options)
                        DispatchQueue.main.async {
                            self?.publish(result, ticket: ticket, elapsed: nil, finished: true, preserveResults: true)
                        }
                        return
                    }
                    let finished = options.scope == .name || (options.sort == .relevance && nameHits.count >= options.limit)
                    DispatchQueue.main.async {
                        if finished { self?.cacheSupplementary([], request: request, ticket: ticket) }
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
                        for plan in plans {
                            var candidateOptions = plan.options
                            let previous = supplementary
                            repeat {
                                let extra = try database.searchSupplementary(plan.query, options: candidateOptions, cancelled: { ticket.isCancelled }, onPartial: { partial in
                                    let result = Self.merge(nameHits, previous + partial.filter { plan.contains($0) }, options: options)
                                    DispatchQueue.main.async {
                                        self?.publish(result, ticket: ticket, elapsed: nil, finished: false, preserveResults: preserveResults)
                                    }
                                })
                                let scoped = extra.filter { plan.contains($0) }
                                if scoped.count >= options.limit || extra.count < candidateOptions.limit {
                                    supplementary += scoped.prefix(options.limit)
                                    break
                                }
                                candidateOptions.limit *= 2
                            } while !ticket.isCancelled
                        }
                        let result = Self.merge(nameHits, supplementary, options: options)
                        DispatchQueue.main.async {
                            self?.cacheSupplementary(supplementary, request: request, ticket: ticket)
                            self?.publish(result, ticket: ticket, elapsed: nameHits.isEmpty ? Date().timeIntervalSince(typedAt) * 1000 : nil, finished: true, preserveResults: preserveResults)
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
        guard !ticket.isCancelled else { return }
        searching = false
        if !(error is CancellationError) { message = error.localizedDescription }
        if refreshAfterSearch { refreshAfterSearch = false; scheduleCatalogRefresh() }
    }

    private func cacheSupplementary(_ hits: [SearchHit], request: String, ticket: MijiSearchTicket) {
        guard !ticket.isCancelled else { return }
        supplementaryCache = (request, hits)
    }

    nonisolated private static func merge(_ names: [SearchHit], _ extra: [SearchHit], options: SearchOptions) -> [SearchHit] {
        let decorated = Dictionary(extra.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var ids = Set<Int64>()
        var merged = (names.map { decorated[$0.id] ?? $0 } + extra).filter { ids.insert($0.id).inserted }
        if options.sort != .relevance {
            merged.sort {
                if options.sort == .modified && $0.file.modified != $1.file.modified { return $0.file.modified > $1.file.modified }
                if options.sort == .size && $0.file.size != $1.file.size { return $0.file.size > $1.file.size }
                let a = $0.file.name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
                let b = $1.file.name.precomposedStringWithCanonicalMapping.lowercased().precomposedStringWithCanonicalMapping
                return a == b ? $0.id < $1.id : a < b
            }
        }
        return Array(merged.prefix(options.limit))
    }

    private func publish(_ result: [SearchHit], ticket: MijiSearchTicket, elapsed: Double?, finished: Bool, preserveResults: Bool) {
        guard !ticket.isCancelled, searchVisible else { return }
        // A catalog refresh commits one complete result set. Its name-only phase
        // must not remove a selected content hit while supplementary work is pending.
        guard !preserveResults || finished else { return }
        hits = result; searching = !finished
        if let elapsed { searchMilliseconds = elapsed }
        if !result.contains(where: { $0.id == selectedID }) { selectedID = result.first?.id }
        loadPreview()
        if finished, refreshAfterSearch { refreshAfterSearch = false; scheduleCatalogRefresh() }
    }

    func setPreviewVisible(_ visible:Bool) {previewEnabled=visible}
    private func suspendPreview() {
        previewTicket?.cancel();previewKey=nil;clearPreview();MijiPreviewThumbnails.clear()
    }
    func showPDFMatch() {
        guard let document=previewPDF,let page=previewPage else{return}
        let terms=MijiPreviewResolver.terms(in:query),title=selected?.file.name ?? "PDF"
        onDismiss()
        MijiPDFReaderController.shared.show(document:document,page:page,terms:terms,title:title)
    }
    private func loadPreview() {
        guard searchVisible,previewEnabled,let hit=selected,let engine=service.engine else {
            previewTicket?.cancel();previewKey=nil;clearPreview();return
        }
        let key="\(hit.id)|\(hit.path)|\(hit.file.inode)|\(hit.file.modified)|\(hit.file.size)|\(hit.file.contentState)|\(hit.file.contentError ?? "")|\(hit.root.isOnline)|\(query)|\(hit.matchedIn)|\(hit.snippet)|\(hit.labels)"
        guard key != previewKey else{return}
        previewTicket?.cancel();previewKey=key;previewQuery=query;clearPreview()
        let ticket=MijiSearchTicket();previewTicket=ticket;previewLoading=true
        let query=query
        let reader=previewReader,url=engine.databaseURL
        previewQueue.async { [weak self] in
            guard !ticket.isCancelled else{return}
            let content=try? reader.open(url).storedContent(fileID:hit.id)
            var resolution=MijiPreviewResolver.resolve(hit:hit,content:content,query:query,cancelled:{ticket.isCancelled})
            guard !ticket.isCancelled else{return}
            let localURL=MijiPreviewResolver.localURL(for:hit)
            if (hit.file.kind == .code || hit.file.fileExtension.lowercased()=="pdf"),let url=localURL,
               let signature=try? FileSignature.read(url),!signature.matches(hit.file) {
                resolution.page=nil;resolution.line=nil
                resolution.warning=[resolution.warning,"文件已变化，正文为上次索引内容；位置将在索引更新后恢复"].compactMap{$0}.joined(separator:"；")
            }
            var document:PDFDocument?
            if hit.file.fileExtension.lowercased()=="pdf",let url=localURL,let size=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=64*1024*1024 {document=PDFDocument(url:url)}
            DispatchQueue.main.async {
                guard let self,!ticket.isCancelled,self.searchVisible,self.selectedID==hit.id else { return }
                self.previewText=resolution.text;self.previewWarning=resolution.warning
                self.previewLocalURL=localURL;self.previewPage=resolution.page;self.previewLine=resolution.line;self.previewPDF=document;self.previewLoading=false
            }
        }
    }
    private func clearPreview() {
        previewText="";previewWarning=nil;previewPage=nil;previewLine=nil;previewPDF=nil;previewLocalURL=nil;previewLoading=false
    }
    func moveSelection(_ step: Int) {
        guard !hits.isEmpty else { return }
        let current = hits.firstIndex { $0.id == selectedID } ?? (step > 0 ? -1 : hits.count)
        selectedID = hits[min(max(current + step, 0), hits.count - 1)].id
    }
    func openSelected() {
        guard let hit = selected else { return }
        guard hit.root.isOnline, FileManager.default.fileExists(atPath: hit.path) else {
            message = "请连接「\(hit.root.name)」后打开此文件。"; return
        }
        if hit.file.kind == .code,let line=previewLine,MijiCodeFileOpener.open(URL(fileURLWithPath:hit.path),line:line) {onDismiss();return}
        onDismiss()
        FileOpenRouter.open(URL(fileURLWithPath: hit.path))
    }
    func revealSelected() {
        guard let hit = selected, hit.root.isOnline else { return }
        onDismiss(); onReveal(URL(fileURLWithPath: hit.path))
    }
    func revealSelectedInFinder() {
        guard let hit = selected, hit.root.isOnline else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
    }
    func previewSelected() {
        guard let hit=selected,let url=MijiPreviewResolver.localURL(for:hit) else{return}
        NotificationCenter.default.post(name:.dirDeskShowSuperPreview,object:url)
    }
    func copySelectedFile(to pasteboard:NSPasteboard = .general) {
        guard let hit=selected,let url=MijiPreviewResolver.localURL(for:hit) else{message="请先连接磁盘或将文件下载到本机。";return}
        pasteboard.clearContents();pasteboard.writeObjects([url as NSURL])
    }
    func copySelectedPath() {
        guard let hit = selected else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hit.path, forType: .string)
    }
}
