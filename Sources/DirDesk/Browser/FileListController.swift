import AppKit
import Combine
import DirDeskCore
import Quartz

/// Actions a browser view forwards to its window's command handler.
@MainActor
protocol BrowserActionHandler: AnyObject {
    func activate(pane: PaneRuntime)
    func open(_ items: [FileItem], in pane: PaneRuntime, newTab: Bool)
    func contextMenu(for items: [FileItem], in pane: PaneRuntime) -> NSMenu
    func backgroundMenu(in pane: PaneRuntime) -> NSMenu
    func commitRename(_ item: FileItem, to name: String, in pane: PaneRuntime)
    func perform(_ command: ShortcutCommand)
    func acceptDrop(_ urls: [URL], into directory: URL, operation: NSDragOperation, in pane: PaneRuntime) -> Bool
    /// Space: true when Super Preview took it (folders and archives); otherwise the view toggles Quick Look.
    func previewWithSpace(_ items: [FileItem], in pane: PaneRuntime) -> Bool
}

/// List view: a flat table whose rows already contain group headers and inline-expanded children.
@MainActor
final class FileListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let pane: PaneRuntime
    weak var handler: BrowserActionHandler?
    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private var rows: [PaneRuntime.Row] = []
    private var representedContentRevision = -1
    private var cancellables: Set<AnyCancellable> = []
    private var applyingSelection = false
    private var columnSignature: [FileListColumn] = []
    private var dateFormatter = FileDateFormatter(locale: Localizer.shared.locale)
    private var renamingRow: Int?
    private var springRow: Int?
    private var springTimer: Timer?
    private var sizeRequests: [String: AnyCancellable] = [:]
    private var sizeStates: [String: FolderSizeState] = [:]
    private var sizesScheduled = false
    private var sizesEnabled = true

    init(pane: PaneRuntime, handler: BrowserActionHandler?) {
        self.pane = pane
        self.handler = handler
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLayout() {
        super.viewDidLayout()
        scheduleVisibleSizes()
    }

    func stopSizeRequests() {
        setSizeRequestsEnabled(false)
    }

    func setSizeRequestsEnabled(_ enabled: Bool) {
        sizesEnabled = enabled
        if enabled { scheduleVisibleSizes() } else { sizeRequests.removeAll() }
    }

    private func scheduleVisibleSizes() {
        guard sizesEnabled, !sizesScheduled else { return }
        sizesScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizesScheduled = false
            self.updateVisibleSizes()
        }
    }

    private func updateVisibleSizes() {
        guard sizesEnabled else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        let indexes = visible.length > 0 ? visible.location..<(visible.location + visible.length) : 0..<0
        let candidates = tableView.tableColumns.contains { $0.identifier.rawValue == FileListColumn.size.rawValue }
            ? indexes.compactMap { rows.indices.contains($0) ? rows[$0].item : nil }.filter(FolderSizes.needsMeasurement) : []
        let paths = Set(candidates.map { $0.url.path })
        sizeStates = sizeStates.filter { paths.contains($0.key) }
        for path in Array(sizeRequests.keys) where !paths.contains(path) { sizeRequests.removeValue(forKey: path) }
        for item in candidates where sizeRequests[item.url.path] == nil {
            let path = item.url.path
            let revision = pane.directoryContentRevision
            sizeRequests[path] = AnyCancellable {}
            sizeRequests[path] = FolderSizes.shared.observe(item) { [weak self] state in
                guard let self, self.sizesEnabled, revision == self.pane.directoryContentRevision else { return }
                self.sizeStates[path] = state
                self.pane.recordDirectorySize(item, state: state)
                guard let column = self.tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == FileListColumn.size.rawValue }) else { return }
                let visible = self.tableView.rows(in: self.tableView.visibleRect)
                guard visible.length > 0 else { return }
                for row in visible.location..<(visible.location + visible.length) where self.rows.indices.contains(row) && self.rows[row].item?.url.path == path {
                    guard let cell = self.tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? FileTextCellView else { continue }
                    cell.configure(text: FolderSizes.text(item, state: state, unit: AppModel.shared.preferences.fileSizeUnit))
                    cell.setAccessibilityLabel(L("Size") + ": " + (cell.textField?.stringValue ?? ""))
                    cell.toolTip = FolderSizes.help(state)
                }
            }
        }
    }

    override func loadView() {
        let container = NSView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        configureTable()
        bind()
    }

    private func configureTable() {
        // Inset columns (10 pt from each edge, with a header hairline before the first column) over full-width
        // stripes and an inset rounded selection drawn by FileTableRowView (reference capture 01-主窗口).
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.action = #selector(clicked)
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask([.copy, .move, .link], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.owner = self
        tableView.setAccessibilityLabel(L("Files"))
        let headerMenu = NSMenu()
        headerMenu.delegate = tableView
        tableView.headerView?.menu = headerMenu
        rebuildColumns()
    }

    private func bind() {
        pane.$rows.receive(on: RunLoop.main).sink { [weak self] rows in self?.apply(rows: rows) }.store(in: &cancellables)
        // Remember the first visible item so a restored session opens scrolled where it was.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recordScrollAnchor(); self?.scheduleVisibleSizes() }.store(in: &cancellables)
        pane.$selectedIDs.receive(on: RunLoop.main).sink { [weak self] ids in self?.applySelection(ids) }.store(in: &cancellables)
        pane.$viewConfiguration.receive(on: RunLoop.main).sink { [weak self] configuration in
            guard let self else { return }
            if configuration.visibleListColumns != self.columnSignature { self.rebuildColumns() }
            self.updateSortIndicator()
            self.updateRowHeight()
            self.scheduleVisibleSizes()
        }.store(in: &cancellables)
        pane.$renamingID.receive(on: RunLoop.main).sink { [weak self] id in
            if let id { self?.beginRename(id) }
        }.store(in: &cancellables)
        AppModel.shared.$configuration.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.dateFormatter = FileDateFormatter(locale: Localizer.shared.locale)
            self?.updateRowHeight()
            self?.reloadKeepingSelection()
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .dirDeskLanguageChanged).sink { [weak self] _ in
            self?.dateFormatter = FileDateFormatter(locale: Localizer.shared.locale)
            self?.rebuildColumns()
            self?.reloadKeepingSelection()
        }.store(in: &cancellables)
        // Relative dates ("5 minutes ago") and age colors drift; refresh them every minute.
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.reloadDateColumns()
        }.store(in: &cancellables)
    }

    // MARK: Columns

    /// Column titles as in the original's header ("修改日期", "创建时间", "上次访问日期", "文件扩展名").
    private func title(for column: FileListColumn) -> String {
        switch column {
        case .name: L("Name")
        case .modificationDate: L("Modified")
        case .size: L("Size")
        case .kind: L("Kind")
        case .creationDate: L("Created")
        case .lastOpenedDate: L("Last Accessed")
        case .addedDate: L("Added")
        case .tags: L("Tags")
        case .fileExtension: L("File Extension")
        }
    }

    /// Default widths measured on the original's header (modified 122, size 66, kind 92, last accessed 120 pt).
    private func defaultWidth(for column: FileListColumn) -> CGFloat {
        switch column {
        case .name: 300
        case .size: 66
        case .kind: 92
        case .tags: 100
        case .fileExtension: 70
        case .lastOpenedDate: 120
        default: 122
        }
    }

    func rebuildColumns() {
        let configuration = pane.viewConfiguration
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        var visible = configuration.visibleListColumns
        if !visible.contains(.name) { visible.insert(.name, at: 0) }
        for column in visible {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = title(for: column)
            tableColumn.width = CGFloat(configuration.listColumnWidths[column.rawValue] ?? Double(defaultWidth(for: column)))
            tableColumn.minWidth = column == .name ? 120 : 44
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue, ascending: true)
            tableColumn.headerCell.alignment = .left
            tableView.addTableColumn(tableColumn)
        }
        columnSignature = configuration.visibleListColumns
        updateSortIndicator()
        updateRowHeight()
        reloadKeepingSelection()
    }

    /// `NSTableView.reloadData()` drops the selection on current macOS without telling the delegate, so every
    /// reload puts the pane's selection back (the pane's selection is the source of truth).
    private func reloadKeepingSelection() {
        tableView.reloadData()
        applySelection(pane.selectedIDs)
    }

    private func updateSortIndicator() {
        let configuration = pane.viewConfiguration
        let descriptor = NSSortDescriptor(key: configuration.sortKey.rawValue, ascending: configuration.sortAscending)
        if tableView.sortDescriptors.first?.key != descriptor.key || tableView.sortDescriptors.first?.ascending != descriptor.ascending {
            applyingSelection = true
            tableView.sortDescriptors = [descriptor]
            applyingSelection = false
        }
    }

    private func updateRowHeight() {
        let density = AppModel.shared.preferences.listDensity
        let thumb = CGFloat(pane.viewConfiguration.listThumbnailSize)
        let height = max(density.rowHeight, thumb + 6)
        if tableView.rowHeight != height { tableView.rowHeight = height }
    }

    func toggleColumn(_ column: FileListColumn) {
        guard column != .name else { return }
        var columns = pane.viewConfiguration.visibleListColumns
        if let index = columns.firstIndex(of: column) {
            columns.remove(at: index)
        } else {
            columns.append(column)
        }
        pane.viewConfiguration.visibleListColumns = columns
    }

    /// Header menu: every column with a check mark; Name is always shown and cannot be turned off.
    func headerMenuItems() -> [NSMenuItem] {
        FileListColumn.allCases.map { column in
            let item = NSMenuItem(title: title(for: column), action: column == .name ? nil : #selector(toggleColumnFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = column == .name || pane.viewConfiguration.visibleListColumns.contains(column) ? .on : .off
            item.isEnabled = column != .name
            return item
        }
    }

    @objc private func toggleColumnFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = FileListColumn(rawValue: raw) else { return }
        toggleColumn(column)
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
        pane.viewConfiguration.listColumnWidths[column.identifier.rawValue] = Double(column.width)
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        let order = tableView.tableColumns.compactMap { FileListColumn(rawValue: $0.identifier.rawValue) }
        columnSignature = order
        pane.viewConfiguration.visibleListColumns = order
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applyingSelection, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key.flatMap(FileSortKey.init) else { return }
        if pane.viewConfiguration.sortKey != key || pane.viewConfiguration.sortAscending != descriptor.ascending {
            pane.viewConfiguration.sortKey = key
            pane.viewConfiguration.sortAscending = descriptor.ascending
        }
    }

    // MARK: Data

    private func apply(rows newRows: [PaneRuntime.Row]) {
        if representedContentRevision != pane.directoryContentRevision {
            sizeRequests.removeAll()
            sizeStates.removeAll()
        }
        scheduleVisibleSizes()
        if applyCloudStatusChanges(newRows) { return }
        representedContentRevision = pane.directoryContentRevision
        // Keep an inline rename going when the folder reloads (for example after a change on disk).
        let renamingID = renamingRow.flatMap { rows.indices.contains($0) ? rows[$0].item?.id : nil }
        rows = newRows
        if let renamingID {
            if let row = newRows.firstIndex(where: { $0.item?.id == renamingID }) {
                renamingRow = row
            } else {
                endRenameField(commit: false)
            }
        }
        tableView.reloadData()
        if let row = renamingRow {
            let rowRect = tableView.rect(ofRow: row)
            renameField.frame.origin.y = rowRect.midY - 14
        }
        applySelection(pane.selectedIDs)
        restoreScrollAnchor()
    }

    /// A resource-only cloud refresh changes neither row geometry nor preview contents. Update the visible badges
    /// directly so NSTableView does not clear its selection and reload a running Quick Look panel.
    private func applyCloudStatusChanges(_ newRows: [PaneRuntime.Row]) -> Bool {
        guard representedContentRevision == pane.directoryContentRevision, rows.count == newRows.count else { return false }
        var changed: [Int] = []
        for index in rows.indices {
            switch (rows[index], newRows[index]) {
            case let (.item(old, oldDepth), .item(new, newDepth)):
                guard oldDepth == newDepth else { return false }
                var comparable = new
                comparable.cloudStatus = old.cloudStatus
                guard comparable == old else { return false }
                if old.cloudStatus != new.cloudStatus { changed.append(index) }
            default:
                guard rows[index] == newRows[index] else { return false }
            }
        }
        guard !changed.isEmpty else { return false }
        rows = newRows
        if let column = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == FileListColumn.name.rawValue }) {
            for index in changed {
                guard let item = rows[index].item,
                      let cell = tableView.view(atColumn: column, row: index, makeIfNecessary: false) as? FileNameCellView else { continue }
                cell.updateCloudStatus(item.cloudStatus, name: item.name)
            }
        }
        return true
    }

    private func recordScrollAnchor() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0, pane.pendingScrollAnchor == nil else { return }
        let first = (visible.location..<(visible.location + visible.length)).first { rows.indices.contains($0) && rows[$0].item != nil }
        pane.scrollAnchorPath = visible.location == 0 ? nil : first.flatMap { rows[$0].item?.url.path }
    }

    /// After the first load of a restored pane, scroll the saved first visible item back to the top.
    private func restoreScrollAnchor() {
        guard let anchor = pane.pendingScrollAnchor, !rows.isEmpty else { return }
        pane.pendingScrollAnchor = nil
        guard let row = rows.firstIndex(where: { $0.item?.url.path == anchor }) else { return }
        // Scrolling up to a row from below leaves it at the top edge, under the header.
        tableView.scrollRowToVisible(rows.count - 1)
        tableView.scrollRowToVisible(row)
    }

    private func reloadDateColumns() {
        let indexes = IndexSet(tableView.tableColumns.indices.filter {
            FileListColumn(rawValue: tableView.tableColumns[$0].identifier.rawValue)?.isDate == true
        })
        guard !indexes.isEmpty, !rows.isEmpty else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<rows.count), columnIndexes: indexes)
    }


    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .group = rows[row] { return true }
        return false
    }

    /// Group titles take 30 pt; later groups get 20 pt of space above them.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .group = rows[row] { return row == 0 ? 30 : 50 }
        return tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: FileTableRowView.identifier, owner: self) as? FileTableRowView ?? FileTableRowView()
        view.identifier = FileTableRowView.identifier
        view.striped = row % 2 == 1 && rows[row].item != nil
        // Hidden items are shown faded across the whole row (icon, text and date pill).
        view.alphaValue = rows[row].item?.isHidden == true ? 0.5 : 1
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].item != nil
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier.rawValue == FileListColumn.name.rawValue || tableColumn == nil else { return nil }
        return rows[row].item?.name
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(_, let title, let count):
            let view = tableView.makeView(withIdentifier: .init("group"), owner: self) as? FileGroupHeaderView ?? FileGroupHeaderView()
            view.identifier = .init("group")
            view.configure(title: title, count: count)
            return view
        case .item(let item, let depth):
            guard let tableColumn, let column = FileListColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            return cell(for: item, depth: depth, column: column, row: row)
        }
    }

    private func cell(for item: FileItem, depth: Int, column: FileListColumn, row: Int) -> NSView {
        let preferences = AppModel.shared.preferences
        switch column {
        case .name:
            let cell = tableView.makeView(withIdentifier: .init("name"), owner: self) as? FileNameCellView ?? FileNameCellView()
            cell.identifier = .init("name")
            cell.assetRevision &+= 1
            let assetRevision = cell.assetRevision
            cell.hasContentThumbnail = false
            let size = CGFloat(pane.viewConfiguration.listThumbnailSize)
            let path = item.url.path
            let wantsThumbnail = FileIcons.wantsListThumbnail(item, categories: preferences.listThumbnailCategories)
            var image = FileIcons.shared.icon(for: item) { [weak cell] image in
                guard let cell, cell.representedPath == path, cell.assetRevision == assetRevision,
                      !cell.hasContentThumbnail else { return }
                cell.iconView.image = image
            }
            if wantsThumbnail {
                if let thumbnail = FileIcons.shared.cachedThumbnail(for: item, size: size) {
                    image = thumbnail
                    cell.hasContentThumbnail = true
                } else {
                    let path = item.url.path
                    FileIcons.shared.thumbnail(for: item, size: size) { [weak cell] thumbnail in
                        guard let cell, let thumbnail, cell.representedPath == path, cell.assetRevision == assetRevision else { return }
                        cell.hasContentThumbnail = true
                        cell.iconView.image = thumbnail
                    }
                }
            }
            let truncation: NSLineBreakMode = switch preferences.filenameTruncation {
            case .middle: .byTruncatingMiddle
            case .tail: .byTruncatingTail
            case .head: .byTruncatingHead
            }
            let tags = item.tags.compactMap { TagColors.color(forTag: $0) }
            let repository = preferences.showsGitStatus && item.isBrowsableFolder
                && GitRepositoryProbe.isRepository(item.url) { [weak cell] value in
                    guard let cell, cell.representedPath == path, cell.assetRevision == assetRevision else { return }
                    cell.badgeView.isHidden = !value || !AppModel.shared.preferences.showsGitStatus
                }
            cell.configure(item: item, depth: depth, expanded: pane.isExpanded(item), iconSize: size, image: image,
                           isGitRepository: repository,
                           tagColors: tags, truncation: truncation)
            // The rename field covers the name of the row being renamed; reused cells must show theirs.
            cell.nameField.alphaValue = row == renamingRow ? 0 : 1
            if row == renamingRow { renamingCell = cell }
            cell.onToggle = { [weak self] in self?.pane.toggleExpansion(item) }
            return cell
        case .modificationDate, .creationDate, .addedDate, .lastOpenedDate:
            let cell = tableView.makeView(withIdentifier: .init("date"), owner: self) as? FileDateCellView ?? FileDateCellView()
            cell.identifier = .init("date")
            let date: Date? = switch column {
            case .modificationDate: item.modificationDate
            case .creationDate: item.creationDate
            case .addedDate: item.addedDate
            default: item.lastOpenedDate
            }
            dateFormatter.absolute = UserDefaults.standard.bool(forKey: "dirdesk-show-absolute-time-v1")
            let text = dateFormatter.string(date, justNow: L("Just now"), minutesAgoFormat: L("%lld min ago"), yesterdayFormat: L("Yesterday %@"), todayFormat: L("Today %@"))
            var background: NSColor?
            var textColor: NSColor?
            if preferences.showsDateAgeColors, let bucket = DateAgeBucket.bucket(for: date) {
                let colors = Theme.dateAgeColors(bucket, theme: preferences.dateColorTheme, dark: view.effectiveAppearance.isDark)
                background = preferences.showsDateAgeStyle ? colors.background : nil
                textColor = preferences.showsDateAgeStyle ? .labelColor : colors.text
            }
            cell.configure(text: text, background: background, textColor: textColor)
            // VoiceOver reads the column and the absolute date, as the original does ("修改日期: 26/10/19 22:55").
            cell.setAccessibilityLabel(title(for: column) + ": " + dateFormatter.absoluteString(date))
            return cell
        case .size:
            let cell = textCell()
            let state = sizeStates[item.url.path]
            cell.configure(text: FolderSizes.text(item, state: state, unit: preferences.fileSizeUnit))
            cell.setAccessibilityLabel(L("Size") + ": " + (cell.textField?.stringValue ?? ""))
            cell.toolTip = FolderSizes.needsMeasurement(item) ? FolderSizes.help(state) : nil
            return cell
        case .kind:
            let cell = textCell()
            cell.configure(text: pane.kindText(item))
            return cell
        case .tags:
            let cell = textCell()
            cell.configure(text: item.tags.joined(separator: ", "))
            return cell
        case .fileExtension:
            let cell = textCell()
            cell.configure(text: item.isBrowsableFolder ? "--" : item.fileExtension.lowercased())
            return cell
        }
    }

    private func textCell() -> FileTextCellView {
        let cell = tableView.makeView(withIdentifier: .init("text"), owner: self) as? FileTextCellView ?? FileTextCellView()
        cell.toolTip = nil
        cell.setAccessibilityLabel(nil)
        cell.identifier = .init("text")
        return cell
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let ids = Set(tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].item?.id : nil })
        if ids != pane.selectedIDs { pane.selectedIDs = ids }
        handler?.activate(pane: pane)
    }

    private func applySelection(_ ids: Set<FileIdentity>) {
        let indexes = IndexSet(rows.indices.filter { rows[$0].item.map { ids.contains($0.id) } ?? false })
        guard indexes != tableView.selectedRowIndexes else { return }
        applyingSelection = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { tableView.scrollRowToVisible(first) }
        applyingSelection = false
    }

    func selectedItems() -> [FileItem] {
        tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].item : nil }
    }

    func item(atRow row: Int) -> FileItem? {
        rows.indices.contains(row) ? rows[row].item : nil
    }

    @objc private func clicked() {
        handler?.activate(pane: pane)
        guard AppModel.shared.preferences.opensItemsWithSingleClick, tableView.clickedRow >= 0,
              let item = item(atRow: tableView.clickedRow), NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty else { return }
        handler?.open([item], in: pane, newTab: false)
    }

    @objc private func doubleClicked() {
        guard tableView.clickedRow >= 0 else {
            if tableView.clickedRow == -1, let command = BlankSpaceDoubleClick.command { handler?.perform(command) }
            return
        }
        guard let item = item(atRow: tableView.clickedRow) else { return }
        handler?.open([item], in: pane, newTab: NSEvent.modifierFlags.contains(.command))
    }

    func openSelection() {
        let items = selectedItems()
        guard !items.isEmpty else { return }
        handler?.open(items, in: pane, newTab: false)
    }

    // MARK: Inline rename

    /// Inline rename uses a separate field laid over the name, as in the original: rounded, accent outline, at
    /// least 280 pt wide even when the column is narrower. Only the base name of a file starts selected.
    private func beginRename(_ id: FileIdentity) {
        guard let row = rows.firstIndex(where: { $0.item?.id == id }), let item = rows[row].item, item.allowsRenaming,
              let nameColumn = tableView.tableColumns.firstIndex(where: { $0.identifier.rawValue == FileListColumn.name.rawValue }) else {
            pane.renamingID = nil
            return
        }
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? FileNameCellView else { return }
        endRenameField(commit: false)
        renamingRow = row
        let field = renameField
        field.font = cell.nameField.font
        field.stringValue = item.name
        field.delegate = self
        let textFrame = tableView.convert(cell.nameField.frame, from: cell)
        let rowRect = tableView.rect(ofRow: row)
        let visible = tableView.visibleRect
        let width = min(max(280, textFrame.width + 28), max(visible.maxX - textFrame.minX - 8, 120))
        field.frame = NSRect(x: textFrame.minX - 6, y: rowRect.midY - 14, width: width, height: 28)
        tableView.addSubview(field)
        renamingCell = cell
        cell.nameField.alphaValue = 0
        view.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let name = item.name as NSString
            let ext = name.pathExtension
            let length = (ext.isEmpty || item.isBrowsableFolder) ? name.length : name.length - ext.count - 1
            editor.selectedRange = NSRange(location: 0, length: max(length, 0))
        }
    }

    private lazy var renameField: NSTextField = {
        let field = InlineRenameField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(white: 0.12, alpha: 1) : NSColor.textBackgroundColor
        }
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.wantsLayer = true
        field.layer?.cornerRadius = 6
        field.layer?.borderWidth = 1
        field.layer?.borderColor = NSColor.controlAccentColor.cgColor
        field.setAccessibilityIdentifier("InlineRename.Field")
        field.setAccessibilityLabel(L("Rename"))
        return field
    }()
    private weak var renamingCell: FileNameCellView?

    /// Removes the rename field; with `commit`, renames the item when the text changed.
    private func endRenameField(commit: Bool) {
        guard let row = renamingRow else { return }
        renamingRow = nil
        let newName = renameField.stringValue
        renameField.delegate = nil
        renameField.removeFromSuperview()
        renamingCell?.nameField.alphaValue = 1
        renamingCell = nil
        pane.renamingID = nil
        guard commit, rows.indices.contains(row), let item = rows[row].item, newName != item.name else { return }
        handler?.commitRename(item, to: newName, in: pane)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === renameField, renamingRow != nil else { return }
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        endRenameField(commit: movement != NSTextMovement.cancel.rawValue)
        view.window?.makeFirstResponder(tableView)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), control === renameField {
            endRenameField(commit: false)
            view.window?.makeFirstResponder(tableView)
            return true
        }
        return false
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        rows[row].item?.url as NSURL?
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        NotificationCenter.default.post(name: .dirDeskFileDragDidBegin, object: nil)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NotificationCenter.default.post(name: .dirDeskFileDragDidEnd, object: nil)
        if operation == .move || operation == .delete { pane.reload() }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let urls = Self.fileURLs(from: info), !urls.isEmpty else { return [] }
        var destination = pane.currentDirectory
        if dropOperation == .on, let item = item(atRow: row), item.isBrowsableFolder {
            destination = item.url
            scheduleSpringLoad(row: row, item: item)
        } else {
            cancelSpringLoad()
            tableView.setDropRow(-1, dropOperation: .on)
        }
        guard let destination else { return [] }
        let operation = Self.allowsDrop(urls, into: destination) ? Self.dropOperation(for: urls, destination: destination, info: info) : []
        DragFeedbackPanel.shared.update(operation: operation, destination: destination)
        return operation
    }

    /// Not into one of the dragged folders or their insides, and not back into the folder the items are already in.
    static func allowsDrop(_ urls: [URL], into destination: URL) -> Bool {
        if urls.contains(where: { destination.path == $0.path || destination.path.hasPrefix($0.path + "/") }) { return false }
        return !urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == destination.standardizedFileURL.path }
    }

    /// Spring-loaded folders: hovering a dragged item over a folder expands it inline after the configured delay.
    private func scheduleSpringLoad(row: Int, item: FileItem) {
        guard springRow != row else { return }
        cancelSpringLoad()
        springRow = row
        let delay = AppModel.shared.preferences.dragHoverExpansionDelay
        springTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.springRow == row, !self.pane.isExpanded(item) else { return }
                self.pane.toggleExpansion(item)
            }
        }
    }

    private func cancelSpringLoad() {
        springTimer?.invalidate()
        springTimer = nil
        springRow = nil
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, movedTo screenPoint: NSPoint) {}

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        cancelSpringLoad()
        DragFeedbackPanel.shared.hide()
        guard let urls = Self.fileURLs(from: info) else { return false }
        var destination = pane.currentDirectory
        if dropOperation == .on, row >= 0, let item = item(atRow: row), item.isBrowsableFolder { destination = item.url }
        guard let destination else { return false }
        let operation = Self.dropOperation(for: urls, destination: destination, info: info)
        return handler?.acceptDrop(urls, into: destination, operation: operation, in: pane) ?? false
    }

    static func fileURLs(from info: NSDraggingInfo) -> [URL]? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    /// Same volume moves, another volume copies; Shift reverses when enabled; Option forces copy.
    static func dropOperation(for urls: [URL], destination: URL, info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) && mask.contains(.copy) { return .copy }
        let sameVolume = urls.allSatisfy { FileOperationSupport.sameVolume($0, destination) }
        var move = sameVolume
        if flags.contains(.shift) && AppModel.shared.preferences.shiftDragReversesOperation { move.toggle() }
        if move && (mask.contains(.move) || mask.contains(.generic)) { return .move }
        if mask.contains(.copy) { return .copy }
        return mask.contains(.generic) ? .generic : []
    }
}

/// Table subclass: keyboard behaviour, context menus, header menu and Quick Look control.
@MainActor
final class FileTableView: NSTableView, NSMenuDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var owner: FileListController?

    override func keyDown(with event: NSEvent) {
        guard let owner else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        switch event.keyCode {
        case 36, 76 where flags.isEmpty: // Return / Enter
            if AppModel.shared.preferences.enterKeyAction == .rename, let item = owner.selectedItems().first, owner.selectedItems().count == 1 {
                owner.pane.renamingID = item.id
            } else {
                owner.openSelection()
            }
        case 49 where flags.isEmpty: // Space
            if owner.handler?.previewWithSpace(owner.selectedItems(), in: owner.pane) != true { toggleQuickLook() }
        case 51 where flags.isEmpty: // Delete (Backspace)
            if AppModel.shared.preferences.backspaceKeyAction == .navigateUp { owner.pane.goUp() } else { super.keyDown(with: event) }
        case 125 where flags == .command: // ⌘↓
            owner.openSelection()
        case 124 where flags.isEmpty: // → expands an inline folder
            if let item = owner.selectedItems().first, item.isBrowsableFolder, !owner.pane.isExpanded(item) { owner.pane.toggleExpansion(item) } else { super.keyDown(with: event) }
        case 123 where flags.isEmpty: // ← collapses
            if let item = owner.selectedItems().first, item.isBrowsableFolder, owner.pane.isExpanded(item) { owner.pane.toggleExpansion(item) } else { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, let item = owner.item(atRow: row) {
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            _ = item
            return owner.handler?.contextMenu(for: owner.selectedItems(), in: owner.pane)
        }
        deselectAll(nil)
        return owner.handler?.backgroundMenu(in: owner.pane)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        owner?.headerMenuItems().forEach(menu.addItem)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if let owner { owner.handler?.activate(pane: owner.pane) }
        return result
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
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

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { owner?.selectedItems().count ?? 0 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard let items = owner?.selectedItems(), items.indices.contains(index) else { return nil }
            return items[index].url as NSURL
        }
    }

    override func reloadData() {
        super.reloadData()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }
}

enum FileOperationSupport {
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let va = try? a.resourceValues(forKeys: keys).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: keys).volumeIdentifier as? NSObject else { return true }
        return va.isEqual(vb)
    }
}

/// Finder tag colors resolved from the system tag list, keyed by tag name.
@MainActor
enum TagColors {
    private static var colors: [String: Int] = [:]
    private static var loaded = false

    static func color(forTag name: String) -> NSColor? {
        if !loaded { load() }
        let label = colors[name] ?? colors[name.lowercased()] ?? defaultLabel(for: name)
        return Theme.finderTagColor(label)
    }

    private static func defaultLabel(for name: String) -> Int? {
        let map: [String: Int] = [
            "gray": 1, "grey": 1, "灰色": 1, "green": 2, "绿色": 2, "purple": 3, "紫色": 3, "blue": 4, "蓝色": 4,
            "yellow": 5, "黄色": 5, "red": 6, "红色": 6, "orange": 7, "橙色": 7,
        ]
        return map[name.lowercased()]
    }

    private static func load() {
        loaded = true
        let defaults = UserDefaults(suiteName: "com.apple.Finder")
        guard let tags = defaults?.dictionary(forKey: "FavoriteTagNames") else { return }
        _ = tags
    }

    static func set(_ name: String, label: Int) { colors[name] = label }
}
