import AppKit
import Carbon
import Combine
import DirDeskCore
import SwiftUI

struct GlobalSearchConfiguration: Codable, Equatable {
    var enabled = true
    var keyCode = UInt32(kVK_Space)
    var modifiers = UInt32(controlKey | optionKey)
    var label: String { FileFloatingConfiguration.label(keyCode: keyCode, modifiers: modifiers) }
}

@MainActor
final class GlobalSearchController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = GlobalSearchController()
    @Published var configuration: GlobalSearchConfiguration {
        didSet { try? store.save(configuration); registerShortcut() }
    }
    @Published private(set) var shortcutError: String?
    private let store = PersistenceStore<GlobalSearchConfiguration>(key: "dirdesk-global-search-v1") { GlobalSearchConfiguration() }
    private var panel: GlobalSearchPanel?
    private var model: MijiSearchModel?
    private var previousApplication: NSRunningApplication?
    private weak var previousWindow: NSWindow?
    private var lastSummon: ContinuousClock.Instant?
    private(set) var lastSummonMilliseconds: Double?
    private var acceptanceSummons: [[String: Any]] = []
    private var cancellables: Set<AnyCancellable> = []

    private override init() {
        configuration = store.load().value
        super.init()
    }

    func install() { registerShortcut() }

    func registerShortcut() {
        guard !UserDefaults.standard.bool(forKey: "DirDeskSnapshotHidden") else { return }
        guard configuration.enabled else {
            GlobalHotKey.shared.unregister(.search)
            shortcutError = nil
            return
        }
        let result = GlobalHotKey.shared.register(.search, keyCode: configuration.keyCode, modifiers: configuration.modifiers) {
            GlobalSearchController.shared.toggle()
        }
        shortcutError = result == noErr ? nil : L("The search shortcut is already in use. Choose another shortcut or open search from the menu bar.")
    }

    func toggle() {
        if panel?.isVisible == true, panel?.isKeyWindow == true, panel?.isDismissing == false { hide() } else { show() }
    }

    func show(scope: URL? = nil) {
        lastSummon = .now
        if panel?.isVisible != true {
            let source = NSWorkspace.shared.frontmostApplication
            let fromWumi = source?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            previousApplication = fromWumi ? nil : source
            previousWindow = fromWumi && NSApp.keyWindow !== panel ? NSApp.keyWindow : nil
        }
        if panel == nil { createPanel() }
        guard let panel, let model else { return }
        model.context = scope
        model.currentFolderOnly = false
        let entering = !panel.isVisible || panel.isDismissing
        model.setSearchVisible(true)
        let target = frame(for: panel, model: model, centered: entering)
        if entering {
            model.panelActivation = UUID()
            panel.prepareEntrance(at: target, compact: model.mode == .all && model.query.isEmpty)
        }
        LightningSearchService.shared.ensureStarted()
        NSApp.unhideWithoutActivation()
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        panel.reveal(at: target, entering: entering)
        model.setWindowVisible(true)
        model.focusSearch = UUID()
        DispatchQueue.main.async { [weak self] in
            guard let self, let start = self.lastSummon else { return }
            self.model?.focusSearch = UUID()
            self.lastSummonMilliseconds = Self.milliseconds(start.duration(to: .now))
            if let path = UserDefaults.standard.string(forKey: "WumiGlobalSearchTelemetry"), let panel = self.panel {
                self.acceptanceSummons.append(["milliseconds": self.lastSummonMilliseconds ?? 0,
                                               "inputFocused": panel.firstResponder is NSTextView,
                                               "keyWindow": panel.isKeyWindow, "visible": panel.isVisible])
                self.acceptanceSummons = Array(self.acceptanceSummons.suffix(200))
                if let data = try? JSONSerialization.data(withJSONObject: self.acceptanceSummons, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        }
    }

    private func frame(for panel: GlobalSearchPanel, model: MijiSearchModel, centered: Bool) -> NSRect {
        let anchor = panel.destinationFrame
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let screen = (centered ? (mouseScreen ?? NSScreen.main) : (panel.screen ?? NSScreen.main))?.visibleFrame ?? anchor
        let width = min(model.floatingWidth, screen.width)
        let height = min(model.floatingHeight, screen.height)
        let leading = (centered ? screen.midX : anchor.midX) - width / 2
        let top = centered ? screen.maxY - 153 : anchor.maxY
        let x = min(max(screen.minX, leading), screen.maxX - width)
        let y = min(max(screen.minY, top - height), screen.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    func hide(returnFocus: Bool = true, animated: Bool = true) {
        guard let panel else { return }
        model?.setSearchVisible(false)
        panel.dismiss(animated: animated) { [weak self] in
            guard let self else { return }
            let window = self.previousWindow
            let application = self.previousApplication
            self.previousApplication = nil
            self.previousWindow = nil
            if returnFocus {
                if let window, window.isVisible { window.makeKeyAndOrderFront(nil) }
                if let application, !application.isActive { application.activate() }
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible,
                  !panel.isKeyWindow, !panel.isDismissing, panel.attachedSheet == nil else { return }
            // Preview panels and context menus keep the search context alive.
            if let key = NSApp.keyWindow, key !== panel,
               key.parent === panel || key.identifier?.rawValue == "SuperPreview.Window"
                || key.className.contains("Popover") { return }
            self.hide(returnFocus: false)
        }
    }

    func shutdown() { hide(returnFocus: false, animated: false); GlobalHotKey.shared.unregister(.search) }

    private func createPanel() {
        let model = MijiSearchModel()
        model.onDismiss = { [weak self] in self?.hide(returnFocus: false, animated: false) }
        model.onReveal = { FileOpenRouter.reveal($0) }
        let panel = GlobalSearchPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.compactWidth, height: PanelMetrics.searchHeight),
                                      styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
        panel.title = "觅迹"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = true
        panel.identifier = NSUserInterfaceItemIdentifier("Wumi.GlobalSearch")
        panel.delegate = self
        panel.model = model
        panel.onEscape = { [weak self] in self?.hide() }
        panel.onSettings = { [weak self] in self?.showSettings() }
        panel.onApplication = { [weak self] in self?.openApplication($0) }
        panel.onClipboardEntry = { [weak self] in self?.copyClipboardEntry($0) }
        let hosting = NSHostingView(rootView: Miji140SearchView(
            model: model,
            onSettings: { [weak self] in self?.showSettings() },
            onAdvanced: { [weak self] in self?.showAdvanced() },
            onApplication: { [weak self] in self?.openApplication($0) },
            onClipboardEntry: { [weak self] in self?.copyClipboardEntry($0) },
            shortcutLabel: configuration.label
        ))
        hosting.sizingOptions = []
        panel.contentView = hosting
        Publishers.Merge(
            Publishers.CombineLatest4(model.$query, model.$hits, model.$previewMode, model.$gridEnabled).map { _ in () },
            Publishers.CombineLatest(model.$mode, model.$showsFileSelectionFeedback).map { _ in () }
        )
        .sink { [weak self, weak panel, weak model] in
            DispatchQueue.main.async {
                guard let self, let panel, let model, panel.isVisible, !panel.isDismissing else { return }
                panel.resize(to: self.frame(for: panel, model: model, centered: false))
            }
        }.store(in: &cancellables)
        self.model = model
        self.panel = panel
    }

    private func showAdvanced() {
        let scope = model?.context
        hide(returnFocus: false, animated: false)
        FileOpenRouter.delegate?.windows.showAdvancedSearch(scope: scope, controller: FileOpenRouter.delegate?.activeController)
    }

    private func showSettings() {
        hide(returnFocus: false, animated: false)
        FileOpenRouter.delegate?.windows.showSettings(section: "lightningSearch")
    }

    private func openApplication(_ application: InstalledApp) {
        if NSWorkspace.shared.open(application.url) { hide(returnFocus: false, animated: false) }
        else { model?.message = "未能打开「\(application.title)」" }
    }

    private func copyClipboardEntry(_ entry: ClipboardEntry) {
        if model?.browse.copyClipboardEntry(entry) == true { hide() }
        else { model?.message = "无法写入剪贴板。" }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

final class GlobalSearchPanel: Miji140SearchPanel {
    weak var model: MijiSearchModel?
    var onEscape: (() -> Void)?
    var onSettings: (() -> Void)?
    var onApplication: ((InstalledApp) -> Void)?
    var onClipboardEntry: ((ClipboardEntry) -> Void)?

    override func cancelOperation(_ sender: Any?) { if let model { escape(model) } }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, let model else { super.sendEvent(event); return }
        guard !isDismissing else { return }
        let horizontal = (model.mode == .apps || model.browsingRecent) && model.query.isEmpty
        switch SearchKeyAction.action(for: event, firstResponder: firstResponder, navigateHorizontally: horizontal) {
        case .selectMode(let mode): model.selectMode(mode)
        case .focusSearch: model.focusSearch = UUID()
        case .reveal:
            if model.mode == .apps, let app = selectedApplication(model) {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            } else { model.revealSelected() }
        case .preview: model.previewSelected()
        case .copyPath: model.copySelectedPath()
        case .copyFile: model.copySelectedFile()
        case .moveLeft, .moveRight:
            let step = event.keyCode == 123 ? -1 : 1
            if model.mode == .apps { model.browse.moveApps(step, query: model.query) }
            else if model.showsFileGrid || model.browsingRecent { model.moveSelection(step) }
            else { super.sendEvent(event) }
        case .hide: escape(model)
        case .settings: onSettings?()
        case .moveDown: move(1, model: model)
        case .moveUp: move(-1, model: model)
        case .open:
            switch model.mode {
            case .apps: if let app = selectedApplication(model) { onApplication?(app) }
            case .clipboard:
                let entries = model.browse.visibleClipboard(query: model.query)
                if let entry = entries.first(where: { $0.id == model.browse.clipboardSelection }) ?? entries.first {
                    onClipboardEntry?(entry)
                }
            case .all, .files: model.openSelected()
            }
        case nil: super.sendEvent(event)
        }
    }

    private func escape(_ model: MijiSearchModel) {
        if model.mode == .all { onEscape?() }
        else if model.browsingRecent && model.previewVisible {
            model.clearSelectionFeedback()
            model.focusSearch = UUID()
        } else { model.selectMode(.all) }
    }

    private func selectedApplication(_ model: MijiSearchModel) -> InstalledApp? {
        let apps = model.browse.visibleApps(query: model.query)
        return apps.first(where: { $0.id == model.browse.appSelection }) ?? apps.first
    }

    private func move(_ direction: Int, model: MijiSearchModel) {
        switch model.mode {
        case .apps: model.browse.moveApps(direction * InstalledApp.gridColumns, query: model.query)
        case .clipboard: model.browse.moveClipboard(direction, query: model.query)
        case .all, .files:
            if model.browsingRecent, !model.hits.isEmpty {
                let featuredCount = min(5, model.hits.count)
                if !model.showsFileSelectionFeedback {
                    let target = direction > 0 ? (model.hits.count > featuredCount ? featuredCount : 0) : model.hits.count - 1
                    model.selectFile(model.hits[target].id)
                } else if let current = model.hits.firstIndex(where: { $0.id == model.selectedID }),
                          direction > 0, current < featuredCount, model.hits.count > featuredCount {
                    model.selectFile(model.hits[featuredCount].id)
                } else if direction < 0, model.hits.firstIndex(where: { $0.id == model.selectedID }) == featuredCount {
                    model.selectFile(model.hits[0].id)
                } else { model.moveSelection(direction) }
            } else { model.moveSelection(direction * (model.showsFileGrid ? model.floatingGridColumns : 1)) }
        }
    }
}
