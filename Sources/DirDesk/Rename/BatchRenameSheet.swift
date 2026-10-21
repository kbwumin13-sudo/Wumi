import AppKit
import DirDeskCore
import SwiftUI

/// Shows Batch Rename as a sheet on the workspace window. Each sheet keeps the selection it was opened with;
/// renames are undone through that window's undo manager.
@MainActor
enum BatchRenameSheet {
    /// The sheet's size when the window has room for it.
    static let preferredSize = NSSize(width: 960, height: 800)
    /// Small windows get a smaller sheet, down to this size; the sheet's content scrolls.
    static let minimumSize = NSSize(width: 720, height: 560)

    static func present(_ items: [FileItem], controller: WorkspaceController) {
        guard !items.isEmpty, let parent = controller.window else { return }
        let items = inDisplayOrder(items, pane: controller.activePane)
        // One sheet at a time: the window already shows Batch Rename or another sheet.
        guard parent.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: fittedSize(in: parent)), styleMask: [.titled],
                             backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = L("Batch Rename")
        sheet.setAccessibilityIdentifier("BatchRename.Sheet")
        let hosting = NSHostingView(rootView: BatchRenameView(items: items, controller: controller) { [weak sheet] in
            if let sheet { end(sheet) }
        })
        hosting.sizingOptions = []
        sheet.contentView = hosting
        parent.beginSheet(sheet)
    }

    private static func end(_ sheet: NSWindow) {
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
        // SwiftUI may still be handling the click that closed the sheet.
        DispatchQueue.main.async { withExtendedLifetime(sheet) {} }
    }

    /// Number sequences count in the order the pane lists the items, as the original does; the selection itself is
    /// unordered. Items the pane does not list keep their order after the listed ones.
    static func inDisplayOrder(_ items: [FileItem], pane: PaneRuntime) -> [FileItem] {
        var position: [FileIdentity: Int] = [:]
        for (index, row) in pane.rows.enumerated() {
            if let item = row.item, position[item.id] == nil { position[item.id] = index }
        }
        return items.enumerated()
            .sorted { (position[$0.element.id] ?? Int.max, $0.offset) < (position[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    private static func fittedSize(in parent: NSWindow) -> NSSize {
        let available = parent.contentLayoutRect.size
        return NSSize(width: max(minimumSize.width, min(preferredSize.width, available.width - 40)).rounded(),
                      height: max(minimumSize.height, min(preferredSize.height, available.height)).rounded())
    }
}
