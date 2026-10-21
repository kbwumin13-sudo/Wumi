import Foundation

// Raw values match the original app's persisted JSON so stored sessions and
// configuration stay comparable field by field (see docs/recon/02).

public enum BrowserViewMode: String, Codable, CaseIterable, Sendable {
    case list, icons, columns, images
}

public enum FileSortKey: String, Codable, CaseIterable, Sendable {
    case name, modificationDate, addedDate, kind, size, creationDate, lastOpenedDate, tags, fileExtension
}

public enum FileGroupingMode: String, Codable, CaseIterable, Sendable {
    case none, kind, application, lastOpened, added, modified, created, size, tags, fileExtension
}

public enum FileListColumn: String, Codable, CaseIterable, Sendable {
    case name, modificationDate, size, kind, creationDate, lastOpenedDate, addedDate, tags, fileExtension

    /// The sort key a column header click selects.
    public var sortKey: FileSortKey {
        switch self {
        case .name: .name
        case .modificationDate: .modificationDate
        case .size: .size
        case .kind: .kind
        case .creationDate: .creationDate
        case .lastOpenedDate: .lastOpenedDate
        case .addedDate: .addedDate
        case .tags: .tags
        case .fileExtension: .fileExtension
        }
    }

    public var isDate: Bool {
        switch self {
        case .modificationDate, .creationDate, .lastOpenedDate, .addedDate: true
        default: false
        }
    }
}

public enum FileListDensity: String, Codable, CaseIterable, Sendable {
    case compact, standard, comfortable

    /// Row pitch in points for list views. Standard matches the original's measured 25 pt rows; the other two are estimates.
    public var rowHeight: CGFloat {
        switch self {
        case .compact: 21
        case .standard: 25
        case .comfortable: 30
        }
    }
}

public enum FilenameTruncation: String, Codable, CaseIterable, Sendable {
    case middle, tail, head
}

public enum FileSizeUnit: String, Codable, CaseIterable, Sendable {
    case decimal, binary
}

public enum DateColorTheme: String, Codable, CaseIterable, Sendable {
    case light, medium, highContrast
}

public enum ListThumbnailCategory: String, Codable, CaseIterable, Sendable {
    case images, documents, multimedia, other
}

public enum AppAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public enum EnterKeyAction: String, Codable, CaseIterable, Sendable {
    case rename, open
}

public enum BackspaceKeyAction: String, Codable, CaseIterable, Sendable {
    case ignore, navigateUp
}

public enum RemovableDeviceBehavior: String, Codable, CaseIterable, Sendable {
    case ask, openDeviceWorkspace, showInLocationsOnly
}

public enum NamedWorkspaceSwitchBehavior: String, Codable, CaseIterable, Sendable {
    case openInNewTab, replaceCurrentTab
}

public enum FileTransitDockEdge: String, Codable, CaseIterable, Sendable {
    case top, left, right
}

public enum BookmarkBarBackground: String, Codable, CaseIterable, Sendable {
    case white, paleBlue, paleMint, paleLavender, palePeach, paleGray, custom
}

public enum SearchInputMode: String, Codable, CaseIterable, Sendable {
    case keyword, wildcard, regularExpression, advanced
}

/// Twelve pane arrangements offered by the layout chooser and the Workspace menu.
public enum PaneLayout: String, Codable, CaseIterable, Sendable {
    case single, twoColumns, twoRows, threeColumns, threeRows
    case oneLeftTwoRight, twoLeftOneRight, oneTopTwoBottom, twoTopOneBottom
    case fourGrid, oneLeftThreeRight, threeLeftOneRight

    /// Where each pane sits, in pane order, as English keys of the original's menus ("Top Left", "Middle Left", …).
    public var paneLocations: [String] {
        switch self {
        case .single: ["Center"]
        case .twoColumns: ["Left", "Right"]
        case .twoRows: ["Top", "Bottom"]
        case .threeColumns: ["Left", "Middle", "Right"]
        case .threeRows: ["Top", "Middle", "Bottom"]
        case .oneLeftTwoRight: ["Left", "Top Right", "Bottom Right"]
        case .twoLeftOneRight: ["Top Left", "Bottom Left", "Right"]
        case .oneTopTwoBottom: ["Top", "Bottom Left", "Bottom Right"]
        case .twoTopOneBottom: ["Top Left", "Top Right", "Bottom"]
        case .fourGrid: ["Top Left", "Top Right", "Bottom Left", "Bottom Right"]
        case .oneLeftThreeRight: ["Left", "Top Right", "Middle Right", "Bottom Right"]
        case .threeLeftOneRight: ["Top Left", "Middle Left", "Bottom Left", "Right"]
        }
    }

    public var paneCount: Int {
        switch self {
        case .single: 1
        case .twoColumns, .twoRows: 2
        case .threeColumns, .threeRows, .oneLeftTwoRight, .twoLeftOneRight, .oneTopTwoBottom, .twoTopOneBottom: 3
        case .fourGrid, .oneLeftThreeRight, .threeLeftOneRight: 4
        }
    }
}
