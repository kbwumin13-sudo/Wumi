import AppKit
import Combine
import DirDeskCore
import Quartz
import SwiftUI

/// Column view as in the original (`FileColumnBrowserState`): one column per folder of a trail that starts where the
/// column view was entered. Selecting a folder makes it the pane's current folder (tab title, path bar and status bar
/// follow) and opens its column; earlier columns keep the folder they lead through, highlighted in grey. Selecting a
/// file only selects it — the inspector shows the preview, there is no preview column, and an archive does not open
/// as a column (its contents show in the inspector, as captured from the original). Columns can be resized by
/// dragging their right edge; widths are remembered per folder.
@MainActor
final class ColumnBrowserController: NSViewController {
    let pane: PaneRuntime
    weak var handler: BrowserActionHandler?
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private var columns: [ColumnTable] = []
    private var cache: [String: [FileItem]] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private lazy var cloudObservation = CloudStatusObservation(
        urls: { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil else { return [] }
            return self.columns.dropLast().flatMap { self.cache[$0.directory.path] ?? [] }
                .filter { $0.cloudStatus?.needsStatusRefresh == true }.map(\.url)
        },
        receive: { [weak self] in self?.applyAncestorCloudStatuses($0) }
    )
    fileprivate var applyingColumnSelection = false

    init(pane: PaneRuntime, handler: BrowserActionHandler?) {
        self.pane = pane
        self.handler = handler
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidAppear() { super.viewDidAppear(); cloudObservation.refresh() }
    override func viewDidDisappear() { super.viewDidDisappear(); cloudObservation.stop() }

    override func loadView() {
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.alignment = .top
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        // Transparent: the pane draws the dark chrome behind the columns (see PaneView), and each column shows the
        // window background on its own panel.
        scrollView.drawsBackground = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            document.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
        view = scrollView
        // Where the pane points decides the trail; its loaded items fill the last column.
        pane.$history.map(\.current).removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncTrail() }.store(in: &cancellables)
        pane.$rows.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshCurrentColumn() }.store(in: &cancellables)
        pane.$loadState.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshCurrentColumn() }.store(in: &cancellables)
        // New folders and Rename edit the name in place in the current column.
        pane.$renamingID.receive(on: RunLoop.main).sink { [weak self] id in
            guard let id else { return }
            DispatchQueue.main.async { self?.columns.last?.beginRename(id) }
        }.store(in: &cancellables)
        // Selections made elsewhere (Select All, Invert Selection, restored sessions) show in the current column.
        pane.$selectedIDs.receive(on: RunLoop.main).sink { [weak self] ids in
            guard let self, !self.applyingColumnSelection else { return }
            self.columns.last?.select(ids: ids)
        }.store(in: &cancellables)
    }

    private var trail: [URL] { columns.map(\.directory) }

    /// Keeps the columns in step with the pane's folder: back to an earlier column, one or more folders deeper below
    /// the first column, or a new trail for a folder elsewhere.
    private func syncTrail() {
        guard let directory = pane.currentDirectory.map(folderURL) else {
            setTrail([])
            return
        }
        let current = trail
        // Browsing ancestry includes application Documents folders projected beneath the Drive root.
        let ancestors = PathUtilities.ancestors(of: directory).map(folderURL)
        if let index = current.firstIndex(of: directory) {
            setTrail(Array(current[...index]))
        } else if let root = current.first, let index = ancestors.firstIndex(of: root) {
            setTrail(Array(ancestors[index...]))
        } else {
            setTrail([directory])
        }
    }

    /// Replaces the columns with `newTrail`, keeping the columns of the shared beginning.
    private func setTrail(_ newTrail: [URL]) {
        cloudObservation.stop()
        var keep = 0
        while keep < min(columns.count, newTrail.count), columns[keep].directory == newTrail[keep] { keep += 1 }
        for column in columns[keep...] { column.removeFromSuperview() }
        columns.removeLast(columns.count - keep)
        for directory in newTrail[keep...] {
            let column = ColumnTable(directory: directory, controller: self)
            columns.append(column)
            stack.addArrangedSubview(column)
            let width = pane.viewConfiguration.columnBrowserWidths[directory.path] ?? pane.viewConfiguration.columnWidth
            column.widthConstraint = column.widthAnchor.constraint(equalToConstant: width + ColumnTable.gap)
            column.widthConstraint?.isActive = true
            column.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
        for (index, column) in columns.enumerated() {
            column.isCurrent = index == columns.count - 1
            column.trailChild = index + 1 < columns.count ? columns[index + 1].directory : nil
            if !column.isCurrent { loadAncestor(column) }
        }
        refreshCurrentColumn()
        cloudObservation.refresh()
        if let last = columns.last {
            DispatchQueue.main.async { [weak self] in self?.scrollView.contentView.scrollToVisible(last.frame) }
        }
    }

    /// The pane's own items (sorted, filtered and searched like the other views) fill the current column.
    private func refreshCurrentColumn() {
        // While a new folder loads, the pane still holds the previous folder's items.
        guard pane.loadState != .loading, let last = columns.last, let current = pane.currentDirectory,
              last.directory.hasSamePath(as: current) else { return }
        last.setItems(pane.displayItems)
        cache[last.directory.path] = pane.displayItems
        last.select(ids: pane.selectedIDs)
    }

    /// Earlier columns read their folder in the background, sorted like the pane.
    private func loadAncestor(_ column: ColumnTable) {
        if let cached = cache[column.directory.path] {
            column.setItems(cached)
            cloudObservation.refresh()
            return
        }
        let directory = column.directory
        let showHidden = pane.viewConfiguration.showsHiddenFiles
        let options = FileSortOptions(pane.viewConfiguration)
        let kind = pane.kindText
        Task.detached(priority: .userInitiated) {
            let loaded = (try? DirectoryLoader.load(directory: directory))?.items ?? []
            let visible = FileSorter.sort(showHidden ? loaded : loaded.filter { !$0.isHidden }, options: options, kind: kind)
            await MainActor.run { [weak self, weak column] in
                guard let self, let column, self.columns.contains(where: { $0 === column }) else { return }
                self.cache[directory.path] = visible
                column.setItems(visible)
                self.cloudObservation.refresh()
            }
        }
    }

    // MARK: Column callbacks

    private func applyAncestorCloudStatuses(_ statuses: [String: FileCloudStatus]) {
        for column in columns.dropLast() {
            guard var items = cache[column.directory.path] else { continue }
            var changed = false
            for index in items.indices where items[index].cloudStatus?.needsStatusRefresh == true {
                guard let status = statuses[items[index].url.standardizedFileURL.path], status != items[index].cloudStatus else { continue }
                items[index].cloudStatus = status
                changed = true
            }
            if changed { cache[column.directory.path] = items; column.updateCloudStatuses(items) }
        }
        cloudObservation.refresh()
    }

    fileprivate func column(_ column: ColumnTable, selected items: [FileItem]) {
        guard let index = columns.firstIndex(where: { $0 === column }) else { return }
        handler?.activate(pane: pane)
        if items.count == 1, let folder = items.first, folder.isBrowsableFolder, !folder.isPackage {
            // A folder opens as the next column and becomes the pane's folder.
            setTrail(Array(trail[...index]) + [folderURL(folder.url)])
            pane.navigate(to: .directory(folder.url.standardizedFileURL))
            return
        }
        if index == columns.count - 1 {
            applyingColumnSelection = true
            pane.selectedIDs = Set(items.map(\.id))
            applyingColumnSelection = false
        } else {
            // Items picked in an earlier column: that column's folder becomes current with them selected.
            setTrail(Array(trail[...index]))
            pane.navigate(to: .directory(column.directory))
            pane.select(urls: items.map(\.url))
        }
    }

    /// ←: back to the previous column, with the folder it leads through selected.
    fileprivate func moveLeft(from column: ColumnTable) {
        guard let index = columns.firstIndex(where: { $0 === column }), index > 0 else { return }
        let previous = columns[index - 1]
        setTrail(Array(trail[...(index - 1)]))
        pane.navigate(to: .directory(previous.directory))
        pane.select(urls: [column.directory])
        previous.focus()
    }

    /// →: into the selected folder's column, selecting its first item.
    fileprivate func moveRight(from column: ColumnTable) {
        guard let index = columns.firstIndex(where: { $0 === column }), index + 1 < columns.count else { return }
        let next = columns[index + 1]
        next.focus()
        if let first = next.items.first {
            next.selectRow(0)
            self.column(next, selected: [first])
        }
    }

    fileprivate func open(_ item: FileItem) {
        handler?.open([item], in: pane, newTab: false)
    }

    fileprivate func previewWithSpace(_ items: [FileItem]) -> Bool {
        handler?.previewWithSpace(items, in: pane) ?? false
    }

    fileprivate func menu(for items: [FileItem]) -> NSMenu? {
        items.isEmpty ? handler?.backgroundMenu(in: pane) : handler?.contextMenu(for: items, in: pane)
    }

    fileprivate func acceptDrop(_ urls: [URL], into directory: URL, operation: NSDragOperation) -> Bool {
        handler?.acceptDrop(urls, into: directory, operation: operation, in: pane) ?? false
    }

    fileprivate func finishRename(_ item: FileItem, to name: String?) {
        pane.renamingID = nil
        if let name, !name.isEmpty, name != item.name { handler?.commitRename(item, to: name, in: pane) }
    }

    fileprivate func resized(_ column: ColumnTable, to width: CGFloat, finished: Bool) {
        column.widthConstraint?.constant = width + ColumnTable.gap
        guard finished else { return }
        var widths = pane.viewConfiguration.columnBrowserWidths
        widths[column.directory.path] = Double(width)
        // Like the original (`ViewConfiguration.maximumColumnBrowserWidthEntries` = 96), keep at most 96 folders,
        // dropping folders that are not in the current columns first.
        let shown = Set(columns.map(\.directory.path))
        for path in widths.keys where widths.count > 96 && !shown.contains(path) { widths[path] = nil }
        pane.viewConfiguration.columnBrowserWidths = widths
        pane.onStateChange?()
    }
}

/// One spelling per folder (standardized, with a trailing slash) so trail comparisons never miss.
private func folderURL(_ url: URL) -> URL {
    URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One column: a single-column table of a folder's children with a draggable right edge.
@MainActor
private final class ColumnTable: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let directory: URL
    private(set) var items: [FileItem] = []
    weak var controller: ColumnBrowserController?
    var widthConstraint: NSLayoutConstraint?
    /// Dark gap after each 200 pt column (8 pt with a hairline 3.5 pt in, as in the original); it is the resize handle.
    static let gap: CGFloat = 8
    /// The column of the pane's current folder shows its selection in the accent color; earlier columns in grey.
    var isCurrent = false {
        didSet { if isCurrent != oldValue { table.enumerateAvailableRowViews { row, _ in row.needsDisplay = true } } }
    }
    /// In an earlier column, the folder the trail continues through.
    var trailChild: URL? { didSet { if trailChild != oldValue { showTrailChild() } } }
    private let table = ColumnTableView()
    private let scroll = NSScrollView()
    private var suppressSelectionCallback = false

    init(directory: URL, controller: ColumnBrowserController) {
        self.directory = folderURL(directory)
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 23
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClick)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.owner = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
        let panel = NSBox()
        panel.boxType = .custom
        panel.borderType = .noBorder
        panel.contentViewMargins = .zero
        panel.fillColor = .controlBackgroundColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        let handle = ColumnResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.resize = { [weak self] width, finished in
            guard let self else { return }
            self.controller?.resized(self, to: width, finished: finished)
        }
        handle.currentWidth = { [weak self] in (self?.frame.width ?? 208) - Self.gap }
        addSubview(panel)
        addSubview(scroll)
        addSubview(handle)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor), panel.trailingAnchor.constraint(equalTo: handle.leadingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor), panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: handle.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor), handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor), handle.widthAnchor.constraint(equalToConstant: Self.gap),
        ])
        table.menu = NSMenu()
        table.menu?.delegate = self
        // Drag files out of a column, or into a column or one of its folders, with the same rules as the list.
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.setAccessibilityIdentifier("FileColumnBrowser.Column.\(directory.lastPathComponent)")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Items that arrived while a name was being edited; applied when editing ends.
    private var pendingItems: [FileItem]?

    /// The ancestor's contents and ordering are unchanged; keep its scroll position and selected trail child.
    func updateCloudStatuses(_ newItems: [FileItem]) {
        guard newItems.count == items.count, zip(items, newItems).allSatisfy({ $0.id == $1.id }) else { return }
        items = newItems
        if pendingItems != nil { pendingItems = newItems }
        for index in items.indices {
            if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ColumnCell {
                cell.updateCloudStatus(items[index])
            }
        }
    }

    func setItems(_ newItems: [FileItem]) {
        guard newItems != items else { return }
        guard renaming == nil else {
            pendingItems = newItems
            return
        }
        items = newItems
        suppressSelectionCallback = true
        table.reloadData()
        suppressSelectionCallback = false
        showTrailChild()
    }

    func focus() {
        window?.makeFirstResponder(table)
    }

    func selectRow(_ row: Int) {
        suppressSelectionCallback = true
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        suppressSelectionCallback = false
    }

    /// Mirrors a selection made outside the column without re-triggering navigation.
    func select(ids: Set<FileIdentity>) {
        let rows = IndexSet(items.indices.filter { ids.contains(items[$0].id) })
        guard rows != table.selectedRowIndexes else { return }
        suppressSelectionCallback = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        suppressSelectionCallback = false
    }

    private var renaming: (item: FileItem, cell: ColumnCell)?

    /// Edits the item's name in its row; Return commits, Escape cancels.
    func beginRename(_ id: FileIdentity) {
        guard renaming == nil, let row = items.firstIndex(where: { $0.id == id }), items[row].allowsRenaming else { return }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ColumnCell else { return }
        renaming = (items[row], cell)
        cell.beginEditing(delegate: self)
    }

    private func endRename(commit: Bool) {
        guard let (item, cell) = renaming else { return }
        renaming = nil
        let name = cell.endEditing()
        window?.makeFirstResponder(table)
        if let pending = pendingItems {
            pendingItems = nil
            setItems(pending)
        }
        controller?.finishRename(item, to: commit ? name.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    private func showTrailChild() {
        guard let trailChild, let row = items.firstIndex(where: { $0.url.hasSamePath(as: trailChild) }) else { return }
        selectRow(row)
        table.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = tableView.makeView(withIdentifier: .init("columnCell"), owner: self) as? ColumnCell ?? ColumnCell()
        cell.identifier = .init("columnCell")
        cell.configure(item)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = ColumnRowView()
        view.column = self
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        controller?.column(self, selected: table.selectedRowIndexes.map { items[$0] })
    }

    @objc private func doubleClick() {
        guard table.clickedRow >= 0 else { return }
        let item = items[table.clickedRow]
        if !item.isBrowsableFolder || item.isPackage { controller?.open(item) }
    }

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let selected = table.selectedRowIndexes.map { items[$0] }
        switch event.keyCode {
        case 123 where flags.isEmpty: // ←
            controller?.moveLeft(from: self)
            return true
        case 124 where flags.isEmpty: // →
            controller?.moveRight(from: self)
            return true
        case 49 where flags.isEmpty: // Space
            if controller?.previewWithSpace(selected) != true { table.toggleQuickLook() }
            return true
        case 125 where flags == .command, 36 where flags.isEmpty, 76 where flags.isEmpty: // ⌘↓, Return, Enter
            for item in selected where !item.isBrowsableFolder || item.isPackage { controller?.open(item) }
            return true
        default:
            return false
        }
    }

    fileprivate var previewURLs: [URL] { table.selectedRowIndexes.map { items[$0].url } }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        items[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        NotificationCenter.default.post(name: .dirDeskFileDragDidBegin, object: nil)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NotificationCenter.default.post(name: .dirDeskFileDragDidEnd, object: nil)
    }

    private func dropDestination(row: Int, operation: NSTableView.DropOperation) -> URL {
        if operation == .on, items.indices.contains(row), items[row].isBrowsableFolder { return items[row].url }
        return directory
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let urls = FileListController.fileURLs(from: info), !urls.isEmpty else { return [] }
        let destination = dropDestination(row: row, operation: dropOperation)
        if destination == directory { tableView.setDropRow(-1, dropOperation: .on) }
        let operation = FileListController.allowsDrop(urls, into: destination)
            ? FileListController.dropOperation(for: urls, destination: destination, info: info) : []
        DragFeedbackPanel.shared.update(operation: operation, destination: destination)
        return operation
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        DragFeedbackPanel.shared.hide()
        guard let urls = FileListController.fileURLs(from: info) else { return false }
        let destination = dropDestination(row: row, operation: dropOperation)
        let operation = FileListController.dropOperation(for: urls, destination: destination, info: info)
        return controller?.acceptDrop(urls, into: destination, operation: operation) ?? false
    }
}

extension ColumnTable: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        endRename(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        endRename(commit: false)
        return true
    }
}

extension ColumnTable: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        var selected = table.selectedRowIndexes.map { items[$0] }
        if row >= 0, !table.selectedRowIndexes.contains(row) { selected = [items[row]] }
        guard let built = controller?.menu(for: selected) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
    }
}

/// Table with the column's keyboard handling (← →, Space, Return) and Quick Look.
private final class ColumnTableView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var owner: ColumnTable?

    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) != true { super.keyDown(with: event) }
    }

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { owner?.previewURLs.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        owner?.previewURLs[index] as NSURL?
    }
}

/// Rounded selection: accent color in the current column, neutral grey in earlier columns.
private final class ColumnRowView: NSTableRowView {
    weak var column: ColumnTable?

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2.5, dy: 0.5), xRadius: 5, yRadius: 5)
        let neutral = effectiveAppearance.isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.1)
        ((column?.isCurrent ?? true) ? NSColor.selectedContentBackgroundColor : neutral).setFill()
        path.fill()
    }

    override var isEmphasized: Bool {
        get { column?.isCurrent ?? super.isEmphasized }
        set { super.isEmphasized = newValue }
    }
}

/// Right edge of a column; drag it to change the column's width (120–600 pt).
private final class ColumnResizeHandle: NSView {
    var resize: ((CGFloat, Bool) -> Void)?
    var currentWidth: (() -> CGFloat)?
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        (effectiveAppearance.isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.08)).setFill()
        NSRect(x: 3.5, y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        startWidth = currentWidth?() ?? 200
    }

    override func mouseDragged(with event: NSEvent) {
        resize?(width(for: event), false)
    }

    override func mouseUp(with event: NSEvent) {
        resize?(width(for: event), true)
    }

    private func width(for event: NSEvent) -> CGFloat {
        min(max(startWidth + event.locationInWindow.x - startX, 120), 600)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { L("Resize Column") }
}

private final class ColumnCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let cloudBadge = CloudStatusBadgeView()
    private var cloudWidth: NSLayoutConstraint!
    private var cloudSpacing: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        name.lineBreakMode = .byTruncatingMiddle
        textField = name
        for view in [icon, name, chevron, cloudBadge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        cloudWidth = cloudBadge.widthAnchor.constraint(equalToConstant: 0)
        cloudSpacing = chevron.leadingAnchor.constraint(equalTo: cloudBadge.trailingAnchor)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 21), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6), name.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudBadge.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 4),
            cloudBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            cloudBadge.heightAnchor.constraint(equalToConstant: 14),
            cloudWidth, cloudSpacing,
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22), chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
        ])
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var path: String?
    private var assetRevision: UInt64 = 0
    private var hasContentThumbnail = false

    func beginEditing(delegate: NSTextFieldDelegate) {
        name.isEditable = true
        name.isSelectable = true
        name.isBordered = true
        name.drawsBackground = true
        name.backgroundColor = .textBackgroundColor
        name.delegate = delegate
        window?.makeFirstResponder(name)
        // Select the name without its extension, like Finder.
        if let editor = name.currentEditor() {
            let base = (name.stringValue as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0, length: (base.isEmpty ? name.stringValue : base).utf16.count)
        }
    }

    /// Ends editing and returns the typed name.
    func endEditing() -> String {
        let typed = name.stringValue
        name.delegate = nil
        name.isEditable = false
        name.isSelectable = false
        name.isBordered = false
        name.drawsBackground = false
        return typed
    }

    /// Column rows show small content thumbnails for images and documents, like the original's column view.
    func configure(_ item: FileItem) {
        path = item.url.path
        assetRevision &+= 1
        let revision = assetRevision
        hasContentThumbnail = false
        let wanted = item.url.path
        let wantsThumbnail = FileIcons.wantsListThumbnail(item, categories: AppModel.shared.preferences.listThumbnailCategories)
        icon.image = FileIcons.shared.icon(for: item) { [weak self] image in
            guard let self, self.path == wanted, self.assetRevision == revision, !self.hasContentThumbnail else { return }
            self.icon.image = image
        }
        name.stringValue = item.name
        chevron.isHidden = !item.isBrowsableFolder || item.isPackage
        updateCloudStatus(item)
        alphaValue = item.isHidden ? 0.5 : 1
        guard wantsThumbnail else { return }
        FileIcons.shared.thumbnail(for: item, size: 16) { [weak self] image in
            guard let self, let image, self.path == wanted, self.assetRevision == revision else { return }
            self.hasContentThumbnail = true
            self.icon.image = image
        }
    }

    func updateCloudStatus(_ item: FileItem) {
        cloudBadge.configure(item.cloudStatus)
        cloudWidth.constant = item.cloudStatus == nil ? 0 : 18
        cloudSpacing.constant = item.cloudStatus == nil ? 0 : 6
        setAccessibilityLabel(cloudBadge.accessibilityLabel(forFileName: item.name))
    }
}

struct ColumnBrowserRepresentable: NSViewControllerRepresentable {
    let pane: PaneRuntime
    let controller: WorkspaceController

    func makeNSViewController(context: Context) -> ColumnBrowserController {
        ColumnBrowserController(pane: pane, handler: controller)
    }

    func updateNSViewController(_ nsViewController: ColumnBrowserController, context: Context) {}
}
