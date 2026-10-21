import AppKit
import DirDeskCore

/// Small floating label next to the pointer while files are dragged over a DirDesk folder: what the drop will do
/// ("Move to “Folder”" / "Copy to “Folder”") and, when Shift swaps the operation, how to switch. Mirrors the original's
/// `FileDragFeedback` (title and hint labels in a panel that expires when updates stop).
@MainActor
final class DragFeedbackPanel {
    static let shared = DragFeedbackPanel()

    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private var expiry: Timer?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, hintLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
        }
        let stack = NSStackView(views: [titleLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        NotificationCenter.default.addObserver(forName: .dirDeskFileDragDidEnd, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DragFeedbackPanel.shared.hide() }
        }
    }

    /// Shows or updates the label for a drop of `operation` into `destination`; an empty operation hides it.
    func update(operation: NSDragOperation, destination: URL) {
        guard operation == .move || operation == .copy else {
            hide()
            return
        }
        let name = PathUtilities.displayName(for: destination)
        let moving = operation == .move
        titleLabel.stringValue = moving ? LF("Move to “%@”", name) : LF("Copy to “%@”", name)
        let shift = NSEvent.modifierFlags.contains(.shift)
        if AppModel.shared.preferences.shiftDragReversesOperation, !NSEvent.modifierFlags.contains(.option) {
            hintLabel.stringValue = switch (shift, moving) {
            case (false, true): L("Hold Shift to copy")
            case (false, false): L("Hold Shift to move")
            case (true, true): L("Release Shift to copy")
            case (true, false): L("Release Shift to move")
            }
            hintLabel.isHidden = false
        } else {
            hintLabel.isHidden = true
        }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 200, height: 44)
        let width = min(max(size.width, 120), 360)
        let mouse = NSEvent.mouseLocation
        panel.setFrame(NSRect(x: mouse.x + 18, y: mouse.y - size.height - 20, width: width, height: size.height), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
            MainActor.assumeIsolated { DragFeedbackPanel.shared.hide() }
        }
    }

    func hide() {
        expiry?.invalidate()
        expiry = nil
        if panel.isVisible { panel.orderOut(nil) }
    }
}
