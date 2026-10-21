import AppKit
import Combine
import DirDeskCore

/// Weak references to the search field and the results table, so the model can move keyboard focus.
@MainActor
final class LightningSearchFocus {
    weak var searchField: NSTextField?
    weak var tableView: NSTableView?
    /// Focus requested before the field was in a window; applied when it appears.
    private var pendingFieldFocus = true

    func focusSearchField(selectAll: Bool = false) {
        guard let field = searchField, let window = field.window else {
            pendingFieldFocus = true
            return
        }
        window.makeFirstResponder(field)
        if selectAll { field.currentEditor()?.selectAll(nil) }
    }

    func fieldDidMoveToWindow(_ field: NSTextField) {
        searchField = field
        guard pendingFieldFocus, field.window != nil else { return }
        pendingFieldFocus = false
        Task { @MainActor in self.focusSearchField(selectAll: true) }
    }

    /// Moves focus into the results, selecting the first row when nothing is selected.
    @discardableResult
    func focusResults() -> Bool {
        guard let table = tableView, table.numberOfRows > 0, let window = table.window else { return false }
        window.makeFirstResponder(table)
        if table.selectedRowIndexes.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        return true
    }
}

struct LightningSearchOutcome: Sendable {
    var result: LightningSearchResult
    var missingFolders: Int
    var folderCount: Int
}

/// State of one Lightning Search window: the query in either mode, the scope, and the latest results.
@MainActor
final class LightningSearchModel: ObservableObject {
    enum Mode: Hashable {
        case visual, expression
    }

    enum ScopeChoice: Hashable {
        case computer, currentFolder, workspace, selected
    }

    /// Pages of the Search Expression help sheet.
    enum HelpTab: Hashable, CaseIterable {
        case basics, filters, examples
    }

    /// Popovers of the Visual filter row.
    enum FilterPopover: Hashable {
        case kinds, tags, customDates
    }

    static let maximumSelectedFolders = 16
    /// Opening more files at once than this is almost always a mistake.
    static let maximumOpenCount = 20

    let service: LightningSearchService
    let focus = LightningSearchFocus()
    weak var window: NSWindow?
    private(set) var openHandler: (URL, Bool) -> Void

    @Published private(set) var currentFolder: URL?
    @Published private(set) var workspaceFolders: [URL]
    @Published private(set) var mode: Mode = .visual
    @Published var visual = LightningVisualQuery() {
        didSet { visualDidChange(from: oldValue) }
    }
    @Published var expressionText = "" {
        didSet { if expressionText != oldValue, mode == .expression { scheduleSearch() } }
    }
    /// The Match Case checkbox of Search Expression mode (Visual mode keeps its own in Advanced Search).
    @Published var expressionMatchCase = false {
        didSet { if expressionMatchCase != oldValue, mode == .expression { scheduleSearch(immediately: true) } }
    }
    @Published private(set) var compiled = LightningVisualCompilation()
    /// The Advanced Search panel is open. Closing it keeps the conditions.
    @Published var showsAdvanced = false
    @Published var showsHelp = false
    @Published var helpTab: HelpTab = .basics
    @Published var presentedPopover: FilterPopover?
    @Published var scope: ScopeChoice = .computer {
        didSet { if scope != oldValue { scopeDidChange() } }
    }
    @Published private(set) var selectedFolders: [URL] = []
    @Published private(set) var scopeMessage: String?
    @Published private(set) var syntaxError: LightningSyntaxError?
    /// The expression the syntax error refers to.
    @Published private(set) var syntaxErrorSource = ""
    @Published private(set) var rows: [LightningRow] = []
    /// Increases with every new result list, so the table knows when to reload.
    @Published private(set) var resultGeneration = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var elapsedMilliseconds = 0
    @Published private(set) var isTruncated = false
    @Published private(set) var isSearching = false
    /// Something to search for: an expression, or any folder scope (an empty query lists the folder).
    @Published private(set) var hasQuery = false
    /// `rows` are the answer to the current query.
    @Published private(set) var hasSearched = false
    /// The last search ran before the index was ready, so it may be incomplete.
    @Published private(set) var usedIncompleteIndex = false
    /// Newest changes first, as in the original.
    @Published private(set) var sortKey: LightningSortKey = .modified
    @Published private(set) var sortDescending = true
    @Published var isPinned = false
    /// A short confirmation shown in the status bar ("Path copied").
    @Published private(set) var notice: String?
    /// Changes when a mode switch is held back for confirmation, so the mode control redraws with the
    /// mode that is still active.
    @Published private(set) var modeControlRevision = 0
    /// Paths of the selected rows; kept by the table and restored after a reload.
    var selectedPaths: Set<String> = []

    private var pendingSearch: Task<Void, Never>?
    private var runningSearch: LightningFlag?
    private var searchSerial = 0
    private var noticeSerial = 0
    /// The expression the visual conditions converted to when Search Expression mode was entered.
    private var expressionAtSwitch: String?
    /// An edited expression set aside by "Restore Visual Conditions", with the visual query it belongs to.
    /// It comes back when the user returns to Search Expression mode without changing the visual conditions.
    private var expressionDraft: (text: String, matchCase: Bool, visual: LightningVisualQuery)?
    private var indexWasSearchable: Bool
    private var cancellables: Set<AnyCancellable> = []

    init(service: LightningSearchService? = nil, currentFolder: URL?, workspace: [URL], openHandler: @escaping (URL, Bool) -> Void) {
        let service = service ?? .shared
        self.service = service
        self.currentFolder = currentFolder
        workspaceFolders = Self.unique(workspace)
        self.openHandler = openHandler
        indexWasSearchable = service.status.stage.isSearchable
        service.$status.dropFirst().sink { [weak self] status in self?.indexStatusDidChange(status) }.store(in: &cancellables)
        service.$indexGeneration.dropFirst().sink { [weak self] _ in self?.indexWasReplaced() }.store(in: &cancellables)
    }

    /// Text of the search field: names in Visual mode, the expression in Search Expression mode.
    var fieldText: String {
        get { mode == .visual ? visual.text : expressionText }
        set {
            if mode == .visual { visual.text = newValue } else { expressionText = newValue }
        }
    }

    /// The window is reused for a new invocation: follow the active pane's folder and workspace.
    func updateContext(currentFolder: URL?, workspace: [URL], openHandler: @escaping (URL, Bool) -> Void) {
        self.openHandler = openHandler
        let folders = Self.unique(workspace)
        guard currentFolder != self.currentFolder || folders != workspaceFolders else { return }
        self.currentFolder = currentFolder
        workspaceFolders = folders
        if (scope == .currentFolder && currentFolder == nil) || (scope == .workspace && folders.isEmpty) {
            scope = .computer
        } else if scope == .currentFolder || scope == .workspace {
            scheduleSearch(immediately: true)
        }
    }

    func windowWillClose() {
        pendingSearch?.cancel()
        runningSearch?.set()
        cancellables.removeAll()
    }

    // MARK: Modes

    /// Visual → Search Expression converts the visual conditions. The way back cannot convert an edited
    /// expression, so it asks first and sets the edited expression aside as a draft.
    func requestMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        switch newMode {
        case .expression:
            if let draft = expressionDraft, draft.visual == visual {
                expressionText = draft.text
                expressionMatchCase = draft.matchCase
            } else {
                expressionText = compiled.expression
                expressionMatchCase = visual.matchCase
            }
            expressionDraft = nil
            expressionAtSwitch = compiled.expression
            mode = .expression
            syntaxError = nil
            showsAdvanced = false
            scheduleSearch(immediately: true)
            focus.focusSearchField()
        case .visual:
            let unchanged = expressionText.trimmingCharacters(in: .whitespacesAndNewlines)
                == (expressionAtSwitch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if unchanged {
                switchToVisual()
                return
            }
            modeControlRevision += 1
            let alert = NSAlert()
            alert.messageText = L("Restore Visual Conditions?")
            alert.informativeText = L("Once edited, an expression can't be converted back into visual conditions. Return to the visual conditions from before your edits? The expression you typed can be brought back until this window closes.")
            alert.addButton(withTitle: L("Restore Visual Conditions"))
            alert.addButton(withTitle: L("Keep Editing Expression"))
            present(alert) { [weak self] restore in
                guard let self, restore else { return }
                self.expressionDraft = (self.expressionText, self.expressionMatchCase, self.visual)
                self.switchToVisual()
            }
        }
    }

    private func switchToVisual() {
        mode = .visual
        syntaxError = nil
        expressionAtSwitch = nil
        scheduleSearch(immediately: true)
        focus.focusSearchField()
    }

    // MARK: Filters

    private func visualDidChange(from old: LightningVisualQuery) {
        guard visual != old else { return }
        let next = visual.compile()
        if next != compiled { compiled = next }
        if mode == .visual { scheduleSearch() }
    }

    func resetFilters() {
        visual.resetFilters()
    }

    var today: LightningVisualDay { LightningVisualDay(Date()) }

    func addCondition(to groupID: UUID) {
        visual.conditions.addCondition(to: groupID)
        showsAdvanced = true
    }

    func addGroup(to groupID: UUID) {
        visual.conditions.addGroup(to: groupID)
        showsAdvanced = true
    }

    func removeItem(_ id: UUID) {
        visual.conditions.removeItem(id: id)
    }

    func updateCondition(_ id: UUID, _ change: (inout LightningCondition) -> Void) {
        var conditions = visual.conditions
        guard conditions.updateCondition(id: id, change) else { return }
        visual.conditions = conditions
    }

    func updateGroup(_ id: UUID, _ change: (inout LightningConditionGroup) -> Void) {
        var conditions = visual.conditions
        guard conditions.updateGroup(id: id, change) else { return }
        visual.conditions = conditions
    }

    // MARK: Scope

    private func scopeDidChange() {
        scopeMessage = nil
        scheduleSearch(immediately: true)
    }

    /// The scopes the Scope menu offers. Current Workspace appears only when the tab shows several folders.
    var scopeChoices: [ScopeChoice] {
        var choices: [ScopeChoice] = [.computer]
        if currentFolder != nil { choices.append(.currentFolder) }
        if workspaceFolders.count > 1 || scope == .workspace { choices.append(.workspace) }
        return choices
    }

    /// Title of the Scope menu: the scope, or the chosen folder's name.
    var scopeTitle: String {
        switch scope {
        case .computer: return L("This Computer")
        case .currentFolder: return L("Current Folder")
        case .workspace: return L("Current Workspace")
        case .selected:
            if selectedFolders.count == 1 { return selectedFolders[0].lastPathComponent }
            return LF("%lld folders", Int64(selectedFolders.count))
        }
    }

    /// Choose Folder…: picks one or more folders and switches to them; cancelling keeps the current scope.
    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = L("Choose a folder to search.")
        panel.prompt = L("Choose")
        if let first = selectedFolders.first ?? currentFolder { panel.directoryURL = first }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK else { return }
                self.setSelectedFolders(panel.urls)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func setSelectedFolders(_ urls: [URL]) {
        let folders = Self.unique(urls)
        guard !folders.isEmpty else { return }
        guard folders.count <= Self.maximumSelectedFolders else {
            scopeMessage = L("Choose fewer folders to search.")
            return
        }
        selectedFolders = folders
        scopeMessage = nil
        if scope != .selected { scope = .selected } else { scheduleSearch(immediately: true) }
    }

    private func resolveScope() -> (scope: LightningScope, folders: [URL])? {
        switch scope {
        case .computer:
            return (.computer, [])
        case .currentFolder:
            guard let currentFolder else {
                scopeMessage = L("Choose a folder to search.")
                return nil
            }
            return (.folder(currentFolder), [currentFolder])
        case .workspace:
            guard !workspaceFolders.isEmpty else {
                scopeMessage = L("Choose a folder to search.")
                return nil
            }
            return (workspaceFolders.count == 1 ? .folder(workspaceFolders[0]) : .folders(workspaceFolders), workspaceFolders)
        case .selected:
            guard !selectedFolders.isEmpty else {
                scopeMessage = L("Choose a folder to search.")
                return nil
            }
            return (selectedFolders.count == 1 ? .folder(selectedFolders[0]) : .folders(selectedFolders), selectedFolders)
        }
    }

    // MARK: Searching

    /// Debounces typing; `immediately` skips the delay (Return, mode and scope changes).
    func scheduleSearch(immediately: Bool = false) {
        pendingSearch?.cancel()
        pendingSearch = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            self?.runSearch()
        }
    }

    func refresh() {
        service.engine?.discardTemporaryIndexes()
        scheduleSearch(immediately: true)
    }

    func setSort(_ key: LightningSortKey, descending: Bool) {
        guard key != sortKey || descending != sortDescending else { return }
        sortKey = key
        sortDescending = descending
        if hasSearched { scheduleSearch(immediately: true) }
    }

    /// Visual mode does not search while a condition is incomplete or invalid.
    var isSearchBlocked: Bool { mode == .visual && !compiled.issues.isEmpty }

    private func runSearch() {
        pendingSearch = nil
        let text = mode == .visual ? compiled.expression : expressionText
        let caseSensitive = mode == .visual ? visual.matchCase : expressionMatchCase
        hasQuery = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scope != .computer
        guard hasQuery, !isSearchBlocked else {
            syntaxError = nil
            clearResults()
            return
        }
        let query: LightningQuery
        do {
            query = try LightningQueryParser.parse(text)
            syntaxError = nil
        } catch let error as LightningSyntaxError {
            // Keep the previous results while the expression is being fixed.
            syntaxError = error
            syntaxErrorSource = text
            return
        } catch {
            return
        }
        guard let (scope, folders) = resolveScope() else {
            clearResults()
            return
        }
        scopeMessage = nil
        service.ensureStarted()
        guard let engine = service.engine else {
            // The index object is still being created; `indexWasReplaced` searches again.
            clearResults()
            hasSearched = true
            usedIncompleteIndex = true
            return
        }
        runningSearch?.set()
        let flag = LightningFlag()
        runningSearch = flag
        searchSerial += 1
        let serial = searchSerial
        isSearching = true
        let sort = sortKey, descending = sortDescending, limit = LightningSearchService.resultLimit
        let incomplete = !service.status.stage.isSearchable
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> LightningSearchOutcome in
                let existing = folders.filter(Self.isDirectory)
                var usable = scope
                if !folders.isEmpty, existing.count != folders.count {
                    guard !existing.isEmpty else {
                        return LightningSearchOutcome(result: LightningSearchResult(), missingFolders: folders.count, folderCount: folders.count)
                    }
                    usable = existing.count == 1 ? .folder(existing[0]) : .folders(existing)
                }
                let result = engine.search(query, scope: usable, caseSensitive: caseSensitive, sort: sort, descending: descending,
                                           limit: limit, isCancelled: { flag.isSet })
                return LightningSearchOutcome(result: result, missingFolders: folders.count - existing.count, folderCount: folders.count)
            }.value
            guard serial == self.searchSerial else { return }
            self.isSearching = false
            guard !outcome.result.cancelled else { return }
            self.apply(outcome, incomplete: incomplete)
        }
    }

    private func apply(_ outcome: LightningSearchOutcome, incomplete: Bool) {
        rows = outcome.result.rows
        totalCount = outcome.result.totalCount
        elapsedMilliseconds = outcome.result.elapsedMilliseconds
        isTruncated = outcome.result.truncated
        usedIncompleteIndex = incomplete
        hasSearched = true
        resultGeneration += 1
        if outcome.missingFolders > 0 {
            scopeMessage = outcome.folderCount == 1 ? L("The search folder does not exist") : L("One of the selected folders is no longer available.")
        }
    }

    private func clearResults() {
        runningSearch?.set()
        runningSearch = nil
        searchSerial += 1
        isSearching = false
        hasSearched = false
        usedIncompleteIndex = false
        if !rows.isEmpty || totalCount != 0 {
            rows = []
            totalCount = 0
            isTruncated = false
            resultGeneration += 1
        }
    }

    private func indexStatusDidChange(_ status: LightningIndexStatus) {
        let searchable = status.stage.isSearchable
        defer { indexWasSearchable = searchable }
        // Results gathered while the index was building are incomplete: search again once it is ready.
        if searchable, !indexWasSearchable, hasQuery { scheduleSearch(immediately: true) }
    }

    private func indexWasReplaced() {
        if hasQuery { scheduleSearch(immediately: true) }
    }

    // MARK: Result actions

    func rows(at indexes: IndexSet) -> [LightningRow] {
        indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    func reveal(_ row: LightningRow) {
        openHandler(row.url, true)
    }

    /// Preview: the item opens in Super Preview over the browser window.
    func preview(_ row: LightningRow) {
        NotificationCenter.default.post(name: .dirDeskShowSuperPreview, object: row.url)
    }

    func open(_ rows: [LightningRow]) {
        for row in rows.prefix(Self.maximumOpenCount) { openHandler(row.url, false) }
    }

    func copy(_ rows: [LightningRow]) {
        guard !rows.isEmpty else { return }
        LightningSearchActions.copy(rows.map(\.url))
        showNotice(LF("Copied %lld items to the Clipboard", Int64(rows.count)))
    }

    func cut(_ rows: [LightningRow]) {
        guard !rows.isEmpty else { return }
        LightningSearchActions.cut(rows.map(\.url))
        showNotice(L("Ready to move — paste at the destination"))
    }

    func copyPaths(_ rows: [LightningRow]) {
        guard !rows.isEmpty else { return }
        LightningSearchActions.copyPaths(rows.map(\.path))
        showNotice(L("Path copied"))
    }

    func sendToFileTransit(_ rows: [LightningRow]) {
        guard !rows.isEmpty else { return }
        NotificationCenter.default.post(name: LightningSearchActions.stageItemsNotification, object: rows.map(\.url))
        showNotice(L("Sent to File Transit"))
    }

    func moveToTrash(_ rows: [LightningRow]) {
        guard !rows.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = rows.count == 1 ? LF("Move “%@” to the Trash?", rows[0].name) : LF("Move %lld items to the Trash?", Int64(rows.count))
        alert.informativeText = L("You can put items back from the Trash, or choose Undo right away.")
        alert.addButton(withTitle: L("Move to Trash"))
        alert.addButton(withTitle: L("Cancel"))
        let urls = rows.map(\.url)
        present(alert) { [weak self] confirmed in
            if confirmed { self?.trash(urls) }
        }
    }

    private func trash(_ urls: [URL]) {
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { LightningSearchActions.trash(urls) }.value
            if !outcome.moved.isEmpty {
                let removed = Set(outcome.moved.map(\.original.path))
                rows.removeAll { removed.contains($0.path) }
                totalCount = max(0, totalCount - removed.count)
                selectedPaths.subtract(removed)
                resultGeneration += 1
                LightningSearchActions.registerUndo(outcome.moved, in: window?.undoManager)
                NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
                showNotice(L("Moved to Trash"))
            }
            if !outcome.failures.isEmpty {
                let alert = NSAlert()
                alert.messageText = L("The operation could not be completed.")
                alert.informativeText = outcome.failures.joined(separator: "\n")
                present(alert) { _ in }
            }
        }
    }

    private func showNotice(_ text: String) {
        noticeSerial += 1
        let serial = noticeSerial
        notice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, serial == self.noticeSerial else { return }
            self.notice = nil
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping (Bool) -> Void) {
        guard let window, window.isVisible else {
            completion(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(response == .alertFirstButtonReturn) }
        }
    }

    // MARK: Helpers

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// `~/…` for paths inside the home folder. The index reports resolved paths, so the resolved home
    /// folder counts too.
    nonisolated static func displayPath(_ path: String) -> String {
        for home in homePaths {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }

    private nonisolated static let homePaths: [String] = {
        let home = NSHomeDirectory()
        guard let resolved = realpath(home, nil) else { return [home] }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        return canonical == home ? [home] : [home, canonical]
    }()
}
