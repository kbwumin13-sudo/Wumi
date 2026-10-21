import Foundation

/// Per-pane display configuration. Field names and defaults follow the original session JSON.
public struct ViewConfiguration: Codable, Equatable, Sendable {
    public var mode: BrowserViewMode = .list
    public var pinnedFolderPaths: [String] = []
    /// Upper bound for "Pin Folder to Top" ("You can pin up to 1,024 folders.").
    public static let maximumPinnedFolders = 1024
    public var gridThumbnailScale: Double = 1
    public var listThumbnailSize: Double = 16
    public var sortAscending: Bool = true
    public var groupingMode: FileGroupingMode = .none
    public var foldersFirst: Bool = false
    public var showsHiddenFiles: Bool = false
    public var columnBrowserWidths: [String: Double] = [:]
    public var columnWidth: Double = 200
    public var visibleListColumns: [FileListColumn] = [.name, .modificationDate, .size, .kind, .lastOpenedDate]
    public var listColumnWidths: [String: Double] = [:]
    public var usesNaturalNumericSorting: Bool = true
    public var sortKey: FileSortKey = .name

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ViewConfiguration()
        mode = try c.decodeIfPresent(BrowserViewMode.self, forKey: .mode) ?? d.mode
        pinnedFolderPaths = try c.decodeIfPresent([String].self, forKey: .pinnedFolderPaths) ?? d.pinnedFolderPaths
        gridThumbnailScale = try c.decodeIfPresent(Double.self, forKey: .gridThumbnailScale) ?? d.gridThumbnailScale
        listThumbnailSize = try c.decodeIfPresent(Double.self, forKey: .listThumbnailSize) ?? d.listThumbnailSize
        sortAscending = try c.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? d.sortAscending
        groupingMode = try c.decodeIfPresent(FileGroupingMode.self, forKey: .groupingMode) ?? d.groupingMode
        foldersFirst = try c.decodeIfPresent(Bool.self, forKey: .foldersFirst) ?? d.foldersFirst
        showsHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .showsHiddenFiles) ?? d.showsHiddenFiles
        columnBrowserWidths = try c.decodeIfPresent([String: Double].self, forKey: .columnBrowserWidths) ?? d.columnBrowserWidths
        columnWidth = try c.decodeIfPresent(Double.self, forKey: .columnWidth) ?? d.columnWidth
        visibleListColumns = try c.decodeIfPresent([FileListColumn].self, forKey: .visibleListColumns) ?? d.visibleListColumns
        listColumnWidths = try c.decodeIfPresent([String: Double].self, forKey: .listColumnWidths) ?? d.listColumnWidths
        usesNaturalNumericSorting = try c.decodeIfPresent(Bool.self, forKey: .usesNaturalNumericSorting) ?? d.usesNaturalNumericSorting
        sortKey = try c.decodeIfPresent(FileSortKey.self, forKey: .sortKey) ?? d.sortKey
    }
}
