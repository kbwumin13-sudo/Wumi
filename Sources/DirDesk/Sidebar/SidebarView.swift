import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers
import SystemConfiguration

/// Sidebar with the five configurable modules, a brand header and the Settings button.
struct SidebarView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var app = AppModel.shared
    @ObservedObject var library = LibraryModel.shared
    @ObservedObject var volumes = VolumeMonitor.shared
    @ObservedObject var tagCatalog = FinderTagCatalog.shared
    let controller: WorkspaceController
    @State private var collapsed: Set<SidebarModule> = []
    @State private var initialized = false
    @State private var transitCount = FileTransitStore.shared.items.count
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let preferences = app.preferences
        let dark = colorScheme == .dark
        let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            // Traffic lights and the sidebar toggle sit cleanly inside the top of the floating glass sidebar.
            Color.clear.frame(height: WorkspaceWindow.titleRowHeight - 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6.5) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 19, height: 19)
                            .shadow(color: .black.opacity(0.16), radius: 2, y: 0.8)
                        Text("Wumi").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color(nsColor: .labelColor))
                    }
                    .padding(.leading, 12)
                    .frame(height: 24)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("Sidebar.Brand")
                    ForEach(preferences.sidebarModuleOrder.filter { !preferences.hiddenSidebarModules.contains($0) }, id: \.self) { module in
                        section(module, preferences: preferences)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            Rectangle()
                .fill(Theme.hairline(dark: dark))
                .frame(height: 0.5)
                .padding(.horizontal, 12)
            Button { controller.showSettings(section: nil) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(L("Settings…")).font(.system(size: 12.5, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(WumiInteractiveButtonStyle(cornerRadius: 9, hoverOpacity: 0.07, pressOpacity: 0.14, pressScale: 0.985))
            .foregroundStyle(Color(nsColor: .labelColor))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .accessibilityIdentifier("Sidebar.Settings")
        }
        .background {
            if reduceTransparency {
                cardShape.fill(Theme.elevatedSurface(dark: dark))
                    .overlay(cardShape.strokeBorder(Theme.subtleBorder(dark: dark), lineWidth: 0.75))
            } else {
                // Single-layer tinted floating surface over unified Theme.chrome so the sidebar
                // stays within one gentle tonal step of the workspace even over bright desktops.
                ZStack {
                    if #available(macOS 26.0, *) {
                        WumiGlassSurface(
                            shape: cardShape,
                            tint: dark ? Color(white: 0.28).opacity(0.36) : Color.white.opacity(0.46),
                            fallbackMaterial: .sidebar
                        )
                    } else {
                        cardShape.fill(dark ? Color.white.opacity(0.045) : Color.white.opacity(0.62))
                    }
                    cardShape.strokeBorder(Theme.hairline(dark: dark), lineWidth: 0.5)
                }
            }
        }
        .clipShape(cardShape)
        .shadow(color: Color.black.opacity(dark ? 0.20 : 0.06), radius: 6, y: 2)
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .background(Theme.chrome)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if let stored = UserDefaults.standard.stringArray(forKey: DefaultsKey.sidebarCollapsedSections) {
                collapsed = Set(stored.compactMap(SidebarModule.init(rawValue:)))
            } else {
                collapsed = Set(SidebarModule.allCases).subtracting(preferences.defaultExpandedSidebarModules)
            }
        }
        .onReceive(FileTransitStore.shared.$items.map(\.count).removeDuplicates()) { transitCount = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .dirDeskExpandSidebar)) { _ in collapsed = [] }
    }

    @ViewBuilder
    private func section(_ module: SidebarModule, preferences: WorkspacePreferences) -> some View {
        let isCollapsed = collapsed.contains(module)
        HStack(spacing: 4) {
            Button {
                WumiMotion.withPreferredAnimation(WumiMotion.snappy, reduceMotion: reduceMotion) {
                    if isCollapsed { collapsed.remove(module) } else { collapsed.insert(module) }
                    UserDefaults.standard.set(collapsed.map(\.rawValue).sorted(), forKey: DefaultsKey.sidebarCollapsedSections)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 12)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    Text(Self.title(module)).font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    Spacer()
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Sidebar.Section.\(module.rawValue)")
            .accessibilityValue(isCollapsed ? L("Collapsed") : L("Expanded"))
            addControl(module)
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 28)
        .padding(.top, 4)
        // Folders dropped on the Common Paths heading are added to it.
        .onDrop(of: module == .commonPaths ? [.fileURL] : [], isTargeted: nil) { providers in
            controller.loadURLs(from: providers) { urls in
                for url in urls { library.addCommonPath(url) }
            }
            return true
        }
        if !isCollapsed {
            VStack(alignment: .leading, spacing: 1) {
                switch module {
                case .builtIn: builtInRows(preferences)
                case .commonPaths: commonPathRows
                case .locations: locationRows(preferences)
                case .bookmarks: BookmarkSidebarRows(parent: nil, depth: 0, model: model, controller: controller)
                case .tags: tagRows
                }
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private func addControl(_ module: SidebarModule) -> some View {
        switch module {
        case .commonPaths:
            // The original's menu: Add from Bookmarked Folders…, Choose Folder…, Import Finder Favorites…; the
            // current folder and the built-in places follow as extras.
            Menu {
                Menu(L("Add from Bookmarked Folders…")) {
                    let folders = library.bookmarks.allTargets().filter { $0.target?.kind == .folder }
                    if folders.isEmpty { Text(L("No bookmarked folders found.")) }
                    ForEach(folders) { node in
                        Button(node.title) { if let url = node.target?.url { library.addCommonPath(url) } }
                    }
                }
                Button(L("Choose Folder…")) { controller.chooseCommonPath() }
                Button(L("Import Finder Favorites…")) { controller.importFinderFavorites() }
                    .accessibilityIdentifier("Sidebar.CommonPaths.ImportFinder")
                Divider()
                Button(L("Add Current Folder to Common Paths")) {
                    if let url = model.activePane.currentDirectory { library.addCommonPath(url) }
                }
                ForEach(CommonPathEntry.builtInOptions, id: \.self) { name in
                    Button(Self.builtInTitle(name)) { library.addBuiltInCommonPath(name) }
                        .disabled(library.commonPaths.contains(.builtIn(name)))
                }
            } label: { plusLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("Add to Common Paths")).accessibilityIdentifier("Sidebar.CommonPaths.Add")
        case .locations:
            // The original's ＋ lists the connection types; each opens Connect to Server with that type.
            Menu {
                ForEach(ConnectToServerSheet.protocolOrder, id: \.self) { kind in
                    Button(ConnectToServerSheet.menuTitle(kind)) { controller.presentConnectToServer(protocolKind: kind) }
                }
            } label: { plusLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("Add Network Location")).accessibilityIdentifier("Sidebar.Locations.Add")
        case .bookmarks:
            Menu {
                Button(L("Add Current Folder")) { controller.addBookmarkForCurrentFolder() }
                Button(L("New Bookmark Folder…")) { controller.newBookmarkFolder(parent: nil) }
                Button(L("Manage Bookmarks…")) { controller.showBookmarkManager() }
            } label: { plusLabel }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("Add Bookmark")).accessibilityIdentifier("Sidebar.Bookmarks.Add")
        case .tags:
            Button { controller.createSidebarTag() } label: { plusLabel }
                .buttonStyle(.plain).help(L("Add Tag")).accessibilityIdentifier("Sidebar.Tags.Add")
        case .builtIn:
            EmptyView()
        }
    }

    /// Menu labels drop SwiftUI styling, so the grey "+" is a baked image.
    private var plusLabel: some View {
        Image(nsImage: Self.plusImage).frame(width: 16, height: 16)
    }

    static let plusImage: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [.secondaryLabelColor]))
        let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }()

    @ViewBuilder
    private func builtInRows(_ preferences: WorkspacePreferences) -> some View {
        let hidden = Set(preferences.hiddenSidebarBuiltInItems)
        if !hidden.contains(.recent) {
            SidebarRow(title: L("Recent"), symbol: "clock", tint: .blue, colored: preferences.usesColoredSidebarIcons,
                       selected: model.activePane.destination.map { if case .recent = $0 { true } else { false } } ?? false) {
                controller.openRecent()
            }
            .contextMenu {
                Button(L("Open")) { controller.openRecent() }
                Button(L("Open in New Tab")) { controller.model.newTab(destination: .recent(.preset(.week))) }
            }
            .accessibilityIdentifier("Sidebar.Location.recent")
        }
        if !hidden.contains(.fileTransit) {
            SidebarRow(title: L("Floating Files"), symbol: "shippingbox", tint: .blue, colored: preferences.usesColoredSidebarIcons,
                       selected: false, badge: transitCount == 0 ? nil : "\(transitCount)") {
                controller.showFileTransit()
            }
            .accessibilityIdentifier("FileTransit.WindowShortcut")
        }
        if !hidden.contains(.sharedFolder) {
            locationRow(title: L("Shared Folder"), url: URL(fileURLWithPath: "/Users/Shared"), symbol: "folder.badge.person.crop", identifier: "shared-folder", preferences: preferences)
        }
    }

    private var commonPathRows: some View {
        ForEach(library.commonPaths, id: \.self) { entry in
            let title: String = switch entry {
            case .builtIn(let name): Self.builtInTitle(name)
            case .folder(_, let title): title
            }
            let symbol: String = switch entry {
            case .builtIn("applications"): ApplicationsGlyph.name
            case .builtIn("desktop"): "menubar.dock.rectangle"
            case .builtIn("downloads"): "arrow.down.circle"
            case .builtIn("documents"): "doc"
            case .builtIn("movies"): "film"
            case .builtIn("music"): "music.note"
            case .builtIn("pictures"): "photo"
            case .builtIn("home"): "house"
            default: "folder"
            }
            SidebarRow(title: title, symbol: symbol, tint: .blue, colored: app.preferences.usesColoredSidebarIcons,
                       selected: model.activePane.currentDirectory?.hasSamePath(as: entry.url) == true) {
                controller.navigateActivePane(to: entry.url)
            }
            .help(entry.url.path)
            .contextMenu {
                Button(L("Open")) { controller.navigateActivePane(to: entry.url) }
                Button(L("Open in New Tab")) { controller.newTab(directory: entry.url) }
                Button(L("Remove from Common Paths")) { library.removeCommonPath(entry) }
            }
            // Drag a row to reorder Common Paths; files dropped on a row go into that folder.
            .onDrag { SidebarOrder.provider(module: .commonPaths, index: library.commonPaths.firstIndex(of: entry) ?? 0) }
            .onDrop(of: [SidebarOrder.type, .fileURL], delegate: CommonPathRowDropDelegate(entry: entry, library: library, controller: controller))
            .accessibilityIdentifier("Sidebar.Location.common-path:\(entry.url.path)")
        }
    }

    @ViewBuilder
    private func locationRows(_ preferences: WorkspacePreferences) -> some View {
        let hidden = Set(preferences.hiddenSidebarBuiltInLocations)
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if !hidden.contains(.iCloudDrive) {
            let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            if FileManager.default.fileExists(atPath: iCloud.path) {
                locationRow(title: L("iCloud Drive"), url: iCloud, symbol: "icloud", identifier: "iCloudDrive", preferences: preferences)
            }
        }
        if !hidden.contains(.home) {
            locationRow(title: NSUserName(), url: home, symbol: "house", identifier: "home", preferences: preferences)
        }
        if !hidden.contains(.thisMac) {
            locationRow(title: ComputerName.local, url: URL(fileURLWithPath: "/"), symbol: "desktopcomputer", identifier: "thisMac", preferences: preferences)
        }
        if !hidden.contains(.airDrop) {
            SidebarRow(title: L("AirDrop"), symbol: "dot.radiowaves.left.and.right", tint: .blue, colored: preferences.usesColoredSidebarIcons, selected: false) {
                controller.openAirDrop()
            }
        }
        if !hidden.contains(.trash) {
            locationRow(title: L("Trash"), url: home.appendingPathComponent(".Trash", isDirectory: true), symbol: "trash", identifier: "trash", preferences: preferences)
        }
        ForEach(volumes.volumes, id: \.url) { volume in
            HStack(spacing: 0) {
                SidebarRow(title: volume.name, symbol: volume.isNetwork ? "network" : "externaldrive", tint: .gray, colored: preferences.usesColoredSidebarIcons,
                           selected: model.activePane.currentDirectory?.path == volume.url.path) {
                    controller.navigateActivePane(to: volume.url)
                }
                if volume.isEjectable {
                    Button { controller.eject(volume) } label: {
                        Image(systemName: "eject.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(LF("Eject %@", volume.name))
                    .accessibilityIdentifier("Sidebar.Volume.Eject.\(volume.name)")
                    .padding(.trailing, 8)
                }
            }
        }
        ForEach(NetworkLocationStore.shared.locations) { location in
            SidebarRow(title: location.name, symbol: "server.rack", tint: .gray, colored: preferences.usesColoredSidebarIcons, selected: false) {
                controller.connect(to: location)
            }
            .contextMenu {
                Button(L("Remove Location")) { NetworkLocationStore.shared.remove(location.id) }
            }
        }
    }

    private func locationRow(title: String, url: URL, symbol: String, identifier: String, preferences: WorkspacePreferences) -> some View {
        SidebarRow(title: title, symbol: symbol, tint: .blue, colored: preferences.usesColoredSidebarIcons,
                   selected: model.activePane.currentDirectory?.hasSamePath(as: url) == true) {
            controller.navigateActivePane(to: url)
        }
        .help(url.path)
        .contextMenu {
            Button(L("Open")) { controller.navigateActivePane(to: url) }
            Button(L("Open in New Tab")) { controller.newTab(directory: url) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            controller.dropProviders(providers, into: url)
        }
        .accessibilityIdentifier("Sidebar.Location.\(identifier)")
    }

    private var tagRows: some View {
        ForEach(tagCatalog.tags, id: \.name) { tag in
            let selected = isTagSelected(tag.name)
            // 32 pt rows like the other sidebar rows; the selected tag turns accent blue on a soft highlight.
            Button { controller.navigateActivePane(toTag: tag.name) } label: {
                HStack(spacing: 6.5) {
                    // Tags without a color show an empty ring, as in the original.
                    Group {
                        if let color = Theme.finderTagColor(tag.label) {
                            Circle().fill(Color(nsColor: color)).frame(width: 9, height: 9)
                        } else {
                            Circle().strokeBorder(selected ? Color.accentColor : Color.secondary, lineWidth: 1).frame(width: 9, height: 9)
                        }
                    }
                    .frame(width: 9)
                    Text(tag.name).font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? Color.accentColor : Color(nsColor: .labelColor))
                    Spacer()
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.05) : .clear)
                    .padding(.vertical, 4))
            }
            .buttonStyle(.plain)
            .contextMenu {
                Menu(L("Tag Color")) {
                    Button(L("None")) { tagCatalog.setColor(0, for: tag.name) }
                    Divider()
                    ForEach(FinderTagCatalog.colorOrder, id: \.self) { label in
                        Button {
                            tagCatalog.setColor(label, for: tag.name)
                        } label: {
                            Label { Text(Self.colorName(label)) } icon: { Image(nsImage: Self.colorDot(label)) }
                        }
                    }
                }
                Divider()
                Button(L("Delete Tag"), role: .destructive) { tagCatalog.delete(tag.name) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("Sidebar.Tag.\(tag.name.lowercased())")
        }
    }

    static func colorName(_ label: Int) -> String {
        switch label {
        case 1: L("Gray")
        case 2: L("Green")
        case 3: L("Purple")
        case 4: L("Blue")
        case 5: L("Yellow")
        case 6: L("Red")
        default: L("Orange")
        }
    }

    /// Colored circle for menu items (menus draw template images in the text color, so this one is not a template).
    static func colorDot(_ label: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            (Theme.finderTagColor(label) ?? .secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func isTagSelected(_ name: String) -> Bool {
        if case .tag(let current) = model.activePane.destination { return current == name }
        return false
    }

    static func title(_ module: SidebarModule) -> String {
        switch module {
        case .builtIn: L("Built-in")
        case .commonPaths: L("Common Paths")
        case .locations: L("Locations")
        case .bookmarks: L("Bookmarks")
        case .tags: L("Tags")
        }
    }

    static func builtInTitle(_ name: String) -> String {
        switch name {
        case "applications": L("Applications")
        case "desktop": L("Desktop")
        case "downloads": L("Downloads")
        case "documents": L("Documents")
        case "movies": L("Movies")
        case "music": L("Music")
        case "pictures": L("Pictures")
        default: L("Home Folder")
        }
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let colored: Bool
    let selected: Bool
    var badge: String? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// Blue glyphs follow the accent color, as the original's sidebar icons do.
    private var iconTint: Color { tint == .blue ? Color.accentColor : tint }

    /// Native macOS sidebar row: crisp continuous pill selection, immediate pointer-down press, and smooth hover.
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if symbol == ApplicationsGlyph.name {
                        ApplicationsGlyph().frame(width: 11.5, height: 11.5)
                    } else {
                        Image(systemName: symbol).font(.system(size: symbol == "folder" ? 15 : 13, weight: selected ? .semibold : .regular))
                    }
                }
                .foregroundStyle(selected ? Color.accentColor : (colored ? iconTint : Color(nsColor: .secondaryLabelColor)))
                .frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? Color.accentColor : Color(nsColor: .labelColor))
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(selected ? Color.accentColor : .secondary)
                        .padding(.horizontal, 5.5).padding(.vertical, 1)
                        .background(Capsule().fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.08)))
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(WumiInteractiveButtonStyle(
            cornerRadius: 9,
            restingFill: selected ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.135) : .clear,
            hoverOpacity: selected ? 0.0 : 0.06,
            pressOpacity: selected ? 0.18 : 0.12,
            pressScale: 0.985
        ))
        .animation(WumiMotion.micro, value: selected)
        .accessibilityLabel(title)
    }
}

/// Applications glyph: three rounded squares and a circle on a 2 × 2 grid, outlined in the row's tint.
struct ApplicationsGlyph: View {
    static let name = "dirdesk.applications"

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let cell = (side - 2.5) / 2
            let line: CGFloat = 1.0
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 1.4).stroke(lineWidth: line).frame(width: cell, height: cell)
                RoundedRectangle(cornerRadius: 1.4).stroke(lineWidth: line).frame(width: cell, height: cell).offset(x: cell + 2.5)
                RoundedRectangle(cornerRadius: 1.4).stroke(lineWidth: line).frame(width: cell, height: cell).offset(y: cell + 2.5)
                Circle().stroke(lineWidth: line).frame(width: cell, height: cell).offset(x: cell + 2.5, y: cell + 2.5)
            }
            .padding(line / 2)
        }
    }
}

/// Bookmarks section tree (folders expand inline).
private struct BookmarkSidebarRows: View {
    let parent: UUID?
    let depth: Int
    @ObservedObject var model: WorkspaceModel
    let controller: WorkspaceController
    @ObservedObject var library = LibraryModel.shared
    @State private var expanded: Set<UUID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ForEach(library.bookmarks.children(of: parent)) { node in
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(title: node.displayTitle,
                           symbol: node.isFolder ? (expanded.contains(node.id) ? "folder.fill" : "folder") : (node.target?.kind == .folder ? "folder" : "doc"),
                           tint: .blue, colored: AppModel.shared.preferences.usesColoredSidebarIcons,
                           selected: node.target.map { model.activePane.currentDirectory?.hasSamePath(as: $0.url) == true } ?? false) {
                    if node.isFolder {
                        WumiMotion.withPreferredAnimation(WumiMotion.snappy, reduceMotion: reduceMotion) {
                            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
                        }
                    } else {
                        controller.openBookmark(node)
                    }
                }
                .padding(.leading, CGFloat(depth) * 12)
                .contextMenu { BookmarkContextMenu(node: node, controller: controller) }
                .accessibilityIdentifier("Sidebar.Bookmark.\(node.id.uuidString)")
                if node.isFolder && expanded.contains(node.id) {
                    BookmarkSidebarRows(parent: node.id, depth: depth + 1, model: model, controller: controller)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
}

/// The startup disk's row is titled with the Mac's local host name ("name-macbook-air"), as in the original.
enum ComputerName {
    static let local: String = {
        // Lowercased like the original ("name-macbook-air"), which shows the Bonjour host name as DNS reports it.
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty { return name.lowercased() }
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        return L("This Mac")
    }()
}

extension Notification.Name {
    /// Expands every sidebar module (offscreen snapshots for layout checks).
    static let dirDeskExpandSidebar = Notification.Name("DirDesk.ExpandSidebar")
}

/// Drag payload for reordering rows inside one sidebar module (`com.kbwumin13.dirdesk.sidebar-order`).
enum SidebarOrder {
    static let type = UTType(exportedAs: "com.kbwumin13.dirdesk.sidebar-order")

    static func provider(module: SidebarModule, index: Int) -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = Data("\(module.rawValue):\(index)".utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(payload, nil)
            return nil
        }
        return provider
    }

    /// Loads the dragged row's module and index.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor (SidebarModule, Int) -> Void) {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) else { return }
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let text = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return }
            let parts = text.split(separator: ":")
            guard parts.count == 2, let module = SidebarModule(rawValue: String(parts[0])), let index = Int(parts[1]) else { return }
            Task { @MainActor in completion(module, index) }
        }
    }
}

/// A Common Paths row: another Common Paths row dropped on it takes its place; files go into its folder.
private struct CommonPathRowDropDelegate: DropDelegate {
    let entry: CommonPathEntry
    let library: LibraryModel
    let controller: WorkspaceController

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [SidebarOrder.type]) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let order = info.itemProviders(for: [SidebarOrder.type])
        if !order.isEmpty {
            SidebarOrder.load(order) { module, source in
                guard module == .commonPaths, let target = library.commonPaths.firstIndex(of: entry), source != target else { return }
                library.moveCommonPath(from: IndexSet(integer: source), to: target > source ? target + 1 : target)
            }
            return true
        }
        return controller.dropProviders(info.itemProviders(for: [.fileURL]), into: entry.url)
    }
}
