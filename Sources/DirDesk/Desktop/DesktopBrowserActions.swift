import AppKit
import DirDeskCore

@MainActor
final class DesktopBrowserActions: NSObject, BrowserActionHandler {
    weak var coordinator: DesktopCoordinator?
    let pane: PaneRuntime
    let zoneID: String
    let screenID: String
    var onRename: ((FileItem) -> Void)?
    init(coordinator: DesktopCoordinator, pane: PaneRuntime, zoneID: String, screenID: String) {
        self.coordinator = coordinator; self.pane = pane; self.zoneID = zoneID; self.screenID = screenID
    }
    func activate(pane: PaneRuntime) { coordinator?.activate(zoneID: zoneID, screenID: screenID) }
    func open(_ items: [FileItem], in pane: PaneRuntime, newTab: Bool) {
        for item in items {
            if item.isBrowsableFolder { coordinator?.reveal(item.url, select: false) }
            else { coordinator?.preview(item) }
        }
    }
    func previewWithSpace(_ items: [FileItem], in pane: PaneRuntime) -> Bool {
        if let item = items.first { coordinator?.preview(item) }
        return true
    }
    func contextMenu(for items: [FileItem], in pane: PaneRuntime) -> NSMenu {
        activate(pane: pane)
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Open in Wumi")) { [weak self] in self?.open(items, in: pane, newTab: false) })
        menu.addItem(ClosureMenuItem(L("Open with Default Application")) { for item in items { NSWorkspace.shared.open(item.url) } })
        menu.addItem(ClosureMenuItem(L("Super Preview")) { [weak self] in if let item = items.first { self?.coordinator?.preview(item) } })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Copy")) { [weak self] in self?.copy(items, cut: false) })
        menu.addItem(ClosureMenuItem(L("Cut")) { [weak self] in self?.copy(items, cut: true) })
        menu.addItem(ClosureMenuItem(L("Paste")) { [weak self] in self?.paste(move: false) })
        if items.count == 1, let item = items.first, item.allowsRenaming {
            menu.addItem(ClosureMenuItem(L("Rename")) { [weak self] in self?.beginRename(item) })
        }
        menu.addItem(ClosureMenuItem(L("Move to Trash")) { [weak self] in self?.trash(items) })
        if let coordinator {
            let collections = NSMenu()
            for zone in coordinator.layout.zones where zone.isCustom || zone.id == DesktopLayout.unassignedZoneID {
                collections.addItem(ClosureMenuItem(zone.isCustom ? zone.title : L(zone.title)) { [weak coordinator] in coordinator?.assign(items, to: zone.id) })
            }
            let entry = NSMenuItem(title: L("Move to Collection"), action: nil, keyEquivalent: "")
            entry.submenu = collections
            menu.addItem(entry)
        }
        return menu
    }
    func backgroundMenu(in pane: PaneRuntime) -> NSMenu {
        activate(pane: pane)
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("New Folder")) { [weak self] in self?.create(folder: true) })
        menu.addItem(ClosureMenuItem(L("New Text File")) { [weak self] in self?.create(folder: false) })
        menu.addItem(ClosureMenuItem(L("Paste")) { [weak self] in self?.paste(move: false) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Undo")) { [weak self] in self?.coordinator?.desktopUndo.undo() })
        menu.addItem(ClosureMenuItem(L("Redo")) { [weak self] in self?.coordinator?.desktopUndo.redo() })
        menu.addItem(ClosureMenuItem(L("New Collection")) { [weak self] in guard let self else { return }; self.coordinator?.addZone(screenID: self.screenID) })
        menu.addItem(ClosureMenuItem(L("Refresh")) { [weak self] in self?.coordinator?.refresh() })
        menu.addItem(ClosureMenuItem(L("Show macOS Desktop")) { [weak self] in self?.coordinator?.setEnabled(false) })
        return menu
    }
    func perform(_ command: ShortcutCommand) {
        activate(pane: pane)
        switch command {
        case .copy: copy(pane.selectedItems, cut: false)
        case .cut: copy(pane.selectedItems, cut: true)
        case .paste: paste(move: false)
        case .pasteAndMove: paste(move: true)
        case .newFolder: create(folder: true)
        case .newFile: create(folder: false)
        case .rename: if let item = pane.selectedItems.first, pane.selectedItems.count == 1 { beginRename(item) }
        case .moveToTrash: trash(pane.selectedItems)
        case .openSelection: open(pane.selectedItems, in: pane, newTab: false)
        case .quickLook: _ = previewWithSpace(pane.selectedItems, in: pane)
        case .invertSelection: pane.invertSelection()
        case .search, .globalQuickSearch:
            if let coordinator {
                var widget = coordinator.layout.searchWidgets[screenID] ?? .init(frame: .init(x: 60, y: 80, width: 470, height: 340))
                widget.isVisible = true
                coordinator.setSearch(screenID: screenID, widget: widget)
            }
        default: break
        }
    }
    private func beginRename(_ item: FileItem) {
        guard item.allowsRenaming else { return }
        pane.renamingID = item.id
        onRename?(item)
    }
    func commitRename(_ item: FileItem, to name: String, in pane: PaneRuntime) {
        guard item.allowsRenaming else { return }
        let finalName: String
        do { finalName = try FileOperations.validateName(name) }
        catch { coordinator?.report(L("A file name cannot be empty or contain a slash.")); return }
        guard finalName != item.name else { pane.renamingID = nil; return }
        if !item.isDirectory, item.fileExtension.lowercased() != (finalName as NSString).pathExtension.lowercased(),
           (!item.fileExtension.isEmpty || !(finalName as NSString).pathExtension.isEmpty),
           FileOperations.extensionAlert(oldExtension: item.fileExtension, newExtension: (finalName as NSString).pathExtension).runModal() != .alertFirstButtonReturn { return }
        Task { [self] in
            do {
                let (url, updated, steps) = try await Task.detached {
                    let url = try DesktopFileActions.rename(item.url, name: finalName)
                    return (url, DirectoryLoader.item(at: url), [FileUndoStep.move(url, to: item.url)])
                }.value
                if let updated { coordinator?.didRename(item, to: updated) }
                coordinator?.desktopUndo.add(steps, name: L("Rename"))
                pane.renamingID = nil
                coordinator?.refresh()
                pane.select(urls: [url])
                NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
            } catch { coordinator?.report(error.localizedDescription) }
        }
    }
    func create(folder: Bool) {
        guard let directory = pane.currentDirectory else { return }
        let template = NewFileTemplate.defaults.first { $0.builtInKind == .plainText }
        let name = folder ? L("untitled folder") : template.map { TemplateRenderer.fileName(for: $0) } ?? L("Untitled.txt")
        let contents = template.map { TemplateRenderer.contents(for: $0) } ?? Data()
        Task { [self] in
            do {
                let (url, steps) = try await Task.detached {
                    let url = try DesktopFileActions.create(in: directory, name: name, contents: contents, folder: folder)
                    return (url, [FileUndoStep.trash(url)])
                }.value
                coordinator?.desktopUndo.add(steps, name: folder ? L("New Folder") : L("New Text File"))
                NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
                coordinator?.refresh()
                await pane.waitForRows()
                guard let item = pane.items.first(where: { $0.url.path == url.path }) else { return }
                coordinator?.assign([item], to: zoneID)
                pane.selectedIDs = [item.id]
                pane.renamingID = item.id
                onRename?(item)
            } catch { coordinator?.report(error.localizedDescription) }
        }
    }
    func copy(_ items: [FileItem], cut: Bool) {
        guard !items.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items.map { $0.url as NSURL })
        coordinator?.appDelegate?.cutURLs = cut ? items.map(\.url) : []
        NSPasteboard.general.setString(cut ? "true" : "false", forType: LightningSearchActions.cutMarkerType)
    }
    func paste(move: Bool) {
        guard let directory = pane.currentDirectory,
              let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return }
        let cut = coordinator?.appDelegate?.cutURLs ?? []
        let marked = NSPasteboard.general.string(forType: LightningSearchActions.cutMarkerType) == "true"
        let shouldMove = move || marked || (!cut.isEmpty && Set(cut) == Set(urls))
        if coordinator?.transfer(urls, into: directory, operation: shouldMove ? .move : .copy, sourceZone: zoneID) == true, shouldMove {
            coordinator?.appDelegate?.cutURLs = []
            NSPasteboard.general.setString("false", forType: LightningSearchActions.cutMarkerType)
        }
    }
    func trash(_ items: [FileItem]) {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        Task { [self] in
            let (result, steps) = await Task.detached {
                let result = DesktopFileActions.trash(urls)
                return (result, result.pairs.reversed().map { FileUndoStep.move($0.trashed, to: $0.original) })
            }.value
            coordinator?.desktopUndo.add(steps, name: L("Move to Trash"))
            coordinator?.refresh()
            if !result.failures.isEmpty { coordinator?.report(result.failures.joined(separator: "\n")) }
            NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
        }
    }
    func acceptDrop(_ urls: [URL], into directory: URL, operation: NSDragOperation, in pane: PaneRuntime) -> Bool {
        // Only a drop on the zone/background changes membership. A real folder always takes a file operation.
        let sourcePaths = Set(urls.map { $0.standardizedFileURL.path })
        let sourceItems = pane.items.filter { sourcePaths.contains($0.url.standardizedFileURL.path) }
        if directory.standardizedFileURL.path == pane.currentDirectory?.standardizedFileURL.path,
           sourceItems.count == urls.count {
            coordinator?.assign(sourceItems, to: zoneID)
            return true
        }
        return coordinator?.transfer(urls, into: directory, operation: operation, sourceZone: zoneID) ?? false
    }
}
