import AppKit
import CoreServices
import DirDeskCore
import SwiftUI

/// Binding into one workspace preference.
@MainActor
func pref<T>(_ keyPath: WritableKeyPath<WorkspacePreferences, T>) -> Binding<T> {
    Binding(get: { AppModel.shared.preferences[keyPath: keyPath] },
            set: { value in AppModel.shared.updatePreferences { $0[keyPath: keyPath] = value } })
}

/// Binding into a plain UserDefaults key with a default.
func defaultsBool(_ key: String, _ fallback: Bool) -> Binding<Bool> {
    Binding(get: { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback },
            set: { UserDefaults.standard.set($0, forKey: key) })
}

struct SettingsPane: View {
    let section: SettingsSection

    var body: some View {
        switch section {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .sidebar: SidebarSettings()
        case .interaction: InteractionSettings()
        case .privacy: PrivacySettings()
        case .shortcuts: ShortcutSettings()
        case .archives: ArchiveSettings()
        case .superPreview: SuperPreviewSettings()
        case .floatingBall: FloatingBallSettings()
        case .fileTransit: FileTransitSettings()
        case .folderSync: FolderSyncSettingsPane()
        case .lightningSearch: LightningSearchSettingsPane()
        case .newFiles: TemplateSettings()
        case .externalTools: ExternalToolSettings()
        case .builtInTools: BuiltInToolSettings()
        case .contextMenu: ContextMenuSettings()
        case .diagnostics: DiagnosticsSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var app = AppModel.shared
    @State private var isDefaultFolderApp = DefaultFolderApplication.isDirDeskDefault
    @AppStorage(DefaultsKey.defaultSortKey) private var sortKey = FileSortKey.name.rawValue
    @AppStorage(DefaultsKey.defaultSortAscending) private var sortAscending = true
    @AppStorage(DefaultsKey.rememberFolderDisplay) private var remembersFolderDisplay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(L("General")) {
                RowStack {
                    SettingsRow(L("Language"),
                                detail: L("Switches every Wumi window and menu to the chosen language right away. Controls drawn by macOS keep the system language.")) {
                        Picker(L("Language"), selection: $app.language) {
                            ForEach(AppLanguage.available) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("Settings.LanguagePicker")
                    }
                    // Direct-download editions only; the App Store build cannot change the folder handler.
                    CheckRow(L("Use Wumi to open folders by default"),
                             detail: L("When macOS opens a folder with its default app, Wumi opens it instead. Some “Show in Finder” actions still use Finder; turning this off gives folders back to the previous app."),
                             isOn: Binding(get: { isDefaultFolderApp }, set: { value in
                                 DefaultFolderApplication.set(enabled: value)
                                 isDefaultFolderApp = DefaultFolderApplication.isDirDeskDefault
                             }))
                }
            }
            SettingsCard(L("Browsing")) {
                RowStack {
                    startupRow
                    sortingRow
                    CheckRow(L("Remember folder sorting and grouping"),
                             detail: L("When on, folders you re-sorted or regrouped by hand open the same way next time. When off, saved choices stay stored but are neither recorded nor applied."),
                             isOn: $remembersFolderDisplay)
                    CheckRow(L("Sort numbers in file names in order"),
                             detail: L("Compares numbers in names by value, so File 2 comes before File 10."),
                             isOn: pref(\.usesNaturalNumericSorting))
                    PopupRow(L("File size units"),
                             detail: L("Show sizes in decimal units (1 KB = 1,000 bytes) or binary units (1 KiB = 1,024 bytes)."),
                             selection: pref(\.fileSizeUnit),
                             options: [(.decimal, L("Decimal")), (.binary, L("Binary"))])
                }
            }
            SettingsCard(L("Workspace")) {
                RowStack {
                    CheckRow(L("Remember window size and position"),
                             detail: L("Windows reopen at the size and place you left them. When off, new windows use the default frame."),
                             isOn: pref(\.remembersWindowGeometry))
                    PopupRow(L("When a removable device connects"),
                             detail: L("Ask first, or go straight to a two-pane workspace for moving files between this Mac and the device."),
                             selection: pref(\.removableDeviceBehavior),
                             options: [(.ask, L("Ask each time")), (.openDeviceWorkspace, L("Open Device Workspace")),
                                       (.showInLocationsOnly, L("Show in Locations only"))])
                    PopupRow(L("When switching workspaces"),
                             detail: L("Open a saved workspace in its own tab, or let it take over the current tab."),
                             selection: pref(\.namedWorkspaceSwitchBehavior),
                             options: [(.openInNewTab, L("Open in New Tab")), (.replaceCurrentTab, L("Replace Current Tab"))],
                             identifier: "Settings.NamedWorkspaceSwitchBehavior")
                }
            }
        }
    }

    private var startupRow: some View {
        SettingsRow(L("Startup folder"),
                    detail: L("The folder a new Wumi window starts in. “Last location” reopens the active pane of the tab you used last; if that folder is gone, Desktop opens instead.")) {
            VStack(alignment: .trailing, spacing: 8) {
                Picker(L("Startup folder"), selection: Binding(get: { app.startupLocationMode }, set: { app.startupLocationMode = $0 })) {
                    Text(L("Desktop")).tag(AppModel.StartupLocationMode.desktop)
                    Text(L("Fixed folder")).tag(AppModel.StartupLocationMode.fixedFolder)
                    Text(L("Last location")).tag(AppModel.StartupLocationMode.lastLocation)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("Settings.StartupFolder")
                if app.startupLocationMode == .fixedFolder {
                    Button(L("Choose Startup Folder…")) { chooseStartupFolder() }
                    if let path = app.startupFixedPath {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                    }
                }
            }
        }
    }

    /// Key, then direction, as two stacked pop-ups like the original (folders-first is chosen per folder in the sort
    /// menu, not here).
    private var sortingRow: some View {
        SettingsRow(L("Default file sorting"),
                    detail: L("Used by folders that have no remembered order. A sort you change on the fly is dropped when you leave the folder.")) {
            VStack(alignment: .trailing, spacing: 8) {
                Picker(L("Default file sorting"), selection: $sortKey) {
                    ForEach(sortKeys, id: \.0) { key, title in Text(title).tag(key.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("Settings.DefaultSortKey")
                Picker(L("Sort direction"), selection: $sortAscending) {
                    Text(L("Ascending")).tag(true)
                    Text(L("Descending")).tag(false)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("Settings.DefaultSortDirection")
            }
        }
    }

    /// The original's order: Name, Modified, Added, Kind, Size, Created, Last Opened, Tags, Extension.
    private var sortKeys: [(FileSortKey, String)] {
        [(.name, L("Name")), (.modificationDate, L("Modified")), (.addedDate, L("Added")), (.kind, L("Kind")), (.size, L("Size")),
         (.creationDate, L("Date Created")), (.lastOpenedDate, L("Date Last Opened")), (.tags, L("Tags")), (.fileExtension, L("File Extension"))]
    }

    private func chooseStartupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK { app.startupFixedPath = panel.url?.path }
    }
}

/// Default handler for public.folder (Launch Services), with the previous handler restored when turned off.
enum DefaultFolderApplication {
    static let previousKey = "dirdesk-previous-folder-handler-v1"

    static var isDirDeskDefault: Bool {
        let handler = LSCopyDefaultRoleHandlerForContentType("public.folder" as CFString, .viewer)?.takeRetainedValue() as String?
        return handler?.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") == .orderedSame
    }

    static func set(enabled: Bool) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        if enabled {
            let current = LSCopyDefaultRoleHandlerForContentType("public.folder" as CFString, .viewer)?.takeRetainedValue() as String?
            if let current, current != bundleID { UserDefaults.standard.set(current, forKey: previousKey) }
            LSSetDefaultRoleHandlerForContentType("public.folder" as CFString, .viewer, bundleID as CFString)
        } else {
            let previous = UserDefaults.standard.string(forKey: previousKey) ?? "com.apple.finder"
            LSSetDefaultRoleHandlerForContentType("public.folder" as CFString, .viewer, previous as CFString)
        }
    }
}

// MARK: Appearance

private struct AppearanceSettings: View {
    @ObservedObject var app = AppModel.shared
    @AppStorage(SettingsKeys.showsAbsoluteTime) private var showsAbsoluteTime = false
    @State private var showsDateLegend = false
    private let fontSizes: [Double] = [10, 11, 12, 13, 14, 15, 16, 17]
    /// Icon view base size in points; the slider runs from 48 to 176 pt in 2 pt steps (100 % = 58 pt).
    private let baseIconSize = 58.0

    var body: some View {
        let p = app.preferences
        VStack(alignment: .leading, spacing: 6) {
            SettingsCard(L("Appearance")) {
                RowStack {
                    PopupRow(L("Color Mode"),
                             detail: L("With Follow System, Wumi changes between light and dark together with your Mac."),
                             selection: pref(\.appearance),
                             options: [(.system, L("Follow System")), (.light, L("Light Mode")), (.dark, L("Dark Mode"))],
                             identifier: "Settings.AppearanceMode")
                    CheckRow(L("Colored Toolbar Icons"),
                             detail: L("Use colored icons in the toolbar and its More menu. Turn off for the plain icons."),
                             isOn: pref(\.usesColoredToolbarIcons), identifier: "Settings.ColoredToolbarIcons")
                    SettingsRow(L("Favorites Bar Background"),
                                detail: L("Tint the favorites bar with a soft preset, or pick Custom to choose your own color. Presets adjust themselves for Dark Mode.")) {
                        HStack(spacing: 8) {
                            if p.bookmarkBarBackground == .custom { customColorPicker }
                            Picker(L("Favorites Bar Background"), selection: pref(\.bookmarkBarBackground)) {
                                Text(L("Pale Blue")).tag(BookmarkBarBackground.paleBlue)
                                Text(L("White")).tag(BookmarkBarBackground.white)
                                Text(L("Pale Mint")).tag(BookmarkBarBackground.paleMint)
                                Text(L("Pale Lavender")).tag(BookmarkBarBackground.paleLavender)
                                Text(L("Pale Peach")).tag(BookmarkBarBackground.palePeach)
                                Text(L("Pale Gray")).tag(BookmarkBarBackground.paleGray)
                                Text(L("Custom")).tag(BookmarkBarBackground.custom)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("Settings.FavoritesBarBackground")
                        }
                    }
                }
            }
            SettingsCard(L("File Views")) {
                RowStack {
                    Toggle(L("Show disk free space in the status bar"), isOn: pref(\.showsDiskFreeSpace))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))
                        .accessibilityIdentifier("Settings.ShowDiskFreeSpace")
                    CheckRow(L("Show Bookmarks and Workspace Bar"),
                             detail: L("Shows bookmarks and the workspace menu along the top of the file area."),
                             isOn: pref(\.showsBookmarksAndWorkspaceBar))
                    thumbnailRow
                    CheckRow(L("Show exact dates and times"),
                             detail: L("Show the full date and time instead of wording such as “5 minutes ago”. When off, dates from the last two hours appear as relative times."),
                             isOn: $showsAbsoluteTime, identifier: "Settings.AbsoluteTime")
                    dateColorRow(theme: p.dateColorTheme)
                    SettingsRow(L("Interface text size"), detail: L("Sets the text size in the sidebar, file views, path bar, and Floating Files.")) {
                        Picker(L("Interface text size"), selection: pref(\.interfaceFontSize)) {
                            ForEach(fontSizes, id: \.self) { Text(LF("%lld pt", Int64($0))).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("Settings.InterfaceFontSize")
                    }
                    PopupRow(L("List row spacing"),
                             detail: L("Changes the row height; every file column stays visible."),
                             selection: pref(\.listDensity),
                             options: [(.compact, L("Compact")), (.standard, L("Standard")), (.comfortable, L("Comfortable"))])
                    PopupRow(L("Long filenames"),
                             detail: L("Pick which part of an overlong name stays visible in icon and gallery views."),
                             selection: pref(\.filenameTruncation),
                             options: [(.middle, L("Keep Beginning and End")), (.tail, L("Keep Beginning")), (.head, L("Keep End"))])
                    SettingsRow(L("File icon size"),
                                detail: L("Resizes file icons in icon view. The grid rearranges itself as the window gets wider or narrower.")) {
                        HStack(spacing: 14) {
                            Slider(value: Binding(get: { app.preferences.iconGridScale * baseIconSize },
                                                  set: { value in app.updatePreferences { $0.iconGridScale = value / baseIconSize } }),
                                   in: 48...176, step: 2) {
                                Text(L("File icon size"))
                            }
                            .labelsHidden()
                            .frame(width: 180)
                            Text(LF("%lld%%", Int64((p.iconGridScale * 100).rounded())))
                                .font(.system(size: 13))
                                .monospacedDigit()
                                .frame(minWidth: 40, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var customColorPicker: some View {
        ColorPicker(L("Custom"), selection: Binding(get: {
            let rgb = app.preferences.bookmarkBarCustomRGB
            return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
        }, set: { color in
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
            let value = (Int(ns.redComponent * 255) << 16) | (Int(ns.greenComponent * 255) << 8) | Int(ns.blueComponent * 255)
            app.updatePreferences { $0.bookmarkBarCustomRGB = value }
        }), supportsOpacity: false)
        .labelsHidden()
    }

    private var thumbnailRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("List thumbnail categories")).font(.system(size: 13))
            HStack(spacing: 18) {
                thumbToggle(.images, L("Images"))
                thumbToggle(.documents, L("Documents (PDF, Office, text)"))
                thumbToggle(.multimedia, L("Multimedia (video and audio)"))
                thumbToggle(.other, L("Other file types"))
            }
            Text(L("Unchecked types show the icon of the app that opens them. Document thumbnails start out turned off."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func thumbToggle(_ category: ListThumbnailCategory, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { app.preferences.listThumbnailCategories.contains(category) }, set: { on in
            app.updatePreferences { p in
                if on { if !p.listThumbnailCategories.contains(category) { p.listThumbnailCategories.append(category) } }
                else { p.listThumbnailCategories.removeAll { $0 == category } }
            }
        }))
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
        .accessibilityIdentifier("Settings.ListThumbnails.\(category.rawValue)")
    }

    /// Info button with the color guide, theme pop-up and on/off checkbox, as in the original row.
    private func dateColorRow(theme: DateColorTheme) -> some View {
        SettingsRow(L("Colored date backgrounds"),
                    detail: L("Shades dates softly by how long ago they were. The date and time format itself does not change.")) {
            HStack(spacing: 22) {
                Button { showsDateLegend.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 14)) }
                    .buttonStyle(.borderless)
                    .help(L("Date color guide"))
                    .accessibilityLabel(L("Date color guide"))
                    .accessibilityIdentifier("Settings.DateColors.Tip")
                    .popover(isPresented: $showsDateLegend, arrowEdge: .bottom) {
                        DateColorLegend(theme: theme).padding(14)
                    }
                Picker(L("Date color theme"), selection: pref(\.dateColorTheme)) {
                    Text(L("Light")).tag(DateColorTheme.light)
                    Text(L("Medium")).tag(DateColorTheme.medium)
                    Text(L("High Contrast")).tag(DateColorTheme.highContrast)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("Settings.DateColorTheme")
                Toggle(L("Colored date backgrounds"), isOn: pref(\.showsDateAgeColors))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityIdentifier("Settings.DateAgeColors")
            }
        }
    }
}

private struct DateColorLegend: View {
    let theme: DateColorTheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let entries: [(DateAgeBucket, String)] = [
            (.minutes, L("Red: less than 5 minutes")), (.hour, L("Rose: 5 minutes to less than 1 hour")),
            (.day, L("Blue: 1 hour to less than 1 day")), (.week, L("Green: 1 day to less than 7 days")), (.older, L("Purple: 7 days or older")),
        ]
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Date color guide")).font(.system(size: 13, weight: .semibold))
            ForEach(entries, id: \.1) { bucket, text in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: Theme.dateAgeColors(bucket, theme: theme, dark: scheme == .dark).background))
                        .frame(width: 44, height: 16)
                    Text(text).font(.system(size: 12))
                }
            }
            Text(L("Missing and future dates have no color.")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("Settings.DateColorLegend")
    }
}

// MARK: Sidebar

private struct SidebarSettings: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        let order = app.preferences.sidebarModuleOrder
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard {
                HStack(spacing: 12) {
                    Text(L("Sidebar icon colors")).font(.system(size: 13))
                    Picker(L("Sidebar icon colors"), selection: pref(\.usesColoredSidebarIcons)) {
                        Text(L("Text color")).tag(false)
                        Text(L("Accent color")).tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("Settings.Sidebar.IconStyle")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            SettingsCard(L("Show and Arrange Sidebar Items")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Check what the sidebar shows and use the arrows to set the order. Hiding something never deletes files, bookmarks, or tags."))
                        .font(.system(size: 12))
                    Text(L("Groups checked as expanded open that way in new windows, and changes also apply to the current window. Collapsing a group in the sidebar itself leaves this default alone."))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 13.5)
                // The original separates the note from the module list and keeps its rows tight.
                VStack(spacing: 0) {
                    Divider()
                    RowStack(rowPadding: 6) {
                        ForEach(Array(order.enumerated()), id: \.element) { index, module in
                            moduleRow(module, index: index, count: order.count)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private func moduleRow(_ module: SidebarModule, index: Int, count: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6.5) {
                Toggle(isOn: Binding(get: { !app.preferences.hiddenSidebarModules.contains(module) }, set: { on in
                    app.updatePreferences { p in
                        if on { p.hiddenSidebarModules.removeAll { $0 == module } } else if !p.hiddenSidebarModules.contains(module) { p.hiddenSidebarModules.append(module) }
                    }
                })) {
                    itemLabel(SidebarView.title(module), detail: moduleDetail(module), titleSize: 14)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("Settings.Sidebar.Visible.\(module.rawValue)")
                if module == .builtIn {
                    VStack(alignment: .leading, spacing: 10) {
                        builtInToggle(.recent, L("Recent"), L("Lists files and folders you opened recently so you can get back to them."))
                        builtInToggle(.fileTransit, L("Floating Files"), L("Holds files for a while so you can copy or move them together later."))
                        builtInToggle(.sharedFolder, L("Shared Folder"), L("Opens the shared folder right from the sidebar."))
                    }
                    .padding(.leading, 20)
                }
                if module == .locations {
                    VStack(alignment: .leading, spacing: 8) {
                        locationToggle(.iCloudDrive, L("iCloud Drive"))
                        locationToggle(.home, L("Home Folder"))
                        locationToggle(.thisMac, L("This Mac"))
                        locationToggle(.airDrop, L("AirDrop"))
                        locationToggle(.trash, L("Trash"))
                    }
                    .padding(.leading, 20)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 16) {
                Toggle(L("Expanded by Default"), isOn: Binding(get: { app.preferences.defaultExpandedSidebarModules.contains(module) }, set: { on in
                    app.updatePreferences { p in
                        if on { if !p.defaultExpandedSidebarModules.contains(module) { p.defaultExpandedSidebarModules.append(module) } }
                        else { p.defaultExpandedSidebarModules.removeAll { $0 == module } }
                    }
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
                .help(SidebarView.title(module))
                .accessibilityIdentifier("Settings.Sidebar.Expanded.\(module.rawValue)")
                MoveButtons(canMoveUp: index > 0, canMoveDown: index < count - 1) { reorder(index, $0) }
            }
            .padding(.top, 8)
        }
    }

    private func itemLabel(_ title: String, detail: String?, titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: titleSize))
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func moduleDetail(_ module: SidebarModule) -> String {
        switch module {
        case .builtIn: L("Pick the shortcuts inside Built-in. Hiding the whole group keeps these choices.")
        case .commonPaths: L("Folder shortcuts you add or remove yourself, such as Desktop or Downloads.")
        case .locations: L("Choose which of these five places appear under Locations. Connected disks and saved servers always appear.")
        case .bookmarks: L("Browse the folders and items you bookmarked.")
        case .tags: L("Find files by their Finder tags.")
        }
    }

    private func reorder(_ index: Int, _ offset: Int) {
        app.updatePreferences { p in
            let target = index + offset
            guard p.sidebarModuleOrder.indices.contains(index), p.sidebarModuleOrder.indices.contains(target) else { return }
            p.sidebarModuleOrder.swapAt(index, target)
        }
    }

    private func builtInToggle(_ item: SidebarBuiltInItem, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: Binding(get: { !app.preferences.hiddenSidebarBuiltInItems.contains(item) }, set: { on in
            app.updatePreferences { p in
                if on { p.hiddenSidebarBuiltInItems.removeAll { $0 == item } } else if !p.hiddenSidebarBuiltInItems.contains(item) { p.hiddenSidebarBuiltInItems.append(item) }
            }
        })) {
            itemLabel(title, detail: detail, titleSize: 13)
        }
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("Settings.Sidebar.BuiltIn.\(item.rawValue)")
    }

    private func locationToggle(_ item: SidebarBuiltInLocation, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { !app.preferences.hiddenSidebarBuiltInLocations.contains(item) }, set: { on in
            app.updatePreferences { p in
                if on { p.hiddenSidebarBuiltInLocations.removeAll { $0 == item } } else if !p.hiddenSidebarBuiltInLocations.contains(item) { p.hiddenSidebarBuiltInLocations.append(item) }
            }
        }))
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
        .accessibilityIdentifier("Settings.Sidebar.Location.\(item.rawValue)")
    }
}

// MARK: Interaction

private struct InteractionSettings: View {
    @ObservedObject var app = AppModel.shared
    @AppStorage(SettingsKeys.blankDoubleClickEnabled) private var blankDoubleClickEnabled = true
    @AppStorage(DefaultsKey.blankDoubleClickAction) private var blankDoubleClickAction = BlankDoubleClickAction.parentFolder.rawValue
    @AppStorage(DefaultsKey.operationErrorSound) private var operationErrorSound = false
    @AppStorage(DefaultsKey.openPathChildrenOnHover) private var showsPathChildrenOnHover = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(L("Keyboard and Pointer")) {
                RowStack {
                    SettingsRow(L("Double-click blank space"),
                                detail: L("Double-clicking empty space takes you to the parent folder or back to the previous location.")) {
                        HStack(spacing: 14) {
                            Picker(L("Double-click action"), selection: $blankDoubleClickAction) {
                                Text(L("Parent Folder")).tag(BlankDoubleClickAction.parentFolder.rawValue)
                                Text(L("Back")).tag(BlankDoubleClickAction.back.rawValue)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("Settings.BlankDoubleClickAction")
                            Toggle(L("Double-click blank space"), isOn: $blankDoubleClickEnabled)
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                        }
                    }
                    CheckRow(L("Operation error sound"),
                             detail: L("Plays one system alert sound when a Wumi file operation fails. Keyboard navigation stays silent."),
                             isOn: $operationErrorSound)
                    CheckRow(L("Show copy and cut feedback"),
                             detail: L("After Copy or Cut, the result appears briefly next to the item count in the status bar."),
                             isOn: pref(\.showsOperationTips))
                    PopupRow(L("How to open files and folders"),
                             detail: L("Open files and folders with a single click or a double-click."),
                             selection: pref(\.opensItemsWithSingleClick),
                             options: [(false, L("Double-click")), (true, L("Single click"))])
                    PopupRow(L("Enter key"),
                             detail: L("Set Enter to rename the selected item or to open it."),
                             selection: pref(\.enterKeyAction),
                             options: [(.rename, L("Rename")), (.open, L("Open"))])
                    PopupRow(L("Backspace key"),
                             detail: L("Leave Backspace unused, or use it to go to the enclosing folder."),
                             selection: pref(\.backspaceKeyAction),
                             options: [(.ignore, L("Ignore")), (.navigateUp, L("Go up one level"))])
                    CheckRow(L("Use mouse side buttons for Back and Forward"),
                             detail: L("The side buttons of your mouse go back and forward in the active pane."),
                             isOn: pref(\.usesMouseButtonsForHistoryNavigation))
                    SettingsRow(L("Wait before opening a folder while dragging"),
                                detail: L("How long a dragged item has to rest on a folder before that folder opens.")) {
                        HStack(spacing: 8) {
                            Text(LF("%.2f s", app.preferences.dragHoverExpansionDelay))
                                .font(.system(size: 13))
                                .monospacedDigit()
                            Stepper(L("Wait before opening a folder while dragging"),
                                    value: Binding(get: { app.preferences.dragHoverExpansionDelay },
                                                   set: { value in app.updatePreferences { $0.dragHoverExpansionDelay = (value * 100).rounded() / 100 } }),
                                    in: 0.1...2.0, step: 0.05)
                                .labelsHidden()
                        }
                    }
                    CheckRow(L("Hold Shift to switch Move and Copy"),
                             detail: L("Dropping into another Wumi folder moves items on the same disk and copies them to a different disk. Hold Shift once you reach the target to swap Move and Copy."),
                             isOn: pref(\.shiftDragReversesOperation))
                    CheckRow(L("Show subfolders when pointing at a path arrow"),
                             detail: L("Rest the pointer on an arrow in the path bar to list the subfolders of that folder."),
                             isOn: $showsPathChildrenOnHover)
                }
            }
        }
    }
}

// MARK: Privacy

private struct PrivacySettings: View {
    @State private var fullDiskAccess: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard(L("Folder permissions")) {
                RowStack {
                    permissionRow(symbol: "lock.shield", title: L("Installed Edition"),
                                  detail: L("This edition runs with your macOS account permissions. macOS may ask before Wumi opens protected folders.")) {
                        Text(L("Local")).font(.system(size: 14, weight: .semibold))
                    }
                    permissionRow(symbol: "hand.raised", title: L("Full Disk Access"),
                                  detail: L("This check is an estimate; System Settings shows the actual permission. Reopen Wumi after you change it.")) {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(statusText)
                                .font(.system(size: 10))
                                .foregroundStyle(fullDiskAccess == true ? Color.green : Color.secondary)
                                .accessibilityIdentifier("Settings.Privacy.FullDiskAccess")
                            Button(L("Open Privacy Settings")) {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                            }
                        }
                    }
                    if fullDiskAccess == false {
                        FullDiskAccessDragCard()
                    }
                }
            }
            SettingsCard(L("Privacy Summary")) {
                VStack(alignment: .leading, spacing: 9) {
                    summaryLine("desktopcomputer", L("File names, paths, metadata, previews, and the file operations you request are all handled on this Mac."))
                    summaryLine("icloud.slash", L("Wumi never uploads file data and has no analytics, ads, accounts, or cloud sync."))
                    summaryLine("star", L("Bookmarks and favorites only help you navigate; they do not change which folders macOS lets Wumi open."))
                }
                .padding(.top, 4)
                .accessibilityIdentifier("Settings.Privacy.Summary")
            }
        }
        .onAppear(perform: check)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private var statusText: String {
        switch fullDiskAccess {
        case nil: L("Checking access…")
        case true?: L("Access detected")
        case false?: L("Access not detected")
        }
    }

    private func permissionRow<Trailing: View>(symbol: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.blue)
                .frame(width: 24)
            SettingsRow(title, detail: detail, control: trailing)
        }
    }

    private func summaryLine(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ~/Library/Safari is only readable with Full Disk Access. Probed off the main thread.
    private func check() {
        Task {
            let granted = await Task.detached(priority: .utility) {
                let protected = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Safari")
                return (try? FileManager.default.contentsOfDirectory(atPath: protected.path)) != nil
            }.value
            fullDiskAccess = granted
        }
    }
}

// MARK: Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject var app = AppModel.shared

    var body: some View {
        let conflicts = app.configuration.shortcutTable.conflicts
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(L("Keyboard Shortcuts")) {
                Text(L("Click the record button and press a key combination, or type a shortcut, then click Apply."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ForEach(conflicts, id: \.binding) { conflict in
                    Text(L("Shortcut conflicts with another command") + ": " + ShortcutTitles.token(for: conflict.binding) + " — "
                         + conflict.commands.map(ShortcutTitles.title).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ShortcutCommand.allCases, id: \.self) { command in
                        ShortcutRow(command: command)
                    }
                }
            }
        }
    }
}

/// Enabled checkbox, command name, token field ("shift+cmd+n"), record button and Apply, as in the original.
/// A secondary binding gets its own field only when one is configured.
private struct ShortcutRow: View {
    let command: ShortcutCommand
    @ObservedObject var app = AppModel.shared
    @State private var primary = ""
    @State private var secondary = ""
    @State private var error: String?
    @State private var recordingSlot: Int?
    @State private var monitor: Any?

    var body: some View {
        let disabled = app.configuration.disabledShortcutCommands.contains(command)
        let hasSecondary = app.configuration.secondaryShortcuts[command] != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle(ShortcutTitles.title(command), isOn: Binding(get: { !disabled }, set: { on in
                    app.update { c in
                        if on { c.disabledShortcutCommands.removeAll { $0 == command } }
                        else if !c.disabledShortcutCommands.contains(command) { c.disabledShortcutCommands.append(command) }
                    }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help(disabled ? L("Enable Shortcut") : L("Disable Shortcut"))
                .accessibilityIdentifier("Shortcut.\(command.rawValue).Enabled")
                Text(ShortcutTitles.title(command))
                    .font(.system(size: 13))
                    .foregroundStyle(disabled ? .secondary : .primary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                field($primary, slot: 0, identifier: "Primary")
                Button(L("Apply")) { commit() }
                    .accessibilityIdentifier("Shortcut.\(command.rawValue).Apply")
            }
            if hasSecondary {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 16 + 150, height: 1)
                    field($secondary, slot: 1, identifier: "Secondary")
                }
            }
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(.red).padding(.leading, 24)
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: stopRecording)
        .onChange(of: app.configuration.shortcuts[command]) { _, _ in load() }
        .onChange(of: app.configuration.secondaryShortcuts[command]) { _, _ in load() }
    }

    private func field(_ text: Binding<String>, slot: Int, identifier: String) -> some View {
        HStack(spacing: 8) {
            TextField(L("Shortcut"), text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .frame(width: 200)
                .onSubmit(commit)
                .accessibilityIdentifier("Shortcut.\(command.rawValue).\(identifier)")
            Button { recordingSlot == slot ? stopRecording() : startRecording(slot) } label: {
                Image(systemName: recordingSlot == slot ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(recordingSlot == slot ? Color.red : Color.primary)
            }
            .help(recordingSlot == slot ? L("Press a shortcut…") : L("Record Shortcut"))
            .accessibilityLabel(L("Record Shortcut"))
            .accessibilityIdentifier("Shortcut.\(command.rawValue).Record\(identifier)")
        }
    }

    private func load() {
        primary = app.configuration.shortcuts[command].map { ShortcutTitles.token(for: $0) } ?? ""
        secondary = app.configuration.secondaryShortcuts[command].map { ShortcutTitles.token(for: $0) } ?? ""
    }

    private func parse(_ text: String) throws -> ShortcutBinding? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let display = ShortcutTitles.fromDisplay(trimmed) { return display }
        return try ShortcutBinding.parse(trimmed)
    }

    private func commit() {
        stopRecording()
        do {
            let p = try parse(primary)
            let s = try parse(secondary)
            error = nil
            app.update { c in
                c.shortcuts[command] = p
                c.secondaryShortcuts[command] = s
            }
            load()
        } catch {
            self.error = L("Invalid shortcut")
        }
    }

    private func startRecording(_ slot: Int) {
        stopRecording()
        recordingSlot = slot
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            if event.keyCode == 53, flags.isEmpty {
                stopRecording()
                return nil
            }
            if let token = ShortcutTitles.token(keyCode: event.keyCode, characters: event.characters(byApplyingModifiers: []), flags: flags) {
                if slot == 0 { primary = token } else { secondary = token }
            } else {
                NSSound.beep()
            }
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingSlot = nil
    }
}

enum ShortcutTitles {
    static func title(_ command: ShortcutCommand) -> String {
        if let layout = command.paneLayout { return PaneLayoutNames.title(layout) }
        switch command {
        case .newWindow: return L("New Window")
        case .openSelection: return L("Open")
        case .invertSelection: return L("Invert Selection")
        case .newTab: return L("New Tab")
        case .closeTab: return L("Close Tab")
        case .removeDuplicateTabs: return L("Remove Duplicate Tabs")
        case .reopenClosedTab: return L("Reopen Closed Tab")
        case .editPath: return L("Edit Path")
        case .search: return L("Search")
        case .globalQuickSearch: return L("Lightning Search")
        case .navigateBack: return L("Back")
        case .navigateForward: return L("Forward")
        case .navigateUp: return L("Up One Level")
        case .addBookmark: return L("Add Bookmark")
        case .newFolder: return L("New Folder")
        case .newFile: return L("New File")
        case .rename: return L("Rename")
        case .duplicate: return L("Duplicate")
        case .cut: return L("Cut")
        case .copy: return L("Copy")
        case .copyPath: return L("Copy Absolute Path")
        case .paste: return L("Paste")
        case .pasteAndMove: return L("Move Item Here")
        case .moveToTrash: return L("Move to Trash")
        case .quickLook: return L("Quick Look")
        case .layoutFourColumns: return PaneLayoutNames.title(.oneLeftThreeRight)
        case .layoutFourRows: return PaneLayoutNames.title(.threeLeftOneRight)
        case .previousPane: return L("Focus Previous Pane")
        case .nextPane: return L("Focus Next Pane")
        case .toggleInspector: return L("Toggle Inspector")
        case .iconView: return L("Icon View")
        case .listView: return L("List View")
        case .columnView: return L("Column View")
        case .imageView: return L("Gallery View")
        case .batchRename: return L("Batch Rename")
        case .openTerminal: return L("Open in Terminal")
        case .openEditor: return L("Open in Editor")
        default: return command.rawValue
        }
    }

    /// Text form shown in the shortcut field, as in the original: "shift+cmd+i", "ctrl+tab", "dd".
    static func token(for binding: ShortcutBinding) -> String {
        if binding.isDoubleTap { return binding.key }
        let names: [ShortcutModifier: String] = [.control: "ctrl", .option: "option", .shift: "shift", .cmd: "cmd"]
        return (binding.modifiers.sorted().map { names[$0]! } + [binding.key]).joined(separator: "+")
    }

    /// Token for a recorded key event, or nil when the key cannot be bound.
    static func token(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> String? {
        let named: [UInt16: String] = [
            36: "return", 76: "return", 48: "tab", 49: "space", 51: "delete", 117: "forwarddelete", 53: "escape",
            123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
            122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
        ]
        // "+" separates tokens, so a plus key cannot be written in the text form.
        guard let key = named[keyCode] ?? characters?.lowercased(), !key.isEmpty, !key.contains("+") else { return nil }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// Parses display strings such as "⇧⌘N" back into bindings.
    static func fromDisplay(_ text: String) -> ShortcutBinding? {
        var modifiers: [ShortcutModifier] = []
        var rest = Substring(text)
        let symbols: [Character: ShortcutModifier] = ["⌃": .control, "⌥": .option, "⇧": .shift, "⌘": .cmd]
        while let first = rest.first, let modifier = symbols[first] {
            modifiers.append(modifier)
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        let keyMap: [String: String] = ["⇥": "tab", "⌫": "delete", "⌦": "forwarddelete", "↩": "return", "⎋": "escape", "↑": "up", "↓": "down", "←": "left", "→": "right", "space": "space"]
        let key = keyMap[String(rest).lowercased()] ?? String(rest).lowercased()
        if modifiers.isEmpty && text.count == 2 && Set(text.lowercased()).count == 1 { return ShortcutBinding([], text.lowercased()) }
        if modifiers.isEmpty && !["space", "return", "delete", "tab", "escape"].contains(key) { return nil }
        return ShortcutBinding(modifiers, key).normalized
    }
}
