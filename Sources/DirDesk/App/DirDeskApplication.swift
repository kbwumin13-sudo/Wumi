import AppKit

/// Application subclass: mouse side buttons drive Back/Forward in the active pane.
final class DirDeskApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .otherMouseDown, event.buttonNumber == 3 || event.buttonNumber == 4 {
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard AppModel.shared.preferences.usesMouseButtonsForHistoryNavigation,
                      let controller = (delegate as? AppDelegate)?.activeController,
                      event.window === controller.window else { return false }
                controller.perform(event.buttonNumber == 3 ? .navigateBack : .navigateForward)
                return true
            }
            if handled { return }
        }
        super.sendEvent(event)
    }
}
