import Foundation

/// Sort options for one view. Mirrors the original: natural compare via `localizedStandardCompare`,
/// otherwise case- and diacritic-insensitive compare; pinned folders, then folders first when enabled.
public struct FileSortOptions: Sendable {
    public var key: FileSortKey
    public var ascending: Bool
    public var foldersFirst: Bool
    public var natural: Bool
    public var pinnedPaths: Set<String>

    public init(key: FileSortKey = .name, ascending: Bool = true, foldersFirst: Bool = false, natural: Bool = true,
                pinnedPaths: Set<String> = []) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
        self.natural = natural
        self.pinnedPaths = pinnedPaths
    }

    public init(_ configuration: ViewConfiguration, naturalOverride: Bool? = nil) {
        self.init(key: configuration.sortKey, ascending: configuration.sortAscending, foldersFirst: configuration.foldersFirst,
                  natural: naturalOverride ?? configuration.usesNaturalNumericSorting,
                  pinnedPaths: Set(configuration.pinnedFolderPaths))
    }
}

public enum FileSorter {
    public static func compareNames(_ a: String, _ b: String, natural: Bool) -> ComparisonResult {
        natural ? a.localizedStandardCompare(b) : a.compare(b, options: [.caseInsensitive, .diacriticInsensitive])
    }

    /// Compares by the primary key only; `nil` values sort before values in ascending order.
    static func comparePrimary(_ a: FileItem, _ b: FileItem, key: FileSortKey, natural: Bool,
                               kind: (FileItem) -> String) -> ComparisonResult {
        func dates(_ x: Date?, _ y: Date?) -> ComparisonResult {
            switch (x, y) {
            case (nil, nil): .orderedSame
            case (nil, _): .orderedAscending
            case (_, nil): .orderedDescending
            case let (x?, y?): x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            }
        }
        switch key {
        case .name:
            return compareNames(a.name, b.name, natural: natural)
        case .modificationDate:
            return dates(a.modificationDate, b.modificationDate)
        case .creationDate:
            return dates(a.creationDate, b.creationDate)
        case .addedDate:
            return dates(a.addedDate, b.addedDate)
        case .lastOpenedDate:
            return dates(a.lastOpenedDate, b.lastOpenedDate)
        case .size:
            let x = a.size ?? -1, y = b.size ?? -1
            return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
        case .kind:
            return compareNames(kind(a), kind(b), natural: natural)
        case .tags:
            let x = a.tags.joined(separator: ","), y = b.tags.joined(separator: ",")
            if x.isEmpty != y.isEmpty { return x.isEmpty ? .orderedDescending : .orderedAscending }
            return compareNames(x, y, natural: natural)
        case .fileExtension:
            return compareNames(a.fileExtension, b.fileExtension, natural: natural)
        }
    }

    /// Decorate-sort-undecorate: names, paths and text keys are converted once per item (as NSString, so the
    /// Finder-style `localizedStandardCompare` runs without re-bridging), which keeps 100,000-item folders fast.
    public static func sort(_ items: [FileItem], options: FileSortOptions, kind: (FileItem) -> String = { _ in "" }) -> [FileItem] {
        struct Key {
            let pinned: Bool
            let folder: Bool
            let name: NSString
            let path: NSString
            let text: NSString?
            let tagsEmpty: Bool
        }
        let keys: [Key] = items.map { item in
            let path = item.url.path
            let text: NSString? = switch options.key {
            case .kind: kind(item) as NSString
            case .tags: item.tags.joined(separator: ",") as NSString
            case .fileExtension: item.fileExtension as NSString
            default: nil
            }
            return Key(pinned: item.isBrowsableFolder && options.pinnedPaths.contains(path), folder: item.isBrowsableFolder,
                       name: item.name as NSString, path: path as NSString, text: text, tagsEmpty: item.tags.isEmpty)
        }
        func names(_ a: NSString, _ b: NSString) -> ComparisonResult {
            options.natural ? a.localizedStandardCompare(b as String) : a.compare(b as String, options: [.caseInsensitive, .diacriticInsensitive])
        }
        func dates(_ x: Date?, _ y: Date?) -> ComparisonResult {
            switch (x, y) {
            case (nil, nil): .orderedSame
            case (nil, _): .orderedAscending
            case (_, nil): .orderedDescending
            case let (x?, y?): x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            }
        }
        func primary(_ i: Int, _ j: Int) -> ComparisonResult {
            let a = items[i], b = items[j]
            switch options.key {
            case .name: return names(keys[i].name, keys[j].name)
            case .modificationDate: return dates(a.modificationDate, b.modificationDate)
            case .creationDate: return dates(a.creationDate, b.creationDate)
            case .addedDate: return dates(a.addedDate, b.addedDate)
            case .lastOpenedDate: return dates(a.lastOpenedDate, b.lastOpenedDate)
            case .size:
                let x = a.size ?? -1, y = b.size ?? -1
                return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case .tags:
                if keys[i].tagsEmpty != keys[j].tagsEmpty { return keys[i].tagsEmpty ? .orderedDescending : .orderedAscending }
                return names(keys[i].text ?? "", keys[j].text ?? "")
            case .kind, .fileExtension:
                return names(keys[i].text ?? "", keys[j].text ?? "")
            }
        }
        let order = items.indices.sorted { i, j in
            let a = keys[i], b = keys[j]
            if a.pinned != b.pinned { return a.pinned }
            if options.foldersFirst, a.folder != b.folder { return a.folder }
            var result = primary(i, j)
            if result == .orderedSame, options.key != .name { result = names(a.name, b.name) }
            if result == .orderedSame { result = a.path.compare(b.path as String) }
            return options.ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return order.map { items[$0] }
    }
}
