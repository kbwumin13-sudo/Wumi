import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

private let bookmarkNodeType = NSPasteboard.PasteboardType("com.kbwumin13.dirdesk.bookmark-node")

/// Bookmark manager, laid out like the original's floating panel (920 × 684 pt): a header with title, note, search
/// field and Done; Show Paths, Expand All and Collapse All; the bookmark outline (36 pt rows, drag to reorder); and a
/// bottom bar with Add (New Bookmark Folder, Add Current Folder, Add Selected Items), Rename…, Edit…, Move to…,
/// Delete and the number of items. Its sheets open on the manager itself.
struct BookmarkManagerView: View {
    @ObservedObject var library = LibraryModel.shared
    @AppStorage(DefaultsKey.bookmarkManagerShowsPaths) private var showsPaths = true
    @State private var query = ""
    @State private var selection: UUID?
    @State private var sheet: ManagerSheet?
    @State private var expansion = OutlineExpansion()
    @FocusState private var searchFocused: Bool
    /// The workspace window the Add menu works on (the active one when the menu is used).
    let controller: () -> WorkspaceController?
    let close: () -> Void

    enum ManagerSheet: Identifiable {
        case newFolder(parent: UUID?)
        case rename(BookmarkLibrary.Node)
        case edit(BookmarkLibrary.Node)
        case add([URL])

        var id: String {
            switch self {
            case .newFolder: "new-folder"
            case .rename(let node): "rename-\(node.id)"
            case .edit(let node): "edit-\(node.id)"
            case .add(let urls): "add-\(urls.map(\.path).joined(separator: "|"))"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 12) {
                Toggle(L("Show Paths"), isOn: $showsPaths)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("Bookmarks.Manager.ShowPaths")
                Button(L("Expand All")) { expansion.request(expand: true) }
                    .accessibilityIdentifier("Bookmarks.Manager.ExpandAll")
                Button(L("Collapse All")) { expansion.request(expand: false) }
                    .accessibilityIdentifier("Bookmarks.Manager.CollapseAll")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            // The inset table style adds 10 pt above the first row, so rows start 12 pt below the buttons.
            BookmarkOutline(selection: $selection, showsPaths: showsPaths, query: query, expansion: expansion, open: open)
                .padding(.horizontal, 10)
                .padding(.top, 2)
            Divider()
            bottomBar
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newFolder(let parent):
                BookmarkNameSheet(title: L("New Bookmark Folder"), initial: L("New Folder"), action: L("Create"),
                                  identifier: "Bookmarks.Manager.NewFolder", commitIdentifier: "Create") { name in
                    library.addBookmarkFolder(named: name, parent: parent)
                } finish: { self.sheet = nil }
            case .rename(let node):
                BookmarkNameSheet(title: L("Rename Bookmark"), initial: node.displayTitle, action: L("Rename"),
                                  identifier: "Bookmarks.Manager.Rename", commitIdentifier: "Save") { name in
                    library.mutateBookmarks { try $0.rename(node.id, to: name) }
                } finish: { self.sheet = nil }
            case .edit(let node):
                BookmarkEditSheet(node: node) { self.sheet = nil }
            case .add(let urls):
                BookmarkAddSheet(urls: urls) { self.sheet = nil }
            }
        }
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Manage Bookmarks")).font(.system(size: 18, weight: .bold))
                Text(L("Arrange bookmarks and bookmark folders, and open frequent places in one step."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            TextField(L("Search Bookmarks"), text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($searchFocused)
                .accessibilityIdentifier("Bookmarks.Manager.Search")
            Button(L("Done"), action: close)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("Bookmarks.Manager.Done")
        }
        .padding(.horizontal, 20)
        .frame(height: 80)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Menu {
                Button(L("New Bookmark Folder")) { sheet = .newFolder(parent: newFolderParent) }
                Button(L("Add Current Folder")) {
                    if let url = controller()?.activePane.currentDirectory { sheet = .add([url]) }
                }
                .disabled(controller()?.activePane.currentDirectory == nil)
                Button(L("Add Selected Items")) {
                    if let items = controller()?.selection, !items.isEmpty { sheet = .add(items.map(\.url)) }
                }
                .disabled(controller()?.selection.isEmpty ?? true)
            } label: {
                Label(L("Add"), systemImage: "plus")
            }
            .fixedSize()
            .accessibilityIdentifier("Bookmarks.Manager.Add")
            // Like the original's bookmark menu, the built-in folder can be renamed and moved but not deleted.
            Button(L("Rename…")) { if let node = selectedNode { sheet = .rename(node) } }
                .disabled(selectedNode == nil)
            Button(L("Edit…")) { if let node = selectedNode { sheet = .edit(node) } }
                .disabled(selectedNode?.target == nil)
            Menu(L("Move to…")) {
                if let node = selectedNode {
                    BookmarkMoveMenuItems(node: node)
                }
            }
            .fixedSize()
            .disabled(selectedNode == nil)
            .accessibilityIdentifier("Bookmarks.Manager.MoveTo")
            Button(L("Delete")) { delete() }
                .disabled(selectedNode == nil || selectedNode?.builtInRole != nil)
            Spacer(minLength: 12)
            if let error = library.lastError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
            }
            // Folders count too: the original reports "1 bookmark" for a library holding only the default folder.
            Text(LF("%lld bookmarks", Int64(library.bookmarks.nodes.count)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var selectedNode: BookmarkLibrary.Node? { selection.flatMap(library.bookmarks.node) }

    /// New folders go into the selected folder (or next to the selected bookmark), else into the default folder.
    private var newFolderParent: UUID? {
        selectedNode.map { $0.isFolder ? $0.id : $0.parentID } ?? library.bookmarks.defaultFolder?.id
    }

    private func open(_ node: BookmarkLibrary.Node) {
        controller()?.openBookmark(node)
    }

    private func delete() {
        guard let node = selectedNode else { return }
        library.mutateBookmarks { $0.remove(node.id) }
        selection = nil
    }
}

/// "Move to" items for a bookmark: the Bookmarks Bar, then every folder indented by depth except the bookmark itself
/// and the folders inside it. Choosing the folder it is already in changes nothing.
struct BookmarkMoveMenuItems: View {
    let node: BookmarkLibrary.Node
    @ObservedObject var library = LibraryModel.shared

    var body: some View {
        Button(L("Bookmarks Bar")) { move(to: nil) }
        ForEach(library.bookmarks.folderOutline(excluding: node.id), id: \.node.id) { entry in
            Button(String(repeating: "    ", count: entry.depth + 1) + entry.node.displayTitle) { move(to: entry.node.id) }
        }
    }

    private func move(to folder: UUID?) {
        guard library.bookmarks.node(node.id)?.parentID != folder else { return }
        library.mutateBookmarks { try $0.move(node.id, to: folder, index: Int.max) }
    }
}

/// Expand All / Collapse All requests passed to the outline; each request bumps the generation.
struct OutlineExpansion: Equatable {
    private(set) var generation = 0
    private(set) var expands = true

    mutating func request(expand: Bool) {
        expands = expand
        generation += 1
    }
}

/// The manager's "New Bookmark Folder" and "Rename Bookmark" sheets: title, name field (text selected), Cancel and
/// the action button. Metrics follow the original's 420 × 149 pt sheet.
struct BookmarkNameSheet: View {
    let title: String
    let action: String
    let identifier: String
    let commitIdentifier: String
    let commit: (String) -> Void
    let finish: () -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String, initial: String, action: String, identifier: String, commitIdentifier: String,
         commit: @escaping (String) -> Void, finish: @escaping () -> Void) {
        self.title = title
        self.action = action
        self.identifier = identifier
        self.commitIdentifier = commitIdentifier
        self.commit = commit
        self.finish = finish
        _name = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .bold))
            TextField("", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .accessibilityLabel(L("Name"))
                .accessibilityIdentifier("\(identifier).Name")
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel"), action: finish).keyboardShortcut(.cancelAction)
                Button(action) {
                    LibraryModel.shared.lastError = nil
                    commit(name)
                    if LibraryModel.shared.lastError == nil { finish() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("\(identifier).\(commitIdentifier)")
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}

/// Native outline with drag-and-drop reordering of bookmark nodes. While searching it lists the matching bookmarks
/// and folders flat.
private struct BookmarkOutline: NSViewRepresentable {
    @Binding var selection: UUID?
    let showsPaths: Bool
    let query: String
    let expansion: OutlineExpansion
    let open: (BookmarkLibrary.Node) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("title"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.rowHeight = 36
        outline.indentationPerLevel = 16
        outline.backgroundColor = .clear
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClick)
        outline.registerForDraggedTypes([bookmarkNodeType, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityIdentifier("Bookmarks.Manager.Outline")
        context.coordinator.outline = outline
        context.coordinator.expansionGeneration = expansion.generation
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        outline.reloadData()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.reload()
        if expansion.generation != coordinator.expansionGeneration, let outline = coordinator.outline {
            coordinator.expansionGeneration = expansion.generation
            if expansion.expands {
                outline.expandItem(nil, expandChildren: true)
            } else {
                outline.collapseItem(nil, collapseChildren: true)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: BookmarkOutline
        weak var outline: NSOutlineView?
        var expansionGeneration = 0
        private var boxes: [UUID: NodeBox] = [:]

        init(_ parent: BookmarkOutline) { self.parent = parent }

        final class NodeBox: NSObject {
            let id: UUID
            init(_ id: UUID) { self.id = id }
        }

        private func box(_ id: UUID) -> NodeBox {
            if let existing = boxes[id] { return existing }
            let new = NodeBox(id)
            boxes[id] = new
            return new
        }

        private var library: BookmarkLibrary { LibraryModel.shared.bookmarks }
        private var searching: Bool { !parent.query.trimmingCharacters(in: .whitespaces).isEmpty }

        private func children(of id: UUID?) -> [BookmarkLibrary.Node] {
            guard searching else { return library.children(of: id) }
            guard id == nil else { return [] }
            let query = parent.query.trimmingCharacters(in: .whitespaces)
            return library.nodes.filter { node in
                node.builtInRole == nil && (node.title.localizedCaseInsensitiveContains(query)
                    || (node.target?.url.path.localizedCaseInsensitiveContains(query) ?? false))
            }
        }

        /// Expanded folders, kept while a search shows the flat list so the tree comes back as it was.
        private var expanded: Set<UUID> = []
        private var restoring = false

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !restoring, !searching, let id = (notification.userInfo?["NSObject"] as? NodeBox)?.id else { return }
            expanded.insert(id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !restoring, !searching, let id = (notification.userInfo?["NSObject"] as? NodeBox)?.id else { return }
            expanded.remove(id)
        }

        func reload() {
            guard let outline else { return }
            let selected = parent.selection
            restoring = true
            outline.reloadData()
            if !searching {
                // Parents first, so nested folders can open.
                for node in library.nodes where expanded.contains(node.id) {
                    var chain: [UUID] = []
                    var current: UUID? = node.id
                    while let id = current {
                        chain.insert(id, at: 0)
                        current = library.node(id)?.parentID
                    }
                    for id in chain where expanded.contains(id) { outline.expandItem(box(id)) }
                }
            }
            restoring = false
            if let selected, library.node(selected) != nil {
                let row = outline.row(forItem: box(selected))
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: (item as? NodeBox)?.id).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            box(children(of: (item as? NodeBox)?.id)[index].id)
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard !searching, let id = (item as? NodeBox)?.id else { return false }
            return library.node(id)?.isFolder ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let id = (item as? NodeBox)?.id, let node = library.node(id) else { return nil }
            let cell = NSTableCellView()
            let icon = NSImageView(image: Self.icon(for: node))
            icon.imageScaling = .scaleProportionallyUpOrDown
            let title = NSTextField(labelWithString: node.displayTitle)
            title.font = .systemFont(ofSize: 13, weight: node.isFolder ? .semibold : .regular)
            title.lineBreakMode = .byTruncatingMiddle
            let text = NSStackView(views: [title])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1
            if parent.showsPaths, let path = node.target?.url.path {
                let detail = NSTextField(labelWithString: (path as NSString).abbreviatingWithTildeInPath)
                detail.font = .systemFont(ofSize: 11)
                detail.textColor = .secondaryLabelColor
                detail.lineBreakMode = .byTruncatingMiddle
                text.addArrangedSubview(detail)
            }
            for view in [icon, text] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.setAccessibilityLabel(title.stringValue)
            return cell
        }

        /// Folders use the system folder icon; bookmarks the icon of their target's type (no file reads, so protected
        /// folders never prompt).
        static func icon(for node: BookmarkLibrary.Node) -> NSImage {
            guard let target = node.target, target.kind != .folder else { return NSWorkspace.shared.icon(for: .folder) }
            return NSWorkspace.shared.icon(for: UTType(filenameExtension: target.url.pathExtension) ?? .data)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline else { return }
            let id = (outline.item(atRow: outline.selectedRow) as? NodeBox)?.id
            if parent.selection != id { parent.selection = id }
        }

        @objc func doubleClick() {
            guard let outline, let id = (outline.item(atRow: outline.clickedRow) as? NodeBox)?.id, let node = library.node(id), !node.isFolder else { return }
            parent.open(node)
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard !searching, let id = (item as? NodeBox)?.id, library.node(id)?.builtInRole == nil else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(id.uuidString, forType: bookmarkNodeType)
            return pasteboardItem
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            if searching { return [] }
            if let id = (item as? NodeBox)?.id, library.node(id)?.isFolder != true { return [] }
            return info.draggingPasteboard.availableType(from: [bookmarkNodeType]) != nil ? .move : .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let parentID = (item as? NodeBox)?.id
            if let raw = info.draggingPasteboard.string(forType: bookmarkNodeType), let id = UUID(uuidString: raw) {
                LibraryModel.shared.mutateBookmarks { try $0.move(id, to: parentID, index: index < 0 ? Int.max : index) }
            } else if let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                LibraryModel.shared.addBookmarks(urls, to: parentID)
            }
            reload()
            return true
        }
    }
}

/// Small modal text prompt used by library windows.
@MainActor
enum Prompt {
    static func text(_ title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func confirm(_ title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Named workspace manager: rename, duplicate, delete, save method, locate the open tab.
struct WorkspaceManagerView: View {
    @ObservedObject var library = NamedWorkspaceLibrary.shared
    @State private var selection: UUID?
    let locate: (UUID) -> Bool
    let open: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if library.workspaces.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(L("No Saved Workspaces")).font(.headline)
                    Text(L("Save the current tab from the Workspaces menu to create one.")).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(library.workspaces, selection: $selection) { workspace in
                    HStack {
                        Image(systemName: "rectangle.3.group")
                        VStack(alignment: .leading) {
                            Text(workspace.name)
                            Text("\(PaneLayoutNames.title(workspace.tab.layout)) · \(workspace.tab.panes.compactMap { $0.history.current?.directoryURL?.lastPathComponent }.joined(separator: ", "))")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Picker("", selection: Binding(get: { workspace.saveMode }, set: { library.setMode(workspace.id, mode: $0) })) {
                            Text(L("Automatic Saving (Dynamic)")).tag(NamedWorkspaceLibrary.SaveMode.dynamic)
                            Text(L("Manual Saving (Static)")).tag(NamedWorkspaceLibrary.SaveMode.static)
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                    .tag(workspace.id)
                    .onTapGesture(count: 2) { open(workspace.id) }
                }
            }
            Divider()
            HStack {
                Button(L("Rename Workspace")) { rename() }.disabled(selection == nil)
                Button(L("Duplicate Workspace")) { if let id = selection { library.duplicate(id) } }.disabled(selection == nil)
                Button(L("Delete")) { delete() }.disabled(selection == nil)
                Button(L("Locate Open Workspace")) { if let id = selection, !locate(id) { NSSound.beep() } }.disabled(selection == nil)
                Spacer()
                Button(L("Open Workspace")) { if let id = selection { open(id) } }.disabled(selection == nil).keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private func rename() {
        guard let id = selection, let workspace = library.workspaces.first(where: { $0.id == id }),
              let name = Prompt.text(L("Rename Workspace"), initial: workspace.name) else { return }
        do {
            try library.rename(id, to: name)
        } catch NamedWorkspaceLibrary.LibraryError.duplicateName {
            NSAlert.show(L("A workspace with this name already exists."))
        } catch {
            NSAlert.show(L("Use a name of 1–128 characters on a single line."))
        }
    }

    private func delete() {
        guard let id = selection, let workspace = library.workspaces.first(where: { $0.id == id }) else { return }
        if Prompt.confirm(L("Delete Workspace?"), message: workspace.name, action: L("Delete")) {
            library.delete(id)
            selection = nil
        }
    }
}

extension NSAlert {
    @MainActor static func show(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}

/// Import Finder sidebar favorites into the bookmarks bar or Common Paths.
struct FinderFavoritesImportView: View {
    enum Destination: String { case bookmarks, commonPaths }
    @State private var favorites: [FinderFavoritesReader.Favorite] = []
    @State private var chosen: Set<URL> = []
    @State private var destination: Destination = .bookmarks
    @State private var message: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Would you like to bring your Finder favorites into Wumi? Choose folders to add to the favorites bar.")).font(.system(size: 13))
            Picker("", selection: $destination) {
                Text(L("Bookmarks Bar")).tag(Destination.bookmarks)
                Text(L("Common Paths")).tag(Destination.commonPaths)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            List(favorites, id: \.url) { favorite in
                Toggle(isOn: Binding(get: { chosen.contains(favorite.url) }, set: { on in
                    if on { chosen.insert(favorite.url) } else { chosen.remove(favorite.url) }
                })) {
                    VStack(alignment: .leading) {
                        Text(favorite.name)
                        Text(favorite.url.path).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 200)
            Text(L("Built-in locations are excluded. More than 8 new folders are grouped in Finder Imports.")).font(.system(size: 11)).foregroundStyle(.secondary)
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button(L("Read Finder Favorites…")) { readFromPanel() }
                Spacer()
                Button(L("Not Now"), action: close)
                Button(L("Import Selected")) { importSelected() }.disabled(chosen.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .onAppear(perform: readDefault)
    }

    private func load(_ url: URL) {
        do {
            let all = try FinderFavoritesReader.read(url)
            favorites = all.filter { !FinderFavoritesReader.isBuiltInLocation($0.url) }
            chosen = Set(favorites.map(\.url))
            message = favorites.isEmpty ? L("No importable folders were found in Finder favorites.") : nil
        } catch {
            message = L("Could not read this favorites file. Select Finder's FavoriteItems.sfl3 or FavoriteItems.sfl4 file and try again.")
        }
    }

    private func readDefault() {
        if let url = FinderFavoritesReader.defaultFileURL { load(url) }
    }

    private func readFromPanel() {
        let panel = NSOpenPanel()
        panel.message = L("Select the Finder favorites file to read its folders. Finder favorites will not be changed.")
        panel.directoryURL = FinderFavoritesReader.defaultFileURL?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    private func importSelected() {
        let urls = favorites.map(\.url).filter(chosen.contains)
        let library = LibraryModel.shared
        switch destination {
        case .commonPaths:
            for url in urls { library.addCommonPath(url) }
        case .bookmarks:
            let fresh = urls.filter { !library.bookmarks.contains(url: $0) }
            if fresh.count > 8 {
                library.addBookmarkFolder(named: L("Finder Imports"), parent: library.bookmarks.defaultFolder?.id)
                let folder = library.bookmarks.children(of: library.bookmarks.defaultFolder?.id).last { $0.isFolder && $0.title == L("Finder Imports") }
                library.addBookmarks(fresh, to: folder?.id)
            } else {
                library.addBookmarks(fresh)
            }
        }
        UserDefaults.standard.set("completed", forKey: DefaultsKey.finderFavoritesOnboarding)
        close()
    }
}

/// "Edit Bookmark" sheet of the bookmark manager: name and absolute path, Cancel / Save. The path must lead to an
/// existing file or folder (`~` and environment variables are expanded).
private struct BookmarkEditSheet: View {
    let node: BookmarkLibrary.Node
    let finish: () -> Void
    @ObservedObject private var library = LibraryModel.shared
    @State private var title: String
    @State private var path: String
    @State private var error: String?

    init(node: BookmarkLibrary.Node, finish: @escaping () -> Void) {
        self.node = node
        self.finish = finish
        _title = State(initialValue: node.title)
        _path = State(initialValue: node.target?.url.path ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Edit Bookmark")).font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Name")).font(.system(size: 12, weight: .semibold))
                TextField(L("Name"), text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("Bookmarks.Manager.Edit.Name")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Path")).font(.system(size: 12, weight: .semibold))
                TextField(L("Enter the full path of a file or folder."), text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityIdentifier("Bookmarks.Manager.Edit.Path")
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel"), action: finish).keyboardShortcut(.cancelAction)
                Button(L("Save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("Bookmarks.Manager.Edit.Save")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            error = L("A bookmark name cannot be empty.")
            return
        }
        guard let url = try? PathUtilities.resolveExisting(path.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = L("Enter the full path of a file or folder that exists.")
            return
        }
        library.mutateBookmarks { library in
            try library.rename(node.id, to: name)
            try library.updateTarget(node.id, url: url)
        }
        if let message = library.lastError {
            error = message
            library.lastError = nil
            return
        }
        finish()
    }
}
