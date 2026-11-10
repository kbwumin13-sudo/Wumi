import Foundation

/// Bounded evidence, not term frequency. Exact matching remains SearchDatabase's job.
enum ContentRelevanceScorer {
    /// 3: focused opening, 2: nearby terms, 1: scattered/late mention, 0: no body evidence.
    static func strength(text: String, positive: [String], bodyMatches: [Bool]) -> Int {
        guard !positive.isEmpty, bodyMatches.contains(true) else { return 0 }
        guard bodyMatches.allSatisfy({ $0 }) else { return 1 }
        // Matching has already validated the entire body. Rank a fixed byte window,
        // avoiding a second whole-body normalization, grapheme walk or frequency count.
        let simple = positive.allSatisfy { term in term.unicodeScalars.allSatisfy {
            $0.isASCII || (0x3400...0x9fff).contains($0.value)
        } }
        var bytes: [UInt8]
        if simple {
            bytes = Array(text.utf8.prefix(4_096))
            for i in bytes.indices where bytes[i] >= 65 && bytes[i] <= 90 { bytes[i] += 32 }
        } else {
            bytes = Array(QueryParser.normalize(String(decoding: text.utf8.prefix(512), as: UTF8.self)).utf8)
        }
        return bytes.withUnsafeBufferPointer { source in
            func offset(_ term: String) -> (Int, Int)? {
                var term = term
                return term.withUTF8 { key -> (Int, Int)? in
                    guard !key.isEmpty, let base = source.baseAddress, let needle = key.baseAddress,
                          let found = memmem(base, source.count, needle, key.count) else { return nil }
                    let start = Int(bitPattern: found) - Int(bitPattern: base)
                    return (start, start + key.count)
                }
            }
            let ranges = positive.compactMap(offset)
            guard ranges.count == positive.count else { return 1 }
            let span = ranges.map(\.1).max()! - ranges.map(\.0).min()!
            let early = ranges.map(\.1).max()! <= 512
            if early && (span <= 240 || offset(positive.joined(separator: " ")) != nil) { return 3 }
            if positive.count > 1 && span <= 240 { return 2 }
            return 1
        }
    }
}
