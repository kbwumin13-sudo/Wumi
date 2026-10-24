import AppKit
import Combine
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

final class DesktopPanel: NSPanel {
    weak var coordinator: DesktopCoordinator?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var undoManager: UndoManager? { coordinator?.undoManager }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .window }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .standardWindow }
    override func accessibilityTitle() -> String? { title }
}

@MainActor
final class DesktopWindowController: NSWindowController, NSWindowDelegate {
    let coordinator: DesktopCoordinator
    let screenID: String
    private var hosting: NSHostingView<DesktopCanvasView>!
    init(coordinator: DesktopCoordinator, screen: NSScreen, screenID: String) {
        self.coordinator = coordinator; self.screenID = screenID
        let panel = DesktopPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.coordinator = coordinator
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.isRestorable = false
        panel.isReleasedWhenClosed = false
        panel.title = L("Wumi Desktop")
        panel.identifier = NSUserInterfaceItemIdentifier("Wumi.Desktop.\(screenID)")
        panel.setAccessibilityIdentifier("Wumi.Desktop.\(screenID)")
        super.init(window: panel)
        panel.delegate = self
        hosting = NSHostingView(rootView: DesktopCanvasView(coordinator: coordinator, pane: coordinator.pane!, screenID: screenID))
        panel.contentView?.addSubview(hosting)
        update(screen: screen)
    }
    required init?(coder: NSCoder) { fatalError() }
    func showDesktop() { window?.orderFrontRegardless() }
    func reload() { hosting?.needsLayout = true }
    func update(screen: NSScreen) {
        window?.setFrame(screen.frame, display: false)
        let visible = screen.visibleFrame
        hosting.frame = NSRect(x: visible.minX - screen.frame.minX, y: visible.minY - screen.frame.minY, width: visible.width, height: visible.height)
    }
    func closeDesktop() {
        window?.delegate = nil
        window?.orderOut(nil)
        hosting?.removeFromSuperview()
        hosting = nil
        close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { coordinator.setEnabled(false); return false }
}

private struct DesktopCanvasView: View {
    @ObservedObject var coordinator: DesktopCoordinator
    @ObservedObject var pane: PaneRuntime
    let screenID: String
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                ForEach(coordinator.zones(on: screenID)) { zone in
                    DesktopZoneView(coordinator: coordinator, pane: pane, zone: zone, screenSize: geometry.size)
                }
                if let widget = coordinator.layout.searchWidgets[screenID], widget.isVisible {
                    DesktopSearchView(coordinator: coordinator, screenID: screenID, widget: widget, screenSize: geometry.size)
                }
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Label(L("Wumi Desktop"), systemImage: "desktopcomputer").font(.headline)
                        Toggle(L("Group by Type"), isOn: Binding(get: { coordinator.layout.automaticGrouping }, set: { coordinator.setAutomaticGrouping($0) }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("Desktop.GroupByType")
                        Button(L("New Collection")) { coordinator.addZone(screenID: screenID) }.accessibilityIdentifier("Desktop.AddCollection")
                        Button(L("Desktop Search")) {
                            var widget = coordinator.layout.searchWidgets[screenID] ?? .init(frame: .init(x: 60, y: 80, width: 470, height: 340))
                            widget.isVisible = true
                            coordinator.setSearch(screenID: screenID, widget: widget)
                        }.accessibilityIdentifier("Desktop.ShowSearch")
                        Spacer()
                        Button(L("Show macOS Desktop")) { coordinator.setEnabled(false) }.accessibilityIdentifier("Desktop.Disable")
                    }.padding(12)
                    if case .failed(let reason) = pane.loadState {
                        HStack {
                            Label(pane.loadFailure == .accessDenied ? L("Desktop access is required. Allow access in Privacy & Security, then retry.") : reason, systemImage: "exclamationmark.triangle")
                            Button(L("Retry")) { coordinator.refresh() }
                            Spacer()
                        }.padding(12).background(Color(nsColor: .controlBackgroundColor))
                    } else if pane.loadState == .loading {
                        HStack { ProgressView().controlSize(.small); Text(L("Loading Desktop…")); Spacer() }.padding(12)
                    }
                    if let message = coordinator.message {
                        HStack { Text(message).textSelection(.enabled); Spacer(); Button(L("Dismiss")) { coordinator.clearMessage() } }
                            .padding(12).background(Color(nsColor: .controlBackgroundColor))
                    }
                    Spacer()
                }
            }
        }.accessibilityIdentifier("Desktop.Canvas.\(screenID)")
    }
}

private struct DesktopZoneView: View {
    @ObservedObject var coordinator: DesktopCoordinator
    @ObservedObject var pane: PaneRuntime
    let zone: DesktopZone
    let screenSize: CGSize
    @State private var moveStart: DesktopRect?
    @State private var resizeStart: DesktopRect?
    @State private var titleDraft = ""
    @State private var editingTitle = false
    private var rect: DesktopRect { zone.frame.clamped(width: screenSize.width, height: screenSize.height) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { coordinator.updateZone(zone.id) { $0.isCollapsed.toggle() } } label: {
                    Image(systemName: zone.isCollapsed ? "chevron.right" : "chevron.down")
                }.buttonStyle(.plain).accessibilityLabel(L("Collapse Collection")).accessibilityIdentifier("Desktop.Zone.\(zone.id).Collapse")
                if editingTitle {
                    TextField(L("Collection Name"), text: $titleDraft, onCommit: {
                        let name = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { coordinator.updateZone(zone.id) { $0.title = name } }
                        editingTitle = false
                    }).accessibilityIdentifier("Desktop.Zone.\(zone.id).Name")
                } else {
                    Text(zone.isCustom ? zone.title : L(zone.title)).font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).onTapGesture(count: 2) { if zone.isCustom { titleDraft = zone.title; editingTitle = true } }
                }
                Text("\(coordinator.items(in: zone.id).count)").foregroundStyle(.secondary).font(.caption)
                Spacer(minLength: 0)
                Menu {
                    Button(L("New Folder")) { actions().create(folder: true) }
                    Button(L("New Text File")) { actions().create(folder: false) }
                    if zone.isCustom {
                        Button(L("Rename Collection")) { titleDraft = zone.title; editingTitle = true }
                        Button(L("Remove Collection")) { coordinator.removeZone(zone.id) }
                    }
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        Button(LF("Move to Display: %@", screen.localizedName)) {
                            coordinator.updateZone(zone.id) { $0.screenID = DesktopCoordinator.screenID(screen) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            .padding(.horizontal, 10).frame(height: 36)
            .background(Color(nsColor: .controlBackgroundColor))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 5).onChanged { value in
                if moveStart == nil { moveStart = rect }
                guard var frame = moveStart else { return }
                frame.x += value.translation.width; frame.y += value.translation.height
                coordinator.updateZone(zone.id) { $0.frame = frame.clamped(width: screenSize.width, height: screenSize.height) }
            }.onEnded { _ in moveStart = nil })
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                DesktopDrop.load(providers) { urls in
                    _ = actions().acceptDrop(urls, into: pane.currentDirectory!, operation: .copy, in: pane)
                }
                return true
            }
            if !zone.isCollapsed {
                DesktopGridHost(coordinator: coordinator, pane: pane, zoneID: zone.id, screenID: zone.screenID,
                                standard: !coordinator.layout.automaticGrouping && coordinator.layout.zones.allSatisfy { !$0.isCustom })
                HStack {
                    Spacer()
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 16).contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if resizeStart == nil { resizeStart = rect }
                            guard var frame = resizeStart else { return }
                            frame.width += value.translation.width; frame.height += value.translation.height
                            coordinator.updateZone(zone.id) { $0.frame = frame.clamped(width: screenSize.width, height: screenSize.height) }
                        }.onEnded { _ in resizeStart = nil })
                }.frame(height: 16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .frame(width: rect.width, height: zone.isCollapsed ? 36 : rect.height)
        .offset(x: rect.x, y: rect.y)
        .accessibilityIdentifier("Desktop.Zone.\(zone.id)")
    }
    private func actions() -> DesktopBrowserActions { DesktopBrowserActions(coordinator: coordinator, pane: pane, zoneID: zone.id, screenID: zone.screenID) }
}

private struct DesktopSearchView: View {
    @ObservedObject var coordinator: DesktopCoordinator
    let screenID: String
    let widget: DesktopSearchWidget
    let screenSize: CGSize
    @State private var moveStart: DesktopRect?
    @State private var resizeStart: DesktopRect?
    private var rect: DesktopRect { widget.frame.clamped(width: screenSize.width, height: screenSize.height, minimumWidth: 360, minimumHeight: 180) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("Desktop Search"), systemImage: "magnifyingglass").font(.headline)
                Spacer()
                Button { var value = widget; value.isVisible = false; coordinator.setSearch(screenID: screenID, widget: value) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L("Close Search"))
            }.padding(10).background(Color(nsColor: .controlBackgroundColor)).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                    if moveStart == nil { moveStart = rect }
                    guard var frame = moveStart else { return }
                    frame.x += value.translation.width; frame.y += value.translation.height
                    var widget = widget; widget.frame = frame.clamped(width: screenSize.width, height: screenSize.height, minimumWidth: 360, minimumHeight: 180)
                    coordinator.setSearch(screenID: screenID, widget: widget)
                }.onEnded { _ in moveStart = nil })
            EmbeddedMijiSearchView(context: coordinator.pane?.currentDirectory, currentFolderOnly: false,
                              onReveal: { coordinator.reveal($0) }, onDismiss: {
                var widget = widget; widget.isVisible = false; coordinator.setSearch(screenID: screenID, widget: widget)
            })
            HStack {
                Spacer()
                Image(systemName: "line.3.horizontal.decrease").frame(width: 24, height: 16).contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in
                        if resizeStart == nil { resizeStart = rect }
                        guard var frame = resizeStart else { return }
                        frame.width += value.translation.width; frame.height += value.translation.height
                        var widget = widget; widget.frame = frame.clamped(width: screenSize.width, height: screenSize.height, minimumWidth: 360, minimumHeight: 180)
                        coordinator.setSearch(screenID: screenID, widget: widget)
                    }.onEnded { _ in resizeStart = nil })
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
        .frame(width: rect.width, height: rect.height).offset(x: rect.x, y: rect.y)
        .accessibilityIdentifier("Desktop.Search.\(screenID)")
    }
}

@MainActor
private enum DesktopDrop {
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url: URL = await withCheckedContinuation({ continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                        if let data = value as? Data { continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil)) }
                        else if let url = value as? URL { continuation.resume(returning: url) }
                        else { continuation.resume(returning: nil) }
                    }
                }) { urls.append(url) }
            }
            if !urls.isEmpty { completion(urls) }
        }
    }
}
