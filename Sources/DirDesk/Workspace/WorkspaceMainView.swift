import AppKit
import DirDeskCore
import SwiftUI

/// Everything right of the sidebar: tab strip, toolbar, bookmark bar, panes + inspector, status bar.
/// A single separator defines the sidebar boundary; each surface aligns to the main split item.
struct WorkspaceMainView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var app = AppModel.shared
    let controller: WorkspaceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            // Preserve the 1 pt leading geometry expected by tabStripLeadingInset without drawing
            // a hard wall next to the floating sidebar card.
            Color.clear.frame(width: 1)
            VStack(spacing: 0) {
                TabStripView(model: model, controller: controller)
                ToolbarRowView(model: model, controller: controller)
                Divider()
                if app.preferences.showsBookmarksAndWorkspaceBar {
                    BookmarkBarView(model: model, controller: controller)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    Divider()
                }
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        PaneLayoutView(tab: model.activeTab, controller: controller)
                            .id(model.activeTabID)
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                        if model.inspectorVisible {
                            InspectorColumn(model: model, tab: model.activeTab, controller: controller,
                                            availableWidth: geometry.size.width - 321)
                                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .clipped()
                    .animation(WumiMotion.resolve(WumiMotion.snappy, reduceMotion: reduceMotion), value: model.inspectorVisible)
                }
                VStack(spacing: 0) {
                    Divider()
                    StatusBarView(model: model)
                }
                .background(Theme.content)
            }
            .animation(WumiMotion.resolve(WumiMotion.snappy, reduceMotion: reduceMotion), value: app.preferences.showsBookmarksAndWorkspaceBar)
        }
        .background(Theme.chrome)
        .font(.system(size: app.preferences.interfaceFontSize))
        .ignoresSafeArea()
        .id(app.language)
    }
}

/// The inspector with its resize handle. Single-pane and multi-pane layouts keep separate widths, 360 and 260 pt
/// by default as in the original; the narrow multi-pane inspector stacks its labels above the values.
private struct InspectorColumn: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var tab: TabRuntime
    let controller: WorkspaceController
    let availableWidth: CGFloat
    @AppStorage(DefaultsKey.inspectorWidth) private var singleWidth: Double = 360
    @AppStorage(DefaultsKey.inspectorWidth + "-multipane") private var multiWidth: Double = 260

    var body: some View {
        let multi = tab.panes.count > 1
        let width = multi ? $multiWidth : $singleWidth
        let maximumWidth = max(180, min(640, Double(availableWidth)))
        let displayedWidth = min(width.wrappedValue, maximumWidth)
        HStack(spacing: 0) {
            InspectorResizeHandle(width: width, displayedWidth: displayedWidth, maximumWidth: maximumWidth)
            InspectorView(model: model, controller: controller)
                .frame(width: displayedWidth)
                .environment(\.inspectorStacksLabels, multi || displayedWidth < 280)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct InspectorResizeHandle: View {
    @Binding var width: Double
    let displayedWidth: Double
    let maximumWidth: Double
    @State private var start: Double?
    @State private var hovering = false

    private var active: Bool { hovering || start != nil }

    var body: some View {
        Rectangle()
            .fill(active ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
            .frame(width: active ? 2 : 1)
            .frame(width: 1)
            .animation(WumiMotion.micro, value: active)
            .overlay(
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if start == nil { start = displayedWidth }
                            width = min(max((start ?? displayedWidth) - value.translation.width, 180), maximumWidth)
                        }
                        .onEnded { _ in start = nil })
            )
    }
}
