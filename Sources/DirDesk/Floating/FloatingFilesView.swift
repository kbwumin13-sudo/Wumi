import AppKit
import DirDeskCore
import SwiftUI

/// Tabs of the Floating Files window: the staging shelf, Downloads, folders the user added, and bookmarks.
enum FloatingTab: Hashable {
    case staging
    case folder(URL)
    case bookmarks
}

/// Floating Files window content, laid out like the original (reference 11-中转舱与浮窗): a tab capsule with
/// Add Folder / Keep Open / Settings / Close on the right, the tab body, and a bottom bar per tab.
struct FloatingFilesView: View {
    @ObservedObject var pane: PaneRuntime
    @ObservedObject var store = FileFloatingStore.shared
    @ObservedObject var controller: FloatingFilesController
    // `-DirDeskSnapshotFloatingTab bookmarks` starts on Bookmarks, for rendering (see `DebugSnapshot`).
    @State private var tab: FloatingTab = UserDefaults.standard.string(forKey: "DirDeskSnapshotFloatingTab") == "bookmarks" ? .bookmarks : .staging
    @State private var showingSettings = false
    @State private var bookmarkFolder: UUID?
    @State private var browsingBookmark: URL?

    static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    private var folderTabs: [URL] {
        [Self.downloads] + store.configuration.pinnedDirectories.filter { $0.standardizedFileURL != Self.downloads.standardizedFileURL }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch tab {
                case .staging: FloatingStagingView(controller: controller)
                case .folder(let root): FloatingFolderView(pane: pane, root: root, controller: controller)
                case .bookmarks:
                    if let browsingBookmark {
                        FloatingFolderView(pane: pane, root: browsingBookmark, controller: controller) { self.browsingBookmark = nil }
                    } else {
                        FloatingBookmarksView(parent: $bookmarkFolder) { url in
                            browsingBookmark = url
                            pane.open(url)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.135)))
        .overlay(alignment: .bottomLeading) { ResizeGrip(controller: controller).padding(6) }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $showingSettings) { FloatingFilesSettingsSheet { showingSettings = false } }
        .onChange(of: tab) { _, newValue in
            if case .folder(let root) = newValue, !(pane.currentDirectory?.path.hasPrefix(root.path) ?? false) { pane.open(root) }
        }
    }

    /// Measured from the original: 30 pt tab capsules 4.5 pt apart from 18 pt in, the four tools 22.5 pt apart on
    /// the right, all centred in a 56 pt row.
    private var header: some View {
        HStack(spacing: 4.5) {
            tabButton(.staging, title: L("Staging"), symbol: "tray")
            ForEach(folderTabs, id: \.self) { url in
                tabButton(.folder(url), title: url == Self.downloads ? L("Downloads") : PathUtilities.displayName(for: url),
                          symbol: url == Self.downloads ? "arrow.down.to.line" : "folder")
                    .contextMenu {
                        if url != Self.downloads {
                            Button(L("Remove")) {
                                store.configuration.pinnedDirectories.removeAll { $0 == url }
                                if tab == .folder(url) { tab = .staging }
                            }
                        }
                    }
            }
            tabButton(.bookmarks, title: L("Bookmarks"), symbol: "bookmark")
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                headerButton("plus", L("Add Folder"), identifier: "FileFloating.AddFolder") { addFolder() }
                headerButton(controller.keepsOpen ? "pin.fill" : "pin", L("Keep Open"), identifier: "FileFloating.KeepOpen") {
                    controller.keepsOpen.toggle()
                }
                .accessibilityValue(controller.keepsOpen ? L("On") : L("Off"))
                headerButton("ellipsis", L("File Floating Settings"), identifier: "FileFloating.Settings") { showingSettings = true }
                headerButton("xmark", L("Close"), identifier: "FileTransit.Collapse") { controller.hide() }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 13.5)
        .frame(height: 56)
    }

    private func tabButton(_ value: FloatingTab, title: String, symbol: String) -> some View {
        let selected = tab == value
        return Button {
            tab = value
            if value == .bookmarks { browsingBookmark = nil }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.leading, 13.5)
            .padding(.trailing, 13)
            .frame(height: 30)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.16) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(value == .staging ? "FileFloating.Staging" : (value == .bookmarks ? "FileFloating.Bookmarks" : "FileFloating.Folder"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func headerButton(_ symbol: String, _ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5)).frame(width: 22.5, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.configuration.pinnedDirectories.contains(url) && url.standardizedFileURL != Self.downloads.standardizedFileURL {
            store.configuration.pinnedDirectories.append(url)
        }
        tab = .folder(url)
    }
}

/// Bottom-left grip that resizes the window from its lower-left corner.
private struct ResizeGrip: View {
    let controller: FloatingFilesController
    @State private var start: NSRect?

    var body: some View {
        Image(systemName: "line.diagonal")
            .font(.system(size: 12, weight: .light))
            .foregroundStyle(.tertiary)
            .overlay(Image(systemName: "line.diagonal").font(.system(size: 7, weight: .light)).foregroundStyle(.tertiary).offset(x: -2, y: 2))
            .rotationEffect(.degrees(90))
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if start == nil { start = controller.panelFrame }
                    guard let start else { return }
                    controller.resizePanel(from: start, by: value.translation)
                }
                .onEnded { _ in
                    start = nil
                    controller.persistPanelSize()
                })
            .help(L("Resize Window"))
            .accessibilityLabel(L("Resize Window"))
    }
}

// MARK: Folder browser

private struct FloatingFolderView: View {
    @ObservedObject var pane: PaneRuntime
    let root: URL
    let controller: FloatingFilesController
    var leave: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    if let leave, pane.currentDirectory?.hasSamePath(as: root) == true { leave() } else { pane.goUp() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text(pane.currentDirectory.map { PathUtilities.displayName(for: $0) } ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(leave == nil && pane.currentDirectory?.hasSamePath(as: root) == true)
                .help(L("Up One Level"))
                TextField(L("Search loaded files"), text: $pane.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Picker("", selection: $pane.viewConfiguration.mode) {
                    Image(systemName: "square.grid.2x2").tag(BrowserViewMode.icons)
                    Image(systemName: "list.bullet").tag(BrowserViewMode.list)
                    Image(systemName: "rectangle.split.3x1").tag(BrowserViewMode.columns)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                Button { pane.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(.secondary).help(L("Reload"))
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            Divider()
            controller.browserView()
                .onAppear { controller.setBrowserVisible(true) }
                .onDisappear { controller.setBrowserVisible(false) }
            Divider()
            HStack(spacing: 12) {
                Text(pane.rows.filter { $0.item != nil }.count.formatted()).font(.system(size: 12)).foregroundStyle(.secondary)
                Image(systemName: "photo.on.rectangle").font(.system(size: 12)).foregroundStyle(.secondary)
                Slider(value: thumbnailBinding, in: pane.viewConfiguration.mode == .list ? 16...64 : 0.5...2.5).controlSize(.mini).frame(width: 110)
                Spacer()
                let selection = pane.selectedItems
                Button(L("Super Preview")) { controller.superPreview(selection) }.disabled(selection.count != 1)
                Button(L("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects(selection.map { $0.url as NSURL })
                }
                .disabled(selection.isEmpty)
                Button(L("Share…")) { controller.share(selection) }.disabled(selection.isEmpty)
                Button(L("Show in Wumi")) { controller.showInMainWindow(selection) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .padding(.leading, 30)
            .padding(.trailing, 16)
            .frame(height: 40)
        }
    }

    private var thumbnailBinding: Binding<Double> {
        Binding(get: {
            pane.viewConfiguration.mode == .list ? pane.viewConfiguration.listThumbnailSize : pane.viewConfiguration.gridThumbnailScale
        }, set: { value in
            if pane.viewConfiguration.mode == .list { pane.viewConfiguration.listThumbnailSize = value.rounded() } else { pane.viewConfiguration.gridThumbnailScale = value }
        })
    }
}

// MARK: Bookmarks

/// Bookmarks as full-width cards (folder icon, name), measured from the original; inside a folder a small
/// "Back" button leads the list.
private struct FloatingBookmarksView: View {
    @Binding var parent: UUID?
    let open: (URL) -> Void
    @ObservedObject var library = LibraryModel.shared

    var body: some View {
        let nodes = library.bookmarks.children(of: parent)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let parent, let node = library.bookmarks.nodes.first(where: { $0.id == parent }) {
                    Button(L("Back")) { self.parent = node.parentID }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.leading, -2)
                        .padding(.top, -2)
                        .accessibilityLabel(L("Back"))
                }
                if nodes.isEmpty && parent == nil {
                    Text(L("No Bookmarks")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                }
                ForEach(nodes) { node in
                    Button {
                        if node.isFolder { parent = node.id } else if let target = node.target { open(target.url) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: node.isFolder || node.target?.kind == .folder ? "folder" : "doc")
                                .font(.system(size: 23.5)).foregroundStyle(Color.accentColor)
                            Text(node.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer()
                        }
                        .padding(.leading, 18)
                        .frame(height: 51.5)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.022)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(node.displayTitle)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 13)
            .padding(.bottom, 12)
        }
    }
}

struct FloatingFilesSettingsSheet: View {
    @ObservedObject var store = FileFloatingStore.shared
    @ObservedObject var app = AppModel.shared
    let done: () -> Void
    @State private var screenName = NSScreen.main?.localizedName ?? ""
    @State private var recording = false
    @State private var monitor: Any?

    private var screen: NSScreen? { NSScreen.screens.first { $0.localizedName == screenName } ?? NSScreen.main }

    /// One grouped list as in the original: position, display, the three hot-zone switches, Preview Hot Zone,
    /// the hover delay with its value on the same row, the shortcut, the window size, and Reset, with the notes
    /// under the rows they explain.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("File Floating Settings")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(L("Done"), action: done).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 21)
            Form {
                Section {
                    Picker(L("Floating Files trigger position"), selection: Binding(get: { app.preferences.fileTransitDockEdge },
                                                                                 set: { edge in AppModel.shared.updatePreferences { $0.fileTransitDockEdge = edge } })) {
                        Text(L("Top")).tag(FileTransitDockEdge.top)
                        Text(L("Left")).tag(FileTransitDockEdge.left)
                        Text(L("Right")).tag(FileTransitDockEdge.right)
                    }
                    .accessibilityIdentifier("FileFloating.ScreenEdge")
                    note(L("Where Floating Files appears; the same setting as in Settings."))
                    Picker(L("Display"), selection: $screenName) {
                        ForEach(NSScreen.screens, id: \.localizedName) { Text($0.localizedName).tag($0.localizedName) }
                    }
                    Toggle(L("Enable hot zone on this display"), isOn: zoneBinding(\.enabled))
                        .accessibilityIdentifier("FileFloating.HotZone.Enabled")
                    Toggle(L("Open on hover"), isOn: zoneBinding(\.hoverEnabled))
                        .accessibilityIdentifier("FileFloating.HotZone.HoverEnabled")
                    Toggle(L("Custom hot zone"), isOn: zoneBinding(\.custom))
                        .accessibilityIdentifier("FileFloating.HotZone.Custom")
                    note(L("Each display and screen edge keeps its own trigger settings."))
                    Button(L("Preview Hot Zone")) { HotZoneController.shared.previewZones() }
                        .accessibilityIdentifier("FileFloating.HotZone.Preview")
                    LabeledContent(L("Hover Delay")) {
                        HStack(spacing: 12) {
                            Slider(value: $store.configuration.hoverDelay, in: 0...1, step: 0.05)
                                .accessibilityLabel(L("Hover Delay"))
                                .accessibilityIdentifier("FileFloating.HotZone.Delay")
                            Text(LF("%@ s", String(format: "%.2f", store.configuration.hoverDelay))).monospacedDigit()
                        }
                        .frame(width: 300)
                    }
                    note(L("Opens after the pointer stays in the hot zone this long; dragging files in opens it right away."))
                    Toggle(L("Enable Global Shortcut"), isOn: $store.configuration.shortcutEnabled)
                    HStack(spacing: 12) {
                        Text(store.configuration.shortcutLabel).font(.system(size: 13, weight: .medium))
                        Button { recording ? stopRecording() : startRecording() } label: {
                            Text(recording ? L("Press a Shortcut…") : L("Record Shortcut")).frame(maxWidth: .infinity)
                        }
                    }
                    note(L("Dragging items out of Staging leaves the originals in place. A move removes the exported unlocked records; a copy keeps them."))
                    LabeledContent(L("Window Width")) {
                        Slider(value: $store.configuration.panelWidth, in: 520...1400, step: 10).frame(width: 270)
                    }
                    LabeledContent(L("Window Height")) {
                        Slider(value: $store.configuration.panelHeight, in: 280...900, step: 10).frame(width: 270)
                    }
                    note(L("Without a custom hot zone, screens with a notch open it at the notch and other screens near the Wumi menu bar icon. If you hide the icon, set the top hot zone yourself."))
                    Button(L("Reset Floating Files Settings")) { store.reset() }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 540)
        .onDisappear(perform: stopRecording)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func zoneBinding(_ keyPath: WritableKeyPath<FileFloatingConfiguration.HotZone, Bool>) -> Binding<Bool> {
        Binding(get: {
            guard let screen else { return false }
            return store.configuration.hotZone(for: screen, edge: app.preferences.fileTransitDockEdge)[keyPath: keyPath]
        }, set: { value in
            guard let screen else { return }
            let key = FileFloatingConfiguration.key(screen, app.preferences.fileTransitDockEdge)
            var zone = store.configuration.hotZone(for: screen, edge: app.preferences.fileTransitDockEdge)
            zone[keyPath: keyPath] = value
            store.configuration.screens[key] = zone
        })
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !flags.isEmpty else { return nil }
            store.configuration.shortcutKey = UInt32(event.keyCode)
            store.configuration.shortcutModifiers = KeyCodeNames.carbonModifiers(flags)
            store.configuration.shortcutLabel = FileFloatingConfiguration.label(keyCode: UInt32(event.keyCode), modifiers: store.configuration.shortcutModifiers)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
