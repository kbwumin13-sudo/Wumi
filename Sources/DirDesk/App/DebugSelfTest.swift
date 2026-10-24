import AppKit
import CryptoKit
import DirDeskCore

/// Scripted checks of file commands through the real window controller (launch argument
/// `-DirDeskSnapshotAction selfTest` with `-DirDeskSnapshotDir <dir>`). Works on a scratch folder under
/// `/tmp/dirdesk-selftest`, puts back everything it moves to the Trash, restores the clipboard, and writes one
/// PASS/FAIL line per check to `<dir>/selftest.txt`, then `selftest-done`.
@MainActor
enum DebugSelfTest {
    static func run(controller: WorkspaceController, reportDirectory: URL) {
        Task { @MainActor in
            var lines: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String = "") {
                // One line per check, so multi-line details (copied paths) stay readable.
                let detail = detail.replacingOccurrences(of: "\n", with: " | ")
                lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : " — " + detail))
            }
            let fm = FileManager.default
            let root = URL(fileURLWithPath: "/tmp/dirdesk-selftest", isDirectory: true)
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root.appendingPathComponent("f", isDirectory: true), withIntermediateDirectories: true)
            fm.createFile(atPath: root.appendingPathComponent("a.txt").path, contents: Data("alpha".utf8))
            fm.createFile(atPath: root.appendingPathComponent("b.txt").path, contents: Data("beta".utf8))
            let clipboard = savedClipboard()
            let pane = controller.activePane
            pane.viewConfiguration.mode = .list
            pane.open(root)
            func exists(_ name: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(name).path) }
            @MainActor func item(_ name: String) -> FileItem? { pane.displayItems.first { $0.name == name } }
            func settle(_ seconds: Double = 0.6) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            @MainActor func waitFor(_ condition: () -> Bool, timeout: Double = 5) async -> Bool {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if condition() { return true }
                    await settle(0.1)
                }
                return condition()
            }
            let undo = controller.window?.undoManager
            check("load scratch folder", await waitFor { item("a.txt") != nil && item("b.txt") != nil && item("f") != nil })

            // Duplicate, undo, redo.
            if let a = item("a.txt") {
                pane.selectedIDs = [a.id]
                controller.duplicateSelection()
                check("duplicate makes \"a 2.txt\"", await waitFor { exists("a 2.txt") })
                await settle()
                undo?.undo()
                check("undo duplicate removes the copy", await waitFor { !exists("a 2.txt") })
                await settle()
                undo?.redo()
                check("redo duplicate brings the copy back", await waitFor { exists("a 2.txt") })
                try? fm.removeItem(at: root.appendingPathComponent("a 2.txt"))
                await settle()
            }

            // Rename, undo, redo; then the occupied-name safety stop.
            if await waitFor({ item("a.txt") != nil }), let a = item("a.txt") {
                controller.commitRename(a, to: "c.txt", in: pane)
                check("rename a.txt to c.txt", await waitFor { exists("c.txt") && !exists("a.txt") })
                await settle()
                undo?.undo()
                check("undo rename", await waitFor { exists("a.txt") && !exists("c.txt") })
                await settle()
                undo?.redo()
                check("redo rename", await waitFor { exists("c.txt") && !exists("a.txt") })
                await settle()
                fm.createFile(atPath: root.appendingPathComponent("a.txt").path, contents: Data("someone else".utf8))
                undo?.undo()
                await settle(1)
                let other = (try? String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)) == "someone else"
                check("undo stops when the old name is taken", exists("c.txt") && other)
                if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
                try? fm.removeItem(at: root.appendingPathComponent("a.txt"))
                try? fm.moveItem(at: root.appendingPathComponent("c.txt"), to: root.appendingPathComponent("a.txt"))
                pane.reload()
                await settle()
            }

            // Trash and undo.
            if await waitFor({ item("b.txt") != nil }), let b = item("b.txt") {
                controller.moveToTrash([b], in: pane)
                check("move b.txt to the Trash", await waitFor { !exists("b.txt") })
                await settle()
                undo?.undo()
                check("undo puts b.txt back", await waitFor { exists("b.txt") })
                await settle()
            }

            // New folder, undo, redo.
            controller.newFolder()
            let folderName = L("untitled folder")
            check("new folder", await waitFor { exists(folderName) })
            await settle()
            pane.renamingID = nil
            undo?.undo()
            check("undo new folder", await waitFor { !exists(folderName) })
            await settle()
            undo?.redo()
            check("redo new folder", await waitFor { exists(folderName) })
            try? fm.removeItem(at: root.appendingPathComponent(folderName))
            pane.reload()
            await settle()

            // Copy path of two items.
            if await waitFor({ item("a.txt") != nil && item("b.txt") != nil }), let a = item("a.txt"), let b = item("b.txt") {
                controller.copyPaths([a.url, b.url], folderOnly: false)
                let text = NSPasteboard.general.string(forType: .string)
                check("copy path writes one path per line", text == a.url.path + "\n" + b.url.path, text ?? "nil")
            }

            // Tags on a file.
            if let b = item("b.txt") {
                controller.setTags(["Red"], on: [b])
                let tags = (try? b.url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
                check("set a tag", tags == ["Red"], tags.joined(separator: ","))
                controller.setTags([], on: [b])
                await settle()
            }

            // Make an alias, undo, redo.
            if let b = item("b.txt") {
                controller.makeAlias([b])
                let aliasName = LF("%@ alias", "b") + ".txt"
                check("make alias", await waitFor { exists(aliasName) }, aliasName)
                await settle()
                undo?.undo()
                check("undo alias", await waitFor { !exists(aliasName) })
                await settle()
                undo?.redo()
                check("redo alias", await waitFor { exists(aliasName) })
                try? fm.removeItem(at: root.appendingPathComponent(aliasName))
                pane.reload()
                await settle()
            }

            // Copy into the subfolder through the operation engine, undo (the copy goes), redo (it comes back).
            if let b = item("b.txt") {
                controller.transfer([b.url], to: root.appendingPathComponent("f", isDirectory: true), move: false)
                check("copy b.txt into f", await waitFor { fm.fileExists(atPath: root.appendingPathComponent("f/b.txt").path) && exists("b.txt") })
                await settle()
                undo?.undo()
                check("undo copy removes it from f", await waitFor { !fm.fileExists(atPath: root.appendingPathComponent("f/b.txt").path) })
                await settle()
                undo?.redo()
                check("redo copy brings it back", await waitFor { fm.fileExists(atPath: root.appendingPathComponent("f/b.txt").path) })
                try? fm.removeItem(at: root.appendingPathComponent("f/b.txt"))
                await settle()
            }

            // Collect into a new folder and undo through the controller's undo registration.
            if let b = item("b.txt"), let transaction = try? FolderOrganizationService.collect([b.url], into: root, folderName: "Collected") {
                controller.registerFolderUndo(transaction)
                check("collect into folder", exists("Collected/b.txt") && !exists("b.txt"))
                await settle()
                undo?.undo()
                check("undo collect restores b.txt and removes the folder", await waitFor { exists("b.txt") && !exists("Collected") })
                pane.reload()
                await settle()
            }

            // Cut, then paste into the subfolder.
            if await waitFor({ item("a.txt") != nil }), let a = item("a.txt") {
                pane.selectedIDs = [a.id]
                controller.cutSelection()
                pane.open(root.appendingPathComponent("f", isDirectory: true))
                await settle()
                controller.paste(move: false)
                check("cut then paste moves the file", await waitFor { fm.fileExists(atPath: root.appendingPathComponent("f/a.txt").path) && !exists("a.txt") })
            }

            // Navigation: back, forward, up (with the folder selected).
            pane.open(root)
            _ = await waitFor { item("f") != nil }
            pane.open(root.appendingPathComponent("f", isDirectory: true))
            await settle()
            pane.goBack()
            check("back returns to the previous folder", pane.currentDirectory?.hasSamePath(as: root) == true)
            pane.goForward()
            check("forward goes to f again", pane.currentDirectory?.lastPathComponent == "f")
            pane.goUp()
            let selectedF = await waitFor { pane.selectedItems.map(\.name) == ["f"] }
            check("up opens the parent with f selected", pane.currentDirectory?.hasSamePath(as: root) == true && selectedF)

            // Hidden files follow the pane setting.
            fm.createFile(atPath: root.appendingPathComponent(".hidden-item").path, contents: Data())
            pane.reload()
            _ = await waitFor { item("b.txt") != nil }
            let hiddenByDefault = item(".hidden-item") == nil
            pane.viewConfiguration.showsHiddenFiles = true
            pane.reload()
            let shownWhenOn = await waitFor { item(".hidden-item") != nil }
            check("hidden files: off hides, on shows", hiddenByDefault && shownWhenOn)
            pane.viewConfiguration.showsHiddenFiles = false
            try? fm.removeItem(at: root.appendingPathComponent(".hidden-item"))
            pane.reload()
            await settle()

            // SHA-256 of a known file goes to the clipboard.
            if let b = item("b.txt") {
                controller.calculateChecksum(b)
                let digest = await waitFor({ (NSPasteboard.general.string(forType: .string) ?? "").count == 64 }, timeout: 5)
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                check("checksum copies the SHA-256", digest && text == Self.sha256Hex(Data("beta".utf8)), text)
            }

            // Double-clicking a ZIP extracts it in place.
            let zip = root.appendingPathComponent("pack.zip")
            if (try? ArchiveService.create(from: [root.appendingPathComponent("b.txt")], to: zip, options: ArchiveCreationOptions())) != nil {
                pane.reload()
                if await waitFor({ item("pack.zip") != nil }), let packed = item("pack.zip") {
                    try? fm.moveItem(at: root.appendingPathComponent("b.txt"), to: root.appendingPathComponent("b-original.txt"))
                    controller.open([packed], in: pane, newTab: false)
                    check("opening a ZIP extracts it next to it", await waitFor({ exists("b.txt") }, timeout: 8))
                    try? fm.removeItem(at: root.appendingPathComponent("b.txt"))
                    try? fm.moveItem(at: root.appendingPathComponent("b-original.txt"), to: root.appendingPathComponent("b.txt"))
                    try? fm.removeItem(at: zip)
                }
            }

            // Sorting, folders first, pinned folders and grouping.
            for (name, size) in [("s1.txt", 1), ("s100.txt", 100), ("s10.txt", 10)] {
                fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(repeating: 65, count: size))
            }
            pane.reload()
            _ = await waitFor { item("s10.txt") != nil }
            pane.viewConfiguration.sortKey = .size
            pane.viewConfiguration.sortAscending = false
            await settle(0.3)
            let sizeOrder = pane.displayItems.map(\.name).filter { $0.hasPrefix("s") && $0.hasSuffix(".txt") }
            check("sort by size, largest first", sizeOrder == ["s100.txt", "s10.txt", "s1.txt"], sizeOrder.joined(separator: ","))
            pane.viewConfiguration.sortKey = .name
            pane.viewConfiguration.sortAscending = true
            pane.viewConfiguration.foldersFirst = false
            pane.viewConfiguration.pinnedFolderPaths = []
            await settle(0.3)
            let nameFirst = pane.displayItems.first?.name
            pane.viewConfiguration.pinnedFolderPaths = [root.appendingPathComponent("f").path]
            await settle(0.3)
            check("a pinned folder sorts first", nameFirst != "f" && pane.displayItems.first?.name == "f", nameFirst ?? "")
            pane.viewConfiguration.pinnedFolderPaths = []
            pane.viewConfiguration.foldersFirst = true
            await settle(0.3)
            check("folders first", pane.displayItems.first?.name == "f")
            pane.viewConfiguration.foldersFirst = false
            pane.viewConfiguration.groupingMode = .kind
            await settle(0.3)
            check("group by kind makes groups", pane.groups.count >= 2, "\(pane.groups.count) groups")
            pane.viewConfiguration.groupingMode = .none
            for name in ["s1.txt", "s100.txt", "s10.txt"] { try? fm.removeItem(at: root.appendingPathComponent(name)) }
            pane.reload()
            await settle()

            // Directory totals through the same service and pane derivation used by browser cells.
            let sizesRoot = root.appendingPathComponent("size-check")
            for (name, bytes) in [("small/.hidden/nested", 7), ("large/data", 29), ("Demo.app/Contents/data", 43)] {
                let file = sizesRoot.appendingPathComponent(name)
                try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(repeating: 65, count: bytes).write(to: file)
            }
            pane.open(sizesRoot)
            _ = await waitFor { item("Demo.app") != nil && item("small") != nil && item("large") != nil }
            for (name, bytes) in [("small", Int64(7)), ("large", Int64(29)), ("Demo.app", Int64(43))] {
                if let directory = item(name) {
                    var last: FolderSizeState?
                    for await state in FolderSizes.shared.updates(for: directory) { last = state }
                    check("logical size of \(name)", last?.measurement == .init(bytes: bytes, isComplete: true))
                } else { check("logical size of \(name)", false, "missing item") }
            }
            pane.viewConfiguration.sortKey = .size
            pane.viewConfiguration.sortAscending = false
            pane.viewConfiguration.foldersFirst = false
            check("folder and package totals drive size sorting", await waitFor {
                pane.displayItems.map(\.name) == ["Demo.app", "large", "small"]
            })
            if let large = item("large") {
                pane.selectedIDs = [large.id]
                try? Data(repeating: 65, count: 53).write(to: sizesRoot.appendingPathComponent("large/data"))
                pane.reload()
                check("reload refreshes nested sizes and preserves selection", await waitFor {
                    pane.displayItems.first?.name == "large" && pane.displayItems.first?.size == 53 && pane.selectedIDs.contains(large.id)
                })
            }
            if let small = item("small") {
                try? Data(repeating: 65, count: 80).write(to: sizesRoot.appendingPathComponent("small/.hidden/nested"))
                FolderSizes.shared.invalidate(in: small.url)
                for await state in FolderSizes.shared.updates(for: small) {
                    pane.recordDirectorySize(small, state: state)
                }
                pane.setSizeObservationActive(false)
                pane.setSizeObservationActive(true)
                check("resume commits a measured size before the deferred sort", await waitFor {
                    pane.displayItems.first?.name == "small" && pane.displayItems.first?.size == 80
                })
            }
            pane.viewConfiguration.sortKey = .name
            pane.viewConfiguration.sortAscending = true
            pane.open(root)
            try? fm.removeItem(at: sizesRoot)
            await settle()

            // New file from the first template, with undo and redo.
            if let template = AppModel.shared.configuration.fileTemplates.first {
                let before = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
                controller.createFile(from: template)
                let created = await waitFor { Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).count > before.count }
                let newName = Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).subtracting(before).first ?? ""
                check("new file from template", created, newName)
                pane.renamingID = nil
                await settle()
                undo?.undo()
                check("undo new file", await waitFor { !exists(newName) })
                await settle()
                undo?.redo()
                check("redo new file", await waitFor { exists(newName) })
                if !newName.isEmpty { try? fm.removeItem(at: root.appendingPathComponent(newName)) }
                pane.reload()
                await settle()
            }

            // Tabs: new, remove duplicates, close and reopen; layouts.
            let model = controller.model
            let startTabs = model.tabs.count
            controller.newTab(directory: root)
            controller.newTab(directory: root)
            await settle()
            check("two new tabs", model.tabs.count == startTabs + 2, "\(model.tabs.count)")
            controller.removeDuplicateTabs()
            await settle()
            let afterDedupe = model.tabs.count
            let singlePaths = model.tabs.filter { $0.panes.count == 1 && !$0.isPinned }.compactMap { $0.activePane.currentDirectory?.path }
            check("remove duplicate tabs", afterDedupe < startTabs + 2 && Set(singlePaths).count == singlePaths.count
                  && model.activeTab.activePane.currentDirectory?.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path, "\(startTabs + 2) → \(afterDedupe)")
            // A fresh session is down to one tab here, so open one to close.
            controller.newTab(directory: root.appendingPathComponent("f", isDirectory: true))
            await settle()
            if let last = model.tabs.last, model.tabs.count > 1 {
                controller.closeTab(last.id)
                await settle()
                let closedCount = model.tabs.count
                model.reopenClosedTab()
                await settle()
                check("reopen closed tab", model.tabs.count == closedCount + 1
                      && model.tabs.last?.activePane.currentDirectory?.lastPathComponent == "f", "\(closedCount) → \(model.tabs.count)")
            } else {
                check("reopen closed tab", false, "no tab to close")
            }
            controller.setLayout(.twoColumns)
            await settle()
            let two = model.activeTab.panes.count
            // "Move Pane To": the two panes trade places.
            let order = model.activeTab.panes.map(\.id)
            if order.count == 2 { model.activeTab.swapPanes(order[0], order[1]) }
            await settle()
            check("move pane swaps places", model.activeTab.panes.map(\.id) == order.reversed(), "\(order.count) panes")
            controller.setLayout(.single)
            await settle()
            check("two-pane layout and back", two == 2 && model.activeTab.panes.count == 1, "\(two)")
            while model.tabs.count > startTabs, let extra = model.tabs.last { _ = model.closeTab(extra.id) }

            // Clone the workspace into a new window, then merge all windows into tabs of one.
            let windowsBefore = appDelegate.controllers.count
            let tabsTotal = appDelegate.controllers.reduce(0) { $0 + $1.model.tabs.count }
            appDelegate.cloneWorkspaceInNewWindow()
            await settle(1)
            check("clone workspace in a new window", appDelegate.controllers.count == windowsBefore + 1)
            let tabsWithClone = appDelegate.controllers.reduce(0) { $0 + $1.model.tabs.count }
            appDelegate.mergeAllWindows()
            await settle(1)
            let merged = appDelegate.controllers.count == 1 && appDelegate.controllers.first?.model.tabs.count == tabsWithClone
            check("merge windows into tabs", merged, "\(tabsTotal) + clone → \(appDelegate.controllers.first?.model.tabs.count ?? 0) tabs")
            if let remaining = appDelegate.controllers.first {
                while remaining.model.tabs.count > 1, let extra = remaining.model.tabs.last { _ = remaining.model.closeTab(extra.id) }
            }

            await DebugOptimizationChecks.run { name, ok, detail in check(name, ok, detail) }
            restoreClipboard(clipboard)
            appDelegate.controllers.first?.activePane.open(root.deletingLastPathComponent())
            try? fm.removeItem(at: root)
            let report = lines.joined(separator: "\n") + "\n"
            try? report.write(to: reportDirectory.appendingPathComponent("selftest.txt"), atomically: true, encoding: .utf8)
            fm.createFile(atPath: reportDirectory.appendingPathComponent("selftest-done").path, contents: nil)
            if UserDefaults.standard.bool(forKey: "WumiSelfTestExit") { NSApp.terminate(nil) }
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func savedClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    private static func restoreClipboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = saved.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
