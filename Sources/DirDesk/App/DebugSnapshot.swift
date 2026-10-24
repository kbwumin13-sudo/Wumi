import AppKit
import DirDeskCore
import SwiftUI

/// Developer aid: with `-DirDeskSnapshotDir <folder>`, renders every visible DirDesk window (and its attached sheets)
/// to PNG files a few seconds after launch, then keeps running. Rendering goes through `cacheDisplay`, so it works
/// while the screen is locked. Optional `-DirDeskSnapshotFolder <path>` opens that folder in the active pane first,
/// and `-DirDeskSnapshotAction <name>` performs one action before the capture (see `perform`).
@MainActor
enum DebugSnapshot {
    static func installIfRequested() {
        let defaults = UserDefaults.standard
        guard let directory = defaults.string(forKey: "DirDeskSnapshotDir") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let folder = defaults.string(forKey: "DirDeskSnapshotFolder") {
                appDelegate.activeController?.activePane.open(URL(fileURLWithPath: folder))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if defaults.string(forKey: "DirDeskSnapshotAction") == "performance" {
                    DebugPerformanceRun.run(delegate: appDelegate, output: URL(fileURLWithPath: directory))
                    return
                }
                if defaults.string(forKey: "DirDeskSnapshotAction") == "integration" {
                    DebugIntegrationRun.run(output: URL(fileURLWithPath: directory))
                    return
                }
                if defaults.string(forKey: "DirDeskSnapshotAction") == "mijiAcceptance" {
                    DebugMijiRun.run(output: URL(fileURLWithPath: directory))
                    return
                }
                if defaults.string(forKey: "DirDeskSnapshotAction") == "desktopAcceptance" {
                    Task { @MainActor in
                        await DebugDesktopRun.run(output: URL(fileURLWithPath: directory))
                        NSApp.terminate(nil)
                    }
                    return
                }
                if let action = defaults.string(forKey: "DirDeskSnapshotAction") { perform(action) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { capture(into: URL(fileURLWithPath: directory)) }
            }
        }
    }

    private static func perform(_ action: String) {
        guard let controller = appDelegate.activeController else { return }
        let items = controller.activePane.displayItems
        switch action {
        case "selectFirst":
            if let first = items.first { controller.activePane.selectedIDs = [first.id] }
        case let name where name.hasPrefix("select:"):
            let target = String(name.dropFirst("select:".count))
            controller.activePane.selectedIDs = Set(items.filter { $0.name == target }.map(\.id))
        case let name where name.hasPrefix("superPreview:"):
            let target = String(name.dropFirst("superPreview:".count))
            if let item = items.first(where: { $0.name == target }) {
                controller.activePane.selectedIDs = [item.id]
                controller.showSuperPreview(item)
            }
        case "batchRename":
            controller.activePane.selectedIDs = Set(items.map(\.id))
            controller.perform(.batchRename)
        case "compress":
            if let first = items.first { controller.showArchiveCreation([first]) }
        case "connect":
            controller.presentConnectToServer()
        case "toolbarCustomization":
            controller.showToolbarCustomization()
        case "addTag":
            controller.createSidebarTag()
        case "saveWorkspace":
            controller.saveTabAsWorkspace()
        case "iconView":
            controller.activePane.viewConfiguration.mode = .icons
        case "galleryView":
            controller.activePane.viewConfiguration.mode = .images
        case "columnView":
            controller.activePane.viewConfiguration.mode = .columns
        case let name where name.hasPrefix("scrollList:"):
            if let row = Int(name.dropFirst("scrollList:".count)), let list = controller.listController(for: controller.activePane) {
                list.tableView.scrollRowToVisible(list.tableView.numberOfRows - 1)
                list.tableView.scrollRowToVisible(row)
            }
        case "selfTest":
            if let directory = UserDefaults.standard.string(forKey: "DirDeskSnapshotDir") {
                DebugSelfTest.run(controller: controller, reportDirectory: URL(fileURLWithPath: directory))
            }
        case "newFolder":
            controller.newFolder()
        case "columnNewFolder":
            controller.activePane.viewConfiguration.mode = .columns
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.newFolder() }
        case let name where name.hasPrefix("columnTrail:"):
            // Column view, then a folder two levels down with one file selected (the column trail).
            let parts = name.dropFirst("columnTrail:".count).split(separator: "|").map(String.init)
            controller.activePane.viewConfiguration.mode = .columns
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let folder = parts.first else { return }
                controller.activePane.open(URL(fileURLWithPath: folder))
                if parts.count > 1 { controller.activePane.select(urls: [URL(fileURLWithPath: folder).appendingPathComponent(parts[1])]) }
            }
        case "getInfo":
            if let first = items.first { appDelegate.windows.showInfo(for: first) }
        case let name where name.hasPrefix("getInfo:"):
            let target = String(name.dropFirst("getInfo:".count))
            if let item = items.first(where: { $0.name == target }) { appDelegate.windows.showInfo(for: item) }
        case "editTags":
            controller.editTags(for: Array(items.prefix(2)))
        case "addBookmark":
            controller.presentBookmarkAdd()
        case "expandSidebar":
            NotificationCenter.default.post(name: .dirDeskExpandSidebar, object: nil)
        case let name where name.hasPrefix("tag:"):
            controller.navigateActivePane(toTag: String(name.dropFirst("tag:".count)))
        case let name where name.hasPrefix("settings:"):
            appDelegate.showSettings(section: String(name.dropFirst("settings:".count)))
        case let name where name.hasPrefix("menuDumpLayout:"):
            // "menuDumpLayout:<layout>|<item>": that layout, then the item's context menu in the last pane.
            let parts = name.dropFirst("menuDumpLayout:".count).split(separator: "|").map(String.init)
            guard parts.count == 2, let layout = PaneLayout(rawValue: parts[0]) else { return }
            let folder = controller.activePane.currentDirectory
            controller.setLayout(layout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let pane = controller.model.activeTab.panes.last else { return }
                controller.activate(pane: pane)
                if let folder { pane.open(folder) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { perform("menuDump:" + parts[1]) }
            }
        case let name where name.hasPrefix("menuDump:"):
            // The context menu for the named items ("a.txt|b.txt"; nothing = the background menu), written as an
            // outline to menu.txt for comparison with the reference library's AX menu trees.
            let names = name.dropFirst("menuDump:".count).split(separator: "|").map(String.init)
            let chosen = items.filter { names.contains($0.name) }
            controller.activePane.selectedIDs = Set(chosen.map(\.id))
            let menu = chosen.isEmpty ? controller.backgroundMenu(in: controller.activePane)
                                      : controller.contextMenu(for: chosen, in: controller.activePane)
            if let directory = UserDefaults.standard.string(forKey: "DirDeskSnapshotDir") {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("menu.txt")
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(outline(menu).utf8).write(to: url)
            }
        case "folderSyncRun":
            controller.showFolderSync()
        case "folderSyncEditor":
            // The editor sheet as Settings › Folder Sync › New shows it, here on the workspace window.
            guard let window = controller.window else { return }
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.contentViewController = NSHostingController(rootView: FolderSyncEditorView(request: .new, save: { _, _ in }, cancel: {}))
            window.beginSheet(sheet)
        case "conflictAlert":
            layOutForCapture(ConflictPrompt.makeAlert(existing: items.first?.url ?? URL(fileURLWithPath: "/tmp/a.txt")), "Alert.Conflict")
        case "extensionAlert":
            layOutForCapture(FileOperations.extensionAlert(oldExtension: "txt", newExtension: "md"), "Alert.ChangeExtension")
        case let name where name.hasPrefix("archivePassword:"):
            let target = String(name.dropFirst("archivePassword:".count))
            if let item = items.first(where: { $0.name == target }) {
                controller.askArchivePassword(for: item, retry: false) { _ in }
            }
        case "floating":
            FloatingFilesController.shared.show()
        case "lightning":
            appDelegate.showLightningSearch(scope: nil)
        case "globalSearch":
            GlobalSearchController.shared.show()
        case "floatingSettings":
            // The Floating Files settings sheet on a window of its own, for rendering.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            window.identifier = NSUserInterfaceItemIdentifier("FloatingFiles.Settings")
            window.contentViewController = NSHostingController(rootView: FloatingFilesSettingsSheet {})
            laidOutWindows.append(window)
        case "twoPanes":
            controller.setLayout(.twoColumns)
        case "twoPanesSelect":
            controller.setLayout(.twoColumns)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let first = controller.activePane.displayItems.first { controller.activePane.selectedIDs = [first.id] }
            }
        default:
            break
        }
    }

    /// Alerts normally run modally; here one is only laid out, so `capture` renders its window without showing it.
    private static var laidOutAlerts: [NSAlert] = []
    private static var laidOutWindows: [NSWindow] = []

    private static func layOutForCapture(_ alert: NSAlert, _ identifier: String) {
        alert.layout()
        alert.window.identifier = NSUserInterfaceItemIdentifier(identifier)
        laidOutAlerts.append(alert)
    }

    /// One line per item: indentation for submenus, "---" for separators, then the key equivalent and "(disabled)".
    private static func outline(_ menu: NSMenu, depth: Int = 0) -> String {
        menu.update()
        var text = ""
        for item in menu.items where !item.isHidden {
            let indent = String(repeating: "  ", count: depth)
            if item.isSeparatorItem {
                text += indent + "---\n"
                continue
            }
            var line = indent + item.title
            if !item.keyEquivalent.isEmpty {
                let flags = item.keyEquivalentModifierMask
                let modifiers = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                    + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
                let key = ["\u{8}": "⌫", "\r": "↩", " ": "Space"][item.keyEquivalent] ?? item.keyEquivalent
                line += "  [\(modifiers)\(key)]"
            }
            if !item.isEnabled { line += "  (disabled)" }
            text += line + "\n"
            if let submenu = item.submenu { text += outline(submenu, depth: depth + 1) }
        }
        return text
    }

    private static func capture(into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var index = 0
        // With -DirDeskSnapshotHidden YES (app launched hidden with `open -j`) windows are not visible, so take every
        // workspace and feature window that has content.
        let includeHidden = UserDefaults.standard.bool(forKey: "DirDeskSnapshotHidden")
        for window in NSApp.windows where window.sheetParent == nil && (window.isVisible || (includeHidden && window.contentView != nil)) {
            for target in [window] + (window.attachedSheet.map { [$0] } ?? []) {
                guard let view = target.contentView?.superview ?? target.contentView else { continue }
                let bounds = view.bounds
                guard bounds.width > 10, bounds.height > 10, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
                view.cacheDisplay(in: bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else { continue }
                index += 1
                let name = String(format: "%02d-%@.png", index, (target.identifier?.rawValue ?? target.title).replacingOccurrences(of: "/", with: "-"))
                try? data.write(to: directory.appendingPathComponent(name))
            }
        }
        try? Data("done \(index)\n".utf8).write(to: directory.appendingPathComponent("done.txt"))
    }
}
