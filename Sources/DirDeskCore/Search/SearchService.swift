import Darwin
import Foundation

/// Limits for one live in-pane search. The defaults follow the original `SearchBudget.default`.
public struct SearchBudget: Equatable, Sendable {
    public var maximumDepth: Int
    public var maximumDirectories: Int
    public var maximumInspectedEntries: Int
    public var maximumResults: Int
    public var maximumElapsedTime: Duration

    public init(maximumDepth: Int, maximumDirectories: Int, maximumInspectedEntries: Int, maximumResults: Int,
                maximumElapsedTime: Duration) {
        self.maximumDepth = maximumDepth
        self.maximumDirectories = maximumDirectories
        self.maximumInspectedEntries = maximumInspectedEntries
        self.maximumResults = maximumResults
        self.maximumElapsedTime = maximumElapsedTime
    }

    public static let `default` = SearchBudget(maximumDepth: 32, maximumDirectories: 10_000, maximumInspectedEntries: 100_000,
                                               maximumResults: 5_000, maximumElapsedTime: .seconds(3))
}

/// Why a live search ended early. `depth` means deeper folders were skipped; the rest stop the search.
public enum SearchStopReason: String, Equatable, Sendable, CaseIterable {
    case folderCount, depth, inspected, results, time, cancelled

    public var message: String {
        switch self {
        case .folderCount: "Search stopped at its folder-count limit."
        case .depth: "Search stopped at its folder-depth limit."
        case .inspected: "Search stopped at its inspected-item limit."
        case .results: "Search stopped at its result limit."
        case .time: "Search stopped at its time limit."
        case .cancelled: "Search stopped."
        }
    }
}

/// Live, depth-first search below a folder (the pane's search field). Results stay a snapshot:
/// nothing is watched, callers refresh to pick up file changes.
public enum SearchService {
    /// Enumerates `root` and reports matches in batches on the calling thread. Runs synchronously;
    /// call off the main thread. Returns nil when the enumeration finished within the budget.
    /// An empty query matches nothing.
    @discardableResult
    public static func search(root: URL, query: SearchQuery, recursive: Bool = true, includeHidden: Bool = false,
                              budget: SearchBudget = .default, now: Date = Date(), calendar: Calendar = .current,
                              batchSize: Int = 200, isCancelled: () -> Bool = { false },
                              onBatch: ([FileItem]) -> Void) -> SearchStopReason? {
        guard !query.isEmpty else { return nil }
        let matchers = query.tokens.map { SearchTokenMatcher($0, now: now, calendar: calendar) }
        // Name conditions are checked on the URL before any metadata is turned into a FileItem.
        let nameMatchers = matchers.filter { $0.token.field == .name }
        let itemMatchers = matchers.filter { $0.token.field != .name }
        let needsTags = matchers.contains { $0.token.field == .tag }
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        let wanted = DirectoryLoader.keys(for: root)
        let keys = Set(wanted)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: wanted,
                                                              options: options, errorHandler: { _, _ in true }) else { return nil }
        let clock = ContinuousClock()
        let started = clock.now
        var inspected = 0
        var directories = 0
        var resultCount = 0
        var skippedDeeperFolders = false
        var stop: SearchStopReason?
        var batch: [FileItem] = []
        batch.reserveCapacity(max(batchSize, 1))
        while let url = enumerator.nextObject() as? URL {
            inspected += 1
            if inspected % 64 == 0 {
                if isCancelled() { stop = .cancelled; break }
                if clock.now - started > budget.maximumElapsedTime { stop = .time; break }
            }
            if inspected > budget.maximumInspectedEntries { stop = .inspected; break }
            let values = try? url.resourceValues(forKeys: keys)
            if recursive, values?.isDirectory == true, values?.isPackage != true, values?.isSymbolicLink != true {
                if enumerator.level >= budget.maximumDepth {
                    enumerator.skipDescendants()
                    skippedDeeperFolders = true
                } else {
                    directories += 1
                    if directories > budget.maximumDirectories { stop = .folderCount; break }
                }
            }
            let name = values?.name ?? url.lastPathComponent
            guard nameMatchers.allSatisfy({ $0.matches(name: name) }) else { continue }
            var item = DirectoryLoader.makeItem(url: url, values: values)
            if needsTags, item.tags.isEmpty { item.tags = tagNames(at: url.path) }
            guard itemMatchers.allSatisfy({ $0.matches(item) }) else { continue }
            batch.append(item)
            resultCount += 1
            if batch.count >= max(batchSize, 1) {
                onBatch(batch)
                batch.removeAll(keepingCapacity: true)
            }
            if resultCount >= budget.maximumResults { stop = .results; break }
        }
        if !batch.isEmpty { onBatch(batch) }
        return stop ?? (skippedDeeperFolders ? .depth : nil)
    }

    /// Finder tags read on their own: requesting tags together with the iCloud keys of
    /// `DirectoryLoader.resourceKeys` returns no tags on current macOS.
    static func tagNames(at path: String) -> [String] {
        guard getxattr(path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, XATTR_NOFOLLOW) > 0 else { return [] }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// True when `item` satisfies every token (used to filter already-loaded rows without enumerating).
    public static func matches(_ item: FileItem, query: SearchQuery, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard !query.isEmpty else { return false }
        return query.tokens.allSatisfy { SearchTokenMatcher($0, now: now, calendar: calendar).matches(item) }
    }
}

/// One token compiled once per search: regular expressions, sizes and date ranges are prepared up front.
struct SearchTokenMatcher {
    let token: SearchToken
    private let regex: NSRegularExpression?
    private let byteCount: Int64?
    private let dateRange: Range<Date>?

    init(_ token: SearchToken, now: Date, calendar: Calendar) {
        self.token = token
        switch token.comparison {
        case .wildcard:
            let escaped = NSRegularExpression.escapedPattern(for: token.value)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            regex = try? NSRegularExpression(pattern: "^" + escaped + "$", options: [.caseInsensitive, .dotMatchesLineSeparators])
        case .regularExpression:
            regex = try? NSRegularExpression(pattern: token.value, options: [.caseInsensitive])
        default:
            regex = nil
        }
        byteCount = token.field == .size ? SearchValueParser.byteCount(token.value) : nil
        dateRange = token.field == .modified ? SearchValueParser.dateInterval(token.value, now: now, calendar: calendar) : nil
    }

    func matches(name: String) -> Bool {
        token.isNegated != matchesText([name])
    }

    func matches(_ item: FileItem) -> Bool {
        let result: Bool
        switch token.field {
        case .name:
            result = matchesText([item.name])
        case .ext:
            let ext = item.isBrowsableFolder ? "" : item.fileExtension
            if token.comparison == .isPresent {
                result = !ext.isEmpty
            } else {
                let wanted = token.value.hasPrefix(".") ? String(token.value.dropFirst()) : token.value
                result = matchesText([ext], value: wanted)
            }
        case .kind:
            let kind = item.isBrowsableFolder ? "folder" : item.isAliasFile ? "alias"
                : item.fileExtension.isEmpty ? "file" : item.fileExtension.uppercased()
            result = matchesText([kind])
        case .tag:
            result = token.comparison == .isPresent ? !item.tags.isEmpty : matchesText(item.tags)
        case .size:
            result = compare(item.isBrowsableFolder ? nil : item.size)
        case .modified:
            result = compare(item.modificationDate)
        }
        return token.isNegated != result
    }

    /// Text comparisons are case- and diacritic-insensitive. A multi-valued field (tags) matches when any value does.
    private func matchesText(_ candidates: [String], value: String? = nil) -> Bool {
        let wanted = value ?? token.value
        switch token.comparison {
        case .isPresent:
            return candidates.contains { !$0.isEmpty }
        case .contains:
            return candidates.contains { $0.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        case .equal:
            return candidates.contains { $0.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        case .wildcard, .regularExpression:
            guard let regex else { return false }
            return candidates.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        case .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual:
            return candidates.contains { candidate in
                let order = candidate.compare(wanted, options: [.caseInsensitive, .numeric])
                switch token.comparison {
                case .greaterThan: return order == .orderedDescending
                case .greaterThanOrEqual: return order != .orderedAscending
                case .lessThan: return order == .orderedAscending
                default: return order != .orderedDescending
                }
            }
        }
    }

    private func compare(_ size: Int64?) -> Bool {
        guard let size else { return false }
        if token.comparison == .isPresent { return true }
        guard let byteCount else { return false }
        switch token.comparison {
        case .greaterThan: return size > byteCount
        case .greaterThanOrEqual: return size >= byteCount
        case .lessThan: return size < byteCount
        case .lessThanOrEqual: return size <= byteCount
        default: return size == byteCount
        }
    }

    /// A date value names a day (or week); `>` means after it, `>=` on or after it, and so on.
    private func compare(_ date: Date?) -> Bool {
        guard let date else { return false }
        if token.comparison == .isPresent { return true }
        guard let dateRange else { return false }
        switch token.comparison {
        case .greaterThan: return date >= dateRange.upperBound
        case .greaterThanOrEqual: return date >= dateRange.lowerBound
        case .lessThan: return date < dateRange.lowerBound
        case .lessThanOrEqual: return date < dateRange.upperBound
        default: return dateRange.contains(date)
        }
    }
}
