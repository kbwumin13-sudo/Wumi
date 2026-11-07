import AppKit
import DirDeskCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Results list: an NSTableView for large result sets, double-click, keyboard commands and dragging.
struct LightningResultsTable: NSViewRepresentable {
    @ObservedObject var model: LightningSearchModel

    func makeCoordinator() -> LightningResultsCoordinator {
        LightningResultsCoordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = LightningResultsTableView()
        context.coordinator.configure(table)
        model.focus.tableView = table
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update()
    }
}

final class LightningResultsTableView: NSTableView {
    weak var coordinator: LightningResultsCoordinator?

    private static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Alternating stripes only behind real rows; the space below the last result stays plain, as in the original.
    override func drawBackground(inClipRect clipRect: NSRect) {
        guard usesAlternatingRowBackgroundColors else { return super.drawBackground(inClipRect: clipRect) }
        guard numberOfRows > 0 else { return }
        let rowsBottom = rect(ofRow: numberOfRows - 1).maxY
        guard rowsBottom > clipRect.minY else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: clipRect.minX, y: clipRect.minY, width: clipRect.width,
                                  height: min(clipRect.height, rowsBottom - clipRect.minY))).setClip()
        super.drawBackground(inClipRect: clipRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.modifierMask)
        switch event.keyCode {
        case 36, 76:
            // Return / Enter: go to the item's location (Command-Return opens it, see performKeyEquivalent).
            if flags.isEmpty { coordinator?.revealSelection() } else { super.keyDown(with: event) }
        case 126 where flags.isEmpty && selectedRow <= 0:
            // Up Arrow on the first row returns to the search field.
            coordinator?.focusSearchField()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(Self.modifierMask)
        switch (event.keyCode, flags) {
        case (36, [.command]), (76, [.command]):
            coordinator?.openSelection()
            return true
        case (51, [.command]):
            coordinator?.trashSelection()
            return true
        case (8, [.command, .option]):
            coordinator?.copyPathsOfSelection()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        coordinator?.copySelection()
    }

    @objc func cut(_ sender: Any?) {
        coordinator?.cutSelection()
    }
}

@MainActor
final class LightningResultsCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Column: String, CaseIterable {
        case name, path, size, modified, created, actions

        var sortKey: LightningSortKey? {
            switch self {
            case .name: .name
            case .path: .path
            case .size: .size
            case .modified: .modified
            case .created: .created
            case .actions: nil
            }
        }

        init?(sortKey: LightningSortKey) {
            switch sortKey {
            case .name: self = .name
            case .path: self = .path
            case .size: self = .size
            case .modified: self = .modified
            case .created: self = .created
            case .none: return nil
            }
        }

        /// Widths of a 980-point window. The inset table style adds 6 points before the first and after the last column.
        var width: CGFloat {
            switch self {
            case .name: 174.5
            case .path: 201.5
            case .size: 96.5
            case .modified: 145.5
            case .created: 146
            case .actions: 184
            }
        }
    }

    private weak var model: LightningSearchModel?
    private weak var table: LightningResultsTableView?
    private var rows: [LightningRow] = []
    private var generation = -1
    private var appliedSort: (key: LightningSortKey, descending: Bool)?
    private var applyingProgrammaticChange = false
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Localizer.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("yyyyMMddHHmm")
        return formatter
    }()
    private let icons = LightningIconCache()
    /// Row of the menu opened by a row's More button; nil for the context menu.
    private var moreMenuRow: Int?

    init(model: LightningSearchModel) {
        self.model = model
    }

    func configure(_ table: LightningResultsTableView) {
        self.table = table
        table.coordinator = self
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.setDraggingSourceOperationMask([.copy, .link, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.setAccessibilityIdentifier("GlobalQuickSearch.Results")
        table.setAccessibilityLabel(L("Search Results"))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            let header = LightningHeaderCell(textCell: title(column))
            header.font = tableColumn.headerCell.font
            header.titleInset = column == .name ? 0 : 1.5
            tableColumn.headerCell = header
            tableColumn.title = title(column)
            tableColumn.width = column.width
            tableColumn.minWidth = column == .actions ? column.width : 60
            if column.sortKey != nil {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            }
            // Name and Path take up changes of the window width; the other columns keep theirs.
            tableColumn.resizingMask = switch column {
            case .name, .path: [.autoresizingMask, .userResizingMask]
            case .actions: []
            default: [.userResizingMask]
            }
            table.addTableColumn(tableColumn)
        }
        // The autosave restores column widths. It would also restore an old sort order, but the model owns the
        // sort (and must not change while SwiftUI builds this view), so `update()` puts the model's order back.
        applyingProgrammaticChange = true
        table.autosaveName = "DirDesk.LightningSearch.ResultColumns"
        table.autosaveTableColumns = true
        applyingProgrammaticChange = false
        appliedSort = nil
        update()
    }

    private func title(_ column: Column) -> String {
        switch column {
        case .name: L("Name")
        case .path: L("Path")
        case .size: L("Size")
        case .modified: L("Modified")
        case .created: L("Created")
        case .actions: L("Actions")
        }
    }

    /// Applies the model's results and sort order; cheap when nothing changed.
    func update() {
        guard let model, let table else { return }
        if generation != model.resultGeneration {
            generation = model.resultGeneration
            rows = model.rows
            applyingProgrammaticChange = true
            table.reloadData()
            let selected = model.selectedPaths
            if !selected.isEmpty {
                let indexes = IndexSet(rows.indices.filter { selected.contains(rows[$0].path) })
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                model.selectedPaths = Set(indexes.map { rows[$0].path })
            }
            applyingProgrammaticChange = false
            if table.selectedRowIndexes.isEmpty, !rows.isEmpty { table.scrollRowToVisible(0) }
        }
        if appliedSort?.key != model.sortKey || appliedSort?.descending != model.sortDescending {
            appliedSort = (model.sortKey, model.sortDescending)
            applyingProgrammaticChange = true
            if let column = Column(sortKey: model.sortKey) {
                table.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: !model.sortDescending)]
            } else {
                table.sortDescriptors = []
            }
            applyingProgrammaticChange = false
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue),
              rows.indices.contains(row) else { return nil }
        let item = rows[row]
        switch column {
        case .name:
            let cell = textCell(tableView, identifier: identifier, withImage: true)
            cell.textField?.stringValue = item.name
            cell.textField?.textColor = .labelColor
            cell.imageView?.image = icons.image(for: item) { [weak self, weak tableView] in
                guard let self, let tableView, let index = self.rows.firstIndex(where: { $0.path == item.path }) else { return }
                tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
            }
            cell.toolTip = item.path
            return cell
        case .path:
            let cell = textCell(tableView, identifier: identifier, withImage: false)
            let folder = (item.path as NSString).deletingLastPathComponent
            cell.textField?.stringValue = item.isOnline ? folder : L("Offline") + " · " + folder
            cell.toolTip = folder
            return cell
        case .size:
            let cell = textCell(tableView, identifier: identifier, withImage: false)
            cell.textField?.stringValue = item.size.map { FileSizeFormatter.string($0, unit: AppModel.shared.preferences.fileSizeUnit) } ?? "--"
            return cell
        case .modified:
            let cell = textCell(tableView, identifier: identifier, withImage: false)
            cell.textField?.stringValue = item.modified.map(dateFormatter.string(from:)) ?? "--"
            return cell
        case .created:
            let cell = textCell(tableView, identifier: identifier, withImage: false)
            cell.textField?.stringValue = item.created.map(dateFormatter.string(from:)) ?? "--"
            return cell
        case .actions:
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? LightningActionsCellView)
                ?? LightningActionsCellView(identifier: identifier, target: self)
            cell.configure(row: row, path: item.path)
            return cell
        }
    }

    /// Name (with a thumbnail), path, size and date cells: 12-point text, everything but the name in gray.
    private func textCell(_ tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier, withImage: Bool) -> NSTableCellView {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView { return reused }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12)
        text.textColor = .secondaryLabelColor
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text
        var constraints = [
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
        ]
        if withImage {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6.5),
            ]
        } else {
            constraints.append(text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6))
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        rows.indices.contains(row) && rows[row].isOnline ? rows[row].url as NSURL : nil
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applyingProgrammaticChange, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
              let column = Column(rawValue: key), let sortKey = column.sortKey else { return }
        appliedSort = (sortKey, !descriptor.ascending)
        model?.setSort(sortKey, descending: !descriptor.ascending)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingProgrammaticChange, let table else { return }
        model?.selectedPaths = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].path : nil })
    }

    // MARK: Commands

    private var selectedRows: [LightningRow] {
        guard let table else { return [] }
        return table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    /// The row of a More button, the clicked row, or the whole selection when the clicked row belongs to it.
    private var menuRows: [LightningRow] {
        guard let table else { return [] }
        if let row = moreMenuRow { return rows.indices.contains(row) ? [rows[row]] : [] }
        let clicked = table.clickedRow
        if clicked >= 0, rows.indices.contains(clicked), !table.selectedRowIndexes.contains(clicked) { return [rows[clicked]] }
        return selectedRows
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let table, rows.indices.contains(table.clickedRow) else { return }
        model?.reveal(rows[table.clickedRow])
    }

    func revealSelection() {
        guard let first = selectedRows.first else { return }
        model?.reveal(first)
    }

    func openSelection() { model?.open(selectedRows) }
    func copySelection() { model?.copy(selectedRows) }
    func cutSelection() { model?.cut(selectedRows) }
    func copyPathsOfSelection() { model?.copyPaths(selectedRows) }
    func trashSelection() { model?.moveToTrash(selectedRows) }

    func focusSearchField() {
        model?.focus.focusSearchField()
    }

    // MARK: Row buttons

    @objc func previewRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        model?.preview(rows[sender.tag])
    }

    @objc func openRow(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        model?.open([rows[sender.tag]])
    }

    @objc func showMoreMenu(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let menu = NSMenu()
        moreMenuRow = sender.tag
        fill(menu)
        moreMenuRow = nil
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY + 4 : -4), in: sender)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let targets = menuRows
        guard let model, let first = targets.first else { return }
        menu.addItem(LightningMenuItem(L("Preview"), symbol: "eye") { model.preview(first) })
        menu.addItem(LightningMenuItem(L("Open"), symbol: "arrow.up.forward.app", key: "\r", modifiers: [.command]) { model.open(targets) })
        menu.addItem(LightningMenuItem(L("Reveal in Wumi"), symbol: "folder", key: "\r", modifiers: []) { model.reveal(first) })
        menu.addItem(.separator())
        menu.addItem(LightningMenuItem(L("Copy"), symbol: "doc.on.doc", key: "c", modifiers: [.command]) { model.copy(targets) })
        menu.addItem(LightningMenuItem(L("Cut"), symbol: "scissors", key: "x", modifiers: [.command]) { model.cut(targets) })
        menu.addItem(LightningMenuItem(L("Copy Path"), symbol: "link", key: "c", modifiers: [.command, .option]) { model.copyPaths(targets) })
        menu.addItem(.separator())
        menu.addItem(LightningMenuItem(L("Send to File Transit"), symbol: "shippingbox") { model.sendToFileTransit(targets) })
        menu.addItem(.separator())
        menu.addItem(LightningMenuItem(L("Move to Trash"), symbol: "trash", key: "\u{8}", modifiers: [.command]) { model.moveToTrash(targets) })
        if !targets.allSatisfy(\.isOnline) {
            menu.autoenablesItems = false
            for item in menu.items where !item.isSeparatorItem && item.title != L("Copy Path") { item.isEnabled = false }
        }
    }
}

/// A column header whose title can sit a little further in than AppKit's default.
final class LightningHeaderCell: NSTableHeaderCell {
    var titleInset: CGFloat = 0

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var frame = cellFrame
        frame.origin.x += titleInset
        frame.size.width = max(0, frame.size.width - titleInset)
        super.drawInterior(withFrame: frame, in: controlView)
    }
}

/// Preview, Open and More for one result.
final class LightningActionsCellView: NSTableCellView {
    private let preview: NSButton
    private let open: NSButton
    private let more: NSButton

    init(identifier: NSUserInterfaceItemIdentifier, target: LightningResultsCoordinator) {
        preview = Self.button(L("Preview"), symbol: "eye", target: target, action: #selector(LightningResultsCoordinator.previewRow(_:)))
        open = Self.button(L("Open"), symbol: "arrow.up.right.square", target: target, action: #selector(LightningResultsCoordinator.openRow(_:)))
        more = Self.button(L("More"), symbol: "ellipsis", target: target, action: #selector(LightningResultsCoordinator.showMoreMenu(_:)))
        super.init(frame: .zero)
        self.identifier = identifier
        let stack = NSStackView(views: [preview, open, more])
        stack.orientation = .horizontal
        stack.spacing = 15
        stack.setCustomSpacing(17.5, after: open)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10.5),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(row: Int, path: String) {
        for button in [preview, open, more] { button.tag = row }
        preview.setAccessibilityIdentifier("LightningSearch.Preview." + path)
        open.setAccessibilityIdentifier("LightningSearch.Open." + path)
        more.setAccessibilityIdentifier("LightningSearch.More." + path)
    }

    private static func button(_ title: String, symbol: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        let button = NSButton(title: title, image: image ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .labelColor
        button.toolTip = title
        button.setButtonType(.momentaryPushIn)
        return button
    }
}

/// A menu item that runs a closure.
private final class LightningMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String?, key: String = "", modifiers: NSEvent.ModifierFlags = [], handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Icons by file type, without touching the file; content thumbnails (Quick Look) replace them once generated.
/// Packages (apps) load their own icon in the background.
@MainActor
final class LightningIconCache {
    private var byType: [String: NSImage] = [:]
    private var byPath: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private let thumbnails = NSCache<NSString, NSImage>()
    /// Files Quick Look could not draw, so they keep their icon.
    private var withoutThumbnail: Set<String> = []
    private lazy var folderIcon = NSWorkspace.shared.icon(for: .folder)

    init() {
        thumbnails.countLimit = 1_500
    }

    func image(for row: LightningRow, loaded: @escaping () -> Void) -> NSImage {
        let pathExtension = (row.name as NSString).pathExtension.lowercased()
        if !row.isOnline { return row.isDirectory && !row.isPackage ? folderIcon : typeIcon(pathExtension, fallback: .data) }
        if row.isPackage {
            if let image = byPath[row.path] { return image }
            if !loading.contains(row.path) { loadIcon(row.path, loaded) }
            return typeIcon(pathExtension, fallback: .package)
        }
        if row.isDirectory { return folderIcon }
        let key = thumbnailKey(row)
        if let thumbnail = thumbnails.object(forKey: key as NSString) { return thumbnail }
        if !withoutThumbnail.contains(key), !loading.contains(key) { loadThumbnail(row, key: key, loaded) }
        return typeIcon(pathExtension, fallback: .data)
    }

    private func thumbnailKey(_ row: LightningRow) -> String {
        row.path + "|" + String(row.modified?.timeIntervalSince1970 ?? 0)
    }

    private func typeIcon(_ pathExtension: String, fallback: UTType) -> NSImage {
        let key = fallback.identifier + "|" + pathExtension
        if let image = byType[key] { return image }
        let type = pathExtension.isEmpty ? fallback : (UTType(filenameExtension: pathExtension) ?? fallback)
        let image = NSWorkspace.shared.icon(for: type)
        byType[key] = image
        return image
    }

    private func loadIcon(_ path: String, _ loaded: @escaping () -> Void) {
        loading.insert(path)
        Task {
            let box = await Task.detached(priority: .utility) { LightningImageBox(NSWorkspace.shared.icon(forFile: path)) }.value
            loading.remove(path)
            if byPath.count > 2_000 { byPath.removeAll() }
            byPath[path] = box.image
            loaded()
        }
    }

    private func loadThumbnail(_ row: LightningRow, key: String, _ loaded: @escaping () -> Void) {
        loading.insert(key)
        let request = QLThumbnailGenerator.Request(fileAt: row.url, size: CGSize(width: 18, height: 18), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let box = representation.map { LightningImageBox($0.nsImage) }
            Task { @MainActor in
                self.loading.remove(key)
                guard let box else {
                    if self.withoutThumbnail.count > 5_000 { self.withoutThumbnail.removeAll() }
                    self.withoutThumbnail.insert(key)
                    return
                }
                self.thumbnails.setObject(box.image, forKey: key as NSString)
                loaded()
            }
        }
    }
}

/// Carries an image created on a background thread to the main actor.
final class LightningImageBox: @unchecked Sendable {
    let image: NSImage

    init(_ image: NSImage) {
        self.image = image
    }
}
