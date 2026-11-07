import AppKit
import Combine
import DirDeskCore
import Quartz
import SwiftUI

/// Window controls align with the tabs while the content owns its navigation chrome.
final class WorkspaceWindow: NSWindow {
    static let titleRowHeight: CGFloat = 44

    func layoutTrafficLights() {
        guard let close = standardWindowButton(.closeButton), let miniaturize = standardWindowButton(.miniaturizeButton),
              let zoom = standardWindowButton(.zoomButton), let titlebar = close.superview, let container = titlebar.superview,
              !styleMask.contains(.fullScreen) else { return }
        let height = Self.titleRowHeight
        var frame = container.frame
        if frame.height != height || frame.origin.y != self.frame.height - height {
            frame.size.height = height
            frame.origin.y = self.frame.height - height
            container.frame = frame
        }
        let spacing = miniaturize.frame.minX - close.frame.minX
        let y = (height - close.frame.height) / 2
        let x0: CGFloat = 14
        for (index, button) in [close, miniaturize, zoom].enumerated() {
            let origin = NSPoint(x: x0 + CGFloat(index) * max(spacing, 20), y: y)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutTrafficLights()
    }
}

/// Owns one workspace window and executes every command that targets it.
@MainActor
final class WorkspaceController: NSWindowController, NSWindowDelegate, BrowserActionHandler, ObservableObject {
    let model: WorkspaceModel
    @Published private(set) var tabStripLeadingInset: CGFloat = 0
    private let splitController = NSSplitViewController()
    private weak var sidebarToggleButton: NSButton?
    private var lists: [UUID: WeakBox<FileListController>] = [:]
    private var grids: [UUID: WeakBox<FileGridController>] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var closingForQuit = false
    /// Set while a window opened in the background waits for DirDesk to become active.
    private var activationObserver: NSObjectProtocol?
    var cutPending: [URL] = []
    weak var appDelegate: AppDelegate?

    init(model: WorkspaceModel) {
        self.model = model
        let window = WorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 460)
        window.title = "Wumi"
        window.identifier = NSUserInterfaceItemIdentifier("DirDesk.WorkspaceWindow")
        window.setAccessibilityIdentifier("DirDesk.WorkspaceWindow")
        super.init(window: window)
        window.delegate = self
        buildContent()
        restoreFrame()
        model.watcherChanged = { [weak self] in self?.appDelegate?.watcherHub.refresh() }
        model.$activeTabID.sink { [weak self] _ in
            DispatchQueue.main.async { self?.appDelegate?.watcherHub.refresh() }
        }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        let sidebar = NSHostingController(rootView: SidebarView(model: model, controller: self).ignoresSafeArea())
        sidebar.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.allowsFullHeightLayout = true
        let main = NSHostingController(rootView: WorkspaceMainView(model: model, controller: self))
        main.sizingOptions = []
        let mainItem = NSSplitViewItem(viewController: main)
        mainItem.minimumThickness = 520
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(mainItem)
        splitController.splitView.autosaveName = "DirDesk.WorkspaceSplit"
        splitController.splitView.dividerStyle = .thin
        window?.contentViewController = splitController
        main.view.postsFrameChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: main.view)
            .sink { [weak self] _ in self?.updateTabStripLeadingInset() }
            .store(in: &cancellables)
        window?.setContentSize(NSSize(width: 1280, height: 800))
        splitController.splitView.setPosition(200, ofDividerAt: 0)
        updateTabStripLeadingInset()
        let toggle = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: L("Toggle Sidebar"))!, target: self,
                              action: #selector(toggleSidebarFromTitlebar))
        toggle.isBordered = false
        toggle.contentTintColor = .secondaryLabelColor
        toggle.toolTip = L("Toggle Sidebar")
        toggle.setAccessibilityIdentifier("Titlebar.SidebarToggle")
        toggle.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggleButton = toggle
        if let close = window?.standardWindowButton(.closeButton), let titlebar = close.superview {
            titlebar.addSubview(toggle)
            NSLayoutConstraint.activate([
                toggle.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor, constant: 84),
                toggle.centerYAnchor.constraint(equalTo: close.centerYAnchor),
                toggle.widthAnchor.constraint(equalToConstant: 28),
                toggle.heightAnchor.constraint(equalToConstant: 28),
            ])
        }
        window?.contentView?.superview?.layoutSubtreeIfNeeded()
        updateTabStripLeadingInset()
    }

    @objc func toggleSidebarFromTitlebar() {
        splitController.toggleSidebar(nil)
    }

    private func updateTabStripLeadingInset() {
        guard let content = window?.contentView,
              let main = splitController.splitViewItems.last?.viewController.view else { return }
        // Main's separator (1), tab padding (14) and scroll content padding (2) precede the first tab.
        // Reserve the actual system controls' right edge, including the sidebar button during split animations.
        let firstTabX = main.convert(.zero, to: content).x + 17
        var controlsEnd: CGFloat = 0
        for button in [window?.standardWindowButton(.zoomButton), sidebarToggleButton].compactMap({ $0 }) {
            controlsEnd = max(controlsEnd, button.convert(button.bounds, to: content).maxX)
        }
        let inset = max(0, controlsEnd + 16 - firstTabX)
        if tabStripLeadingInset != inset { tabStripLeadingInset = inset }
    }

    private func restoreFrame() {
        guard let window else { return }
        if AppModel.shared.preferences.remembersWindowGeometry, let stored = WindowGeometryStore.frame(for: model.windowID) {
            window.setFrame(stored.rect, display: false)
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        } else {
            window.center()
        }
    }

    func show() {
        if NSApp.isActive {
            showWindow(nil)
        } else {
            // Opened while DirDesk is not the active app (launched with `open -g`, say): wait behind the app in front
            // instead of covering it, and come forward when DirDesk is activated.
            window?.orderBack(nil)
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                        queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishBackgroundShow() }
            }
        }
        (window as? WorkspaceWindow)?.layoutTrafficLights()
        model.startLoading()
        appDelegate?.watcherHub.refresh()
    }

    private func finishBackgroundShow() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if NSApp.keyWindow == nil { showWindow(nil) }
    }

    // MARK: Window delegate

    func windowDidResize(_ notification: Notification) {
        (window as? WorkspaceWindow)?.layoutTrafficLights()
        updateTabStripLeadingInset()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        (window as? WorkspaceWindow)?.layoutTrafficLights()
        updateTabStripLeadingInset()
    }
    func windowDidBecomeKey(_ notification: Notification) {
        (window as? WorkspaceWindow)?.layoutTrafficLights()
        appDelegate?.rebuildMainMenuIfNeeded()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let window, AppModel.shared.preferences.remembersWindowGeometry else { return }
        WindowGeometryStore.save(NSRectValue(window.frame), for: model.windowID)
    }

    /// Sheets hang from just below the tab strip (40 pt from the top), where the original attaches them.
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        guard let content = window.contentView else { return rect }
        return NSRect(x: rect.minX, y: content.bounds.height - 40, width: rect.width, height: 0)
    }

    func windowWillClose(_ notification: Notification) {
        model.saveNow()
        if !(appDelegate?.isTerminating ?? false) {
            // Explicitly closed windows are not restored at the next launch.
            model.sessionStore.remove(model.windowID)
            WindowGeometryStore.remove(model.windowID)
        }
        appDelegate?.windowControllerDidClose(self)
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        cancellables.removeAll()
        model.watcherChanged = nil
        // Hosted SwiftUI views keep their action controller alive. Closing an
        // NSWindow does not detach that content, so explicitly break the cycle
        // after AppKit has finished dispatching the close notification.
        DispatchQueue.main.async { [self] in
            for item in splitController.splitViewItems { splitController.removeSplitViewItem(item) }
            window?.contentViewController = nil
            window?.delegate = nil
            window = nil
        }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        appDelegate?.lastActiveController = self
    }

    // MARK: Pane views registry

    /// The list view showing `pane`, when it is in list mode.
    func listController(for pane: PaneRuntime) -> FileListController? {
        lists[pane.id]?.value
    }

    func register(list: FileListController, for pane: PaneRuntime) {
        lists[pane.id] = WeakBox(list)
    }

    func register(grid: FileGridController, for pane: PaneRuntime) {
        grids[pane.id] = WeakBox(grid)
    }

    func focusActivePaneView() {
        let pane = model.activePane
        if let list = lists[pane.id]?.value, list.view.window != nil {
            window?.makeFirstResponder(list.tableView)
        } else if let grid = grids[pane.id]?.value, grid.view.window != nil {
            window?.makeFirstResponder(grid.collectionView)
        }
    }

    // MARK: BrowserActionHandler

    func activate(pane: PaneRuntime) {
        let tab = model.activeTab
        guard tab.activePaneID != pane.id, tab.panes.contains(where: { $0.id == pane.id }) else { return }
        tab.activePaneID = pane.id
        model.scheduleSave()
    }

    func open(_ items: [FileItem], in pane: PaneRuntime, newTab: Bool) {
        let folders = items.filter(\.isBrowsableFolder)
        let files = items.filter { !$0.isBrowsableFolder }
        if let folder = folders.first {
            if newTab || folders.count > 1 {
                for (index, folder) in folders.enumerated() {
                    model.newTab(directory: folder.url, activate: index == folders.count - 1)
                }
            } else {
                pane.open(resolveAlias(folder.url))
                LibraryModel.shared.recordVisit(folder.url)
            }
            _ = folder
        }
        for file in files {
            let target = resolveAlias(file.url)
            var isDirectory: ObjCBool = false
            if file.isAliasFile, FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                pane.open(target)
                continue
            }
            // Like the original, opening a ZIP/7Z/RAR extracts it into its folder instead of handing it to another app.
            if !file.isAliasFile, ArchiveService.browsableExtensions.contains(file.fileExtension.lowercased()) {
                extract(file, to: nil)
                continue
            }
            NSWorkspace.shared.open(file.url)
            LibraryModel.shared.recordVisit(file.url)
        }
    }

    private func resolveAlias(_ url: URL) -> URL {
        (try? URL(resolvingAliasFileAt: url, options: [.withoutUI])) ?? url
    }

    func commitRename(_ item: FileItem, to name: String, in pane: PaneRuntime) {
        guard item.allowsRenaming else { pane.renamingID = nil; return }
        do {
            let renamed = try FileOperations.rename(item.url, to: name, undoManager: window?.undoManager)
            pane.reload()
            pane.select(urls: [renamed])
        } catch let error as FileOperations.OperationError {
            presentError(error.message)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func acceptDrop(_ urls: [URL], into directory: URL, operation: NSDragOperation, in pane: PaneRuntime) -> Bool {
        let move = operation == .move || (operation == .generic && urls.allSatisfy { FileOperationSupport.sameVolume($0, directory) })
        transfer(urls, to: directory, move: move)
        return true
    }

    func transfer(_ urls: [URL], to directory: URL, move: Bool) {
        appDelegate?.operations.start(.init(kind: move ? .move : .copy, sources: urls, destination: directory),
                                      undoManager: window?.undoManager) { [weak self] report in
            self?.refreshPanes(showing: [directory] + urls.map { $0.deletingLastPathComponent() })
            if !report.failures.isEmpty {
                self?.presentError(report.failures.map { "\($0.source.lastPathComponent): \($0.message)" }.joined(separator: "\n"))
            }
            if let pane = self?.model.activePane, pane.currentDirectory?.hasSamePath(as: directory) == true {
                pane.select(urls: report.createdURLs)
            }
        }
    }

    func refreshPanes(showing directories: [URL]) {
        let paths = Set(directories.map { $0.standardizedFileURL.path })
        for pane in model.allPanes where pane.loadState != .idle {
            if let current = pane.currentDirectory?.standardizedFileURL.path, paths.contains(current) {
                pane.reload()
            }
            for path in paths where pane.expandedPaths.contains(path) { pane.directoryChanged(path) }
        }
    }

    // MARK: Navigation helpers

    func navigateActivePane(to url: URL) {
        model.activePane.open(url)
        LibraryModel.shared.recordVisit(url)
        focusActivePaneView()
    }

    func navigateActivePane(toTag name: String) {
        model.activePane.navigate(to: .tag(name))
    }

    func openRecent() {
        model.activePane.navigate(to: .recent(.preset(.week)))
    }

    func newTab(directory: URL? = nil, after reference: UUID? = nil) {
        model.newTab(directory: directory, after: reference)
    }

    func closeTab(_ id: UUID) {
        if !model.closeTab(id) { window?.performClose(nil) }
    }

    func removeDuplicateTabs() {
        var removed = model.removeDuplicateTabs()
        for other in appDelegate?.controllers ?? [] where other !== self {
            let paths = Set(model.tabs.filter { $0.panes.count == 1 }.compactMap { $0.activePane.currentDirectory?.path })
            for tab in other.model.tabs where tab.panes.count == 1 && !tab.isPinned {
                if let path = tab.activePane.currentDirectory?.path, paths.contains(path), other.model.closeTab(tab.id) { removed += 1 }
            }
        }
        model.activePane.operationMessage = removed > 0 ? L("Duplicate tabs removed") : L("No duplicate tabs")
        clearOperationMessage(after: 3)
    }

    func clearOperationMessage(after seconds: Double) {
        let pane = model.activePane
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { pane.operationMessage = nil }
    }

    func renameTab(_ id: UUID) {
        guard let tab = model.tabs.first(where: { $0.id == id }) else { return }
        if let name = promptText(title: L("Rename Tab"), message: nil, initial: tab.title) {
            tab.customTitle = name.isEmpty ? nil : name
            model.scheduleSave()
        }
    }

    func moveTabToNewWindow(_ id: UUID) {
        guard let state = model.detachTab(id) else { return }
        appDelegate?.openWindow(with: state)
    }

    func setLayout(_ layout: PaneLayout) {
        model.activeTab.setLayout(layout, configuration: model.activePane.viewConfiguration)
        model.allPanes.forEach(model.attach)
        appDelegate?.watcherHub.refresh()
    }

    // MARK: Alerts and prompts

    func presentError(_ message: String, source: ApplicationErrorLog.Source = .fileOperation) {
        ApplicationErrorLog.shared.record(message: message, source: source)
        if UserDefaults.standard.bool(forKey: DefaultsKey.operationErrorSound) {
            NSSound.beep()
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("The operation could not be completed.")
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func promptText(title: String, message: String?, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let message { alert.informativeText = message }
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func loadURLs(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let url = object as? URL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion(urls) }
        }
    }

    func dropProviders(_ providers: [NSItemProvider], into directory: URL) -> Bool {
        loadURLs(from: providers) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            let sameVolume = urls.allSatisfy { FileOperationSupport.sameVolume($0, directory) }
            var move = sameVolume
            if NSEvent.modifierFlags.contains(.shift), AppModel.shared.preferences.shiftDragReversesOperation { move.toggle() }
            if NSEvent.modifierFlags.contains(.option) { move = false }
            if directory.path.hasSuffix("/.Trash") {
                FileOperations.trash(urls, undoManager: self.window?.undoManager) { _ in self.refreshPanes(showing: urls.map { $0.deletingLastPathComponent() }) }
            } else {
                self.transfer(urls, to: directory, move: move)
            }
        }
        return true
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
