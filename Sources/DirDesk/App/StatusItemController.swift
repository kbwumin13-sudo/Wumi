import AppKit
import DirDeskCore

/// Menu bar item for Floating Files / File Transit (shown when the preference is on).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()
    private var item: NSStatusItem?
    private weak var delegate: AppDelegate?

    func install(delegate: AppDelegate?) {
        self.delegate = delegate
        let wanted = AppModel.shared.preferences.showsFileTransitMenuBarItem
        if wanted, item == nil {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem.button?.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: L("Floating Files"))
            statusItem.button?.toolTip = L("Floating Files")
            // A click opens the Floating Files window directly (as the original); the menu is on right-click.
            // The overlay also accepts files dropped on the icon and stages them.
            if let button = statusItem.button {
                let overlay = StatusItemDropView(frame: button.bounds)
                overlay.autoresizingMask = [.width, .height]
                overlay.onClick = { [weak self] in self?.toggleFloatingFiles() }
                overlay.onRightClick = { [weak self] in self?.showMenu() }
                overlay.onDrop = { pasteboard in
                    guard FileTransitStore.shared.importPasteboard(pasteboard) else { return false }
                    FloatingFilesController.shared.show()
                    return true
                }
                button.addSubview(overlay)
            }
            item = statusItem
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    private func toggleFloatingFiles() {
        let controller = FloatingFilesController.shared
        if controller.isVisible {
            controller.hide()
        } else if let button = item?.button, let window = button.window {
            controller.show(below: window.convertToScreen(button.convert(button.bounds, to: nil)))
        } else {
            controller.show()
        }
    }

    private func showMenu() {
        guard let item, let button = item.button else { return }
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = FileTransitStore.shared
        menu.addItem(ClosureMenuItem(L("Show Floating Files")) { FloatingFilesController.shared.show() })
        menu.addItem(ClosureMenuItem(L("Add Files or Folders…")) { store.presentAddPanel() })
        if !store.items.isEmpty {
            menu.addItem(.separator())
            for record in store.items.prefix(12) {
                // Originals are shown in Finder; imported text, images and links open.
                let entry = ClosureMenuItem(record.name) {
                    record.originalPath != nil ? store.revealInFinder([record.id]) : store.open(record.id)
                }
                let icon = TransitThumbnails.placeholder(for: record).copy() as? NSImage
                icon?.size = NSSize(width: 16, height: 16)
                entry.image = icon
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Copy All")) { store.copyAll() })
            if !store.isReadOnly {
                menu.addItem(ClosureMenuItem(L("Clear Unlocked Items")) { store.clearUnlocked() })
            }
        }
        if store.canRestore && !store.isReadOnly {
            menu.addItem(ClosureMenuItem(L("Restore Recently Removed")) { store.restoreRecentlyRemoved() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("New Window")) { [weak self] in
            self?.delegate?.newWindow(directory: nil)
            activateApp()
        })
    }
}

/// Transparent view over the status item button: click, right-click and drops (files, promised files, text,
/// images and links all go to File Transit).
final class StatusItemDropView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(TransitPasteboard.acceptedTypes)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        TransitPasteboard.dropOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDrop?(sender.draggingPasteboard) ?? false
    }
}
