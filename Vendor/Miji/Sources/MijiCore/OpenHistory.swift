import Foundation

/// Files opened from Miji rank higher for a while. Each open adds 1 to a
/// score that halves every two weeks; a score lifts relevance by at most 30,
/// below the 30 between a literal name hit and a pinyin hit. Only file IDs
/// and times are kept, beside the index they belong to.
public final class OpenHistory: @unchecked Sendable {
    static let halfLife = 14.0 * 86_400
    /// Dropped once decayed below this (one open about eight weeks ago).
    static let floor = 0.06
    static let capacity = 4_096
    private struct Entry: Codable { var id: Int64; var score: Double; var last: Double }
    private struct Saved: Codable { var database: String; var entries: [Entry] }
    private let url: URL
    /// Identity of the index the IDs belong to: a recreated database reuses
    /// IDs for other files, so its predecessor's opens are ignored.
    private let database: String
    private let lock = NSLock()
    private var entries: [Int64: Entry] = [:]

    public init(url: URL, database: String) {
        self.url = url
        self.database = database
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.database == database {
            for entry in saved.entries where entry.score.isFinite && entry.score > 0 && entry.last.isFinite { entries[entry.id] = entry }
        }
    }

    static func decayed(_ score: Double, from last: Double, to now: Double) -> Double {
        score * exp2(-max(0, now - last) / halfLife)
    }
    static func boost(_ score: Double) -> Int32 { score > 0 ? Int32(min(30, 12 * log1p(score))) : 0 }

    public func record(_ id: Int64, now: Double = Date().timeIntervalSince1970) {
        lock.lock()
        let previous = entries[id].map { Self.decayed($0.score, from: $0.last, to: now) } ?? 0
        entries[id] = Entry(id: id, score: previous + 1, last: now)
        entries = entries.filter { Self.decayed($0.value.score, from: $0.value.last, to: now) >= Self.floor }
        if entries.count > Self.capacity {
            let kept = entries.values.sorted { Self.decayed($0.score, from: $0.last, to: now) > Self.decayed($1.score, from: $1.last, to: now) }.prefix(Self.capacity)
            entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
        }
        // Written under the lock, so a later record never loses to an earlier.
        if let data = try? JSONEncoder().encode(Saved(database: database, entries: Array(entries.values))) { try? data.write(to: url, options: .atomic) }
        lock.unlock()
    }

    /// The current lift per file ID, without the ones that decayed to nothing.
    public func boosts(now: Double = Date().timeIntervalSince1970) -> [Int64: Int32] {
        lock.lock(); defer { lock.unlock() }
        var result: [Int64: Int32] = [:]
        for entry in entries.values {
            let lift = Self.boost(Self.decayed(entry.score, from: entry.last, to: now))
            if lift > 0 { result[entry.id] = lift }
        }
        return result
    }

    func lastUses() -> [Int64: Double] {
        lock.lock(); defer { lock.unlock() }
        return entries.mapValues(\.last)
    }
}
