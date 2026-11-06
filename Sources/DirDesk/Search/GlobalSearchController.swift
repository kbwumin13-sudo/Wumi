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
        if panel?.isVisible == true, panel?.isKeyWindow == true { hide() } else { show() }
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
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            let width = model.panelWidth
            let height = model.panelHeight
            panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 70,
                                  width: width, height: height), display: false)
        }
        model.setSearchVisible(true)
        LightningSearchService.shared.ensureStarted()
        NSApp.unhideWithoutActivation()
        panel.makeKeyAndOrderFront(nil)
        // The panel is on screen now; its occlusion report follows a moment later.
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

    func hide(returnFocus: Bool = true) {
        model?.setSearchVisible(false)
        panel?.orderOut(nil)
        if returnFocus {
            if let previousWindow, previousWindow.isVisible { previousWindow.makeKeyAndOrderFront(nil) }
            previousApplication?.activate()
        }
        previousApplication = nil
        previousWindow = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible,
                  !panel.isKeyWindow, panel.attachedSheet == nil else { return }
            // Preview panels and context menus keep the search context alive.
            if let key = NSApp.keyWindow, key !== panel,
               key.parent === panel || key.identifier?.rawValue == "SuperPreview.Window"
                || key.className.contains("Popover") { return }
            self.hide(returnFocus: false)
        }
    }

    func shutdown() { hide(returnFocus: false); GlobalHotKey.shared.unregister(.search) }

    private func createPanel() {
        let model = MijiSearchModel()
        model.onDismiss = { [weak self] in self?.hide(returnFocus: false) }
        model.onReveal = { FileOpenRouter.reveal($0) }
        let panel = GlobalSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 100),
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
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.identifier = NSUserInterfaceItemIdentifier("Wumi.GlobalSearch")
        panel.delegate = self
        panel.model = model
        panel.onEscape = { [weak self] in self?.hide() }
        panel.onSettings = { [weak self] in self?.showSettings() }
        let hosting = NSHostingView(rootView: MijiSearchView(model: model, onDismiss: { [weak self] in self?.hide() },
            onAdvanced: { [weak self] in self?.showAdvanced() }, onSettings: { [weak self] in self?.showSettings() }))
        hosting.sizingOptions = []
        panel.contentView = hosting
        Publishers.CombineLatest4(model.$query,model.$hits,model.$previewEnabled,model.$gridEnabled)
            .sink { [weak panel,weak model] _ in
                DispatchQueue.main.async {
                    guard let panel,let model else{return}
                    let old=panel.frame,width=model.panelWidth,height=model.panelHeight
                    let screen=(panel.screen ?? NSScreen.main)?.visibleFrame ?? old
                    let x=min(max(screen.minX,old.midX-width/2),max(screen.minX,screen.maxX-width))
                    let y=min(max(screen.minY,old.maxY-height),max(screen.minY,screen.maxY-height))
                    panel.setFrame(NSRect(x:x,y:y,width:width,height:height),display:true)
                }
            }.store(in:&cancellables)
        self.model = model
        self.panel = panel
    }

    private func showAdvanced() {
        let scope = model?.context
        hide(returnFocus: false)
        FileOpenRouter.delegate?.windows.showAdvancedSearch(scope: scope, controller: FileOpenRouter.delegate?.activeController)
    }

    private func showSettings() {
        hide(returnFocus: false)
        FileOpenRouter.delegate?.windows.showSettings(section: "lightningSearch")
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

final class GlobalSearchPanel: NSPanel {
    weak var model: MijiSearchModel?
    var onEscape: (() -> Void)?
    var onSettings: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let model {
            switch MijiSearchKeyAction.action(for: event, firstResponder: firstResponder) {
            case .focusSearch: model.focusSearch = UUID()
            case .reveal: model.revealSelected()
            case .preview: model.previewSelected()
            case .copyPath: model.copySelectedPath()
            case .copyFile: model.copySelectedFile()
            case .moveLeft: if model.gridEnabled {model.moveSelection(-1)}else{super.sendEvent(event)}
            case .moveRight: if model.gridEnabled {model.moveSelection(1)}else{super.sendEvent(event)}
            case .hide: onEscape?()
            case .settings: onSettings?()
            case .moveDown: model.moveSelection(model.gridEnabled ? model.gridColumns : 1)
            case .moveUp: model.moveSelection(model.gridEnabled ? -model.gridColumns : -1)
            case .open: model.openSelected()
            case nil: super.sendEvent(event)
            }
            return
        }
        super.sendEvent(event)
    }
}
