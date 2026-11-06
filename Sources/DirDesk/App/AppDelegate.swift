import AppKit
import Combine
import DirDeskCore
import SwiftUI

/// FSEvents fan-out: one watcher for every directory shown in any pane of any window.
@MainActor
final class WatcherHub {
    weak var delegate: AppDelegate?
    private lazy var watcher = DirectoryWatcher { [weak self] paths in
        Task { @MainActor in self?.changed(paths) }
    }

    func refresh() {
        guard let delegate else { return }
        var paths = Set<String>()
        for controller in delegate.controllers {
            for pane in controller.model.allPanes { paths.formUnion(pane.watchedPaths) }
        }
        for pane in DesktopCoordinator.shared.desktopPanes { paths.formUnion(pane.watchedPaths) }
        if FloatingFilesController.shared.isVisible { paths.formUnion(FloatingFilesController.shared.pane.watchedPaths) }
        watcher.watch(paths)
    }

    private func changed(_ paths: Set<String>) {
        guard let delegate else { return }
        var panes = delegate.controllers.flatMap { $0.model.allPanes }
        panes.append(FloatingFilesController.shared.pane)
        panes.append(contentsOf: DesktopCoordinator.shared.desktopPanes)
        for pane in panes {
            for path in paths where pane.watchedPaths.contains(path) { pane.directoryChanged(path) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var controllers: [WorkspaceController] = []
    weak var lastActiveController: WorkspaceController?
    let watcherHub = WatcherHub()
    let operations = OperationCenter()
    var cutURLs: [URL] = []
    private(set) var isTerminating = false
    private var menuSignature = ""
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    private var lastDKey: TimeInterval = 0
    let windows = FeatureWindows()

    var activeController: WorkspaceController? {
        (NSApp.keyWindow?.windowController as? WorkspaceController) ?? (NSApp.mainWindow?.windowController as? WorkspaceController)
            ?? lastActiveController ?? controllers.last
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        watcherHub.delegate = self
        windows.appDelegate = self
        FileOpenRouter.delegate = self
        AppModel.shared.applyAppearance()
        rebuildMainMenuIfNeeded(force: true)
        NSApp.servicesProvider = ServiceProvider(delegate: self)
        NSUpdateDynamicServices()
        restoreOrOpenWindows()
        installKeyMonitor()
        StatusItemController.shared.install(delegate: self)
        FloatingFilesController.shared.appDelegate = self
        DeviceCoordinator.shared.install(delegate: self)
        registerFloatingFilesShortcut()
        GlobalSearchController.shared.install()
        DesktopCoordinator.shared.install(delegate: self)
        GlobalSearchController.shared.$configuration.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            StatusItemController.shared.install(delegate: self)
        }.store(in: &cancellables)
        DesktopCoordinator.shared.$isEnabled.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            StatusItemController.shared.install(delegate: self)
        }.store(in: &cancellables)
        HotZoneController.shared.install()
        FileFloatingStore.shared.$configuration.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.registerFloatingFilesShortcut()
        }.store(in: &cancellables)
        AppModel.shared.$configuration.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.rebuildMainMenuIfNeeded()
            StatusItemController.shared.install(delegate: self)
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .dirDeskLanguageChanged).sink { [weak self] _ in
            self?.rebuildMainMenuIfNeeded(force: true)
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .dirDeskFilesChanged).sink { [weak self] _ in
            self?.controllers.forEach { controller in
                controller.model.allPanes.filter { $0.loadState != .idle }.forEach { $0.reload() }
            }
        }.store(in: &cancellables)
        LightningSearchService.shared.startIfAllowed()
        FolderSyncScheduler.shared.start()
        NotificationCenter.default.publisher(for: LightningSearchActions.stageItemsNotification).receive(on: RunLoop.main).sink { note in
            guard let urls = note.object as? [URL], !urls.isEmpty else { return }
            FileTransitStore.shared.add(urls)
            FloatingFilesController.shared.show()
        }.store(in: &cancellables)
        // Full Screen in an image preview opens the file in Super Preview; an archive entry clicked in the inspector
        // opens its archive there with that entry shown.
        NotificationCenter.default.publisher(for: .dirDeskShowSuperPreview).receive(on: RunLoop.main).sink { [weak self] note in
            guard let url = note.object as? URL, let self else { return }
            let controller = self.activeController ?? self.controllers.first ?? self.newWindow(directory: url.deletingLastPathComponent())
            let entry = note.userInfo?["archiveEntry"] as? String
            Task {
                guard let item = await Task.detached(operation: { DirectoryLoader.item(at: url) }).value else { return }
                controller.showSuperPreview(item, archiveEntry: entry)
            }
        }.store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(directory: nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        controllers.forEach { $0.model.saveNow() }
        WorkspaceSessionStore.shared.flush()
        FileTransitStore.shared.flush()
        LightningSearchService.shared.stopForTermination { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DesktopCoordinator.shared.shutdown()
        GlobalSearchController.shared.shutdown()
        GlobalHotKey.shared.shutdown()
        // Keeps the Lightning Search index snapshot so the next launch can search right away.
        LightningSearchService.shared.shutdown()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("New Window")) { [weak self] in self?.newWindow(directory: nil) })
        return menu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openExternally(urls)
    }

    /// Opens folders in a new tab of the active window (or reveals files in their folder).
    func openExternally(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if controllers.isEmpty { newWindow(directory: nil) }
        guard let controller = activeController else { return }
        for url in urls.prefix(50).map(FileOpenRouter.resolvedFileURL) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true {
                controller.newTab(directory: url)
            } else {
                controller.newTab(directory: url.deletingLastPathComponent())
                controller.model.activePane.select(urls: [url])
            }
        }
        FileOpenRouter.present(controller)
    }

    func registerFloatingFilesShortcut() {
        guard !UserDefaults.standard.bool(forKey: "DirDeskSnapshotHidden") else { return }
        let configuration = FileFloatingStore.shared.configuration
        if configuration.shortcutEnabled {
            GlobalHotKey.shared.register(keyCode: configuration.shortcutKey, modifiers: configuration.shortcutModifiers) {
                FloatingFilesController.shared.toggle()
            }
        } else {
            GlobalHotKey.shared.unregister()
        }
    }

    // MARK: Windows

    private func restoreOrOpenWindows() {
        let sessions = WorkspaceSessionStore.shared.loadAll()
        if sessions.isEmpty {
            newWindow(directory: nil)
        } else {
            for session in sessions { open(session: session) }
        }
    }

    @discardableResult
    func open(session: WindowSession) -> WorkspaceController {
        let model = WorkspaceModel(session: session, store: WorkspaceSessionStore.shared)
        let controller = WorkspaceController(model: model)
        controller.appDelegate = self
        controllers.append(controller)
        controller.show()
        lastActiveController = controller
        return controller
    }

    @discardableResult
    func newWindow(directory: URL?) -> WorkspaceController {
        let start = directory ?? AppModel.shared.startupDirectory()
        let tab = WorkspaceTab(pane: BrowserPaneState(destination: .directory(start), viewConfiguration: AppModel.shared.defaultViewConfiguration))
        let controller = open(session: WindowSession(tabs: [tab], activeTabID: tab.id))
        if controllers.count > 1, let window = controller.window, let previous = controllers.dropLast().last?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        }
        controller.model.scheduleSave()
        return controller
    }

    func openWindow(with tab: WorkspaceTab) {
        open(session: WindowSession(tabs: [tab], activeTabID: tab.id)).model.scheduleSave()
    }

    func windowControllerDidClose(_ controller: WorkspaceController) {
        controllers.removeAll { $0 === controller }
        if lastActiveController === controller { lastActiveController = controllers.last }
        watcherHub.refresh()
    }

    func mergeAllWindows() {
        guard let target = activeController else { return }
        for other in controllers where other !== target {
            for tab in other.model.tabs where target.model.tabs.count < WindowSession.maximumTabs {
                target.model.adoptTab(tab.state)
            }
            other.window?.close()
        }
    }

    func cloneWorkspaceInNewWindow() {
        guard let source = activeController else { return }
        var session = source.model.session
        session.id = UUID()
        session.tabs = session.tabs.map { tab in
            var copy = tab
            copy.id = UUID()
            copy.panes = copy.panes.map { var p = $0; p.id = UUID(); return p }
            copy.activePaneID = copy.panes.first?.id ?? copy.activePaneID
            return copy
        }
        session.activeTabID = session.tabs.first?.id ?? session.activeTabID
        open(session: session).model.scheduleSave()
    }

    // MARK: Menu

    func rebuildMainMenuIfNeeded(force: Bool = false) {
        let configuration = AppModel.shared.configuration
        let signature = "\(Localizer.shared.code)|\(configuration.shortcuts.count)|\(configuration.secondaryShortcuts.count)|\(configuration.disabledShortcutCommands)|\(configuration.shortcuts.map { "\($0.key.rawValue)=\($0.value.textForm)" }.sorted())"
        guard force || signature != menuSignature else { return }
        menuSignature = signature
        NSApp.mainMenu = MainMenuBuilder.build(delegate: self)
    }

    /// True when the key window is a secondary window (Floating Files, Settings, Info…), not a workspace.
    var secondaryWindowIsKey: Bool {
        guard let key = NSApp.keyWindow else { return false }
        return !(key.windowController is WorkspaceController)
    }

    @objc func performShortcutCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = ShortcutCommand(rawValue: raw) else { return }
        if command == .newWindow {
            newWindow(directory: activeController?.model.activePane.currentDirectory)
            return
        }
        if secondaryWindowIsKey {
            // Commands belong to the key window; only Close Tab has a meaning here (close that window).
            if command == .closeTab { NSApp.keyWindow?.performClose(nil) }
            if command == .quickLook || command == .navigateUp || command == .navigateBack || command == .navigateForward,
               NSApp.keyWindow?.identifier?.rawValue == "DirDesk.FloatingFiles" {
                FloatingFilesController.shared.perform(command)
            }
            return
        }
        activeController?.perform(command)
    }

    @objc func showSettingsAction(_ sender: Any?) { showSettings(section: nil) }
    @objc func newWindowAction(_ sender: Any?) { newWindow(directory: activeController?.model.activePane.currentDirectory) }
    @objc func mergeWindowsAction(_ sender: Any?) { mergeAllWindows() }
    @objc func cloneWorkspaceAction(_ sender: Any?) { cloneWorkspaceInNewWindow() }
    @objc func goToFolderAction(_ sender: Any?) { activeController?.perform(.editPath) }
    @objc func connectToServerAction(_ sender: Any?) { activeController.map { showConnectToServer(controller: $0) } }
    @objc func closePaneAction(_ sender: Any?) { activeController?.model.activeTab.closeActivePane() }
    @objc func lightningSearchAction(_ sender: Any?) { showLightningSearch(scope: activeController?.model.activePane.currentDirectory) }
    @objc func advancedSearchAction(_ sender: Any?) {
        windows.showAdvancedSearch(scope: activeController?.model.activePane.currentDirectory, controller: activeController)
    }
    @objc func revealInFinderAction(_ sender: Any?) { activeController?.revealInFinder() }
    @objc func selectAllItemsAction(_ sender: Any?) { activeController?.model.activePane.selectAll() }
    @objc func toggleSidebarAction(_ sender: Any?) { activeController?.toggleSidebarFromTitlebar() }
    @objc func closeAllWindowsAction(_ sender: Any?) { controllers.forEach { $0.window?.performClose(nil) } }
    @objc func showHelpAction(_ sender: Any?) { showSettings(section: "about") }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if secondaryWindowIsKey, menuItem.action == #selector(performShortcutCommand(_:)),
           let raw = menuItem.representedObject as? String, let command = ShortcutCommand(rawValue: raw) {
            let floating = NSApp.keyWindow?.identifier?.rawValue == "DirDesk.FloatingFiles"
            return command == .newWindow || command == .closeTab
                || (floating && [.quickLook, .navigateUp, .navigateBack, .navigateForward].contains(command))
        }
        guard let controller = activeController else {
            return menuItem.action == #selector(newWindowAction(_:)) || menuItem.action == #selector(showSettingsAction(_:))
        }
        if menuItem.action == #selector(performShortcutCommand(_:)), let raw = menuItem.representedObject as? String,
           let command = ShortcutCommand(rawValue: raw) {
            let hasSelection = !controller.model.activePane.selectedIDs.isEmpty
            switch command {
            case .rename: return controller.model.activePane.selectedIDs.count == 1
            case .duplicate, .cut, .copy, .moveToTrash, .openSelection, .batchRename: return hasSelection
            case .navigateBack: return controller.model.activePane.history.canGoBack
            case .navigateForward: return controller.model.activePane.history.canGoForward
            case .navigateUp: return controller.model.activePane.canGoUp
            case .reopenClosedTab: return !controller.model.closedTabs.isEmpty
            case .paste, .pasteAndMove: return NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            case .previousPane, .nextPane: return controller.model.activeTab.panes.count > 1
            default: break
            }
            if let layout = command.paneLayout { menuItem.state = controller.model.activeTab.layout == layout ? .on : .off }
            switch command {
            case .iconView: menuItem.state = controller.model.activePane.viewConfiguration.mode == .icons ? .on : .off
            case .listView: menuItem.state = controller.model.activePane.viewConfiguration.mode == .list ? .on : .off
            case .columnView: menuItem.state = controller.model.activePane.viewConfiguration.mode == .columns ? .on : .off
            case .imageView: menuItem.state = controller.model.activePane.viewConfiguration.mode == .images ? .on : .off
            case .toggleInspector: menuItem.title = controller.model.inspectorVisible ? L("Hide Inspector") : L("Show Inspector")
            default: break
            }
        }
        if menuItem.action == #selector(closePaneAction(_:)) { return controller.model.activeTab.panes.count > 1 }
        if menuItem.action == #selector(mergeWindowsAction(_:)) { return controllers.count > 1 }
        return true
    }

    // MARK: Double-tap "D" opens Lightning Search when typing outside text fields

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            guard let self else { return event }
            LightningSearchService.shared.userDidInteract()
            guard event.type == .keyDown else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            let isTextInput = (NSApp.keyWindow?.firstResponder is NSText) || (NSApp.keyWindow?.firstResponder is NSTextView)
            guard flags.isEmpty, !isTextInput, event.charactersIgnoringModifiers?.lowercased() == "d",
                  AppModel.shared.configuration.shortcuts[.globalQuickSearch]?.isDoubleTap == true,
                  !AppModel.shared.configuration.disabledShortcutCommands.contains(.globalQuickSearch) else {
                self.lastDKey = 0
                return event
            }
            let now = event.timestamp
            if now - self.lastDKey < 0.35 {
                self.lastDKey = 0
                self.showLightningSearch(scope: self.activeController?.model.activePane.currentDirectory)
                return nil
            }
            self.lastDKey = now
            return event
        }
    }

    // MARK: Feature windows

    func showSettings(section: String?) { windows.showSettings(section: section) }
    func showLightningSearch(scope: URL?) { windows.showLightningSearch(scope: scope, controller: activeController) }
    func showInfo(for item: FileItem) { windows.showInfo(for: item) }
    func showBatchRename(_ items: [FileItem], controller: WorkspaceController) { windows.showBatchRename(items, controller: controller) }
    func showBookmarkManager() { windows.showBookmarkManager(controller: activeController) }
    func importFinderFavorites(controller: WorkspaceController) { windows.importFinderFavorites(controller: controller) }
    func showWorkspaceManager() { windows.showWorkspaceManager(controller: activeController) }
    func showConnectToServer(controller: WorkspaceController) { windows.showConnectToServer(controller: controller) }
    func showFileTransit() { windows.showFileTransit() }
    func showBuiltInTool(_ tool: BuiltInToolID, items: [FileItem], controller: WorkspaceController) {
        windows.showBuiltInTool(tool, items: items, controller: controller)
    }
}

/// Services menu "Open in Wumi".
final class ServiceProvider: NSObject {
    weak var delegate: AppDelegate?

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    @objc func openInDirDesk(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No readable file or folder was provided." as NSString
            return
        }
        if urls.count > 50 {
            error.pointee = "Wumi can open up to 50 items at once." as NSString
        }
        MainActor.assumeIsolated { delegate?.openExternally(Array(urls.prefix(50))) }
    }
}
