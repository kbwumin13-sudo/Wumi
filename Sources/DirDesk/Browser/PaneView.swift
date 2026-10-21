import AppKit
import DirDeskCore
import SwiftUI

/// One browser pane: path bar plus the active view mode.
struct PaneView: View {
    @ObservedObject var pane: PaneRuntime
    @ObservedObject var tab: TabRuntime
    let controller: WorkspaceController

    private var isActive: Bool { tab.activePaneID == pane.id }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PathBarView(pane: pane, controller: controller, close: tab.panes.count > 1 ? { [weak tab] in
                    guard let tab else { return }
                    tab.activePaneID = pane.id
                    tab.closeActivePane()
                } : nil)
                Divider()
            }
            .background(Theme.chrome)
            content
                .overlay {
                    // In the list view the state sits below the column header, as in the original.
                    PaneStateView(pane: pane, controller: controller)
                        .padding(.top, pane.viewConfiguration.mode == .list ? 28 : 0)
                }
        }
        // The active pane of a split carries a 1 pt accent outline.
        .overlay {
            if tab.panes.count > 1 && isActive {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 1).allowsHitTesting(false)
            }
        }
        .background(Theme.content)
        .onAppear { pane.setSizeObservationActive(true) }
        .onDisappear { pane.setSizeObservationActive(false) }
        .simultaneousGesture(TapGesture().onEnded { controller.activate(pane: pane) })
        .overlay(alignment: .trailing) {
            if AppModel.shared.preferences.showsQuickCapsule {
                FloatingBallView(pane: pane, controller: controller)
                    .padding(.trailing, 6)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane.viewConfiguration.mode {
        case .list:
            FileListRepresentable(pane: pane, controller: controller)
        case .icons, .images:
            FileGridRepresentable(pane: pane, controller: controller, gallery: pane.viewConfiguration.mode == .images)
        case .columns:
            // Empty space right of the columns is the dark chrome, as in the original.
            ColumnBrowserRepresentable(pane: pane, controller: controller)
                .background(Theme.chrome)
        }
    }
}

struct FileListRepresentable: NSViewControllerRepresentable {
    let pane: PaneRuntime
    let controller: WorkspaceController

    func makeNSViewController(context: Context) -> FileListController {
        let list = FileListController(pane: pane, handler: controller)
        controller.register(list: list, for: pane)
        return list
    }

    func updateNSViewController(_ nsViewController: FileListController, context: Context) {}

    static func dismantleNSViewController(_ controller: FileListController, coordinator: ()) {
        controller.stopSizeRequests()
    }
}

/// Arranges a tab's panes according to its layout, with draggable dividers whose ratios persist.
struct PaneLayoutView: View {
    @ObservedObject var tab: TabRuntime
    let controller: WorkspaceController

    var body: some View {
        let panes = tab.panes
        Group {
            switch tab.layout {
            case .single:
                pane(0, panes)
            case .twoColumns:
                SplitStack(axis: .horizontal, ratios: ratios(0, count: 2)) { [pane(0, panes), pane(1, panes)] }
            case .twoRows:
                SplitStack(axis: .vertical, ratios: ratios(0, count: 2)) { [pane(0, panes), pane(1, panes)] }
            case .threeColumns:
                SplitStack(axis: .horizontal, ratios: ratios(0, count: 3)) { [pane(0, panes), pane(1, panes), pane(2, panes)] }
            case .threeRows:
                SplitStack(axis: .vertical, ratios: ratios(0, count: 3)) { [pane(0, panes), pane(1, panes), pane(2, panes)] }
            case .oneLeftTwoRight:
                SplitStack(axis: .horizontal, ratios: ratios(0, count: 2)) {
                    [pane(0, panes), AnyView(SplitStack(axis: .vertical, ratios: ratios(2, count: 2)) { [pane(1, panes), pane(2, panes)] })]
                }
            case .twoLeftOneRight:
                SplitStack(axis: .horizontal, ratios: ratios(0, count: 2)) {
                    [AnyView(SplitStack(axis: .vertical, ratios: ratios(2, count: 2)) { [pane(0, panes), pane(1, panes)] }), pane(2, panes)]
                }
            case .oneTopTwoBottom:
                SplitStack(axis: .vertical, ratios: ratios(0, count: 2)) {
                    [pane(0, panes), AnyView(SplitStack(axis: .horizontal, ratios: ratios(2, count: 2)) { [pane(1, panes), pane(2, panes)] })]
                }
            case .twoTopOneBottom:
                SplitStack(axis: .vertical, ratios: ratios(0, count: 2)) {
                    [AnyView(SplitStack(axis: .horizontal, ratios: ratios(2, count: 2)) { [pane(0, panes), pane(1, panes)] }), pane(2, panes)]
                }
            case .fourGrid:
                SplitStack(axis: .vertical, ratios: ratios(0, count: 2)) {
                    [AnyView(SplitStack(axis: .horizontal, ratios: ratios(2, count: 2)) { [pane(0, panes), pane(1, panes)] }),
                     AnyView(SplitStack(axis: .horizontal, ratios: ratios(4, count: 2)) { [pane(2, panes), pane(3, panes)] })]
                }
            case .oneLeftThreeRight:
                SplitStack(axis: .horizontal, ratios: ratios(0, count: 2)) {
                    [pane(0, panes), AnyView(SplitStack(axis: .vertical, ratios: ratios(2, count: 3)) { [pane(1, panes), pane(2, panes), pane(3, panes)] })]
                }
            case .threeLeftOneRight:
                SplitStack(axis: .horizontal, ratios: ratios(0, count: 2)) {
                    [AnyView(SplitStack(axis: .vertical, ratios: ratios(2, count: 3)) { [pane(0, panes), pane(1, panes), pane(2, panes)] }), pane(3, panes)]
                }
            }
        }
    }

    private func pane(_ index: Int, _ panes: [PaneRuntime]) -> AnyView {
        guard panes.indices.contains(index) else { return AnyView(Color.clear) }
        return AnyView(PaneView(pane: panes[index], tab: tab, controller: controller).id(panes[index].id))
    }

    /// Binding to `count` ratios stored from `offset` in the tab's flat ratio list.
    private func ratios(_ offset: Int, count: Int) -> Binding<[Double]> {
        Binding(get: {
            let stored = tab.splitRatios
            guard stored.count >= offset + count else { return Array(repeating: 1 / Double(count), count: count) }
            return Array(stored[offset..<(offset + count)])
        }, set: { newValue in
            var stored = tab.splitRatios
            if stored.count < offset + count {
                stored += Array(repeating: 0.5, count: offset + count - stored.count)
            }
            stored.replaceSubrange(offset..<(offset + count), with: newValue)
            tab.splitRatios = stored
            tab.onStateChange?()
        })
    }
}

/// Lays out children along an axis with draggable dividers; ratios sum to 1.
struct SplitStack: View {
    let axis: Axis
    @Binding var ratios: [Double]
    let content: () -> [AnyView]

    init(axis: Axis, ratios: Binding<[Double]>, content: @escaping () -> [AnyView]) {
        self.axis = axis
        self._ratios = ratios
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let views = content()
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let normalized = normalizedRatios(count: views.count)
            let dividerCount = CGFloat(max(views.count - 1, 0))
            let available = max(total - dividerCount, 1)
            let layout = AnyLayout(axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0)))
            layout {
                ForEach(Array(views.enumerated()), id: \.offset) { index, view in
                    view.frame(width: axis == .horizontal ? available * normalized[index] : nil,
                               height: axis == .vertical ? available * normalized[index] : nil)
                    if index < views.count - 1 {
                        SplitDivider(axis: axis) { delta in
                            adjust(index, delta: delta / available, count: views.count)
                        }
                    }
                }
            }
        }
    }

    private func normalizedRatios(count: Int) -> [Double] {
        guard ratios.count == count else { return Array(repeating: 1 / Double(count), count: count) }
        let sum = ratios.reduce(0, +)
        return sum > 0 ? ratios.map { $0 / sum } : Array(repeating: 1 / Double(count), count: count)
    }

    private func adjust(_ index: Int, delta: CGFloat, count: Int) {
        var values = normalizedRatios(count: count)
        let minimum = 0.1
        let change = Double(delta)
        let a = values[index] + change, b = values[index + 1] - change
        guard a >= minimum, b >= minimum else { return }
        values[index] = a
        values[index + 1] = b
        ratios = values
    }
}

private struct SplitDivider: View {
    let axis: Axis
    let onDrag: (CGFloat) -> Void
    @State private var last: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .overlay(
                Color.clear
                    .frame(width: axis == .horizontal ? 7 : nil, height: axis == .vertical ? 7 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let current = axis == .horizontal ? value.translation.width : value.translation.height
                            onDrag(current - last)
                            last = current
                        }
                        .onEnded { _ in last = 0 })
            )
            .accessibilityLabel(L("Resize Panes"))
    }
}
