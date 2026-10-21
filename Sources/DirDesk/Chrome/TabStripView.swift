import AppKit
import DirDeskCore
import SwiftUI

/// Tab strip drawn in the title-bar row, to the right of the sidebar.
struct TabStripView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var controller: WorkspaceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                            if index > 0, tab.id != model.activeTabID, model.tabs[index - 1].id != model.activeTabID {
                                Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1, height: 14)
                            }
                            // The original shows the close button even on a lone tab; closing it closes the window.
                            TabChip(tab: tab, isActive: tab.id == model.activeTabID,
                                    select: { model.selectTab(tab.id) },
                                    close: { controller.closeTab(tab.id) })
                                .id(tab.id)
                                .contextMenu { tabMenu(tab) }
                                .onDrag {
                                    NSItemProvider(object: tab.id.uuidString as NSString)
                                }
                                .onDrop(of: [.plainText, .fileURL], delegate: TabDropDelegate(tab: tab, model: model, controller: controller,
                                                                                         reorder: { reorder($0, onto: tab) }))
                        }
                        Button(action: { controller.newTab() }) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                        .padding(.leading, 2)
                        .help(L("New Tab"))
                        .accessibilityIdentifier("Tabs.New")
                        .accessibilityLabel(L("New Tab"))
                    }
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.activeTabID) { _, id in
                    if reduceMotion { proxy.scrollTo(id) }
                    else { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 14 + controller.tabStripLeadingInset)
        .padding(.trailing, 12)
        .frame(height: WorkspaceWindow.titleRowHeight, alignment: .center)
        .background(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .onTapGesture(count: 2) { controller.window?.performZoom(nil) }
        .accessibilityIdentifier("Chrome.TabStrip")
    }

    /// The original's tab menu: Rename, Pin/Unpin, Close (unavailable for pinned tabs), Remove Duplicates,
    /// Close Tabs to the Right.
    @ViewBuilder
    private func tabMenu(_ tab: TabRuntime) -> some View {
        Button(L("Rename Tab")) { controller.renameTab(tab.id) }
            .accessibilityIdentifier("Tabs.Rename")
        Button(tab.isPinned ? L("Unpin Tab") : L("Pin Tab")) { model.togglePin(tab.id) }
        Button(L("Close Tab")) { controller.closeTab(tab.id) }
            .disabled(model.tabs.count < 2 || tab.isPinned)
        Button(L("Remove Duplicate Tabs")) { controller.removeDuplicateTabs() }
            .help(L("Removes duplicate single-pane folder tabs in all windows; pinned and multi-pane tabs stay."))
            .accessibilityIdentifier("Tabs.RemoveDuplicates")
        Button(L("Close Tabs to the Right")) { model.closeTabs(rightOf: tab.id) }
            .disabled(model.tabs.last?.id == tab.id)
            .accessibilityIdentifier("Tabs.CloseRight")
    }

    private func reorder(_ providers: [NSItemProvider], onto target: TabRuntime) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
            Task { @MainActor in
                guard let index = model.tabs.firstIndex(where: { $0.id == target.id }) else { return }
                model.moveTab(id, to: index)
            }
        }
        return true
    }
}

/// Drops on a tab: another tab reorders the strip; files go into the folder of the tab's active pane, with the same
/// move/copy rules as a pane. Holding dragged files over a tab switches to it after the folder spring-loading delay.
private struct TabDropDelegate: DropDelegate {
    let tab: TabRuntime
    let model: WorkspaceModel
    let controller: WorkspaceController
    let reorder: ([NSItemProvider]) -> Bool

    @MainActor private static var switchTimer: Timer?

    private var directory: URL? { tab.activePane.currentDirectory }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) || (info.hasItemsConforming(to: [.fileURL]) && directory != nil)
    }

    func dropEntered(info: DropInfo) {
        guard info.hasItemsConforming(to: [.fileURL]), tab.id != model.activeTabID else { return }
        let id = tab.id
        MainActor.assumeIsolated {
            Self.switchTimer?.invalidate()
            Self.switchTimer = Timer.scheduledTimer(withTimeInterval: AppModel.shared.preferences.dragHoverExpansionDelay, repeats: false) { _ in
                MainActor.assumeIsolated { model.selectTab(id) }
            }
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated {
            Self.switchTimer?.invalidate()
            Self.switchTimer = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard info.hasItemsConforming(to: [.fileURL]) else { return DropProposal(operation: .move) }
        let flags = NSEvent.modifierFlags
        let reverses = flags.contains(.shift) && AppModel.shared.preferences.shiftDragReversesOperation
        return DropProposal(operation: flags.contains(.option) || reverses ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dropExited(info: info)
        let files = info.itemProviders(for: [.fileURL])
        if !files.isEmpty, let directory {
            return controller.dropProviders(files, into: directory)
        }
        return reorder(info.itemProviders(for: [.plainText]))
    }
}

/// Quiet, rounded tabs retain pinning, closing, drag destinations and full-path help.
private struct TabChip: View {
    @ObservedObject var tab: TabRuntime
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if tab.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: tab.panes.count > 1 ? "rectangle.split.2x1" : "folder")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 11.5)
                        .foregroundStyle(isActive ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.8))
                }
            }
            .frame(width: 12)
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !tab.isPinned {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .opacity(isActive || hovering ? 1 : 0)
                .help(L("Close Tab"))
                .accessibilityIdentifier("Tabs.Close.\(tab.id.uuidString)")
                .accessibilityLabel(L("Close Tab"))
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(width: 180, height: 30)
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(isActive && contrast == .increased ? Color.primary.opacity(0.45) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(tab.activePane.currentDirectory?.path ?? tab.title)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Tab.\(tab.id.uuidString)")
        .accessibilityLabel(LF(tab.isPinned ? "Pinned tab %@" : "Tab %@", tab.title))
    }

    private var fill: Color {
        if isActive { return Theme.selectedTab }
        if tab.isPinned { return Color.primary.opacity(0.035) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }
}
