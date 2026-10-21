import AppKit
import DirDeskCore
import SwiftUI

/// Floating ball at the right center of each pane; expands its enabled actions on hover.
struct FloatingBallView: View {
    @ObservedObject var pane: PaneRuntime
    @ObservedObject var app = AppModel.shared
    let controller: WorkspaceController
    @State private var expanded = false
    @State private var hidden = false

    var body: some View {
        let preferences = app.preferences
        let actions = preferences.floatingBallActionOrder.filter { preferences.enabledFloatingBallActions.contains($0) }
        if !hidden {
            // Expanded buttons split around the ball like the original: the first half above it, the rest below.
            let above = Array(actions.prefix((actions.count + 1) / 2))
            let below = Array(actions.dropFirst(above.count))
            // Measured from the original: 24 pt buttons every 28 pt, 14 pt clear of the 32 pt ball.
            VStack(spacing: 4) {
                if expanded {
                    ForEach(above, id: \.self) { action in actionButton(action) }
                    Color.clear.frame(width: 1, height: 6)
                }
                // A faint disc with a centre dot, as in the original (reference capture 01-主窗口).
                Circle()
                    .fill(Color.primary.opacity(expanded ? 0.16 : 0.09))
                    .overlay(Circle().fill(Color.primary.opacity(0.6)).frame(width: 5, height: 5))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .onTapGesture(count: 2) {
                        controller.performFloatingBallAction(preferences.floatingBallDoubleClickAction, pane: pane)
                    }
                    .contextMenu {
                        Button(L("Close Floating Ball")) { hidden = true }
                        Button(L("Configure Floating Ball")) { controller.showSettings(section: "floatingBall") }
                    }
                    .help(LF("Double-click: %@", Self.title(preferences.floatingBallDoubleClickAction)))
                    .accessibilityIdentifier("FloatingBall.Body.\(pane.id.uuidString)")
                    .accessibilityLabel(L("Floating Ball"))
                    .accessibilityAddTraits(.isButton)
                if expanded {
                    Color.clear.frame(width: 1, height: 6.5)
                    ForEach(below, id: \.self) { action in actionButton(action) }
                }
            }
            .padding(4)
            .opacity(expanded ? 1 : 1 - preferences.floatingBallTransparency)
            .onHover { hovering in
                guard preferences.expandsFloatingBallOnHover else { return }
                withAnimation(.easeOut(duration: 0.15)) { expanded = hovering }
            }
        }
    }

    private func actionButton(_ action: FloatingBallAction) -> some View {
        let enabled = isEnabled(action)
        return Button { controller.performFloatingBallAction(action, pane: pane) } label: {
            Image(systemName: Self.symbol(action))
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(Self.title(action))
        .accessibilityLabel(Self.title(action))
        .accessibilityIdentifier("FloatingBall.\(action.rawValue).\(pane.id.uuidString)")
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }

    /// Back and forward need history, Up needs a parent folder; the original greys them out.
    private func isEnabled(_ action: FloatingBallAction) -> Bool {
        switch action {
        case .back: pane.history.canGoBack
        case .forward: pane.history.canGoForward
        case .up: pane.canGoUp
        default: true
        }
    }

    static func symbol(_ action: FloatingBallAction) -> String {
        switch action {
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .up: "arrow.up"
        case .selectAll: "checkmark.square"
        case .compressAll: "archivebox"
        case .collectAll: "folder.badge.plus"
        case .compressFolder: "archivebox.fill"
        case .collectFolder: "tray.and.arrow.down"
        case .refresh: "arrow.clockwise"
        case .copyPath: "doc.on.doc"
        }
    }

    static func title(_ action: FloatingBallAction) -> String {
        switch action {
        case .back: L("Back")
        case .forward: L("Forward")
        case .up: L("Go Up")
        case .selectAll: L("Select All Items")
        case .compressAll: L("Compress Selected Items")
        case .collectAll: L("Collect Selected Items into New Folder")
        case .compressFolder: L("Compress All Items in Current Folder")
        case .collectFolder: L("Collect All Items in Current Folder into New Folder")
        case .refresh: L("Refresh")
        case .copyPath: L("Copy Folder Path")
        }
    }
}
