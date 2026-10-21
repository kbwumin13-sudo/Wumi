import AppKit
import DirDeskCore
import Quartz
import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceController {
    var activePane: PaneRuntime { model.activePane }

    /// Items a command acts on: the selection, or nothing.
    var selection: [FileItem] { activePane.selectedItems }

    // MARK: Shortcut commands

    func perform(_ command: ShortcutCommand) {
        let pane = activePane
        if let layout = command.paneLayout {
            setLayout(layout)
            return
        }
        switch command {
        case .newWindow: appDelegate?.newWindow(directory: pane.currentDirectory)
        case .openSelection: open(selection, in: pane, newTab: false)
        case .invertSelection: pane.invertSelection()
        case .newTab: newTab()
        case .closeTab: closeTab(model.activeTabID)
        case .removeDuplicateTabs: removeDuplicateTabs()
        case .reopenClosedTab: model.reopenClosedTab()
        case .editPath: NotificationCenter.default.post(name: .dirDeskEditPath, object: pane.id)
        case .search, .globalQuickSearch: appDelegate?.showLightningSearch(scope: pane.currentDirectory)
        case .navigateBack: pane.goBack()
        case .navigateForward: pane.goForward()
        case .navigateUp: pane.goUp()
        case .addBookmark: presentBookmarkAdd()
        case .newFolder: newFolder()
        case .newFile:
            if let template = AppModel.shared.configuration.fileTemplates.first(where: \.isDefault) ?? AppModel.shared.configuration.fileTemplates.first {
                createFile(from: template)
            }
        case .rename:
            if let item = selection.first, selection.count == 1, item.allowsRenaming { pane.renamingID = item.id }
        case .duplicate: duplicateSelection()
        case .cut: cutSelection()
        case .copy: copyToClipboard(selection)
        case .copyPath: copyPaths(selection.isEmpty ? [pane.currentDirectory].compactMap { $0 } : selection.map(\.url), folderOnly: selection.isEmpty)
        case .paste: paste(move: false)
        case .pasteAndMove: paste(move: true)
        case .moveToTrash: moveToTrash(selection, in: pane)
        case .quickLook: toggleQuickLook()
        case .previousPane: model.activeTab.focusPane(offset: -1); focusActivePaneView()
        case .nextPane: model.activeTab.focusPane(offset: 1); focusActivePaneView()
        case .toggleInspector: model.inspectorVisible.toggle()
        case .iconView: pane.viewConfiguration.mode = .icons
        case .listView: pane.viewConfiguration.mode = .list
        case .columnView: pane.viewConfiguration.mode = .columns
        case .imageView: pane.viewConfiguration.mode = .images
        case .batchRename:
            if selection.allSatisfy(\.allowsRenaming) { showBatchRename(selection) }
        case .openTerminal: openExternalTool(kind: .terminal)
        case .openEditor: openExternalTool(kind: .editor)
        case .layoutFourColumns, .layoutFourRows, .layoutSingle, .layoutTwoColumns, .layoutTwoRows, .layoutFourGrid, .layoutOneLeftTwoRight,
             .layoutTwoLeftOneRight, .layoutOneTopTwoBottom, .layoutTwoTopOneBottom, .layoutThreeRows, .layoutThreeColumns:
            break
        }
    }

    func performToolbar(_ command: ToolbarCommand) {
        switch command {
        case .viewMode: break
        case .paneLayout: setLayout(model.activeTab.layout == .single ? .twoColumns : .single)
        case .newFolder: perform(.newFolder)
        case .newFile: perform(.newFile)
        case .search: perform(.search)
        case .terminal: perform(.openTerminal)
        case .inspector: perform(.toggleInspector)
        case .openFolder: chooseFolderToOpen()
        case .sort: activePane.setSort(activePane.viewConfiguration.sortKey)
        case .foldersFirst: activePane.viewConfiguration.foldersFirst.toggle()
        case .grouping: activePane.viewConfiguration.groupingMode = activePane.viewConfiguration.groupingMode == .none ? .kind : .none
        case .externalTools: perform(.openEditor)
        case .quickLook: perform(.quickLook)
        case .copyPath: perform(.copyPath)
        case .revealInFinder: revealInFinder()
        case .hiddenFiles: activePane.viewConfiguration.showsHiddenFiles.toggle()
        case .airDrop: shareAirDrop()
        case .folderSync: showFolderSync()
        }
    }

    // MARK: File commands

    func newFolder() {
        guard let directory = activePane.currentDirectory else { return }
        do {
            let url = try FileOperations.createFolder(in: directory, undoManager: window?.undoManager)
            beginRenameAfterCreation(url)
        } catch let error as FileOperations.OperationError {
            presentError(error.message)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func createFile(from template: NewFileTemplate) {
        guard let directory = activePane.currentDirectory else { return }
        do {
            let url = try FileOperations.createFile(from: template, in: directory, undoManager: window?.undoManager)
            beginRenameAfterCreation(url)
        } catch let error as FileOperations.OperationError {
            presentError(error.message)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func beginRenameAfterCreation(_ url: URL) {
        let pane = activePane
        let destination = pane.destination
        pane.reload()
        Task { @MainActor [weak pane] in
            guard let pane else { return }
            await pane.waitForRows()
            guard pane.destination == destination else { return }
            // Compare paths: a folder item's URL ends with a slash, the created URL does not.
            if let item = pane.rows.compactMap(\.item).first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) {
                pane.selectedIDs = [item.id]
                pane.renamingID = item.id
            }
        }
    }

    func duplicateSelection() {
        let created = FileOperations.duplicate(selection.map(\.url), undoManager: window?.undoManager)
        activePane.reload()
        activePane.select(urls: created)
    }

    func makeAlias(_ items: [FileItem]) {
        let created = FileOperations.makeAlias(items.map(\.url), undoManager: window?.undoManager)
        activePane.reload()
        activePane.select(urls: created)
        if !created.isEmpty { activePane.operationMessage = L("Aliases Created"); clearOperationMessage(after: 3) }
    }

    func moveToTrash(_ items: [FileItem], in pane: PaneRuntime) {
        guard !items.isEmpty else { return }
        FileOperations.trash(items.map(\.url), undoManager: window?.undoManager) { [weak self] trashed in
            guard let self else { return }
            pane.reload()
            if !trashed.isEmpty { pane.operationMessage = L("Moved to Trash"); self.clearOperationMessage(after: 3) }
        }
    }

    func copyToClipboard(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        cutPending = []
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.writeObjects(items.map { $0.url as NSURL }) {
            activePane.operationMessage = LF("Copied %lld items to the Clipboard", Int64(items.count))
        } else {
            activePane.operationMessage = L("Copy failed")
        }
        clearOperationMessage(after: 4)
    }

    func cutSelection() {
        let items = selection
        guard !items.isEmpty else { return }
        copyToClipboard(items)
        cutPending = items.map(\.url)
        appDelegate?.cutURLs = cutPending
        activePane.operationMessage = L("Ready to move — paste at the destination")
        clearOperationMessage(after: 4)
    }

    func paste(move: Bool) {
        guard let directory = activePane.currentDirectory,
              let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let cut = appDelegate?.cutURLs ?? []
        // Lightning Search marks cut results on the pasteboard instead of remembering them here.
        let marked = NSPasteboard.general.string(forType: LightningSearchActions.cutMarkerType) == "true"
        let shouldMove = move || marked || (!cut.isEmpty && Set(cut) == Set(urls))
        transfer(urls, to: directory, move: shouldMove)
        if shouldMove {
            appDelegate?.cutURLs = []
            if marked { NSPasteboard.general.clearContents() }
        }
    }

    func copyPaths(_ urls: [URL], folderOnly: Bool) {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        activePane.operationMessage = L("Path copied")
        clearOperationMessage(after: 3)
    }

    func revealInFinder() {
        let urls = selection.isEmpty ? [activePane.currentDirectory].compactMap { $0 } : selection.map(\.url)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func previewWithSpace(_ items: [FileItem], in pane: PaneRuntime) -> Bool {
        guard SuperPreviewController.handlesSpace(for: items), let item = items.first else { return false }
        SuperPreviewController.shared.toggle(item, controller: self)
        return true
    }

    func showSuperPreview(_ item: FileItem, archiveEntry: String? = nil) {
        SuperPreviewController.shared.show(item, controller: self, archiveEntry: archiveEntry)
    }

    func toggleQuickLook() {
        if previewWithSpace(selection, in: activePane) { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        focusActivePaneView()
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func openExternalTool(kind: ExternalToolKind) {
        let configuration = AppModel.shared.configuration
        guard let tool = configuration.defaultTool(of: kind) else {
            presentError(kind == .terminal ? L("No terminal application is configured.") : L("No editor application is configured."))
            return
        }
        openWith(tool: tool)
    }

    func openWith(tool: ExternalTool) {
        openWith(tool: tool, targets: selection.isEmpty ? [activePane.currentDirectory].compactMap { $0 } : selection.map(\.url))
    }

    /// Terminals receive one folder (the first selected folder, else the folder of the first item); editors get every target.
    func openWith(tool: ExternalTool, targets requested: [URL]) {
        let appURL = URL(fileURLWithPath: tool.applicationPath)
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            presentError(L("The configured application is unavailable."))
            return
        }
        var targets = requested.isEmpty ? [activePane.currentDirectory].compactMap { $0 } : requested
        if tool.kind == .terminal {
            let folder = targets.first(where: { $0.hasDirectoryPath }) ?? targets.first.map { url -> URL in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : url.deletingLastPathComponent()
            }
            targets = [folder].compactMap { $0 }
        }
        NSWorkspace.shared.open(targets, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Task { @MainActor in self.presentError(error.localizedDescription) }
            }
        }
    }

    func open(_ items: [FileItem], withApplication appURL: URL) {
        NSWorkspace.shared.open(items.map(\.url), withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    func chooseOtherApplication(for items: [FileItem]) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = L("Choose an app to open the selected item(s).")
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            MainActor.assumeIsolated { self.open(items, withApplication: app) }
        }
    }

    func chooseFolderToOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = activePane.currentDirectory
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self.navigateActivePane(to: url) }
        }
    }

    func chooseDestination(title: String, message: String, startingAt start: URL? = nil, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = title
        panel.message = message
        panel.directoryURL = start ?? activePane.currentDirectory
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { completion(url) }
        }
    }

    func shareAirDrop() {
        let urls = selection.map(\.url)
        guard !urls.isEmpty else {
            presentError(L("Select one or more files or folders to send with AirDrop."))
            return
        }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            presentError(L("AirDrop is unavailable."))
            return
        }
        service.perform(withItems: urls)
    }

    func openAirDrop() {
        let airDrop = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
        if FileManager.default.fileExists(atPath: airDrop.path) {
            NSWorkspace.shared.openApplication(at: airDrop, configuration: NSWorkspace.OpenConfiguration())
        } else {
            presentError(L("AirDrop is unavailable."))
        }
    }

    func setDefaultApplication(_ app: URL, for type: UTType) {
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.presentError(error.localizedDescription)
                } else {
                    self.activePane.operationMessage = L("Default application updated for this file type.")
                    self.clearOperationMessage(after: 3)
                }
            }
        }
    }

    func showAllSubfiles(_ folder: URL) {
        model.newTab(destination: .allSubfiles(folder), after: model.activeTabID)
    }

    /// Dissolves the split: the first pane stays in this tab and every other pane, with its history and view
    /// settings, moves into its own tab.
    func splitPanesIntoTabs() {
        let tab = model.activeTab
        guard tab.panes.count > 1 else { return }
        let room = WindowSession.maximumTabs - model.tabs.count
        let extras = tab.panes.dropFirst().prefix(max(room, 0)).map { pane -> WorkspaceTab in
            var state = pane.state
            state.id = UUID()
            return WorkspaceTab(pane: state)
        }
        tab.setLayout(.single, configuration: tab.panes[0].viewConfiguration)
        for state in extras { model.adoptTab(state) }
        model.activeTabID = tab.id
    }

    func share(_ items: [FileItem]) {
        guard let contentView = window?.contentView else { return }
        let picker = NSSharingServicePicker(items: items.map(\.url))
        let point = contentView.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        picker.show(relativeTo: NSRect(origin: point, size: .zero), of: contentView, preferredEdge: .minY)
    }

    func calculateChecksum(_ item: FileItem) {
        activePane.operationMessage = L("Calculating SHA-256…")
        let url = item.url
        Task.detached(priority: .userInitiated) {
            let digest = try? ChecksumService().checksum(of: url, algorithm: .sha256)
            await MainActor.run {
                self.activePane.operationMessage = nil
                // Like the original: the digest goes to the clipboard and the status bar shows "SHA-256 copied".
                if let digest {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(digest, forType: .string)
                    self.activePane.operationResult = PaneRuntime.OperationResult(summary: L("SHA-256 copied"), details: [item.name, digest], showsEllipsis: false)
                } else {
                    self.activePane.operationResult = PaneRuntime.OperationResult(summary: L("The operation could not be completed."), details: [item.name])
                }
            }
        }
    }

    func eject(_ volume: VolumeMonitor.Volume) {
        DeviceCoordinator.shared.eject(volume, presentingIn: window)
    }

    // MARK: Floating ball

    func performFloatingBallAction(_ action: FloatingBallAction, pane: PaneRuntime) {
        activate(pane: pane)
        switch action {
        case .back: pane.goBack()
        case .forward: pane.goForward()
        case .up: pane.goUp()
        case .selectAll: pane.selectAll()
        case .refresh: pane.reload()
        case .copyPath: copyPaths([pane.currentDirectory].compactMap { $0 }, folderOnly: true)
        case .compressAll: compress(pane.selectedItems)
        case .compressFolder: compress(pane.displayItems)
        case .collectAll: runBuiltInTool(.collectIntoFolder, items: pane.selectedItems)
        case .collectFolder: runBuiltInTool(.collectIntoFolder, items: pane.displayItems)
        }
    }

    // MARK: Bookmarks and workspaces

    /// "Add Current Folder" opens the Add Bookmark sheet for the pane's folder, as the original's bookmark menus do
    /// (runtime capture 2026-10-20); a bookmark folder's own "Add Current Folder Here" adds straight into it.
    func addBookmarkForCurrentFolder(parent: UUID? = nil) {
        guard let url = activePane.currentDirectory else { return }
        if let parent {
            LibraryModel.shared.addBookmarks([url], to: parent)
        } else {
            presentBookmarkAdd(urls: [url])
        }
    }

    func addBookmarksForSelection() {
        let urls = selection.map(\.url)
        guard !urls.isEmpty else { return }
        presentBookmarkAdd(urls: urls)
    }

    /// The original's "New Bookmark Folder" sheet (name "New Folder", Cancel / Create) on the workspace window.
    func newBookmarkFolder(parent: UUID?) {
        presentBookmarkNameSheet(title: L("New Bookmark Folder"), initial: L("New Folder"), action: L("Create"),
                                 identifier: "Bookmarks.NewFolder", commitIdentifier: "Create") { name in
            LibraryModel.shared.addBookmarkFolder(named: name, parent: parent ?? LibraryModel.shared.bookmarks.defaultFolder?.id)
        }
    }

    private func presentBookmarkNameSheet(title: String, initial: String, action: String, identifier: String, commitIdentifier: String,
                                          commit: @escaping (String) -> Void) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 149), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentViewController = NSHostingController(rootView: BookmarkNameSheet(
            title: title, initial: initial, action: action, identifier: identifier, commitIdentifier: commitIdentifier, commit: commit
        ) { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        })
        window.beginSheet(sheet)
    }

    func openBookmark(_ node: BookmarkLibrary.Node) {
        guard let target = node.target else { return }
        guard FileManager.default.fileExists(atPath: target.url.path) else {
            presentError(L("This bookmark is currently unavailable."))
            return
        }
        if target.kind == .folder {
            navigateActivePane(to: target.url)
        } else {
            activePane.open(target.url.deletingLastPathComponent())
            activePane.select(urls: [target.url])
        }
    }

    func renameBookmark(_ node: BookmarkLibrary.Node) {
        presentBookmarkNameSheet(title: L("Rename Bookmark"), initial: node.displayTitle, action: L("Rename"),
                                 identifier: "Bookmarks.Rename", commitIdentifier: "Save") { name in
            LibraryModel.shared.mutateBookmarks { try $0.rename(node.id, to: name) }
        }
    }

    /// The original's sheet: title, note, name (the current folder's name), save mode with its explanation,
    /// Cancel / Save. Errors stay in the sheet.
    func saveTabAsWorkspace() {
        guard let window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 267), styleMask: [.titled], backing: .buffered, defer: false)
        let close: () -> Void = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        let defaultName = activePane.currentDirectory.map { PathUtilities.displayName(for: $0) } ?? model.activeTab.title
        sheet.contentViewController = NSHostingController(rootView: SaveWorkspaceSheet(defaultName: defaultName, cancel: close) { [weak self] name, mode in
            guard let self else { return nil }
            do {
                let workspace = try NamedWorkspaceLibrary.shared.create(name: name, mode: mode, tab: self.model.activeTab.state)
                self.model.activeTab.namedWorkspaceID = workspace.id
                self.model.scheduleSave()
                close()
                return nil
            } catch NamedWorkspaceLibrary.LibraryError.duplicateName {
                return L("A workspace with this name already exists.")
            } catch {
                return L("Use a name of 1–128 characters on a single line.")
            }
        })
        window.beginSheet(sheet)
    }

    func saveBoundWorkspace() {
        guard let id = model.activeTab.namedWorkspaceID else { return }
        NamedWorkspaceLibrary.shared.update(id, tab: model.activeTab.state)
        activePane.operationMessage = L("Workspace saved.")
        clearOperationMessage(after: 3)
    }

    func openNamedWorkspace(_ id: UUID) {
        guard let workspace = NamedWorkspaceLibrary.shared.workspaces.first(where: { $0.id == id }) else {
            presentError(L("This workspace is no longer available."))
            return
        }
        var state = workspace.tab
        state.id = UUID()
        state.namedWorkspaceID = workspace.id
        state.panes = state.panes.map { pane in
            var copy = pane
            copy.id = UUID()
            return copy
        }
        state.activePaneID = state.panes.first?.id ?? state.activePaneID
        if AppModel.shared.preferences.namedWorkspaceSwitchBehavior == .replaceCurrentTab {
            let old = model.activeTabID
            model.adoptTab(state)
            _ = model.closeTab(old)
        } else {
            model.adoptTab(state)
        }
    }

    static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    // MARK: Tags

    func toggleTag(_ tag: String, on items: [FileItem], applied: Bool) {
        for item in items {
            var tags = item.tags
            if applied { tags.removeAll { $0 == tag } } else if !tags.contains(tag) { tags.append(tag) }
            try? (item.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        activePane.reload()
        FinderTagCatalog.shared.tagsChanged()
    }

    func setTags(_ tags: [String], on items: [FileItem]) {
        for item in items { try? (item.url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        activePane.reload()
        FinderTagCatalog.shared.tagsChanged()
    }

    /// The original's "Add Tag" sheet: name, one of eight colors (none, red, orange, yellow, green, blue, purple,
    /// gray), Cancel / Add.
    func createSidebarTag() {
        guard let window else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 345), styleMask: [.titled], backing: .buffered, defer: false)
        let close: () -> Void = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        sheet.contentViewController = NSHostingController(rootView: AddTagSheet(cancel: close) { name, label in
            SidebarTagColors.set(label, for: name)
            FinderTagCatalog.shared.create(name)
            close()
        })
        window.beginSheet(sheet)
    }

    func chooseCommonPath() {
        chooseDestination(title: L("Add"), message: L("Add to Common Paths")) { url in LibraryModel.shared.addCommonPath(url) }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// "Save Current Tab as Workspace" sheet.
private struct SaveWorkspaceSheet: View {
    let cancel: () -> Void
    /// Returns an error message to show, or nil when the workspace was saved.
    let save: (String, NamedWorkspaceLibrary.SaveMode) -> String?
    @State private var name: String
    @State private var mode: NamedWorkspaceLibrary.SaveMode = .dynamic
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(defaultName: String, cancel: @escaping () -> Void, save: @escaping (String, NamedWorkspaceLibrary.SaveMode) -> String?) {
        self.cancel = cancel
        self.save = save
        _name = State(initialValue: defaultName)
    }

    // Metrics follow the original's 500 × 267 pt sheet: 24 pt margins, 18 pt between sections, a 17 pt bold
    // title over a 13 pt note, and the mode's explanation 8 pt under the radio buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Save Current Tab as Workspace")).font(.system(size: 17, weight: .bold))
            Text(L("A workspace remembers the folders, panes, and browsing layout in this tab. It does not copy your files."))
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L("Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityIdentifier("Workspaces.Create.Name")
            VStack(alignment: .leading, spacing: 8) {
                // "Saving" sits to the left of the two radio buttons, as in the original.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L("Saving")).font(.system(size: 13))
                    Picker(L("Saving"), selection: $mode) {
                        Text(L("Automatic Saving (Dynamic)")).tag(NamedWorkspaceLibrary.SaveMode.dynamic)
                        Text(L("Manual Saving (Static)")).tag(NamedWorkspaceLibrary.SaveMode.static)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                Text(mode == .dynamic ? L("Changes you make while browsing are kept, so the workspace reopens where you left off.")
                                      : L("The workspace keeps this layout until you save it again yourself."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            }
            HStack {
                Spacer()
                Button(L("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L("Save")) { error = save(name, mode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("Workspaces.Create.Save")
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { nameFocused = true }
    }
}

/// Colors chosen for tags created in DirDesk (Finder's own color tags keep their system color).
enum SidebarTagColors {
    static func label(for name: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: DefaultsKey.finderTagColorOverrides) as? [String: Int])?[name]
    }

    static func set(_ label: Int?, for name: String) {
        var all = (UserDefaults.standard.dictionary(forKey: DefaultsKey.finderTagColorOverrides) as? [String: Int]) ?? [:]
        all[name] = label
        UserDefaults.standard.set(all, forKey: DefaultsKey.finderTagColorOverrides)
    }
}

/// "Add Tag" sheet.
private struct AddTagSheet: View {
    let cancel: () -> Void
    let add: (String, Int?) -> Void
    @State private var name = ""
    @State private var label: Int?
    @FocusState private var nameFocused: Bool

    /// Finder label numbers in the original's order: none, red, orange, yellow, green, blue, purple, gray.
    private static let choices: [(Int?, String)] = [(nil, "None"), (6, "Red"), (7, "Orange"), (5, "Yellow"), (2, "Green"),
                                                      (4, "Blue"), (3, "Purple"), (1, "Gray")]

    /// Metrics from the original's sheet (460 pt wide): a 60 pt icon tile beside the title, 26 pt gaps between the
    /// sections, 20 pt color dots on a 42 pt pitch, a hairline above the buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06))
                    Image(systemName: "tag").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                }
                .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Add Tag")).font(.system(size: 17, weight: .bold))
                    Text(L("Create a label for the things that belong together.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text(L("Name")).font(.system(size: 12, weight: .semibold)).padding(.top, 26)
            TextField(L("Project"), text: $name)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($nameFocused)
                .accessibilityIdentifier("SidebarTag.Name")
                .padding(.top, 6)
            Text(L("Tag Color")).font(.system(size: 12, weight: .semibold)).padding(.top, 26)
            HStack(spacing: 12) {
                ForEach(Array(Self.choices.enumerated()), id: \.offset) { _, choice in
                    Button { label = choice.0 } label: {
                        ZStack {
                            if let number = choice.0 {
                                Circle().fill(Color(nsColor: Theme.finderTagColor(number) ?? .gray)).frame(width: 20, height: 20)
                            } else {
                                Circle().strokeBorder(Color.secondary, lineWidth: 1.5).frame(width: 20, height: 20)
                            }
                            if label == choice.0 {
                                Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L(choice.1))
                    .accessibilityLabel(L(choice.1))
                }
            }
            .padding(.top, 13)
            Divider().padding(.top, 24)
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel"), action: cancel).keyboardShortcut(.cancelAction).controlSize(.large)
                Button(L("Add")) { add(name.trimmingCharacters(in: .whitespacesAndNewlines), label) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 24)
        }
        .padding(28)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }
}
