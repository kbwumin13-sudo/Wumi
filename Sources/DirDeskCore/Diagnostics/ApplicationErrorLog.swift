import Foundation

/// In-memory log of the errors shown during this app session (at most 512, oldest replaced first).
/// Entries keep the error domain, code and a redacted summary: quoted names and paths are replaced, so
/// file names, paths and contents never enter the log or its export.
public final class ApplicationErrorLog: @unchecked Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        case fileOperation, directory, search, fileTransit, settings, diagnostics
    }

    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var date: Date
        public var source: Source
        public var domain: String
        public var code: Int
        public var summary: String
        /// Short reference shown next to the entry ("E3F2A1B0").
        public var reference: String
    }

    public struct Report: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var appVersion: String
        public var appBuild: String
        public var operatingSystem: String
        public var sessionStartedAt: Date
        public var capturedAt: Date
        public var since: Date?
        public var overwritten: Bool
        public var entries: [Entry]
    }

    public static let capacity = 512
    public static let shared = ApplicationErrorLog()
    public static let didChangeNotification = Notification.Name("DirDeskApplicationErrorLogDidChange")

    public let sessionStartedAt: Date
    private let lock = NSLock()
    private var storage: [Entry] = []
    private var replacedOlderEntries = false
    private let capacity: Int

    public init(capacity: Int = ApplicationErrorLog.capacity, sessionStartedAt: Date = Date()) {
        self.capacity = capacity
        self.sessionStartedAt = sessionStartedAt
    }

    /// True once older entries were dropped because the log reached its capacity.
    public var overwritten: Bool { lock.withLock { replacedOlderEntries } }

    @discardableResult
    public func record(_ error: Error, source: Source, date: Date = Date()) -> Entry {
        let nsError = error as NSError
        return record(message: nsError.localizedDescription, source: source, domain: nsError.domain, code: nsError.code, date: date)
    }

    @discardableResult
    public func record(message: String, source: Source, domain: String = "DirDesk", code: Int = 0, date: Date = Date()) -> Entry {
        let id = UUID()
        let entry = Entry(id: id, date: date, source: source, domain: domain, code: code, summary: Self.redact(message),
                          reference: String(id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)))
        lock.withLock {
            storage.append(entry)
            if storage.count > capacity {
                storage.removeFirst(storage.count - capacity)
                replacedOlderEntries = true
            }
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return entry
    }

    /// Entries at or after `since` (all when nil), newest first.
    public func entries(since: Date? = nil) -> [Entry] {
        lock.withLock { storage.filter { since == nil || $0.date >= since! }.reversed() }
    }

    public func clear() {
        lock.withLock {
            storage.removeAll()
            replacedOlderEntries = false
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    public func report(since: Date?, appVersion: String, appBuild: String, capturedAt: Date = Date()) -> Report {
        Report(schemaVersion: 1, appVersion: appVersion, appBuild: appBuild,
               operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
               sessionStartedAt: sessionStartedAt, capturedAt: capturedAt, since: since, overwritten: overwritten,
               entries: entries(since: since))
    }

    public static func encode(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    private static let quoted = try! NSRegularExpression(pattern: #"[“"「‘'][^”"」’']*[”"」’']"#)
    private static let pathLike = try! NSRegularExpression(pattern: #"(?<![\w.])(file://)?(~/|/)[^\s“”"'「」，。,;:]*[^\s“”"'「」，。,;:.]"#)

    /// Replaces quoted names and path-like tokens with placeholders.
    public static func redact(_ text: String) -> String {
        var result = text
        result = quoted.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "“…”")
        result = pathLike.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<path>")
        return String(result.prefix(400))
    }
}
