import Foundation

/// Order of the Finder tags DirDesk lists (sidebar, Tags submenu, Lightning Search), as observed in the original:
/// tags that items carry come first (in Finder's favorite order, then by name), then tags created in DirDesk, then
/// the remaining Finder favorites. Hidden tags and duplicates are left out. Names compare by the current locale
/// (`localizedStandardCompare`), so under a Chinese region Han names come before Latin ones, as the original showed
/// (runtime capture 2026-10-20). Hidden names match case-insensitively; the original stores them lowercased.
public enum FinderTagOrdering {
    public static func order(inUse: some Collection<String>, created: [String], favorites: [String], hidden: Set<String>) -> [String] {
        let hidden = Set(hidden.map { $0.lowercased() })
        let rank = Dictionary(favorites.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let used = inUse.sorted { a, b in
            switch (rank[a], rank[b]) {
            case let (x?, y?): x < y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.localizedStandardCompare(b) == .orderedAscending
            }
        }
        var seen = Set<String>()
        return (used + created + favorites).filter { !$0.isEmpty && !hidden.contains($0.lowercased()) && seen.insert($0).inserted }
    }
}
