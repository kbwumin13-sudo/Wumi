import Foundation

/// Workspace-level preferences retain their serialized keys; Wumi supplies its own appearance defaults.
/// Missing keys decode to defaults so older or partial configurations stay readable.
public struct WorkspacePreferences: Codable, Equatable, Sendable {
    // Appearance
    public var appearance: AppAppearance = .system
    public var interfaceFontSize: Double = 13
    public var usesColoredToolbarIcons: Bool = false
    public var showsToolbarLabels: Bool = false
    public var usesColoredSidebarIcons: Bool = true
    public var showsContextMenuIcons: Bool = true
    public var showsBookmarksAndWorkspaceBar: Bool = true
    public var bookmarkBarBackground: BookmarkBarBackground = .paleGray
    public var bookmarkBarCustomRGB: Int = 0xF6F9FC
    public var listDensity: FileListDensity = .standard
    public var iconGridScale: Double = 1
    public var filenameTruncation: FilenameTruncation = .middle
    public var listThumbnailCategories: [ListThumbnailCategory] = [.images, .multimedia, .other]
    public var showsDateAgeColors: Bool = true
    public var showsDateAgeStyle: Bool = true
    public var dateColorTheme: DateColorTheme = .light
    public var showsDiskFreeSpace: Bool = true
    public var showsGitStatus: Bool = true
    public var fileSizeUnit: FileSizeUnit = .decimal

    // Sidebar
    public var sidebarModuleOrder: [SidebarModule] = [.builtIn, .commonPaths, .locations, .bookmarks, .tags]
    public var hiddenSidebarModules: [SidebarModule] = []
    public var defaultExpandedSidebarModules: [SidebarModule] = [.locations, .builtIn, .commonPaths]
    public var hiddenSidebarBuiltInItems: [SidebarBuiltInItem] = []
    public var hiddenSidebarBuiltInLocations: [SidebarBuiltInLocation] = []
    public var sidebarItemOrder: [String: [String]] = [:]
    public var pinnedFolderPaths: [String] = []

    // Interaction
    public var opensItemsWithSingleClick: Bool = false
    public var enterKeyAction: EnterKeyAction = .rename
    public var backspaceKeyAction: BackspaceKeyAction = .ignore
    public var usesMouseButtonsForHistoryNavigation: Bool = true
    public var dragHoverExpansionDelay: Double = 0.45
    public var shiftDragReversesOperation: Bool = true
    public var showsOperationTips: Bool = true
    public var usesNaturalNumericSorting: Bool = true
    public var remembersWindowGeometry: Bool = true
    public var removableDeviceBehavior: RemovableDeviceBehavior = .ask
    public var namedWorkspaceSwitchBehavior: NamedWorkspaceSwitchBehavior = .openInNewTab

    // Archives and preview
    public var previewsArchives: Bool = true
    public var previewsFolders: Bool = true
    public var archiveDirectBrowseSizeLimitMB: Int = 512

    // Floating ball
    public var showsQuickCapsule: Bool = true
    public var floatingBallTransparency: Double = 0.35
    public var expandsFloatingBallOnHover: Bool = true
    public var floatingBallDoubleClickAction: FloatingBallAction = .up
    public var enabledFloatingBallActions: [FloatingBallAction] = [.selectAll, .back, .forward, .up]
    public var floatingBallActionOrder: [FloatingBallAction] = FloatingBallAction.allCases

    // File Transit / Floating Files
    public var showsFileTransitMenuBarItem: Bool = true
    public var showsFileTransitWindowShortcut: Bool = true
    public var enablesFileTransitIsland: Bool = true
    public var fileTransitDockEdge: FileTransitDockEdge = .top
    public var fileTransitDockUsesAutomaticPlacement: Bool = true
    public var fileTransitPanelOpacity: Double = 0.8

    public init() {}

    public static let defaults = WorkspacePreferences()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorkspacePreferences()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        appearance = v(.appearance, d.appearance)
        interfaceFontSize = v(.interfaceFontSize, d.interfaceFontSize)
        usesColoredToolbarIcons = v(.usesColoredToolbarIcons, d.usesColoredToolbarIcons)
        showsToolbarLabels = v(.showsToolbarLabels, d.showsToolbarLabels)
        usesColoredSidebarIcons = v(.usesColoredSidebarIcons, d.usesColoredSidebarIcons)
        showsContextMenuIcons = v(.showsContextMenuIcons, d.showsContextMenuIcons)
        showsBookmarksAndWorkspaceBar = v(.showsBookmarksAndWorkspaceBar, d.showsBookmarksAndWorkspaceBar)
        bookmarkBarBackground = v(.bookmarkBarBackground, d.bookmarkBarBackground)
        bookmarkBarCustomRGB = v(.bookmarkBarCustomRGB, d.bookmarkBarCustomRGB)
        listDensity = v(.listDensity, d.listDensity)
        iconGridScale = v(.iconGridScale, d.iconGridScale)
        filenameTruncation = v(.filenameTruncation, d.filenameTruncation)
        listThumbnailCategories = v(.listThumbnailCategories, d.listThumbnailCategories)
        showsDateAgeColors = v(.showsDateAgeColors, d.showsDateAgeColors)
        showsDateAgeStyle = v(.showsDateAgeStyle, d.showsDateAgeStyle)
        dateColorTheme = v(.dateColorTheme, d.dateColorTheme)
        showsDiskFreeSpace = v(.showsDiskFreeSpace, d.showsDiskFreeSpace)
        showsGitStatus = v(.showsGitStatus, d.showsGitStatus)
        fileSizeUnit = v(.fileSizeUnit, d.fileSizeUnit)
        sidebarModuleOrder = v(.sidebarModuleOrder, d.sidebarModuleOrder)
        hiddenSidebarModules = v(.hiddenSidebarModules, d.hiddenSidebarModules)
        defaultExpandedSidebarModules = v(.defaultExpandedSidebarModules, d.defaultExpandedSidebarModules)
        hiddenSidebarBuiltInItems = v(.hiddenSidebarBuiltInItems, d.hiddenSidebarBuiltInItems)
        hiddenSidebarBuiltInLocations = v(.hiddenSidebarBuiltInLocations, d.hiddenSidebarBuiltInLocations)
        sidebarItemOrder = v(.sidebarItemOrder, d.sidebarItemOrder)
        pinnedFolderPaths = v(.pinnedFolderPaths, d.pinnedFolderPaths)
        opensItemsWithSingleClick = v(.opensItemsWithSingleClick, d.opensItemsWithSingleClick)
        enterKeyAction = v(.enterKeyAction, d.enterKeyAction)
        backspaceKeyAction = v(.backspaceKeyAction, d.backspaceKeyAction)
        usesMouseButtonsForHistoryNavigation = v(.usesMouseButtonsForHistoryNavigation, d.usesMouseButtonsForHistoryNavigation)
        dragHoverExpansionDelay = v(.dragHoverExpansionDelay, d.dragHoverExpansionDelay)
        shiftDragReversesOperation = v(.shiftDragReversesOperation, d.shiftDragReversesOperation)
        showsOperationTips = v(.showsOperationTips, d.showsOperationTips)
        usesNaturalNumericSorting = v(.usesNaturalNumericSorting, d.usesNaturalNumericSorting)
        remembersWindowGeometry = v(.remembersWindowGeometry, d.remembersWindowGeometry)
        removableDeviceBehavior = v(.removableDeviceBehavior, d.removableDeviceBehavior)
        namedWorkspaceSwitchBehavior = v(.namedWorkspaceSwitchBehavior, d.namedWorkspaceSwitchBehavior)
        previewsArchives = v(.previewsArchives, d.previewsArchives)
        previewsFolders = v(.previewsFolders, d.previewsFolders)
        archiveDirectBrowseSizeLimitMB = v(.archiveDirectBrowseSizeLimitMB, d.archiveDirectBrowseSizeLimitMB)
        showsQuickCapsule = v(.showsQuickCapsule, d.showsQuickCapsule)
        floatingBallTransparency = v(.floatingBallTransparency, d.floatingBallTransparency)
        expandsFloatingBallOnHover = v(.expandsFloatingBallOnHover, d.expandsFloatingBallOnHover)
        floatingBallDoubleClickAction = v(.floatingBallDoubleClickAction, d.floatingBallDoubleClickAction)
        enabledFloatingBallActions = v(.enabledFloatingBallActions, d.enabledFloatingBallActions)
        floatingBallActionOrder = v(.floatingBallActionOrder, d.floatingBallActionOrder)
        showsFileTransitMenuBarItem = v(.showsFileTransitMenuBarItem, d.showsFileTransitMenuBarItem)
        showsFileTransitWindowShortcut = v(.showsFileTransitWindowShortcut, d.showsFileTransitWindowShortcut)
        enablesFileTransitIsland = v(.enablesFileTransitIsland, d.enablesFileTransitIsland)
        fileTransitDockEdge = v(.fileTransitDockEdge, d.fileTransitDockEdge)
        fileTransitDockUsesAutomaticPlacement = v(.fileTransitDockUsesAutomaticPlacement, d.fileTransitDockUsesAutomaticPlacement)
        fileTransitPanelOpacity = v(.fileTransitPanelOpacity, d.fileTransitPanelOpacity)
    }
}
