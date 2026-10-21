import AppKit
import Combine
import DirDeskCore
import SwiftUI

/// Floating panel that stays above other apps and can become key for keyboard navigation.
final class FloatingFilesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Borderless windows are otherwise left out of the app's accessibility window list.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .window }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .floatingWindow }
    override func accessibilityTitle() -> String? { title }
}

/// Floating Files: a mini browser plus the staging shelf (File Transit), opened by the global
/// shortcut, the menu bar item, the sidebar entry or a screen-edge hot zone.
@MainActor
final class FloatingFilesController: NSObject, NSWindowDelegate, BrowserActionHandler, ObservableObject {
    static let shared = FloatingFilesController()

    private var panel: FloatingFilesPanel?
    let pane: PaneRuntime
    weak var appDelegate: AppDelegate?
    private var cancellables: Set<AnyCancellable> = []
    /// "Keep Open": when off, the window hides as soon as another window or app takes focus.
    @Published var keepsOpen = false

    private override init() {
        let store = FileFloatingStore.shared
        let start = store.configuration.lastDirectory.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var configuration = ViewConfiguration()
        configuration.mode = store.configuration.viewMode
        configuration.visibleListColumns = [.name, .modificationDate, .size]
        pane = PaneRuntime(directory: start, configuration: configuration)
        super.init()
        pane.onStateChange = { [weak self] in self?.persistLocation() }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    @Published private(set) var sizeObservationEnabled = false
    private var browserVisible = false

    func setBrowserVisible(_ visible: Bool) {
        browserVisible = visible
        updateSizeObservation()
    }

    private func updateSizeObservation() {
        let enabled = isVisible && browserVisible
        if sizeObservationEnabled != enabled { sizeObservationEnabled = enabled }
        pane.setSizeObservationActive(enabled)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// Opens with the window's top-left just under `anchor` (the menu bar icon), like the original.
    func show(below anchor: NSRect) {
        show()
        guard let panel, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: anchor.minX, y: min(anchor.minY, visible.maxY) - panel.frame.height)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        panel.setFrameOrigin(origin)
    }

    func show() {
        if panel == nil { buildPanel() }
        guard let panel else { return }
        if pane.loadState == .idle { pane.load() }
        position(panel)
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        updateSizeObservation()
        activateApp()
        appDelegate?.watcherHub.refresh()
        // The Staging tab rechecks its files (they may have moved while the window was hidden).
        if FileTransitStore.shared.shelfView?.window != nil { FileTransitStore.shared.shelfDidAppear() }
    }

    func hide() {
        panel?.orderOut(nil)
        updateSizeObservation()
    }

    /// Borderless dark rounded window (the original has no title bar: its own tabs and Close button sit on top).
    private func buildPanel() {
        let configuration = FileFloatingStore.shared.configuration
        let panel = FloatingFilesPanel(contentRect: NSRect(x: 0, y: 0, width: configuration.panelWidth, height: configuration.panelHeight),
                                       styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = L("Floating Files")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 520, height: 280)
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("DirDesk.FloatingFiles")
        panel.setAccessibilityTitle(L("Floating Files"))
        panel.contentView = NSHostingView(rootView: FloatingFilesView(pane: pane, controller: self))
        applyOpacity()
        AppModel.shared.$configuration.sink { [weak self] _ in self?.applyOpacity() }.store(in: &cancellables)
        FileFloatingStore.shared.$configuration.sink { [weak self] configuration in
            guard let self, let panel = self.panel, !panel.inLiveResize else { return }
            let size = NSSize(width: configuration.panelWidth, height: configuration.panelHeight)
            if panel.frame.size != size {
                panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height), display: true)
            }
        }.store(in: &cancellables)
        self.panel = panel
    }

    /// Window opacity follows the File Transit setting (Reduce Transparency keeps it opaque).
    private func applyOpacity() {
        let opacity = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1 : AppModel.shared.preferences.fileTransitPanelOpacity
        panel?.alphaValue = CGFloat(max(0.4, opacity))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Sheets (settings) and open panels keep it visible; otherwise an unpinned window steps aside.
        guard !keepsOpen, let panel, panel.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !panel.isKeyWindow, panel.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            if NSApp.keyWindow?.identifier?.rawValue == "SuperPreview.Window" { return }
            // Quick Look opened from this window (Staging or the folder browser) keeps it open.
            if NSApp.keyWindow is QLPreviewPanel { return }
            self.hide()
        }
    }

    // MARK: Helpers for the view

    var panelFrame: NSRect { panel?.frame ?? .zero }

    /// Bottom-left grip: dragging left/down grows the window while its top-right corner stays put.
    func resizePanel(from start: NSRect, by translation: CGSize) {
        guard let panel else { return }
        let width = max(panel.minSize.width, start.width - translation.width)
        let height = max(panel.minSize.height, start.height + translation.height)
        panel.setFrame(NSRect(x: start.maxX - width, y: start.maxY - height, width: width, height: height), display: true)
    }

    func persistPanelSize() {
        guard let frame = panel?.frame else { return }
        FileFloatingStore.shared.configuration.panelWidth = frame.width
        FileFloatingStore.shared.configuration.panelHeight = frame.height
    }

    @ViewBuilder
    func browserView() -> some View {
        switch pane.viewConfiguration.mode {
        case .icons, .images: FloatingGridHost(pane: pane, controller: self)
        case .columns: FloatingColumnHost(pane: pane, controller: self)
        case .list: FloatingListHost(pane: pane, controller: self)
        }
    }

    func superPreview(_ items: [FileItem]) {
        guard let item = items.first, let controller = appDelegate?.activeController ?? appDelegate?.controllers.first else { return }
        SuperPreviewController.shared.show(item, controller: controller)
    }

    func share(_ items: [FileItem]) {
        guard let view = panel?.contentView, !items.isEmpty else { return }
        NSSharingServicePicker(items: items.map(\.url)).show(relativeTo: NSRect(x: view.bounds.maxX - 200, y: 8, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    /// "Show in DirDesk": the selection (or the current folder) in the main window.
    func showInMainWindow(_ items: [FileItem]) {
        let targets = items.isEmpty ? [pane.currentDirectory].compactMap { $0 } : items.map(\.url)
        guard !targets.isEmpty else { return }
        if !keepsOpen { hide() }
        if let controller = appDelegate?.activeController ?? appDelegate?.controllers.first, let first = targets.first {
            let folder = items.isEmpty ? first : first.deletingLastPathComponent()
            controller.navigateActivePane(to: folder)
            if !items.isEmpty { controller.activePane.select(urls: targets) }
            controller.window?.makeKeyAndOrderFront(nil)
            activateApp()
        } else {
            appDelegate?.openExternally(targets)
        }
    }

    /// Opens a folder (`select` false) or shows an item in its folder (`select` true) in the frontmost DirDesk window.
    func showInMainWindow(url: URL, select: Bool) {
        if !keepsOpen { hide() }
        let folder = select ? url.deletingLastPathComponent() : url
        if let controller = appDelegate?.activeController ?? appDelegate?.controllers.first {
            controller.navigateActivePane(to: folder)
            if select { controller.activePane.select(urls: [url]) }
            controller.window?.makeKeyAndOrderFront(nil)
        } else if let delegate = appDelegate {
            let controller = delegate.newWindow(directory: folder)
            if select { controller.activePane.select(urls: [url]) }
        }
        activateApp()
    }

    /// Opens below the menu bar near the top center of the screen under the pointer.
    private func position(_ panel: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // Top: centred, its top edge right on the menu bar, as the original opens it from the sidebar.
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height)
        switch AppModel.shared.preferences.fileTransitDockEdge {
        case .top: break
        case .left: origin = NSPoint(x: visible.minX + 8, y: visible.midY - size.height / 2)
        case .right: origin = NSPoint(x: visible.maxX - size.width - 8, y: visible.midY - size.height / 2)
        }
        panel.setFrameOrigin(origin)
    }

    func windowDidEndLiveResize(_ notification: Notification) { persistPanelSize() }

    private func persistLocation() {
        if let directory = pane.currentDirectory, FileFloatingStore.shared.configuration.lastDirectory != directory {
            FileFloatingStore.shared.configuration.lastDirectory = directory
        }
        if FileFloatingStore.shared.configuration.viewMode != pane.viewConfiguration.mode {
            FileFloatingStore.shared.configuration.viewMode = pane.viewConfiguration.mode
        }
        appDelegate?.watcherHub.refresh()
    }

    // MARK: BrowserActionHandler

    func activate(pane: PaneRuntime) {}

    func open(_ items: [FileItem], in pane: PaneRuntime, newTab: Bool) {
        if let folder = items.first(where: \.isBrowsableFolder) {
            pane.open(folder.url)
        }
        for file in items where !file.isBrowsableFolder { NSWorkspace.shared.open(file.url) }
    }

    func contextMenu(for items: [FileItem], in pane: PaneRuntime) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Open"), symbol: "arrow.up.forward.square") { [weak self] in self?.open(items, in: pane, newTab: false) })
        menu.addItem(ClosureMenuItem(L("Add to File Transit"), symbol: "shippingbox") { FileTransitStore.shared.add(items.map(\.url)) })
        menu.addItem(ClosureMenuItem(L("Copy"), symbol: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(items.map { $0.url as NSURL })
        })
        menu.addItem(ClosureMenuItem(L("Reveal in Finder"), symbol: "macwindow") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) })
        menu.addItem(ClosureMenuItem(L("Quick Look"), symbol: "eye") { [weak self] in self?.quickLook() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Open in Wumi"), symbol: "macwindow.badge.plus") { [weak self] in
            self?.appDelegate?.openExternally(items.map(\.url))
        })
        return menu
    }

    func backgroundMenu(in pane: PaneRuntime) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Refresh"), symbol: "arrow.clockwise") { pane.reload() })
        if let directory = pane.currentDirectory {
            menu.addItem(ClosureMenuItem(L("Open in Wumi"), symbol: "macwindow.badge.plus") { [weak self] in
                self?.appDelegate?.openExternally([directory])
            })
        }
        return menu
    }

    func commitRename(_ item: FileItem, to name: String, in pane: PaneRuntime) {
        if let renamed = try? FileOperations.rename(item.url, to: name, undoManager: panel?.undoManager) {
            pane.reload()
            pane.select(urls: [renamed])
        }
    }

    func perform(_ command: ShortcutCommand) {
        switch command {
        case .navigateUp: pane.goUp()
        case .navigateBack: pane.goBack()
        case .navigateForward: pane.goForward()
        case .quickLook: quickLook()
        default: break
        }
    }

    func previewWithSpace(_ items: [FileItem], in pane: PaneRuntime) -> Bool { false }

    func acceptDrop(_ urls: [URL], into directory: URL, operation: NSDragOperation, in pane: PaneRuntime) -> Bool {
        appDelegate?.operations.start(.init(kind: operation == .move ? .move : .copy, sources: urls, destination: directory),
                                      undoManager: panel?.undoManager) { _ in pane.reload() }
        return true
    }

    private func quickLook() {
        guard let panel = QLPreviewPanelBridge.panel else { return }
        panel.isVisible ? panel.orderOut(nil) : panel.makeKeyAndOrderFront(nil)
    }
}

import Quartz

enum QLPreviewPanelBridge {
    static var panel: QLPreviewPanel? { QLPreviewPanel.shared() }
}

private struct FloatingListHost: NSViewControllerRepresentable {
    let pane: PaneRuntime
    @ObservedObject var controller: FloatingFilesController
    func makeNSViewController(context: Context) -> FileListController {
        let browser = FileListController(pane: pane, handler: controller)
        browser.setSizeRequestsEnabled(controller.sizeObservationEnabled)
        return browser
    }
    func updateNSViewController(_ browser: FileListController, context: Context) { browser.setSizeRequestsEnabled(controller.sizeObservationEnabled) }
    static func dismantleNSViewController(_ browser: FileListController, coordinator: ()) { browser.stopSizeRequests() }
}

private struct FloatingGridHost: NSViewControllerRepresentable {
    let pane: PaneRuntime
    @ObservedObject var controller: FloatingFilesController
    func makeNSViewController(context: Context) -> FileGridController {
        let browser = FileGridController(pane: pane, handler: controller, gallery: false)
        browser.setSizeRequestsEnabled(controller.sizeObservationEnabled)
        return browser
    }
    func updateNSViewController(_ browser: FileGridController, context: Context) { browser.setSizeRequestsEnabled(controller.sizeObservationEnabled) }
    static func dismantleNSViewController(_ browser: FileGridController, coordinator: ()) { browser.stopSizeRequests() }
}

private struct FloatingColumnHost: NSViewControllerRepresentable {
    let pane: PaneRuntime
    let controller: FloatingFilesController
    func makeNSViewController(context: Context) -> ColumnBrowserController { ColumnBrowserController(pane: pane, handler: controller) }
    func updateNSViewController(_ nsViewController: ColumnBrowserController, context: Context) {}
}
