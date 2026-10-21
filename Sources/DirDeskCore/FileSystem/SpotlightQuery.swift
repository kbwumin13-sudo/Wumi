import CoreServices
import Foundation

/// Synchronous Spotlight (MDQuery) helper for the Recent and Tag destinations. Call off the main thread.
public enum SpotlightQuery {
    public enum Scope: Sendable {
        case home, computer, folders([URL])
    }

    public enum QueryError: Error {
        case couldNotCreateQuery, couldNotExecuteQuery, timedOut
    }

    /// Paths of the items matching `query`. With a `timeout`, a query still running after that many seconds is stopped
    /// and `QueryError.timedOut` is thrown, as the original does for its bounded Spotlight sessions.
    public static func paths(matching query: String, scope: Scope, limit: Int, timeout: TimeInterval? = nil) throws -> [String] {
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil) else { throw QueryError.couldNotCreateQuery }
        try execute(mdQuery, scope: scope, limit: limit, timeout: timeout)
        let count = MDQueryGetResultCount(mdQuery)
        var result: [String] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String { result.append(path) }
        }
        return result
    }

    private static let stopQueue = DispatchQueue(label: "com.kbwumin13.dirdesk.spotlight.stop")

    private static func execute(_ mdQuery: MDQuery, scope: Scope, limit: Int, timeout: TimeInterval?) throws {
        let scopes: [Any] = switch scope {
        case .home: [kMDQueryScopeHome as Any]
        case .computer: [kMDQueryScopeComputer as Any]
        case .folders(let urls): urls.map { $0.path }
        }
        MDQuerySetSearchScope(mdQuery, scopes as CFArray, 0)
        MDQuerySetMaxCount(mdQuery, limit)
        final class Flag: @unchecked Sendable { var value = false }
        let timedOut = Flag()
        let stop = DispatchWorkItem { [mdQuery] in
            timedOut.value = true
            MDQueryStop(mdQuery)
        }
        if let timeout { stopQueue.asyncAfter(deadline: .now() + timeout, execute: stop) }
        let executed = MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue))
        let didTimeOut = stopQueue.sync {
            stop.cancel()
            return timedOut.value
        }
        if didTimeOut { throw QueryError.timedOut }
        guard executed else { throw QueryError.couldNotExecuteQuery }
    }

    /// Escapes a value for use inside a double-quoted Spotlight query string.
    public static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Escapes a value for an exact (non-wildcard) match: backslash, quote, `*` and `?`.
    public static func literal(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
    }

    /// Files and folders the user opened within the interval (macOS Last Used dates), excluding apps.
    public static func recentlyUsed(in interval: DateInterval, limit: Int = 2000) throws -> [String] {
        let start = Int(interval.start.timeIntervalSinceNow)
        let end = Int(interval.end.timeIntervalSinceNow)
        let query = "kMDItemLastUsedDate >= $time.now(\(start)) && kMDItemLastUsedDate <= $time.now(\(max(end, 0) + 60))"
            + " && kMDItemContentTypeTree != \"com.apple.application\""
        return try paths(matching: query, scope: .home, limit: limit)
    }

    /// Query for items carrying the tag: the exact name (case- and diacritic-insensitive) or the name stored with a
    /// color suffix; a color tag also matches the legacy Finder label number, like the original's fallback.
    public static func tagQuery(name: String, legacyLabel: Int?) -> String {
        let value = literal(name)
        let names = "kMDItemUserTags == \"\(value)\"cd || kMDItemUserTags == \"\(value)\\n*\"cd"
        if let legacyLabel, (1...7).contains(legacyLabel) {
            return "(kMDItemFSLabel == \(legacyLabel) || \(names))"
        }
        return "(\(names))"
    }

    /// Items carrying a Finder tag with this name.
    public static func tagged(_ name: String, legacyLabel: Int? = nil, limit: Int = 5000, timeout: TimeInterval? = 10) throws -> [String] {
        try paths(matching: tagQuery(name: name, legacyLabel: legacyLabel), scope: .computer, limit: limit, timeout: timeout)
    }

    /// Names of the Finder tags in use on this Mac with how many items carry each, from one bounded Spotlight query
    /// (the original allows 4 seconds and 20,000 items).
    public static func tagsInUse(limit: Int = 20_000, timeout: TimeInterval = 4) throws -> [String: Int] {
        let attribute = "kMDItemUserTags" as CFString
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, "kMDItemUserTags == \"*\"" as CFString, [attribute] as CFArray, nil) else {
            throw QueryError.couldNotCreateQuery
        }
        try execute(mdQuery, scope: .computer, limit: limit, timeout: timeout)
        var result: [String: Int] = [:]
        for value in (MDQueryCopyValuesOfAttribute(mdQuery, attribute) as? [Any]) ?? [] {
            guard let name = value as? String else { continue }
            // Tags stored with a color suffix ("Name\n6") are counted under the bare name.
            let bare = name.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
            guard !bare.isEmpty else { continue }
            result[bare, default: 0] += MDQueryGetCountOfResultsWithAttributeValue(mdQuery, attribute, value as CFTypeRef)
        }
        return result
    }
}
