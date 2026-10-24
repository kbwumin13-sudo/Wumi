import Foundation

/// File IDs written or confirmed by one scan, as a bitset over SQLite's
/// AUTOINCREMENT ids. Pruning compares a scope against this set, so a scan never
/// has to rewrite unchanged rows to mark them as seen.
public final class FileIDSet {
    private var words: [UInt64] = []
    public private(set) var count = 0
    /// `largestID`, when known, sizes the set for every existing row at once.
    public init(largestID: Int64 = 0) {
        if largestID > 0 { words = [UInt64](repeating: 0, count: Int(largestID >> 6) + 1) }
    }

    public func insert(_ id: Int64) {
        guard id >= 0 else { return }
        let word = Int(id >> 6), bit = UInt64(1) << UInt64(id & 63)
        if word >= words.count {
            // New rows take the next IDs: grow by a quarter, not by doubling.
            words.append(contentsOf: repeatElement(0, count: max(word + 1 - words.count, words.count / 4)))
        }
        if words[word] & bit == 0 { words[word] |= bit; count += 1 }
    }

    public func contains(_ id: Int64) -> Bool {
        guard id >= 0 else { return false }
        let word = Int(id >> 6)
        return word < words.count && words[word] & (UInt64(1) << UInt64(id & 63)) != 0
    }
}

/// What a scan batch actually wrote. Unchanged rows cost a lookup, not a write.
public struct ScanWriteStatistics: Equatable, Sendable {
    public var inserted = 0
    public var updated = 0
    public var unchanged = 0
    public var metadataWrites = 0
    public init() {}

    public static func += (lhs: inout ScanWriteStatistics, rhs: ScanWriteStatistics) {
        lhs.inserted += rhs.inserted; lhs.updated += rhs.updated
        lhs.unchanged += rhs.unchanged; lhs.metadataWrites += rhs.metadataWrites
    }
}
