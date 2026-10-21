import AppKit
import DirDeskCore
import SwiftUI

/// One built-in tool interaction attached to a workspace window. It owns the sheet that shows the
/// options, progress and report views in turn, keeps temporary files until the interaction ends,
/// and enforces one tool operation per window.
@MainActor
final class BuiltInToolSession {
    private static var sessions: [ObjectIdentifier: BuiltInToolSession] = [:]

    /// Usable size of option sheets; larger sheets are shrunk to fit the parent window down to this.
    nonisolated static let minimumSheetSize = NSSize(width: 560, height: 460)

    let tool: BuiltInToolID
    private(set) weak var controller: WorkspaceController?
    private let key: ObjectIdentifier
    private var sheet: NSWindow?
    private(set) var isEnded = false
    private var endHandlers: [() -> Void] = []
    private var closeObserver: NSObjectProtocol?

    var title: String { BuiltInToolSupport.title(tool) }

    /// The tool operation already running in `controller`'s window, if any.
    static func current(for controller: WorkspaceController) -> BuiltInToolSession? {
        let key = ObjectIdentifier(controller)
        guard let session = sessions[key] else { return nil }
        guard session.controller === controller, !session.isEnded else {
            sessions[key] = nil
            return nil
        }
        return session
    }

    init(tool: BuiltInToolID, controller: WorkspaceController) {
        self.tool = tool
        self.controller = controller
        key = ObjectIdentifier(controller)
        Self.sessions[key] = self
        if let window = controller.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            }
        }
    }

    /// Runs `handler` when the session ends (closing the window, Cancel, Done), e.g. to stop work or delete staging files.
    func onEnd(_ handler: @escaping () -> Void) {
        if isEnded { handler() } else { endHandlers.append(handler) }
    }

    /// Shows `content` in the session's sheet, replacing what it showed before. A nil `minimumSize`
    /// makes the sheet fixed-size.
    func show<Content: View>(_ content: Content, size: NSSize, minimumSize: NSSize? = BuiltInToolSession.minimumSheetSize) {
        guard !isEnded else { return }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        let target = fittedSize(size, minimum: minimumSize)
        if let sheet {
            if let previous = sheet.contentView { Self.keepAlive(previous) }
            sheet.contentMinSize = minimumSize ?? target
            if minimumSize == nil { sheet.styleMask.remove(.resizable) } else { sheet.styleMask.insert(.resizable) }
            sheet.contentView = hosting
            // Sheets sit centered on their parent. The resize is not animated: animating an attached sheet's
            // frame drags the parent window along.
            let frame = sheet.frameRect(forContentRect: NSRect(origin: .zero, size: target))
            let anchor = sheet.sheetParent?.frame ?? sheet.frame
            let next = NSRect(x: (anchor.midX - frame.width / 2).rounded(), y: (anchor.midY - frame.height / 2).rounded(),
                              width: frame.width, height: frame.height)
            sheet.setFrame(next, display: true, animate: false)
        } else {
            let style: NSWindow.StyleMask = minimumSize == nil ? [.titled] : [.titled, .resizable]
            let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: target), styleMask: style, backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            sheet.title = title
            sheet.contentMinSize = minimumSize ?? target
            sheet.contentView = hosting
            sheet.setAccessibilityIdentifier("BuiltInTool.Sheet")
            self.sheet = sheet
            if let parent = controller?.window {
                parent.beginSheet(sheet)
            } else {
                sheet.center()
                sheet.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Ends the interaction: closes the sheet, runs the end handlers and frees the window for another tool.
    func end() {
        guard !isEnded else { return }
        isEnded = true
        if Self.sessions[key] === self { Self.sessions[key] = nil }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        let handlers = endHandlers
        endHandlers = []
        handlers.forEach { $0() }
        guard let sheet else { return }
        self.sheet = nil
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
        Self.keepAlive(sheet)
    }

    /// Tells the user that this window already runs a tool.
    func showBusyAlert() {
        guard let sheet, sheet.isVisible else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L("Finish or cancel the current tool operation first.")
        alert.beginSheetModal(for: sheet)
    }

    private func fittedSize(_ size: NSSize, minimum: NSSize?) -> NSSize {
        guard let parent = controller?.window else { return size }
        let available = parent.contentLayoutRect.size
        let floor = minimum ?? size
        return NSSize(width: max(floor.width, min(size.width, available.width - 40)).rounded(),
                      height: max(floor.height, min(size.height, available.height - 24)).rounded())
    }

    /// Keeps a view or window that SwiftUI may still be using until the current event has been handled.
    private static func keepAlive(_ view: NSView) {
        DispatchQueue.main.async { withExtendedLifetime(view) {} }
    }

    private static func keepAlive(_ window: NSWindow) {
        DispatchQueue.main.async { withExtendedLifetime(window) {} }
    }
}
