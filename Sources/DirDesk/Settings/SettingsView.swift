import AppKit
import DirDeskCore
import SwiftUI

/// The 18 settings sections in the original's four sidebar groups (基础 / 特色功能 / 高级功能 / 关于).
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, sidebar, interaction, privacy, shortcuts
    case archives, superPreview, floatingBall, fileTransit, lightningSearch, newFiles, externalTools, builtInTools, contextMenu
    case folderSync, diagnostics
    case about

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case basic, features, advanced, about
        var title: String {
            switch self {
            case .basic: L("Basics")
            case .features: L("Special Features")
            case .advanced: L("Advanced Features")
            case .about: L("About")
            }
        }
    }

    var group: Group {
        switch self {
        case .general, .appearance, .sidebar, .interaction, .privacy, .shortcuts: .basic
        case .folderSync, .diagnostics: .advanced
        case .about: .about
        default: .features
        }
    }

    /// Sidebar and header title. The original uses short names here ("Shortcuts", "Archives", "Preview", "New Files").
    var title: String {
        switch self {
        case .general: L("General")
        case .appearance: L("Appearance")
        case .sidebar: L("Sidebar")
        case .interaction: L("Interaction")
        case .privacy: L("Privacy & Permissions")
        case .shortcuts: L("Shortcuts")
        case .archives: L("Archives")
        case .superPreview: L("Preview")
        case .floatingBall: L("Floating Ball")
        case .fileTransit: L("Floating Files")
        case .folderSync: L("Folder Sync")
        case .lightningSearch: L("Lightning Search")
        case .newFiles: L("New Files")
        case .externalTools: L("External Tools")
        case .builtInTools: L("Built-in Tools")
        case .contextMenu: L("Context Menu")
        case .diagnostics: L("Diagnostics")
        case .about: L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush.pointed"
        case .sidebar: "sidebar.left"
        case .interaction: "dot.circle.and.cursorarrow"
        case .privacy: "hand.raised"
        case .shortcuts: "command"
        case .archives: "archivebox"
        case .superPreview: "eye"
        case .floatingBall: "circle.circle"
        case .fileTransit: "shippingbox.fill"
        case .folderSync: "folder.badge.gearshape"
        case .lightningSearch: "magnifyingglass"
        case .newFiles: "doc.badge.plus"
        case .externalTools: "apple.terminal"
        case .builtInTools: "wand.and.sparkles"
        case .contextMenu: "menucard"
        case .diagnostics: "waveform.path.ecg"
        case .about: "info.circle"
        }
    }

    /// Icon gradients sampled from the reference: (top, bottom) as RGB.
    var gradient: (top: Int, bottom: Int) {
        switch self {
        case .general, .sidebar, .lightningSearch: (0x21ABFF, 0x0190FF)
        case .appearance, .superPreview: (0xF156FF, 0xDB33F1)
        case .interaction, .shortcuts, .floatingBall: (0x8F9AFF, 0x6D7BFE)
        case .privacy: (0x52E278, 0x32D057)
        case .archives, .externalTools: (0xFFAB56, 0xFF902F)
        case .fileTransit, .newFiles, .folderSync: (0x5FE1FF, 0x3CD3FE)
        case .builtInTools, .contextMenu, .diagnostics: (0x2CE2EF, 0x00D2E0)
        case .about: (0xB2B2B7, 0x98989C)
        }
    }

    /// Privacy, Folder Sync, Diagnostics and About have no "Restore This Page" in the original.
    var hasRestoreButton: Bool {
        switch self {
        case .privacy, .folderSync, .diagnostics, .about: false
        default: true
        }
    }

    /// Row titles that the settings search matches besides the page title.
    var searchTerms: [String] {
        switch self {
        case .general:
            [L("Language"), L("Use Wumi to open folders by default"), L("Startup folder"), L("Default file sorting"),
             L("Remember folder sorting and grouping"), L("Sort numbers in file names in order"), L("File size units"),
             L("Remember window size and position"), L("When a removable device connects"), L("When switching workspaces")]
        case .appearance:
            [L("Color Mode"), L("Colored Toolbar Icons"), L("Favorites Bar Background"), L("Show disk free space in the status bar"),
             L("Show Bookmarks and Workspace Bar"), L("List thumbnail categories"), L("Show exact dates and times"),
             L("Colored date backgrounds"), L("Interface text size"), L("List row spacing"), L("Long filenames"), L("File icon size"), L("Toolbar")]
        case .sidebar:
            [L("Sidebar icon colors"), L("Show and Arrange Sidebar Items"), L("Recent"), L("Shared Folder"), L("Common Paths"),
             L("Locations"), L("Bookmarks"), L("Tags")]
        case .interaction:
            [L("Keyboard and Pointer"), L("Double-click blank space"), L("Operation error sound"), L("Show copy and cut feedback"),
             L("How to open files and folders"), L("Enter key"), L("Backspace key"), L("Use mouse side buttons for Back and Forward"),
             L("Wait before opening a folder while dragging"), L("Hold Shift to switch Move and Copy"), L("Show subfolders when pointing at a path arrow")]
        case .privacy: [L("Folder permissions"), L("Installed Edition"), L("Full Disk Access"), L("Privacy Summary")]
        case .shortcuts: [L("Keyboard Shortcuts"), L("Record Shortcut")]
        case .archives: [L("Archive Browsing"), L("Largest archive to browse without extracting")]
        case .superPreview: [L("Preview archive contents"), L("Preview folder contents"), L("Show Git badges and status")]
        case .floatingBall: [L("Transparency"), L("Double-click action"), L("Show floating ball buttons on hover"), L("Floating ball buttons")]
        case .fileTransit:
            [L("File Floating Settings"), L("Open Floating Files from the chosen trigger position"), L("Show the Floating Files icon in the menu bar"),
             L("Floating Files trigger position"), L("Floating window background opacity")]
        case .newFiles: [L("New File Templates"), L("Add Template")]
        case .externalTools: [L("Terminal"), L("Editor")]
        case .builtInTools: [L("Search tools or extensions")] + BuiltInToolID.allCases.map(BuiltInToolSupport.title)
        case .contextMenu: [L("Context menu presets"), L("Show context menu icons"), L("Current menu items")]
        case .about: [L("Version"), L("Copy Version Information")]
        case .lightningSearch, .folderSync, .diagnostics: []
        }
    }
}

/// UserDefaults keys owned by the settings window that have no field in the efficiency configuration.
enum SettingsKeys {
    /// Checkbox of "Double-click blank space" (original: dirdeck-open-parent-on-blank-double-click-v1). Default on.
    static let blankDoubleClickEnabled = "dirdesk-open-parent-on-blank-double-click-v1"
    /// "Show exact dates and times"; read by the list date cells.
    static let showsAbsoluteTime = "dirdesk-show-absolute-time-v1"
}

/// Values of `DefaultsKey.blankDoubleClickAction`.
enum BlankDoubleClickAction: String {
    case parentFolder, back
}

/// Double-click on empty space in the list and icon views (Settings › Interaction): parent folder or back,
/// nil when switched off. Both settings default to the original's (on, parent folder).
enum BlankSpaceDoubleClick {
    static var command: ShortcutCommand? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: SettingsKeys.blankDoubleClickEnabled) as? Bool ?? true else { return nil }
        return defaults.string(forKey: DefaultsKey.blankDoubleClickAction) == BlankDoubleClickAction.back.rawValue ? .navigateBack : .navigateUp
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selection: SettingsSection = .general

    func select(identifier: String) {
        switch identifier {
        case "toolbar": selection = .appearance
        case "defaultSorting": selection = .general
        default: if let section = SettingsSection(rawValue: identifier) { selection = section }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var app = AppModel.shared
    @State private var query = ""
    @State private var notice: String?
    @State private var noticeID = 0
    /// Bumped after a restore so panes that copy settings into local state (editors, path lists) reload them.
    @State private var paneGeneration = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 224)
            // A faint edge that starts below the 32 pt title bar, as in the original.
            Rectangle().fill(Color.primary.opacity(0.05)).frame(width: 1).padding(.top, 32)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    SettingsPane(section: navigation.selection)
                        .id(paneGeneration)
                        .padding(.top, 20)
                    footer
                        .padding(.top, 13)
                }
                .padding(.horizontal, 28)
                .padding(.top, 62)
                .padding(.bottom, 24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(navigation.selection)
            .overlay(alignment: .top) { titlebarFade }
        }
        // The original's settings window uses the darker control background (#1E1E1E in Dark Mode) for both columns.
        .background(Color(nsColor: .controlBackgroundColor))
        .ignoresSafeArea()
        .id(app.language)
    }

    /// Content scrolling under the transparent title bar fades out, like the original's scroll edge.
    private var titlebarFade: some View {
        let background = Color(nsColor: .controlBackgroundColor)
        return LinearGradient(stops: [.init(color: background, location: 0), .init(color: background, location: 0.65),
                                      .init(color: background.opacity(0), location: 1)],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: 40)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: Sidebar

    private var filteredSections: [SettingsSection] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            ([section.title, section.group.title] + section.searchTerms).contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField(L("Search Settings"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .accessibilityIdentifier("Settings.Search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Clear Search"))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 14)
            .padding(.top, 48)
            sectionList
            Button(L("Restore All Settings…")) { restoreAll() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .accessibilityIdentifier("Settings.RestoreAll")
        }
    }

    /// Grouped section rows; keeps the selected page scrolled into view when it changes from elsewhere.
    private var sectionList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let sections = filteredSections
                    if sections.isEmpty {
                        Text(L("No Matching Settings"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                    ForEach(SettingsSection.Group.allCases, id: \.self) { group in
                        let members = sections.filter { $0.group == group }
                        if !members.isEmpty {
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 14)
                                .padding(.top, 15.5)
                                .padding(.bottom, 2.5)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(members) { section in sidebarRow(section) }
                        }
                    }
                }
                .padding(.top, 5)
                .padding(.bottom, 10)
            }
            .onAppear { proxy.scrollTo(navigation.selection) }
            .onChange(of: navigation.selection) { _, section in withAnimation { proxy.scrollTo(section) } }
        }
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        Button { navigation.selection = section } label: {
            HStack(spacing: 10) {
                SettingsIcon(section: section, size: 26)
                Text(section.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(navigation.selection == section ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .id(section)
        .accessibilityIdentifier("Settings.Section.\(section.rawValue)")
        .accessibilityAddTraits(navigation.selection == section ? .isSelected : [])
    }

    // MARK: Page chrome

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            SettingsIcon(section: navigation.selection, size: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(navigation.selection.group.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(navigation.selection.title)
                    .font(.system(size: 23, weight: .bold))
            }
            .padding(.top, -2)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var footer: some View {
        let section = navigation.selection
        if section.hasRestoreButton || notice != nil {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if let notice {
                    Text(notice)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                if section.hasRestoreButton {
                    Button(L("Restore This Page")) {
                        SettingsRestore.restore(section)
                        paneGeneration += 1
                        show(L("This page was restored to its defaults."))
                    }
                    .accessibilityIdentifier(section == .builtInTools ? "BuiltInTools.RestoreDefaults" : "Settings.RestorePage")
                }
            }
        }
    }

    private func show(_ message: String) {
        noticeID += 1
        let id = noticeID
        withAnimation { notice = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard id == noticeID else { return }
            withAnimation { notice = nil }
        }
    }

    private func restoreAll() {
        let alert = NSAlert()
        alert.messageText = L("Restore all settings?")
        alert.informativeText = L("Restores app preferences. Language, the default folder application, files, bookmarks and rename history are kept.")
        alert.addButton(withTitle: L("Restore Defaults"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SettingsRestore.restoreAll()
        paneGeneration += 1
        show(L("All settings were restored to their defaults."))
    }
}

/// "Restore This Page" and "Restore All Settings…". Language, the default folder app, files,
/// bookmarks and rename history are never touched.
@MainActor
enum SettingsRestore {
    private static let generalKeys = [DefaultsKey.defaultSortKey, DefaultsKey.defaultSortAscending, DefaultsKey.foldersFirst,
                                      DefaultsKey.rememberFolderDisplay]
    private static let appearanceKeys = [SettingsKeys.showsAbsoluteTime]
    private static let interactionKeys = [SettingsKeys.blankDoubleClickEnabled, DefaultsKey.blankDoubleClickAction,
                                          DefaultsKey.operationErrorSound, DefaultsKey.openPathChildrenOnHover]

    static func restore(_ section: SettingsSection) {
        let app = AppModel.shared
        let d = WorkspacePreferences.defaults
        switch section {
        case .general:
            removeKeys(generalKeys)
            app.startupLocationMode = .desktop
            app.updatePreferences { p in
                p.usesNaturalNumericSorting = d.usesNaturalNumericSorting; p.fileSizeUnit = d.fileSizeUnit
                p.remembersWindowGeometry = d.remembersWindowGeometry; p.removableDeviceBehavior = d.removableDeviceBehavior
                p.namedWorkspaceSwitchBehavior = d.namedWorkspaceSwitchBehavior
            }
        case .appearance:
            removeKeys(appearanceKeys)
            app.updatePreferences { p in
                p.appearance = d.appearance; p.usesColoredToolbarIcons = d.usesColoredToolbarIcons; p.showsToolbarLabels = d.showsToolbarLabels
                p.bookmarkBarBackground = d.bookmarkBarBackground; p.bookmarkBarCustomRGB = d.bookmarkBarCustomRGB
                p.showsDiskFreeSpace = d.showsDiskFreeSpace; p.showsBookmarksAndWorkspaceBar = d.showsBookmarksAndWorkspaceBar
                p.listThumbnailCategories = d.listThumbnailCategories; p.showsDateAgeColors = d.showsDateAgeColors
                p.showsDateAgeStyle = d.showsDateAgeStyle; p.dateColorTheme = d.dateColorTheme; p.interfaceFontSize = d.interfaceFontSize
                p.listDensity = d.listDensity; p.filenameTruncation = d.filenameTruncation; p.iconGridScale = d.iconGridScale
            }
        case .sidebar:
            app.updatePreferences { p in
                p.sidebarModuleOrder = d.sidebarModuleOrder; p.hiddenSidebarModules = d.hiddenSidebarModules
                p.defaultExpandedSidebarModules = d.defaultExpandedSidebarModules; p.hiddenSidebarBuiltInItems = d.hiddenSidebarBuiltInItems
                p.hiddenSidebarBuiltInLocations = d.hiddenSidebarBuiltInLocations; p.usesColoredSidebarIcons = d.usesColoredSidebarIcons
            }
        case .interaction:
            removeKeys(interactionKeys)
            app.updatePreferences { p in
                p.opensItemsWithSingleClick = d.opensItemsWithSingleClick; p.enterKeyAction = d.enterKeyAction
                p.backspaceKeyAction = d.backspaceKeyAction; p.usesMouseButtonsForHistoryNavigation = d.usesMouseButtonsForHistoryNavigation
                p.dragHoverExpansionDelay = d.dragHoverExpansionDelay; p.shiftDragReversesOperation = d.shiftDragReversesOperation
                p.showsOperationTips = d.showsOperationTips
            }
        case .shortcuts:
            let c = EfficiencyConfiguration.defaults
            app.update { $0.shortcuts = c.shortcuts; $0.secondaryShortcuts = c.secondaryShortcuts; $0.disabledShortcutCommands = c.disabledShortcutCommands }
        case .archives:
            app.updatePreferences { $0.archiveDirectBrowseSizeLimitMB = d.archiveDirectBrowseSizeLimitMB }
        case .superPreview:
            app.updatePreferences { p in
                p.previewsArchives = d.previewsArchives; p.previewsFolders = d.previewsFolders; p.showsGitStatus = d.showsGitStatus
            }
        case .floatingBall:
            app.updatePreferences { p in
                p.showsQuickCapsule = d.showsQuickCapsule; p.floatingBallTransparency = d.floatingBallTransparency
                p.expandsFloatingBallOnHover = d.expandsFloatingBallOnHover; p.floatingBallDoubleClickAction = d.floatingBallDoubleClickAction
                p.enabledFloatingBallActions = d.enabledFloatingBallActions; p.floatingBallActionOrder = d.floatingBallActionOrder
            }
        case .fileTransit:
            app.updatePreferences { p in
                p.enablesFileTransitIsland = d.enablesFileTransitIsland; p.showsFileTransitMenuBarItem = d.showsFileTransitMenuBarItem
                p.fileTransitDockEdge = d.fileTransitDockEdge; p.fileTransitPanelOpacity = d.fileTransitPanelOpacity
                p.showsFileTransitWindowShortcut = d.showsFileTransitWindowShortcut
                p.fileTransitDockUsesAutomaticPlacement = d.fileTransitDockUsesAutomaticPlacement
            }
        case .newFiles:
            app.update { $0.fileTemplates = EfficiencyConfiguration.defaults.fileTemplates }
        case .externalTools:
            app.update { $0.externalTools = EfficiencyConfiguration.defaultExternalTools }
        case .builtInTools:
            app.update { $0.enabledBuiltInTools = EfficiencyConfiguration.defaults.enabledBuiltInTools }
        case .contextMenu:
            app.update { $0.contextMenuCommands = EfficiencyConfiguration.defaults.contextMenuCommands }
            app.updatePreferences { $0.showsContextMenuIcons = d.showsContextMenuIcons }
        case .lightningSearch:
            LightningSearchService.shared.updateFolders(watched: LightningSearchService.defaultWatchedFolders,
                                                        ignored: LightningSearchService.defaultIgnoredFolders)
        case .privacy, .folderSync, .diagnostics, .about:
            break
        }
    }

    static func restoreAll() {
        AppModel.shared.update { configuration in
            // Pinned folders and the user's sidebar item order are data, not preferences.
            let pinned = configuration.workspacePreferences.pinnedFolderPaths
            let itemOrder = configuration.workspacePreferences.sidebarItemOrder
            configuration = .defaults
            configuration.workspacePreferences.pinnedFolderPaths = pinned
            configuration.workspacePreferences.sidebarItemOrder = itemOrder
        }
        removeKeys(generalKeys + appearanceKeys + interactionKeys)
        AppModel.shared.startupLocationMode = .desktop
        // Floating Files settings go back to defaults; pinned folders and the last location are kept.
        let floating = FileFloatingStore.shared
        var fresh = FileFloatingConfiguration()
        fresh.pinnedDirectories = floating.configuration.pinnedDirectories
        fresh.lastDirectory = floating.configuration.lastDirectory
        fresh.viewMode = floating.configuration.viewMode
        floating.configuration = fresh
        restore(.lightningSearch)
    }

    private static func removeKeys(_ keys: [String]) {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    }
}

/// Rounded, gradient-filled section icon used in the sidebar (26 pt) and the page header (42 pt).
struct SettingsIcon: View {
    let section: SettingsSection
    let size: CGFloat

    var body: some View {
        let gradient = section.gradient
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [settingsColor(gradient.top), settingsColor(gradient.bottom)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay { glyph.foregroundStyle(.white) }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var glyph: some View {
        if section == .lightningSearch {
            // Magnifying glass with a bolt in the lens, as in the original's icon.
            ZStack {
                Image(systemName: "magnifyingglass").font(.system(size: size * 0.56, weight: .semibold))
                Image(systemName: "bolt.fill").font(.system(size: size * 0.21, weight: .bold)).offset(x: -size * 0.055, y: -size * 0.055)
            }
        } else {
            Image(systemName: section.symbol).font(.system(size: size * 0.5, weight: .medium))
        }
    }
}

private func settingsColor(_ rgb: Int) -> Color {
    Color(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
}

/// Rounded card with an optional bold section title, used by every settings pane.
struct SettingsCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7.5) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, 20.5)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Outline only, like the original's cards.
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.045)))
    }
}

/// Stacks rows with a hairline between them, like the rows inside the original's cards.
struct RowStack<Content: View>: View {
    let rowPadding: CGFloat
    @ViewBuilder let content: Content

    init(rowPadding: CGFloat = 13, @ViewBuilder content: () -> Content) {
        self.rowPadding = rowPadding
        self.content = content()
    }

    var body: some View {
        Group(subviews: content) { subviews in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 { Divider() }
                    subview
                        .padding(.vertical, rowPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// One preference row: bold title with a grey explanation on the left, its control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 270, alignment: .leading)
            Spacer(minLength: 12)
            control
        }
    }
}

/// Row whose control is a checkbox at the trailing edge (the original's AXCheckBox rows).
struct CheckRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool
    let identifier: String?

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>, identifier: String? = nil) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
        self.identifier = identifier
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .settingsIdentifier(identifier)
        }
    }
}

/// Row whose control is a pop-up menu sized to its widest option.
struct PopupRow<Value: Hashable>: View {
    let title: String
    let detail: String?
    @Binding var selection: Value
    let options: [(Value, String)]
    let identifier: String?

    init(_ title: String, detail: String? = nil, selection: Binding<Value>, options: [(Value, String)], identifier: String? = nil) {
        self.title = title
        self.detail = detail
        self._selection = selection
        self.options = options
        self.identifier = identifier
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
            }
            .labelsHidden()
            .fixedSize()
            .settingsIdentifier(identifier)
        }
    }
}

/// Up and down chevrons used by every reorderable list in Settings.
struct MoveButtons: View {
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!canMoveUp)
                .help(L("Move Up"))
                .accessibilityLabel(L("Move Up"))
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!canMoveDown)
                .help(L("Move Down"))
                .accessibilityLabel(L("Move Down"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
    }
}

extension View {
    @ViewBuilder func settingsIdentifier(_ identifier: String?) -> some View {
        if let identifier { accessibilityIdentifier(identifier) } else { self }
    }
}
