import Foundation

/// Sorting and grouping of one folder. With "Remember folder sorting and grouping" on, rules the user changed by
/// hand are stored per folder and restored when the folder is entered again.
public struct FolderDisplayRules: Codable, Equatable, Sendable {
    public var sortKey: FileSortKey
    public var ascending: Bool
    public var foldersFirst: Bool
    public var grouping: FileGroupingMode

    public init(sortKey: FileSortKey, ascending: Bool, foldersFirst: Bool, grouping: FileGroupingMode) {
        self.sortKey = sortKey
        self.ascending = ascending
        self.foldersFirst = foldersFirst
        self.grouping = grouping
    }

    public init(_ configuration: ViewConfiguration) {
        self.init(sortKey: configuration.sortKey, ascending: configuration.sortAscending,
                  foldersFirst: configuration.foldersFirst, grouping: configuration.groupingMode)
    }

    public func apply(to configuration: inout ViewConfiguration) {
        configuration.sortKey = sortKey
        configuration.sortAscending = ascending
        configuration.foldersFirst = foldersFirst
        configuration.groupingMode = grouping
    }

    /// Rules of a folder without remembered rules: the default sorting plus the pane's own grouping.
    public static func standard(sortKey: FileSortKey, ascending: Bool, baseline: FolderDisplayBaseline) -> FolderDisplayRules {
        FolderDisplayRules(sortKey: sortKey, ascending: ascending, foldersFirst: baseline.foldersFirst, grouping: baseline.groupingMode)
    }
}

/// Grouping and folders-first of a pane. Folders without remembered rules use it, so a remembered folder's
/// grouping does not follow the pane into the next folder. Sorting is not part of it: temporary sort changes
/// end when the folder is left.
public struct FolderDisplayBaseline: Codable, Equatable, Sendable {
    public var groupingMode: FileGroupingMode
    public var foldersFirst: Bool

    public init(groupingMode: FileGroupingMode = .none, foldersFirst: Bool = false) {
        self.groupingMode = groupingMode
        self.foldersFirst = foldersFirst
    }

    public init(_ configuration: ViewConfiguration) {
        self.init(groupingMode: configuration.groupingMode, foldersFirst: configuration.foldersFirst)
    }
}

/// Remembered folder rules in UserDefaults, most recently changed last. Records are kept while remembering is
/// switched off; they are only neither written nor applied then.
public final class FolderDisplayStore: @unchecked Sendable {
    public static let shared = FolderDisplayStore(defaults: .standard)
    public static let capacity = 2000

    private struct Record: Codable {
        var path: String
        var rules: FolderDisplayRules
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var records: [Record]?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: DefaultsKey.rememberFolderDisplay) }
        set { defaults.set(newValue, forKey: DefaultsKey.rememberFolderDisplay) }
    }

    public var count: Int { lock.withLock { load().count } }

    public func rules(for folder: URL) -> FolderDisplayRules? {
        let path = Self.key(folder)
        return lock.withLock { load().last { $0.path == path }?.rules }
    }

    public func remember(_ rules: FolderDisplayRules, for folder: URL) {
        let path = Self.key(folder)
        lock.withLock {
            var list = load().filter { $0.path != path }
            list.append(Record(path: path, rules: rules))
            if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
            save(list)
        }
    }

    public func forget(_ folder: URL) {
        let path = Self.key(folder)
        lock.withLock {
            let list = load()
            let kept = list.filter { $0.path != path }
            if kept.count != list.count { save(kept) }
        }
    }

    public func removeAll() {
        lock.withLock { save([]) }
    }

    static func key(_ folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func load() -> [Record] {
        if let records { return records }
        let decoded = defaults.data(forKey: DefaultsKey.folderDisplay).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        records = decoded
        return decoded
    }

    private func save(_ list: [Record]) {
        records = list
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: DefaultsKey.folderDisplay) }
    }
}
