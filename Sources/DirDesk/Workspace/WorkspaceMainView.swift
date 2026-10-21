import AppKit
import DirDeskCore
import SwiftUI

/// Everything right of the sidebar: tab strip, toolbar, bookmark bar, panes + inspector, status bar.
/// A single separator defines the sidebar boundary; each surface aligns to the main split item.
struct WorkspaceMainView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var app = AppModel.shared
    let controller: WorkspaceController

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            VStack(spacing: 0) {
                TabStripView(model: model, controller: controller)
                ToolbarRowView(model: model, controller: controller)
                Divider()
                if app.preferences.showsBookmarksAndWorkspaceBar {
                    BookmarkBarView(model: model, controller: controller)
                    Divider()
                }
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        PaneLayoutView(tab: model.activeTab, controller: controller)
                            .id(model.activeTabID)
                            .frame(minWidth: 320)
                        if model.inspectorVisible {
                            InspectorColumn(model: model, tab: model.activeTab, controller: controller,
                                            availableWidth: geometry.size.width - 321)
                        }
                    }
                }
                VStack(spacing: 0) {
                    Divider()
                    StatusBarView(model: model)
                }
                .background(Theme.content)
            }
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
        InspectorResizeHandle(width: width, displayedWidth: displayedWidth, maximumWidth: maximumWidth)
        InspectorView(model: model, controller: controller)
            .frame(width: displayedWidth)
            .environment(\.inspectorStacksLabels, multi || displayedWidth < 280)
    }
}

private struct InspectorResizeHandle: View {
    @Binding var width: Double
    let displayedWidth: Double
    let maximumWidth: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if start == nil { start = displayedWidth }
                            width = min(max((start ?? displayedWidth) - value.translation.width, 180), maximumWidth)
                        }
                        .onEnded { _ in start = nil })
            )
    }
}
