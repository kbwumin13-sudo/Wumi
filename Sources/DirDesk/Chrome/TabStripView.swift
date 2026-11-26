import AppKit
import DirDeskCore
import SwiftUI

/// Tab strip drawn in the title-bar row, to the right of the sidebar.
struct TabStripView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var controller: WorkspaceController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargetedTabID: UUID?

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    WumiGlassContainer(spacing: 8) {
                        HStack(spacing: 6) {
                            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                                if index > 0, tab.id != model.activeTabID, model.tabs[index - 1].id != model.activeTabID {
                                    Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1, height: 14)
                                        .transition(.opacity)
                                }
                                // The original shows the close button even on a lone tab; closing it closes the window.
                                TabChip(tab: tab, isActive: tab.id == model.activeTabID,
                                        isDropTargeted: dropTargetedTabID == tab.id,
                                        select: { model.selectTab(tab.id) },
                                        close: { controller.closeTab(tab.id) })
                                    .id(tab.id)
                                    .transition(reduceMotion
                                        ? .opacity
                                        : .opacity.combined(with: .scale(scale: 0.94)))
                                    .contextMenu { tabMenu(tab) }
                                    .onDrag {
                                        NSItemProvider(object: tab.id.uuidString as NSString)
                                    }
                                    .onDrop(of: [.plainText, .fileURL], delegate: TabDropDelegate(
                                        tab: tab, model: model, controller: controller,
                                        setDropTargeted: { targeted in
                                            if targeted { dropTargetedTabID = tab.id }
                                            else if dropTargetedTabID == tab.id { dropTargetedTabID = nil }
                                        },
                                        reorder: { reorder($0, onto: tab) }))
                            }
                            Button(action: { controller.newTab() }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 28, height: 28)
                                    .wumiGlass(in: Circle(), interactive: true)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(WumiInteractiveButtonStyle(cornerRadius: 14, hoverOpacity: 0.06, pressOpacity: 0.14, pressScale: 0.93))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                            .help(L("New Tab"))
                            .accessibilityIdentifier("Tabs.New")
                            .accessibilityLabel(L("New Tab"))
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(WumiMotion.resolve(WumiMotion.snappy, reduceMotion: reduceMotion), value: model.tabs.map(\.id))
                }
                .onChange(of: model.activeTabID) { _, id in
                    if reduceMotion { proxy.scrollTo(id) }
                    else { withAnimation(WumiMotion.quick) { proxy.scrollTo(id) } }
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
    let setDropTargeted: (Bool) -> Void
    let reorder: ([NSItemProvider]) -> Bool

    @MainActor private static var switchTimer: Timer?

    private var directory: URL? { tab.activePane.currentDirectory }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) || (info.hasItemsConforming(to: [.fileURL]) && directory != nil)
    }

    func dropEntered(info: DropInfo) {
        setDropTargeted(true)
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
        setDropTargeted(false)
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

/// Elevated Liquid Glass capsule tabs aligned with macOS 26/27 and Miji's pill grammar.
private struct TabChip: View {
    @ObservedObject var tab: TabRuntime
    let isActive: Bool
    let isDropTargeted: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: Capsule { Capsule() }
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        HStack(spacing: 5.5) {
            Group {
                if tab.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 10.5)).foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: tab.panes.count > 1 ? "rectangle.split.2x1" : "folder")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 11.5)
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary.opacity(0.85))
                }
            }
            .frame(width: 13)
            Text(tab.title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !tab.isPinned {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 17, height: 17)
                        .contentShape(Circle())
                }
                .buttonStyle(WumiInteractiveButtonStyle(cornerRadius: 8.5, hoverOpacity: 0.11, pressOpacity: 0.19, pressScale: 0.90))
                .foregroundStyle(.secondary)
                .opacity(isActive || hovering ? 1 : 0)
                .allowsHitTesting(isActive || hovering)
                .animation(WumiMotion.micro, value: isActive || hovering)
                .help(L("Close Tab"))
                .accessibilityIdentifier("Tabs.Close.\(tab.id.uuidString)")
                .accessibilityLabel(L("Close Tab"))
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(width: 180, height: 29)
        .modifier(TabChipSurfaceModifier(
            isActive: isActive,
            isDropTargeted: isDropTargeted,
            hovering: hovering,
            isPinned: tab.isPinned
        ))
        .contentShape(shape)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .animation(WumiMotion.micro, value: hovering)
        .animation(WumiMotion.micro, value: isActive)
        .animation(WumiMotion.micro, value: isDropTargeted)
        .help(tab.activePane.currentDirectory?.path ?? tab.title)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Tab.\(tab.id.uuidString)")
        .accessibilityLabel(LF(tab.isPinned ? "Pinned tab %@" : "Tab %@", tab.title))
    }
}

private struct TabChipSurfaceModifier: ViewModifier {
    let isActive: Bool
    let isDropTargeted: Bool
    let hovering: Bool
    let isPinned: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var dark: Bool { colorScheme == .dark }

    func body(content: Content) -> some View {
        let shape = Capsule()
        if isActive && !isDropTargeted && !reduceTransparency {
            content
                .wumiGlass(in: shape, interactive: true)
                .overlay(
                    shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.45) : .clear, lineWidth: 1)
                )
        } else {
            content
                .background(
                    shape
                        .fill(fill)
                        .shadow(color: isActive ? Theme.pillShadow(dark: dark) : .clear, radius: isActive ? 2.5 : 0, y: isActive ? 1 : 0)
                )
                .overlay(
                    shape.strokeBorder(borderColor, lineWidth: isDropTargeted ? 1.5 : (isActive && contrast == .increased ? 1 : 0.5))
                )
        }
    }

    private var fill: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.16) }
        if isActive { return Theme.elevatedSurface(dark: dark) }
        if hovering { return Theme.chipFill(dark: dark, hovered: true, selected: false) }
        if isPinned { return Color.primary.opacity(0.03) }
        return .clear
    }

    private var borderColor: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.75) }
        if isActive { return contrast == .increased ? Color.primary.opacity(0.45) : Theme.hairline(dark: dark) }
        return .clear
    }
}
