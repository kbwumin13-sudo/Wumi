import AppKit
import SwiftUI

/// The app as a draggable card: drop it on the Full Disk Access list in System Settings to add Wumi there,
/// as the original's local edition guides. The drag carries the app bundle's file URL, like dragging it from Finder.
struct FullDiskAccessDragCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Drag Wumi into the Full Disk Access list")).font(.system(size: 12, weight: .semibold))
                Text(L("After you drop it, confirm with Touch ID or your password. Wumi shows up in the list once macOS accepts it."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "hand.draw").foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider()
        }
        .help(L("Drag Wumi into the Full Disk Access list"))
        .accessibilityIdentifier("FullDiskAccess.DragCard")
    }
}
