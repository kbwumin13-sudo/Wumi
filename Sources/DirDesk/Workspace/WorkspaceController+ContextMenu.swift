import AppKit
import DirDeskCore
import UniformTypeIdentifiers

/// Context menus for items, the pane background and the transfer destinations they offer.
///
/// Layout follows the original's runtime menus (reference captures in docs/reference/04-右键菜单): the configured
/// commands with their separators, then a section that depends on the selection (file type defaults and extension,
/// or folder pinning, icon and flattened view), and finally "Open Current Pane in New Tab".
extension WorkspaceController {
    func contextMenu(for items: [FileItem], in pane: PaneRuntime) -> NSMenu {
        var sections: [[NSMenuItem]] = [[]]
        for command in AppModel.shared.configuration.contextMenuCommands {
            if command.isSeparator {
                sections.append([])
            } else {
                sections[sections.count - 1] += menuItems(for: command, items: items, pane: pane)
            }
        }
        sections.append(selectionSpecificItems(items, pane: pane))
        sections.append([openPaneInNewTabItem(pane)] + paneArrangementItems(pane))
        return assembleMenu(sections)
    }

    func backgroundMenu(in pane: PaneRuntime) -> NSMenu {
        let newFile = NSMenuItem(title: L("New File"), action: nil, keyEquivalent: "")
        newFile.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        newFile.submenu = newFileMenu()
        let paste = shortcut(ClosureMenuItem(L("Paste"), symbol: "doc.on.clipboard") { [weak self] in self?.paste(move: false) }, .paste)
        paste.isEnabled = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let folder = pane.currentDirectory
        let copyPath = shortcut(ClosureMenuItem(L("Copy Folder Path"), symbol: "doc.on.doc") { [weak self] in
            self?.copyPaths([folder].compactMap { $0 }, folderOnly: true)
        }, .copyPath)
        let bookmark = shortcut(ClosureMenuItem(L("Add Current Folder"), symbol: "star") { [weak self] in self?.addBookmarkForCurrentFolder() }, .addBookmark)
        return assembleMenu([
            [shortcut(ClosureMenuItem(L("New Folder"), symbol: "folder.badge.plus") { [weak self] in self?.perform(.newFolder) }, .newFolder), newFile],
            [shortcut(ClosureMenuItem(L("Invert Selection"), symbol: "checklist") { pane.invertSelection() }, .invertSelection), paste],
            [bookmark, copyPath, terminalItem(targets: [folder].compactMap { $0 }), editorItem(targets: [folder].compactMap { $0 })],
            [openPaneInNewTabItem(pane)],
        ])
    }

    /// Template list shared by the background menu and the toolbar's New File button.
    func newFileMenu() -> NSMenu {
        let menu = NSMenu()
        for template in AppModel.shared.configuration.fileTemplates.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let title = (template.emoji.map { "\($0) " } ?? "") + L(template.name)
            let item = ClosureMenuItem(title) { [weak self] in self?.createFile(from: template) }
            item.image = Self.templateIcon(template.builtInKind)
            item.setAccessibilityIdentifier("NewFile.Template.\(template.builtInKind?.rawValue ?? template.id.uuidString)")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let more = ClosureMenuItem(L("Add More Formats…"), symbol: "gearshape") { [weak self] in self?.showSettings(section: "newFiles") }
        more.setAccessibilityIdentifier("NewFile.AddMoreFormats")
        menu.addItem(more)
        return menu
    }

    static func templateIcon(_ kind: BuiltInFileTemplateKind?) -> NSImage? {
        let (symbol, color): (String, NSColor) = switch kind {
        case .markdown: ("doc.richtext", .systemPurple)
        case .plainText: ("doc.text", .systemIndigo)
        case .jsonFile: ("curlybraces.square", .systemOrange)
        case .wordDocument: ("doc.text.fill", .systemBlue)
        case .excelSpreadsheet: ("tablecells", .systemGreen)
        case .powerPointPresentation: ("rectangle.on.rectangle", .systemRed)
        case .csvSpreadsheet: ("tablecells.badge.ellipsis", .systemTeal)
        case .pagesDocument: ("doc.append", .systemOrange)
        case .keynotePresentation: ("play.rectangle", .systemBlue)
        case .numbersSpreadsheet: ("chart.bar.doc.horizontal", .systemGreen)
        case nil: ("doc", .secondaryLabelColor)
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
    }

    // MARK: Configured commands

    private func menuItems(for command: ContextMenuCommand, items: [FileItem], pane: PaneRuntime) -> [NSMenuItem] {
        let single = items.count == 1 ? items.first : nil
        let urls = items.map(\.url)
        switch command {
        case .open:
            return [shortcut(ClosureMenuItem(L("Open"), symbol: "arrow.up.forward.square") { [weak self] in self?.open(items, in: pane, newTab: false) }, .openSelection)]
        case .openWith:
            let item = NSMenuItem(title: L("Open With"), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil)
            item.submenu = applicationMenu(for: single) { [weak self] app in self?.open(items, withApplication: app) } other: { [weak self] in
                self?.chooseOtherApplication(for: items)
            }
            return [item]
        case .openInNewTab:
            return [ClosureMenuItem(L("Open in New Tab"), symbol: "plus.square.on.square") { [weak self] in self?.openInNewTabs(items) }]
        case .openTerminal:
            return [terminalItem(targets: urls)]
        case .openEditor:
            return [editorItem(targets: urls)]
        case .quickLook:
            return [shortcut(ClosureMenuItem(L("Quick Look"), symbol: "eye") { [weak self] in self?.toggleQuickLook() }, .quickLook)]
        case .getInfo:
            return [ClosureMenuItem(L("Get Info"), symbol: "info.circle") { [weak self] in self?.showInfo(items) }]
        case .rename:
            let item = shortcut(ClosureMenuItem(L("Rename"), symbol: "pencil") { if let single, single.allowsRenaming { pane.renamingID = single.id } }, .rename)
            item.isEnabled = single?.allowsRenaming == true
            return [item]
        case .builtInTools:
            let entries = builtInToolMenuItems(for: items).filter { $0.tool.category != .folders }
            guard !entries.isEmpty else { return [] }
            let item = NSMenuItem(title: L("Built-in Tools"), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
            let submenu = NSMenu()
            for entry in entries { submenu.addItem(ClosureMenuItem(entry.title, symbol: BuiltInToolSupport.symbol(entry.tool), action: entry.action)) }
            item.submenu = submenu
            return [item]
        case .compress:
            let title = single.map { LF("Create Archive from “%@”…", $0.name) } ?? LF("Create Archive from %lld Items…", Int64(items.count))
            var result: [NSMenuItem] = [ClosureMenuItem(title, symbol: "archivebox") { [weak self] in self?.showArchiveCreation(items) }]
            let enabled = Set(AppModel.shared.configuration.enabledBuiltInTools)
            if enabled.contains(.collectIntoFolder) {
                result.append(ClosureMenuItem(LF("Create New Folder from %lld Items…", Int64(items.count)), symbol: "folder.badge.plus") { [weak self] in
                    self?.collectIntoNewFolder(items)
                })
            }
            if enabled.contains(.dissolveFolder), items.allSatisfy({ $0.isBrowsableFolder && !$0.isPackage }) {
                result.append(ClosureMenuItem(L("Dissolve Folder"), symbol: "folder.badge.minus") { [weak self] in
                    self?.runBuiltInTool(.dissolveFolder, items: items)
                })
            }
            return result
        case .extract:
            guard let single, ArchiveService.isArchive(single.url) else { return [] }
            return [ClosureMenuItem(L("Extract"), symbol: "shippingbox") { [weak self] in self?.extract(single, to: nil) }]
        case .extractTo:
            guard let single, ArchiveService.isArchive(single.url) else { return [] }
            return [destinationItem(title: L("Extract To"), symbol: "shippingbox.and.arrow.backward", hereTitle: L("Extract Here")) { [weak self] url in
                self?.extract(single, to: url)
            }]
        case .duplicate:
            return [shortcut(ClosureMenuItem(L("Duplicate"), symbol: "plus.square.on.square") { [weak self] in self?.duplicateSelection() }, .duplicate)]
        case .makeAlias:
            return [ClosureMenuItem(L("Make Alias"), symbol: "arrowshape.turn.up.right") { [weak self] in self?.makeAlias(items) }]
        case .invertSelection:
            return [shortcut(ClosureMenuItem(L("Invert Selection"), symbol: "checklist") { pane.invertSelection() }, .invertSelection)]
        case .cut:
            return [shortcut(ClosureMenuItem(L("Cut"), symbol: "scissors") { [weak self] in self?.cutSelection() }, .cut)]
        case .copy:
            return [shortcut(ClosureMenuItem(L("Copy"), symbol: "doc.on.doc") { [weak self] in self?.copyToClipboard(items) }, .copy)]
        case .copyTo:
            return [destinationItem(title: L("Copy To"), symbol: "doc.on.doc.fill", hereTitle: L("Copy Here")) { [weak self] url in
                self?.transfer(urls, to: url, move: false)
            }]
        case .sendTo:
            return [destinationItem(title: L("Send To"), symbol: "paperplane", hereTitle: L("Move Here")) { [weak self] url in
                self?.transfer(urls, to: url, move: true)
            }]
        case .share:
            return [ClosureMenuItem(L("Share…"), symbol: "square.and.arrow.up") { [weak self] in self?.share(items) }]
        case .tags:
            return [tagsItem(items)]
        case .copyPath:
            return [shortcut(ClosureMenuItem(L("Copy Absolute Path"), symbol: "link") { [weak self] in self?.copyPaths(urls, folderOnly: false) }, .copyPath)]
        case .reveal:
            return [ClosureMenuItem(L("Reveal in Finder"), symbol: "macwindow") { NSWorkspace.shared.activateFileViewerSelecting(urls) }]
        case .bookmarks:
            return [shortcut(ClosureMenuItem(L("Add Selected Items to Bookmarks"), symbol: "star") { LibraryModel.shared.addBookmarks(urls) }, .addBookmark)]
        case .checksum:
            guard let single, !single.isBrowsableFolder else { return [] }
            return [ClosureMenuItem(L("Calculate SHA-256"), symbol: "number") { [weak self] in self?.calculateChecksum(single) }]
        case .batchRename:
            guard items.count > 1, items.allSatisfy(\.allowsRenaming) else { return [] }
            return [shortcut(ClosureMenuItem(L("Batch Rename"), symbol: "character.cursor.ibeam") { [weak self] in self?.showBatchRename(items) }, .batchRename)]
        case .paneTransfer:
            return paneTransferItem(urls, from: pane).map { [$0] } ?? []
        case .trash:
            return [shortcut(ClosureMenuItem(L("Move to Trash"), symbol: "trash") { [weak self] in self?.moveToTrash(items, in: pane) }, .moveToTrash)]
        case .separatorOpen, .separatorEdit, .separatorLocation, .separatorDestructive:
            return []
        }
    }

    /// File: default application for its type and Change Extension. Folder: pinning, icon and the flattened view.
    private func selectionSpecificItems(_ items: [FileItem], pane: PaneRuntime) -> [NSMenuItem] {
        if items.count == 1, let file = items.first, !file.isBrowsableFolder {
            var result: [NSMenuItem] = []
            if let type = file.contentType {
                let item = NSMenuItem(title: L("Set Default Application for This File Type"), action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "app.badge.checkmark", accessibilityDescription: nil)
                item.submenu = applicationMenu(for: file) { [weak self] app in self?.setDefaultApplication(app, for: type) } other: { [weak self] in
                    self?.chooseApplication { app in self?.setDefaultApplication(app, for: type) }
                }
                result.append(item)
            }
            result.append(ClosureMenuItem(L("Change Extension…"), symbol: "character.textbox") { [weak self] in self?.changeExtension(file, in: pane) })
            return result
        }
        let folders = items.filter { $0.isBrowsableFolder && !$0.isPackage }
        guard !folders.isEmpty, folders.count == items.count else { return [] }
        let pinned = Set(pane.viewConfiguration.pinnedFolderPaths)
        let allPinned = folders.allSatisfy { pinned.contains($0.url.path) }
        var result: [NSMenuItem] = [
            ClosureMenuItem(allPinned ? L("Unpin Folder") : L("Pin Folder to Top"), symbol: allPinned ? "pin.slash" : "pin") { [weak self] in
                self?.setPinned(!allPinned, folders: folders, in: pane)
            },
        ]
        if folders.count == 1, let folder = folders.first {
            result.append(ClosureMenuItem(L("Change Folder Icon"), symbol: "paintpalette") { [weak self] in self?.showFolderIconEditor(folder.url) })
            result.append(ClosureMenuItem(L("Show All Subfiles in New Tab"), symbol: "list.bullet.indent") { [weak self] in self?.showAllSubfiles(folder.url) })
        }
        return result
    }

    private func openPaneInNewTabItem(_ pane: PaneRuntime) -> NSMenuItem {
        ClosureMenuItem(L("Open Current Pane in New Tab"), symbol: "macwindow.badge.plus") { [weak self] in self?.openPaneInNewTab(pane) }
    }

    /// With several panes, the original ends the item menu with Remove Pane › (close it, move it or all panes to new
    /// tabs) and Move Pane To › (the other panes' places; the two panes swap).
    private func paneArrangementItems(_ pane: PaneRuntime) -> [NSMenuItem] {
        let tab = model.activeTab
        guard tab.panes.count > 1, tab.panes.contains(where: { $0.id == pane.id }) else { return [] }
        let remove = NSMenu()
        remove.addItem(ClosureMenuItem(L("Close Current Pane")) { [weak tab] in
            tab?.activePaneID = pane.id
            tab?.closeActivePane()
        })
        remove.addItem(ClosureMenuItem(L("Move Current Pane to New Tab")) { [weak self, weak tab] in
            self?.openPaneInNewTab(pane)
            tab?.activePaneID = pane.id
            tab?.closeActivePane()
        })
        remove.addItem(ClosureMenuItem(L("Move All Panes to New Tabs")) { [weak self] in self?.splitPanesIntoTabs() })
        let removeItem = NSMenuItem(title: L("Remove Pane"), action: nil, keyEquivalent: "")
        removeItem.image = NSImage(systemSymbolName: "rectangle.badge.minus", accessibilityDescription: nil)
        let move = NSMenu()
        for (index, other) in tab.panes.enumerated() where other.id != pane.id {
            move.addItem(ClosureMenuItem(paneLocation(index, in: tab)) { [weak tab] in tab?.swapPanes(pane.id, other.id) })
        }
        let moveItem = NSMenuItem(title: L("Move Pane To"), action: nil, keyEquivalent: "")
        moveItem.image = NSImage(systemSymbolName: "rectangle.2.swap", accessibilityDescription: nil)
        return [removeItem.withSubmenu(remove), moveItem.withSubmenu(move)]
    }

    /// "Top Left", "Middle Left", … for the pane at `index` in the tab's layout.
    func paneLocation(_ index: Int, in tab: TabRuntime) -> String {
        let locations = tab.layout.paneLocations
        return locations.indices.contains(index) ? L(locations[index]) : LF("Pane %lld", Int64(index + 1))
    }

    // MARK: Building blocks

    private func assembleMenu(_ sections: [[NSMenuItem]]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        if !AppModel.shared.preferences.showsContextMenuIcons { Self.removeImages(menu) }
        return menu
    }

    private static func removeImages(_ menu: NSMenu) {
        for item in menu.items where item.submenu == nil || item.image != nil {
            if item.submenu == nil || !(item.submenu?.items.contains { $0.image != nil && $0.title.isEmpty } ?? false) { item.image = nil }
        }
    }

    /// Shows the configured shortcut of `command` next to the item, as the original's context menus do.
    private func shortcut(_ item: NSMenuItem, _ command: ShortcutCommand) -> NSMenuItem {
        guard let binding = AppModel.shared.configuration.shortcutTable.bindings(for: command).first, !binding.isDoubleTap else { return item }
        if binding.modifiers.isEmpty {
            switch binding.key.lowercased() {
            case "return": item.keyEquivalent = "\r"
            case "space": item.keyEquivalent = " "
            default: return item
            }
            item.keyEquivalentModifierMask = []
        } else if let (key, flags) = MainMenuBuilder.keyEquivalent(for: binding) {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = flags
        }
        return item
    }

    /// Applications able to open `item` (only "Other…" for a multiple selection), as in Open With. Like the original,
    /// each app appears once (updater copies of the same bundle ID are left out) under its file name, e.g.
    /// "Numbers Creator Studio" rather than its localized display name.
    private func applicationMenu(for item: FileItem?, choose: @escaping (URL) -> Void, other: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        if let item {
            var seen = Set<String>()
            for app in NSWorkspace.shared.urlsForApplications(toOpen: item.url) {
                guard seen.insert(Bundle(url: app)?.bundleIdentifier ?? app.path).inserted else { continue }
                if seen.count > 40 { break }
                let entry = ClosureMenuItem(app.deletingPathExtension().lastPathComponent) { choose(app) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
                menu.addItem(entry)
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
        }
        menu.addItem(ClosureMenuItem(L("Other…"), action: other))
        return menu
    }

    private func terminalItem(targets: [URL]) -> NSMenuItem {
        let tools = AppModel.shared.configuration.externalTools.filter { $0.kind == .terminal }.sorted { $0.sortOrder < $1.sortOrder }
        guard !tools.isEmpty else {
            let item = shortcut(NSMenuItem(title: L("Open in Terminal"), action: nil, keyEquivalent: ""), .openTerminal)
            item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            item.isEnabled = false
            return item
        }
        let item = NSMenuItem(title: L("Open in Terminal"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        let submenu = NSMenu()
        for tool in tools {
            submenu.addItem(ClosureMenuItem(L(tool.name)) { [weak self] in self?.openWith(tool: tool, targets: targets) })
        }
        item.submenu = submenu
        return item
    }

    private func editorItem(targets: [URL]) -> NSMenuItem {
        let tools = AppModel.shared.configuration.externalTools.filter { $0.kind == .editor }.sorted { $0.sortOrder < $1.sortOrder }
        if tools.count > 1 {
            let item = NSMenuItem(title: L("Open in Editor"), action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
            let submenu = NSMenu()
            for tool in tools {
                submenu.addItem(ClosureMenuItem(L(tool.name)) { [weak self] in self?.openWith(tool: tool, targets: targets) })
            }
            item.submenu = submenu
            return item
        }
        let tool = AppModel.shared.configuration.defaultTool(of: .editor) ?? tools.first
        let item = shortcut(ClosureMenuItem(L("Open in Editor"), symbol: "chevron.left.forwardslash.chevron.right") { [weak self] in
            if let tool { self?.openWith(tool: tool, targets: targets) }
        }, .openEditor)
        item.isEnabled = tool != nil
        return item
    }

    /// "Copy To" style submenu: the sidebar folders, each with "<here>" and "Choose Subfolder…", then "Choose Other Folder…".
    private func destinationItem(title: String, symbol: String, hereTitle: String, perform: @escaping (URL) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let submenu = NSMenu()
        let header = NSMenuItem(title: L("Locations"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)
        for destination in SidebarDestinations.entries() {
            let entry = NSMenuItem(title: destination.title, action: nil, keyEquivalent: "")
            entry.image = NSImage(systemSymbolName: destination.symbol, accessibilityDescription: nil)
            let choices = NSMenu()
            choices.addItem(ClosureMenuItem(hereTitle) { perform(destination.url) })
            choices.addItem(ClosureMenuItem(L("Choose Subfolder…")) { [weak self] in
                self?.chooseDestination(title: title, message: title, startingAt: destination.url, completion: perform)
            })
            entry.submenu = choices
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem(L("Choose Other Folder…")) { [weak self] in
            self?.chooseDestination(title: title, message: title, completion: perform)
        })
        return item.withSubmenu(submenu)
    }

    private func tagsItem(_ items: [FileItem]) -> NSMenuItem {
        let item = NSMenuItem(title: L("Tags"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let submenu = NSMenu()
        for tag in FinderTagCatalog.shared.tags {
            let applied = items.allSatisfy { $0.tags.contains(tag.name) }
            let entry = ClosureMenuItem(tag.name) { [weak self] in self?.toggleTag(tag.name, on: items, applied: applied) }
            entry.state = applied ? .on : (items.contains { $0.tags.contains(tag.name) } ? .mixed : .off)
            if let color = Theme.finderTagColor(tag.label) { entry.image = Self.dot(color) }
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem(L("Add Tags…")) { [weak self] in self?.editTags(for: items) })
        submenu.addItem(ClosureMenuItem(L("Remove All Tags")) { [weak self] in self?.setTags([], on: items) })
        return item.withSubmenu(submenu)
    }

    private func paneTransferItem(_ urls: [URL], from pane: PaneRuntime) -> NSMenuItem? {
        let others = model.activeTab.panes.enumerated().filter { $0.element.id != pane.id && $0.element.currentDirectory != nil }
        guard !others.isEmpty else { return nil }
        let item = NSMenuItem(title: L("Copy or Move to Pane"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        let submenu = NSMenu()
        for (index, other) in others {
            let folder = other.currentDirectory!
            // "Top Left: Folder", as the original labels panes.
            let label = paneLocation(index, in: model.activeTab) + ": " + PathUtilities.displayName(for: folder)
            submenu.addItem(ClosureMenuItem(LF("Copy to %@", label)) { [weak self] in self?.transfer(urls, to: folder, move: false) })
            submenu.addItem(ClosureMenuItem(LF("Move to %@", label)) { [weak self] in self?.transfer(urls, to: folder, move: true) })
        }
        return item.withSubmenu(submenu)
    }

    // MARK: Actions

    /// Folders open in their own tabs; files open their folder in a new tab with the file selected.
    func openInNewTabs(_ items: [FileItem]) {
        for item in items.prefix(WindowSession.maximumTabs) {
            if item.isBrowsableFolder {
                model.newTab(directory: item.url, after: model.activeTabID)
            } else if let tab = model.newTab(directory: item.url.deletingLastPathComponent(), after: model.activeTabID) {
                tab.activePane.select(urls: [item.url])
            }
        }
    }

    func openPaneInNewTab(_ pane: PaneRuntime) {
        var state = pane.state
        state.id = UUID()
        model.adoptTab(WorkspaceTab(pane: state))
    }

    /// "Create New Folder from N Items…" asks for the name with the same prompt as the built-in collect tool.
    func collectIntoNewFolder(_ items: [FileItem]) {
        runBuiltInTool(.collectIntoFolder, items: items)
    }

    func setPinned(_ pinned: Bool, folders: [FileItem], in pane: PaneRuntime) {
        var paths = pane.viewConfiguration.pinnedFolderPaths
        if pinned {
            for folder in folders where !paths.contains(folder.url.path) { paths.append(folder.url.path) }
            guard paths.count <= ViewConfiguration.maximumPinnedFolders else {
                presentError(L("At most 1,024 folders can be pinned."))
                return
            }
        } else {
            let removed = Set(folders.map(\.url.path))
            paths.removeAll { removed.contains($0) }
        }
        pane.viewConfiguration.pinnedFolderPaths = paths
    }

    func changeExtension(_ item: FileItem, in pane: PaneRuntime) {
        let current = item.url.pathExtension
        let alert = NSAlert()
        alert.messageText = L("Change File Extension")
        alert.informativeText = L("Changing an extension may cause the file to open in a different application.")
        let field = NSTextField(string: current)
        field.placeholderString = L("New Extension")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        let note = NSTextField(labelWithString: L("Leave empty to remove the extension; the leading dot is optional."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [field, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 48)
        alert.accessoryView = stack
        alert.addButton(withTitle: L("Change Extension…").replacingOccurrences(of: "…", with: ""))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var ext = field.stringValue.trimmingCharacters(in: .whitespaces)
        if ext.hasPrefix(".") { ext.removeFirst() }
        guard ext != current else { return }
        let base = item.url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? base : base + "." + ext
        do {
            let renamed = try FileOperations.rename(item.url, to: name, undoManager: window?.undoManager, confirmExtension: false)
            pane.reload()
            pane.select(urls: [renamed])
        } catch let error as FileOperations.OperationError {
            presentError(error.message)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func chooseApplication(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.message = L("Choose an app to open the selected item(s).")
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let app = panel.url else { return }
            MainActor.assumeIsolated { completion(app) }
        }
    }
}

extension NSMenuItem {
    func withSubmenu(_ menu: NSMenu) -> NSMenuItem {
        submenu = menu
        return self
    }
}

/// Folders offered by Copy To, Send To and Extract To: the shared folder, common paths, iCloud Drive and Home,
/// in sidebar order (reference capture ctx-file-txt-sub-copyto).
@MainActor
enum SidebarDestinations {
    struct Entry {
        let title: String
        let url: URL
        let symbol: String
    }

    static func entries() -> [Entry] {
        let preferences = AppModel.shared.preferences
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        var result: [Entry] = []
        if !preferences.hiddenSidebarBuiltInItems.contains(.sharedFolder) {
            result.append(Entry(title: L("Shared Folder"), url: URL(fileURLWithPath: "/Users/Shared", isDirectory: true), symbol: "person.2"))
        }
        for entry in LibraryModel.shared.commonPaths {
            switch entry {
            case .builtIn(let name): result.append(Entry(title: SidebarView.builtInTitle(name), url: entry.url, symbol: "folder"))
            case .folder(let url, let title): result.append(Entry(title: title, url: url, symbol: "folder"))
            }
        }
        let hidden = Set(preferences.hiddenSidebarBuiltInLocations)
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if !hidden.contains(.iCloudDrive), FileManager.default.fileExists(atPath: iCloud.path) {
            result.append(Entry(title: L("iCloud Drive"), url: iCloud, symbol: "icloud"))
        }
        if !hidden.contains(.home) { result.append(Entry(title: NSUserName(), url: home, symbol: "house")) }
        var seen = Set<String>()
        return result.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }
}
