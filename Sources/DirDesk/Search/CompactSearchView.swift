import AppKit
import Combine
import DirDeskCore
import SwiftUI

/// One query session per surface; the expensive index and extractors belong to the app service.
@MainActor
final class CompactSearchModel: ObservableObject {
    enum Match: String, CaseIterable { case all, name, contents }
    @Published var query = "" { didSet { if query != oldValue { schedule() } } }
    @Published var currentFolderOnly = false { didSet { if currentFolderOnly != oldValue { schedule() } } }
    @Published var match: Match = .all { didSet { if match != oldValue { schedule() } } }
    @Published private(set) var rows: [LightningRow] = []
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    @Published private(set) var elapsedMilliseconds = 0
    let focus = LightningSearchFocus()
    var onReveal: (URL) -> Void
    private(set) var context: URL?
    private var workspace: [URL]
    private var visible = true
    private var pending: Task<Void, Never>?
    private var cancellation: LightningFlag?
    private var serial = 0
    private var refreshAfterSearch = false
    private var subscriptions: Set<AnyCancellable> = []
    private let service: LightningSearchService
    nonisolated static let limit = 200

    init(context: URL?, workspace: [URL], currentFolderOnly: Bool? = nil, onReveal: @escaping (URL) -> Void) {
        self.context = context
        self.workspace = workspace
        self.currentFolderOnly = currentFolderOnly ?? (context != nil)
        self.onReveal = onReveal
        service = .shared
        service.$indexGeneration.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            if self.searching { self.refreshAfterSearch = true } else { self.schedule(immediate: true, preserveResults: true) }
        }.store(in: &subscriptions)
        service.$status.map { $0.stage.isSearchable }.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.schedule(immediate: true)
        }.store(in: &subscriptions)
    }

    func updateContext(_ context: URL?, workspace: [URL]) {
        guard context != self.context || workspace != self.workspace else { return }
        self.context = context
        self.workspace = workspace
        if context == nil { currentFolderOnly = false }
        schedule(immediate: true)
    }

    func setVisible(_ value: Bool) {
        visible = value
        if value { schedule(immediate: true) }
        else { pending?.cancel(); cancellation?.set(); serial += 1; searching = false }
    }

    func schedule(immediate: Bool = false, preserveResults: Bool = false) {
        pending?.cancel()
        cancellation?.set()
        serial += 1
        refreshAfterSearch = false
        if !preserveResults { rows = [] }
        error = nil
        elapsedMilliseconds = 0
        guard visible else { return }
        let request = serial
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { rows = []; searching = false; error = nil; return }
        searching = true
        pending = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(20)) }
            guard !Task.isCancelled, let self, request == self.serial else { return }
            self.run(text, request: request)
        }
    }

    private func run(_ text: String, request: Int) {
        service.ensureStarted()
        guard let engine = service.engine else { searching = true; return }
        let scope: LightningScope = currentFolderOnly && context != nil ? .folder(context!) : .computer
        let flag = LightningFlag()
        cancellation = flag
        searching = true
        error = nil
        let parsed: LightningQuery
        do { parsed = try LightningQueryParser.parse(text) }
        catch let issue as LightningSyntaxError { self.error = LightningStatusText.syntaxMessage(issue); searching = false; return }
        catch { self.error = error.localizedDescription; searching = false; return }
        // Explicit expressions always run as one complete tree. Incremental name/content union
        // is valid only for the simple free-text search, where each branch independently matches.
        let simple = !text.contains(":") && !text.contains("(") && !text.contains(")") && !text.contains("|")
            && !text.contains("!") && !text.contains("*") && !text.contains("?")
            && ![" AND ", " OR ", "NOT "].contains(where: text.contains)
        let selectedMatch = match
        let primary: LightningQuery = selectedMatch == .contents && simple ? .filter(.content([text])) : parsed
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                if simple && selectedMatch != .contents {
                    return engine.searchNames(primary, scope: scope, caseSensitive: false, sort: .none,
                                              descending: false, limit: Self.limit, isCancelled: { flag.isSet })
                }
                return engine.search(primary, scope: scope, caseSensitive: false, sort: .none,
                                     descending: false, limit: Self.limit, isCancelled: { flag.isSet })
            }.value
            guard let self, self.serial == request, !flag.isSet else { return }
            self.rows = result.rows
            self.elapsedMilliseconds = result.elapsedMilliseconds
            self.searching = selectedMatch == .all && simple
            if selectedMatch == .all && simple {
                let supplementary = await Task.detached(priority: .utility) {
                    engine.search(.filter(.content([text])), scope: scope, caseSensitive: false, sort: .none,
                                  descending: false, limit: Self.limit, isCancelled: { flag.isSet })
                }.value
                guard self.serial == request, !flag.isSet else { return }
                var seen = Set(result.rows.map(\.path))
                self.rows = Array((result.rows + supplementary.rows.filter { seen.insert($0.path).inserted }).prefix(Self.limit))
            }
            self.searching = false
            if self.refreshAfterSearch { self.schedule(immediate: true, preserveResults: true) }
        }
    }

    func reveal(_ row: LightningRow) { if row.isOnline { onReveal(row.url) } }
    func open(_ row: LightningRow) { FileOpenRouter.open(row) }
    func preview(_ row: LightningRow) {
        guard row.isOnline else { return }
        NotificationCenter.default.post(name: .dirDeskShowSuperPreview, object: row.url)
    }
}

struct CompactSearchView: View {
    @StateObject private var model: CompactSearchModel
    @ObservedObject private var service = LightningSearchService.shared
    let onDismiss: () -> Void
    private let context: URL?
    private let workspace: [URL]

    init(context: URL?, workspace: [URL], currentFolderOnly: Bool? = nil, onReveal: @escaping (URL) -> Void, onDismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: CompactSearchModel(context: context, workspace: workspace, currentFolderOnly: currentFolderOnly, onReveal: onReveal))
        self.context = context; self.workspace = workspace; self.onDismiss = onDismiss
    }

    init(model: CompactSearchModel, onDismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: model)
        context = model.context; workspace = []; self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(.secondary)
                CompactQueryField(model: model, dismiss: onDismiss)
                    .frame(height: 34)
                if model.searching { ProgressView().controlSize(.small).accessibilityLabel(L("Searching…")) }
                Button(action: onDismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel(L("Close"))
                    .accessibilityIdentifier("Wumi.CompactSearch.Close")
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            HStack(spacing: 8) {
                Picker(L("Match"), selection: $model.match) {
                    Text(L("All")).tag(CompactSearchModel.Match.all)
                    Text(L("Name")).tag(CompactSearchModel.Match.name)
                    Text(L("File Contents")).tag(CompactSearchModel.Match.contents)
                }
                .pickerStyle(.segmented).frame(maxWidth: 270).labelsHidden()
                .accessibilityIdentifier("Wumi.CompactSearch.Match")
                Spacer(minLength: 8)
                if model.context != nil {
                    Picker(L("Search Scope"), selection: $model.currentFolderOnly) {
                        Text(L("This Computer")).tag(false)
                        Text(L("Current Folder")).tag(true)
                    }
                    .labelsHidden().fixedSize().accessibilityIdentifier("Wumi.CompactSearch.Scope")
                }
                Button(L("Advanced Search")) {
                    if let delegate = FileOpenRouter.delegate {
                        onDismiss()
                        delegate.windows.showLightningSearch(scope: model.context, controller: delegate.activeController)
                    }
                }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
            }
            .padding(.horizontal, 18).padding(.bottom, 10)
            if !model.query.isEmpty {
                Divider()
                ZStack {
                    CompactResults(model: model)
                    if model.rows.isEmpty {
                        VStack(spacing: 9) {
                            Text(model.error ?? (model.searching ? L("Searching…") : L("No Results")))
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                            if case .failed(let reason) = service.status.stage {
                                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }.padding()
                    }
                }
                .frame(minHeight: 100, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 8) {
                Text(model.query.isEmpty ? L("Search names, pinyin, documents and image text")
                     : LF("Showing %lld results", Int64(model.rows.count)))
                    .lineLimit(1)
                Spacer()
                Text(L("Return to reveal · Space to preview")).lineLimit(1)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.setVisible(true) }
        .onDisappear { model.setVisible(false) }
        .onChange(of: context) { _, value in model.updateContext(value, workspace: workspace) }
    }
}

private struct CompactQueryField: NSViewRepresentable {
    @ObservedObject var model: CompactSearchModel
    let dismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> LightningSearchTextField {
        let field = LightningSearchTextField()
        field.focusOwner = model.focus
        field.delegate = context.coordinator
        field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 19); field.usesSingleLineMode = true
        field.placeholderString = L("Search files")
        field.setAccessibilityIdentifier("Wumi.CompactSearch.Field")
        field.stringValue = model.query
        return field
    }
    func updateNSView(_ field: LightningSearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != model.query, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = model.query }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CompactQueryField
        init(_ parent: CompactQueryField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.model.query = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.moveDown(_:)) { return parent.model.focus.focusResults() }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.dismiss(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if let row = parent.model.rows.first {
                    if NSApp.currentEvent?.modifierFlags.contains(.command) == true { parent.model.open(row) }
                    else { parent.model.reveal(row) }
                } else { parent.model.schedule(immediate: true) }
                return true
            }
            return false
        }
    }
}

private struct CompactResults: NSViewRepresentable {
    @ObservedObject var model: CompactSearchModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = CompactTable()
        table.owner = context.coordinator
        table.headerView = nil; table.rowHeight = 50; table.style = .fullWidth
        table.intercellSpacing = .zero; table.backgroundColor = .clear
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")))
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.reveal)
        table.setAccessibilityIdentifier("Wumi.CompactSearch.Results")
        context.coordinator.table = table
        model.focus.tableView = table
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(model) }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
        var model: CompactSearchModel
        weak var table: CompactTable?
        private var displayed: [LightningRow] = []
        private var displayedQuery = ""
        init(_ model: CompactSearchModel) { self.model = model }
        func update(_ model: CompactSearchModel) {
            self.model = model
            guard displayed != model.rows || displayedQuery != model.query else { return }
            let selected = selectedRow?.path
            displayed = model.rows
            displayedQuery = model.query
            table?.reloadData()
            if let selected, let index = displayed.firstIndex(where: { $0.path == selected }) {
                table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else {
                table?.deselectAll(nil)
            }
        }
        var selectedRow: LightningRow? {
            guard let table else { return nil }
            let i = table.selectedRow
            return displayed.indices.contains(i) ? displayed[i] : nil
        }
        func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard displayed.indices.contains(row) else { return nil }
            let item = displayed[row]
            let cell = NSView()
            let icon = NSImageView(image: NSImage(systemSymbolName: item.isDirectory && !item.isPackage ? "folder" : "doc",
                                                 accessibilityDescription: nil)!)
            icon.contentTintColor = item.isDirectory ? .systemBlue : .secondaryLabelColor
            let name = NSTextField(labelWithString: item.name)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.lineBreakMode = .byTruncatingMiddle
            let path = NSTextField(labelWithString: (item.isOnline ? "" : L("Offline") + " · ") + LightningSearchModel.displayPath(item.path))
            path.font = .systemFont(ofSize: 10); path.textColor = .secondaryLabelColor
            path.lineBreakMode = .byTruncatingMiddle
            let range = (item.name as NSString).range(of: model.query, options: .caseInsensitive)
            if range.location != NSNotFound {
                let attributed = NSMutableAttributedString(string: item.name)
                attributed.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
                name.attributedStringValue = attributed
            }
            for view in [icon, name, path] { cell.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18), icon.widthAnchor.constraint(equalToConstant: 25),
                icon.heightAnchor.constraint(equalToConstant: 25), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
                name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
                path.leadingAnchor.constraint(equalTo: name.leadingAnchor), path.trailingAnchor.constraint(equalTo: name.trailingAnchor),
                path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3)
            ])
            cell.setAccessibilityElement(true)
            cell.setAccessibilityLabel(item.name + " · " + path.stringValue)
            return cell
        }
        @objc func reveal() { if let row = selectedRow { model.reveal(row) } }
        func open() { if let row = selectedRow { model.open(row) } }
        func preview() { if let row = selectedRow { model.preview(row) } }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard displayed.indices.contains(row), displayed[row].isOnline else { return nil }
            return displayed[row].url as NSURL
        }
        func menu(for event: NSEvent) -> NSMenu? {
            guard let row = selectedRow else { return nil }
            let menu = NSMenu()
            let reveal = ClosureMenuItem(L("Open in Wumi")) { [weak self] in self?.model.reveal(row) }
            let open = ClosureMenuItem(L("Open")) { [weak self] in self?.model.open(row) }
            let preview = ClosureMenuItem(L("Quick Look")) { [weak self] in self?.model.preview(row) }
            for item in [reveal, open, preview] { item.isEnabled = row.isOnline; menu.addItem(item) }
            menu.autoenablesItems = false
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Copy Path")) { LightningSearchActions.copyPaths([row.path]) })
            if row.isOnline {
                menu.addItem(ClosureMenuItem(L("Copy")) { LightningSearchActions.copy([row.url]) })
                menu.addItem(ClosureMenuItem(L("Cut")) { LightningSearchActions.cut([row.url]) })
                menu.addItem(ClosureMenuItem(L("Copy To")) { FileOpenRouter.chooseDestination(for: [row.url], move: false) })
                menu.addItem(ClosureMenuItem(L("Send To")) { FileOpenRouter.chooseDestination(for: [row.url], move: true) })
                menu.addItem(ClosureMenuItem(L("Add to File Transit")) { FileTransitStore.shared.add([row.url]) })
            }
            return menu
        }
    }
}

private final class CompactTable: NSTableView {
    weak var owner: CompactResults.Coordinator?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return owner?.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            if event.modifierFlags.contains(.command) { owner?.open() } else { owner?.reveal() }
        case 49: owner?.preview()
        case 126 where selectedRow <= 0: owner?.model.focus.focusSearchField()
        default: super.keyDown(with: event)
        }
    }
    @objc func copy(_ sender: Any?) {
        guard let row = owner?.selectedRow, row.isOnline else { return }
        LightningSearchActions.copy([row.url])
    }
    @objc func cut(_ sender: Any?) {
        guard let row = owner?.selectedRow, row.isOnline else { return }
        LightningSearchActions.cut([row.url])
    }
}
