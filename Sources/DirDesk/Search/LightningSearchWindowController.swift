import AppKit
import Combine
import SwiftUI

/// Opens Lightning Search windows. Each call reuses the frontmost unpinned search window, or opens a new one
/// when every open window is pinned (up to `maximumWindows`).
@MainActor
enum LightningSearchPresenter {
    static let maximumWindows = 8
    private static var controllers: [LightningSearchWindowController] = []

    /// - Parameters:
    ///   - scope: the active pane's folder, offered as the Current Folder scope.
    ///   - workspace: the folders of the current workspace, offered as the Current Workspace scope.
    ///   - openHandler: `reveal == true` goes to the item's location; `false` opens it.
    static func show(scope: URL?, workspace: [URL], openHandler: @escaping (URL, _ reveal: Bool) -> Void) {
        LightningSearchService.shared.ensureStarted()
        if let reusable = controllers.last(where: { !$0.model.isPinned && !$0.isClosed }) {
            reusable.model.updateContext(currentFolder: scope, workspace: workspace, openHandler: openHandler)
            reusable.present(cascadingFrom: nil)
            return
        }
        guard controllers.filter({ !$0.isClosed }).count < maximumWindows else {
            let alert = NSAlert()
            alert.messageText = L("Too many search windows are open. Close another search window and try again.")
            alert.addButton(withTitle: L("OK"))
            if let window = NSApp.keyWindow, window.attachedSheet == nil {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        let model = LightningSearchModel(currentFolder: scope, workspace: workspace, openHandler: openHandler)
        let controller = LightningSearchWindowController(model: model)
        let previous = controllers.last?.window
        controllers.append(controller)
        controller.onClose = { closed in
            // Deferred: the controller is still running its windowWillClose when this is called.
            Task { @MainActor in controllers.removeAll { $0 === closed } }
        }
        controller.present(cascadingFrom: previous)
    }

    /// Number of open search windows.
    static var windowCount: Int { controllers.filter { !$0.isClosed }.count }
}

/// Escape closes the window from anywhere inside it, unless an input method is composing text.
final class LightningSearchWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, attachedSheet == nil,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           !((firstResponder as? NSTextView)?.hasMarkedText() ?? false) {
            performClose(nil)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class LightningSearchWindowController: NSWindowController, NSWindowDelegate {
    static let frameName = "DirDesk.LightningSearch.Frame"
    /// The original's window: 980 × 712 points.
    static let defaultSize = NSSize(width: 980, height: 712)

    let model: LightningSearchModel
    var onClose: ((LightningSearchWindowController) -> Void)?
    private(set) var isClosed = false
    private var cancellables: Set<AnyCancellable> = []
    private var advancedPanel: LightningAdvancedPanelController?

    init(model: LightningSearchModel) {
        self.model = model
        let window = LightningSearchWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                           backing: .buffered, defer: false)
        window.title = L("Lightning Search")
        window.minSize = NSSize(width: 780, height: 520)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("DirDesk.LightningSearchWindow")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: LightningSearchView(model: model))
        window.setFrame(NSRect(origin: window.frame.origin, size: Self.defaultSize), display: false)
        model.window = window
        model.$isPinned.removeDuplicates().sink { [weak self] pinned in self?.applyPin(pinned) }.store(in: &cancellables)
        model.$showsAdvanced.removeDuplicates().dropFirst().sink { [weak self] shows in self?.showAdvanced(shows) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(cascadingFrom previous: NSWindow?) {
        guard let window else { return }
        if !window.isVisible {
            if let previous {
                window.setContentSize(previous.contentLayoutRect.size)
                window.setFrameTopLeftPoint(NSPoint(x: previous.frame.minX + 26, y: previous.frame.maxY - 26))
            } else if !window.setFrameUsingName(Self.frameName) {
                window.center()
            }
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        activateApp()
        model.focus.focusSearchField(selectAll: true)
    }

    /// Pinned windows float above other windows and stay visible when another app is active.
    private func applyPin(_ pinned: Bool) {
        guard let window else { return }
        window.level = pinned ? .floating : .normal
        if pinned {
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            window.collectionBehavior.remove(.fullScreenAuxiliary)
        }
        advancedPanel?.updateLevel()
    }

    private func showAdvanced(_ shows: Bool) {
        guard let window else { return }
        if shows {
            let panel = advancedPanel ?? LightningAdvancedPanelController(model: model, parent: window)
            panel.onResignKey = { [weak self] in self?.scheduleCloseCheck() }
            advancedPanel = panel
            panel.show()
        } else {
            advancedPanel?.hide()
        }
    }

    // MARK: Closing when unpinned

    /// An unpinned window closes when the user clicks outside it (and outside its Advanced Search panel): in
    /// another window of this app or in another app. Its own sheets, panels (Advanced Search, previews, open
    /// panels), popovers and menus do not count.
    func windowDidResignKey(_ notification: Notification) {
        scheduleCloseCheck()
    }

    private func scheduleCloseCheck() {
        guard !model.isPinned else { return }
        DispatchQueue.main.async { [weak self] in self?.closeIfFocusMovedAway() }
    }

    private func closeIfFocusMovedAway() {
        guard let window, window.isVisible, !window.isKeyWindow, advancedPanel?.panel?.isKeyWindow != true, !model.isPinned,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        if NSApp.isActive {
            guard let key = NSApp.keyWindow, !(key is NSPanel), key.sheetParent == nil, key.parent == nil,
                  !NSStringFromClass(type(of: key)).contains("Popover") else { return }
        }
        window.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        window?.saveFrame(usingName: Self.frameName)
        advancedPanel?.close()
        advancedPanel = nil
        model.windowWillClose()
        onClose?(self)
        onClose = nil
    }
}
