import AppKit
import DirDeskCore

/// Regression checks for deferred tab loading and asynchronous browser metadata, run by `selfTest`.
@MainActor
enum DebugOptimizationChecks {
    static func run(report: (String, Bool, String) -> Void) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-optimization-\(UUID().uuidString)")
        let a = root.appendingPathComponent("a", isDirectory: true)
        let b = root.appendingPathComponent("b", isDirectory: true)
        let child = b.appendingPathComponent("child", isDirectory: true)
        let target = b.appendingPathComponent("selected.txt")
        do {
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data("selection".utf8).write(to: target)
            try Data("child".utf8).write(to: child.appendingPathComponent("nested.txt"))
            try Data("a".utf8).write(to: a.appendingPathComponent("a.txt"))
        } catch {
            report("optimization fixture", false, error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: root) }

        func wait(_ predicate: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return predicate()
        }

        let active = WorkspaceTab(pane: BrowserPaneState(destination: .directory(a)))
        var restoredPane = BrowserPaneState(destination: .directory(b))
        restoredPane.selectedIdentities = [FileIdentity(fallbackPath: target.path)]
        restoredPane.expandedPaths = [child.path]
        restoredPane.scrollAnchor = target.path
        let background = WorkspaceTab(pane: restoredPane)
        let controller = appDelegate.open(session: WindowSession(tabs: [active, background], activeTabID: active.id))
        let model = controller.model
        defer { controller.close() }
        let ready = await wait { model.activePane.displayItems.contains { $0.name == "a.txt" } }
        report("lazy restore loads the active tab", ready, "")
        guard let lazy = model.tabs.first(where: { $0.id == background.id })?.activePane else {
            report("lazy restore keeps the background tab", false, "")
            return
        }
        report("unvisited tab does not enumerate its folder", lazy.loadState == .idle && lazy.items.isEmpty && lazy.watchedPaths.isEmpty, "")
        let stored = lazy.state
        report("unvisited tab retains selection, expansion and scroll anchor",
               stored.selectedIdentities.map(\.fallbackPath) == [target.path]
               && stored.expandedPaths == [child.path] && stored.scrollAnchor == target.path, "")
        NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
        controller.refreshPanes(showing: [b])
        try? await Task.sleep(for: .milliseconds(150))
        report("file notifications leave unvisited tabs deferred", lazy.loadState == .idle && lazy.items.isEmpty, "")

        model.activeTabID = background.id
        let restored = await wait {
            lazy.displayItems.contains { $0.name == "selected.txt" }
                && lazy.selectedItems.contains { $0.name == "selected.txt" }
                && lazy.rows.contains { $0.item?.name == "nested.txt" }
        }
        report("direct tab activation restores content, selection and expanded children", restored, "")
        report("activated tab watches its folder", lazy.watchedPaths.contains(b.path), "")

        if let extra = model.newTab(directory: b, activate: false) {
            report("background new tab stays deferred", extra.activePane.loadState == .idle, "")
            model.selectTab(extra.id)
            report("selecting a deferred new tab loads it", await wait {
                extra.activePane.displayItems.contains { $0.name == "selected.txt" }
            }, "")
            model.closeTab(extra.id)
        }
        model.selectTab(offset: -1)
        report("keyboard tab selection retains loaded content", model.activePane.currentDirectory?.path == a.path
               && model.activePane.displayItems.contains { $0.name == "a.txt" }, "")

        let repo = root.appendingPathComponent("repository", isDirectory: true)
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let repositoryDetected = await GitRepositoryProbe.isRepository(repo)
        let ordinaryFolder = await GitRepositoryProbe.isRepository(a)
        report("asynchronous repository badge detects .git and ordinary folders", repositoryDetected && !ordinaryFolder, "")
        try? FileManager.default.removeItem(at: repo.appendingPathComponent(".git"))
        GitRepositoryProbe.invalidate(repo)
        report("repository refresh observes removed .git", !(await GitRepositoryProbe.isRepository(repo)), "")
        try? FileManager.default.createDirectory(at: a.appendingPathComponent(".git"), withIntermediateDirectories: true)
        GitRepositoryProbe.invalidate(a)
        report("repository refresh observes newly created .git", await GitRepositoryProbe.isRepository(a), "")

        if let folder = DirectoryLoader.item(at: repo) {
            var delivered: NSImage?
            _ = FileIcons.shared.icon(for: folder) { delivered = $0 }
            report("asynchronous folder icon completes", await wait { delivered != nil }, "")
        }

        let large = root.appendingPathComponent("large", isDirectory: true)
        let fixtureReady = await Task.detached {
            do {
                try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
                for index in 0..<512 {
                    try Data("file".utf8).write(to: large.appendingPathComponent("\(index).txt"))
                }
                return true
            } catch { return false }
        }.value
        guard fixtureReady else { report("large rename fixture", false, ""); return }
        let pane = model.activePane
        pane.open(large)
        await pane.waitForRows()
        controller.newFolder()
        let renameReady = await wait {
            guard let table = controller.listController(for: pane)?.tableView else { return false }
            return pane.displayItems.count == 513
                && table.subviews.contains { $0.accessibilityIdentifier() == "InlineRename.Field" }
                && pane.selectedItems.first?.name == L("untitled folder")
        }
        report("create and inline rename after asynchronous large-directory rows", renameReady, "512 files")

        var galleryState = BrowserPaneState(destination: .directory(large))
        galleryState.viewConfiguration.mode = .images
        let savedPath = large.appendingPathComponent("511.txt").path
        galleryState.selectedIdentities = [FileIdentity(fallbackPath: savedPath)]
        let galleryTab = WorkspaceTab(pane: galleryState)
        let gallery = appDelegate.open(session: WindowSession(tabs: [galleryTab], activeTabID: galleryTab.id))
        defer { gallery.close() }
        let galleryPane = gallery.activePane
        await galleryPane.waitForRows()
        try? await Task.sleep(for: .milliseconds(350))
        report("gallery restores non-first selection after asynchronous rows",
               galleryPane.selectedItems.map(\.url.path) == [savedPath], "512 files and a folder; actual gallery window")
    }
}
