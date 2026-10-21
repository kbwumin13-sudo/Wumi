import AppKit
import DirDeskCore

/// Builds the main menu with the same structure as the original
/// (App, File, Edit, View, Navigate, Workspace, Window, Help), using the configured shortcuts.
@MainActor
enum MainMenuBuilder {
    static func keyEquivalent(for binding: ShortcutBinding) -> (String, NSEvent.ModifierFlags)? {
        guard !binding.isDoubleTap, !binding.modifiers.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for modifier in binding.modifiers {
            switch modifier {
            case .cmd: flags.insert(.command)
            case .option: flags.insert(.option)
            case .shift: flags.insert(.shift)
            case .control: flags.insert(.control)
            }
        }
        let key: String
        switch binding.key.lowercased() {
        case "tab": key = "\t"
        case "delete": key = "\u{8}"
        case "forwarddelete": key = String(UnicodeScalar(NSDeleteFunctionKey)!)
        case "return": key = "\r"
        case "space": key = " "
        case "escape": key = "\u{1b}"
        case "up": key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "left": key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case let other where other.count == 1: key = other
        default: return nil
        }
        return (key, flags)
    }

    static func build(delegate: AppDelegate) -> NSMenu {
        let configuration = AppModel.shared.configuration
        let table = configuration.shortcutTable
        let main = NSMenu()

        func command(_ title: String, _ command: ShortcutCommand, symbol: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.performShortcutCommand(_:)), keyEquivalent: "")
            item.target = delegate
            item.representedObject = command.rawValue
            if let binding = table.bindings(for: command).first, let (key, flags) = keyEquivalent(for: binding) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = flags
            }
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            return item
        }

        func action(_ title: String, _ selector: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }

        /// Cut/Copy/Paste repeat in the Workspace menu without key equivalents (those belong to the Edit menu).
        func withoutKey(_ item: NSMenuItem) -> NSMenuItem {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return item
        }

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            return item
        }

        // App menu
        let appName = "Wumi"
        let services = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: L("Services"))
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        main.addItem(submenu(appName, [
            action(LF("About %@", appName), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            action(L("Settings…"), #selector(AppDelegate.showSettingsAction(_:)), key: ",", target: delegate),
            .separator(),
            services,
            .separator(),
            action(LF("Hide %@", appName), #selector(NSApplication.hide(_:)), key: "h"),
            action(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]),
            action(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            action(LF("Quit %@", appName), #selector(NSApplication.terminate(_:)), key: "q"),
        ]))

        // File
        // Same order as the original's File menu (reference capture menubar-2).
        main.addItem(submenu(L("File"), [
            command(L("New Window"), .newWindow),
            action(L("Merge Windows into Tabs"), #selector(AppDelegate.mergeWindowsAction(_:)), target: delegate),
            action(L("Clone Workspace in New Window"), #selector(AppDelegate.cloneWorkspaceAction(_:)), target: delegate),
            command(L("Open"), .openSelection),
            action(L("Go to Folder…"), #selector(AppDelegate.goToFolderAction(_:)), target: delegate),
            action(L("Connect to Server…"), #selector(AppDelegate.connectToServerAction(_:)), key: "k", target: delegate),
            command(L("New Tab"), .newTab),
            command(L("Close Tab"), .closeTab),
            command(L("Remove Duplicate Tabs"), .removeDuplicateTabs),
            command(L("Reopen Closed Tab"), .reopenClosedTab),
            .separator(),
            // AppKit adds "Close All" (⌥⌘W) as the alternate of this item.
            action(L("Close"), #selector(NSWindow.performClose(_:))),
        ]))

        // Edit
        main.addItem(submenu(L("Edit"), [
            action(L("Undo"), Selector(("undo:")), key: "z"),
            action(L("Redo"), Selector(("redo:")), key: "z", modifiers: [.command, .shift]),
            .separator(),
            action(L("Cut"), #selector(NSText.cut(_:)), key: "x"),
            // The system wording for the Edit menu ("拷贝"), as in the original; file commands say "复制".
            action(L("Copy (Edit Menu)"), #selector(NSText.copy(_:)), key: "c"),
            action(L("Paste"), #selector(NSText.paste(_:)), key: "v"),
            action(L("Delete"), #selector(NSText.delete(_:))),
            action(L("Select All"), #selector(NSText.selectAll(_:)), key: "a"),
        ]))

        // View
        // The original's View menu only toggles the inspector and full screen; view modes live in Workspace.
        let inspector = command(L("Hide Inspector"), .toggleInspector)
        inspector.identifier = NSUserInterfaceItemIdentifier("Menu.ToggleInspector")
        main.addItem(submenu(L("View"), [
            inspector,
            action(L("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]),
        ]))

        // Navigate
        main.addItem(submenu(L("Navigate"), [
            command(L("Edit Path"), .editPath),
            command(L("Search"), .search),
            action(L("Lightning Search"), #selector(AppDelegate.lightningSearchAction(_:)), target: delegate),
            .separator(),
            command(L("Back"), .navigateBack),
            command(L("Forward"), .navigateForward),
            command(L("Up One Level"), .navigateUp),
            command(L("Quick Look"), .quickLook),
        ]))

        // Workspace
        var layoutItems: [NSMenuItem] = []
        let layoutCommands: [(ShortcutCommand, PaneLayout)] = [
            (.layoutSingle, .single), (.layoutTwoColumns, .twoColumns), (.layoutTwoRows, .twoRows), (.layoutThreeColumns, .threeColumns),
            (.layoutThreeRows, .threeRows), (.layoutOneLeftTwoRight, .oneLeftTwoRight), (.layoutTwoLeftOneRight, .twoLeftOneRight),
            (.layoutOneTopTwoBottom, .oneTopTwoBottom), (.layoutTwoTopOneBottom, .twoTopOneBottom), (.layoutFourGrid, .fourGrid),
        ]
        for (shortcut, layout) in layoutCommands {
            layoutItems.append(command(PaneLayoutNames.title(layout), shortcut))
        }
        let oneLeftThree = NSMenuItem(title: PaneLayoutNames.title(.oneLeftThreeRight), action: #selector(WorkspaceMenuTarget.setLayout(_:)), keyEquivalent: "")
        oneLeftThree.representedObject = PaneLayout.oneLeftThreeRight.rawValue
        oneLeftThree.target = WorkspaceMenuTarget.shared
        let threeLeftOne = NSMenuItem(title: PaneLayoutNames.title(.threeLeftOneRight), action: #selector(WorkspaceMenuTarget.setLayout(_:)), keyEquivalent: "")
        threeLeftOne.representedObject = PaneLayout.threeLeftOneRight.rawValue
        threeLeftOne.target = WorkspaceMenuTarget.shared
        WorkspaceMenuTarget.shared.delegate = delegate
        main.addItem(submenu(L("Workspace"), [
            command(L("New Folder"), .newFolder),
            command(L("New File"), .newFile),
            .separator(),
            command(L("Add Bookmark…"), .addBookmark),
            command(L("Copy Absolute Path"), .copyPath),
            action(L("Reveal in Finder"), #selector(AppDelegate.revealInFinderAction(_:)), target: delegate),
            command(L("Open in Terminal"), .openTerminal),
            command(L("Open in Editor"), .openEditor),
            .separator(),
            command(L("Rename"), .rename),
            command(L("Duplicate"), .duplicate),
            withoutKey(command(L("Cut"), .cut)),
            withoutKey(command(L("Copy"), .copy)),
            withoutKey(command(L("Paste"), .paste)),
            command(L("Move Item Here"), .pasteAndMove),
            command(L("Move to Trash"), .moveToTrash),
            .separator(),
        ] + layoutItems + [oneLeftThree, threeLeftOne] + [
            action(L("Close Current Pane"), #selector(AppDelegate.closePaneAction(_:)), target: delegate),
            action(L("Dissolve Split View and Open in New Tabs"), #selector(WorkspaceMenuTarget.splitIntoTabs(_:)), target: WorkspaceMenuTarget.shared),
            command(L("Focus Previous Pane"), .previousPane),
            command(L("Focus Next Pane"), .nextPane),
            action(L("Select All Items"), #selector(AppDelegate.selectAllItemsAction(_:)), target: delegate),
            command(L("Invert Selection"), .invertSelection),
            command(L("Batch Rename…"), .batchRename),
            .separator(),
            command(L("Icon View"), .iconView),
            command(L("List View"), .listView),
            command(L("Column View"), .columnView),
            command(L("Gallery View"), .imageView),
        ]))

        // Window
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(action(L("Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        windowMenu.addItem(action(L("Zoom"), #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(action(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        let windowItem = NSMenuItem(title: L("Window"), action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        // Help
        let helpMenu = NSMenu(title: L("Help"))
        helpMenu.addItem(action(L("Wumi Help"), #selector(AppDelegate.showHelpAction(_:)), key: "?", target: delegate))
        let helpItem = NSMenuItem(title: L("Help"), action: nil, keyEquivalent: "")
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        return main
    }
}

@MainActor
final class WorkspaceMenuTarget: NSObject {
    static let shared = WorkspaceMenuTarget()
    weak var delegate: AppDelegate?

    @objc func setLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let layout = PaneLayout(rawValue: raw) else { return }
        delegate?.activeController?.setLayout(layout)
    }

    @objc func splitIntoTabs(_ sender: NSMenuItem) {
        delegate?.activeController?.splitPanesIntoTabs()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(splitIntoTabs(_:)) { return (delegate?.activeController?.model.activeTab.panes.count ?? 0) > 1 }
        return true
    }
}

/// Standard edit actions routed to the active pane when no text field handles them.
extension WorkspaceController {
    @objc func copy(_ sender: Any?) { perform(.copy) }
    @objc func cut(_ sender: Any?) { perform(.cut) }
    @objc func paste(_ sender: Any?) { perform(.paste) }
    @objc override func selectAll(_ sender: Any?) { activePane.selectAll() }
}
