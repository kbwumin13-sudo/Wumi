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
    @State private var collapseWork: DispatchWorkItem?
    @Namespace private var glassNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let preferences = app.preferences
        let actions = preferences.floatingBallActionOrder.filter { preferences.enabledFloatingBallActions.contains($0) }
        let dark = colorScheme == .dark
        if !hidden {
            // Expanded circular glass buttons morph smoothly out of the central orb, matching Miji's Spotlight dock.
            let above = Array(actions.prefix((actions.count + 1) / 2))
            let below = Array(actions.dropFirst(above.count))
            WumiGlassContainer(spacing: 12) {
                VStack(spacing: 5.5) {
                    if expanded {
                        ForEach(above, id: \.self) { action in
                            actionButton(action)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.76, anchor: .bottom).combined(with: .opacity))
                        }
                        Color.clear.frame(width: 1, height: 4)
                    }
                    // Liquid Glass orb with a centered accent indicator dot.
                    Circle()
                        .fill(.clear)
                        .frame(width: 34, height: 34)
                        .wumiGlass(in: Circle(), interactive: true)
                        .wumiGlassID("floating-orb", in: glassNamespace)
                        .overlay(
                            Circle()
                                .fill(expanded ? Color.accentColor : Color.primary.opacity(0.62))
                                .frame(width: expanded ? 6.5 : 5, height: expanded ? 6.5 : 5)
                        )
                        .shadow(color: Theme.pillShadow(dark: dark), radius: expanded ? 6 : 3, y: 1.5)
                        .scaleEffect(expanded && !reduceMotion ? 1.04 : 1.0)
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
                        Color.clear.frame(width: 1, height: 4)
                        ForEach(below, id: \.self) { action in
                            actionButton(action)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.76, anchor: .top).combined(with: .opacity))
                        }
                    }
                }
            }
            .padding(5)
            .opacity(expanded ? 1 : 1 - preferences.floatingBallTransparency)
            .onHover { hovering in
                guard preferences.expandsFloatingBallOnHover else { return }
                collapseWork?.cancel()
                collapseWork = nil
                if hovering {
                    WumiMotion.withPreferredAnimation(WumiMotion.morph, reduceMotion: reduceMotion) { expanded = true }
                } else {
                    let work = DispatchWorkItem {
                        WumiMotion.withPreferredAnimation(WumiMotion.snappy, reduceMotion: reduceMotion) { expanded = false }
                    }
                    collapseWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
                }
            }
        }
    }

    private func actionButton(_ action: FloatingBallAction) -> some View {
        let enabled = isEnabled(action)
        let dark = colorScheme == .dark
        return Button { controller.performFloatingBallAction(action, pane: pane) } label: {
            Image(systemName: Self.symbol(action))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 28)
                .wumiGlass(in: Circle(), interactive: true)
                .wumiGlassID("floating-action-\(action.rawValue)", in: glassNamespace)
                .shadow(color: Theme.pillShadow(dark: dark), radius: 2.5, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(WumiInteractiveButtonStyle(cornerRadius: 14, hoverOpacity: 0.06, pressOpacity: 0.14, pressScale: 0.91))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(Self.title(action))
        .accessibilityLabel(Self.title(action))
        .accessibilityIdentifier("FloatingBall.\(action.rawValue).\(pane.id.uuidString)")
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
