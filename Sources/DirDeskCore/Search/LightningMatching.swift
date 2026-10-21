import Darwin
import Foundation

/// Name normalization: case-insensitive matching compares NFC + lowercase UTF-8, case-sensitive
/// matching compares NFC UTF-8 (on-disk names are often decomposed).
enum LightningText {
    static func fold(_ name: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        if name.allSatisfy({ $0 < 0x80 }) {
            return name.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }
        }
        return fold(string: String(decoding: name, as: UTF8.self))
    }

    static func fold(string: String) -> [UInt8] {
        Array(string.precomposedStringWithCanonicalMapping.lowercased().utf8)
    }

    static func normalize(string: String) -> [UInt8] {
        Array(string.precomposedStringWithCanonicalMapping.utf8)
    }

    static func normalize(_ name: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        normalize(string: String(decoding: name, as: UTF8.self))
    }

    /// ASCII-only case folding, used for file contents.
    @inline(__always)
    static func asciiLower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }
}

enum LightningBytes {
    @inline(__always)
    static func contains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: UnsafeBufferPointer<UInt8>) -> Bool {
        let count = needle.count
        if count == 0 { return true }
        guard count <= haystack.count, let base = haystack.baseAddress, let pattern = needle.baseAddress else { return false }
        if count == 1 { return memchr(base, Int32(pattern[0]), haystack.count) != nil }
        return memmem(base, haystack.count, pattern, count) != nil
    }

    @inline(__always)
    static func hasPrefix(_ text: UnsafeBufferPointer<UInt8>, _ prefix: UnsafeBufferPointer<UInt8>) -> Bool {
        guard prefix.count <= text.count else { return false }
        if prefix.isEmpty { return true }
        return memcmp(text.baseAddress!, prefix.baseAddress!, prefix.count) == 0
    }

    @inline(__always)
    static func hasSuffix(_ text: UnsafeBufferPointer<UInt8>, _ suffix: UnsafeBufferPointer<UInt8>) -> Bool {
        guard suffix.count <= text.count else { return false }
        if suffix.isEmpty { return true }
        return memcmp(text.baseAddress! + (text.count - suffix.count), suffix.baseAddress!, suffix.count) == 0
    }

    @inline(__always)
    static func equal(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0
    }

    /// Byte-wise ordering of two names: shorter prefix first.
    @inline(__always)
    static func compare(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
        let shared = min(a.count, b.count)
        if shared > 0 {
            let order = memcmp(a.baseAddress!, b.baseAddress!, shared)
            if order != 0 { return Int(order) }
        }
        return a.count - b.count
    }

    /// Glob match of a whole name: `*` matches any run of characters, `?` exactly one character.
    /// Works on UTF-8; `?` consumes a whole scalar.
    static func glob(_ pattern: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>) -> Bool {
        var p = 0, t = 0
        var starPattern = -1, starText = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == 0x3F {
                p += 1
                t = nextScalar(text, t)
            } else if p < pattern.count, pattern[p] == 0x2A {
                starPattern = p
                starText = t
                p += 1
            } else if p < pattern.count, pattern[p] == text[t] {
                p += 1
                t += 1
            } else if starPattern >= 0 {
                p = starPattern + 1
                starText = nextScalar(text, starText)
                t = starText
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == 0x2A { p += 1 }
        return p == pattern.count
    }

    @inline(__always)
    private static func nextScalar(_ text: UnsafeBufferPointer<UInt8>, _ index: Int) -> Int {
        var next = index + 1
        while next < text.count, text[next] & 0xC0 == 0x80 { next += 1 }
        return next
    }
}

/// Matches one name (or one path component) against a prepared pattern.
struct LightningNameMatcher {
    enum Mode: Equatable {
        case substring, prefix, suffix, exact, glob
    }

    let mode: Mode
    /// Folded bytes when case-insensitive, NFC bytes when case-sensitive.
    let pattern: [UInt8]
    let caseSensitive: Bool

    init(text: String, mode: Mode, caseSensitive: Bool) {
        self.mode = mode
        self.caseSensitive = caseSensitive
        pattern = caseSensitive ? LightningText.normalize(string: text) : LightningText.fold(string: text)
    }

    private init(mode: Mode, pattern: [UInt8], caseSensitive: Bool) {
        self.mode = mode
        self.pattern = pattern
        self.caseSensitive = caseSensitive
    }

    /// A copy with its own pattern buffer (see `LightningPlanNode.copy()`).
    func copy() -> LightningNameMatcher {
        LightningNameMatcher(mode: mode, pattern: pattern.map { $0 }, caseSensitive: caseSensitive)
    }

    @inline(__always)
    func matches(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        pattern.withUnsafeBufferPointer { pattern in
            switch mode {
            case .substring: return LightningBytes.contains(name, pattern)
            case .prefix: return LightningBytes.hasPrefix(name, pattern)
            case .suffix: return LightningBytes.hasSuffix(name, pattern)
            case .exact: return LightningBytes.equal(name, pattern)
            case .glob: return LightningBytes.glob(pattern, name)
            }
        }
    }

    /// Matches entry `index` of `view`, choosing the folded or NFC form of its name.
    @inline(__always)
    func matches(entry index: Int, in view: LightningStorageView) -> Bool {
        if !caseSensitive { return matches(view.folded(index)) }
        if view.flags[index] & LightningEntryFlag.ascii != 0 { return matches(view.raw(index)) }
        let normalized = LightningText.normalize(view.raw(index))
        return normalized.withUnsafeBufferPointer { matches($0) }
    }
}

/// A search term containing `/`, matched against the chain of path components that ends at the item.
///
/// Each segment's slashes decide how it matches a component: slashes on both sides need the whole
/// name, a trailing slash only a suffix, a leading slash only a prefix; a segment with wildcards must
/// match the whole name. A `**` segment spans any number of folders (at least one at the end of the
/// term, so `photos/**` lists descendants). Matching is not anchored at the volume root.
struct LightningPathPattern {
    enum Segment {
        case component(LightningNameMatcher)
        case globstar
    }

    let segments: [Segment]

    private init(segments: [Segment]) {
        self.segments = segments
    }

    func copy() -> LightningPathPattern {
        LightningPathPattern(segments: segments.map { segment in
            switch segment {
            case let .component(matcher): .component(matcher.copy())
            case .globstar: .globstar
            }
        })
    }

    init?(term: String, caseSensitive: Bool) {
        let parts = term.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var segments: [Segment] = []
        for (index, part) in parts.enumerated() where !part.isEmpty {
            if part == "**" {
                if case .globstar? = segments.last { continue }
                segments.append(.globstar)
                continue
            }
            let left = index > 0, right = index < parts.count - 1
            let mode: LightningNameMatcher.Mode
            if part.contains("*") || part.contains("?") {
                mode = .glob
            } else if left && right {
                mode = .exact
            } else if left {
                mode = .prefix
            } else if right {
                mode = .suffix
            } else {
                mode = .substring
            }
            segments.append(.component(LightningNameMatcher(text: part, mode: mode, caseSensitive: caseSensitive)))
        }
        guard !segments.isEmpty else { return nil }
        self.segments = segments
    }

    func matches(entry index: Int, in view: LightningStorageView) -> Bool {
        let last = segments.count - 1
        if case .globstar = segments[last] {
            // The trailing `**` consumes the item itself and possibly more folders above it.
            let parent = Int(view.parent[index])
            return parent >= 0 && match(last, parent, view)
        }
        return match(last, index, view)
    }

    /// Whether `segments[0...segment]` match a consecutive chain of components ending at `node`.
    private func match(_ segment: Int, _ node: Int, _ view: LightningStorageView) -> Bool {
        if segment < 0 { return true }
        switch segments[segment] {
        case .globstar:
            if match(segment - 1, node, view) { return true }
            guard node >= 0 else { return false }
            return match(segment, Int(view.parent[node]), view)
        case let .component(matcher):
            guard node >= 0, matcher.matches(entry: node, in: view) else { return false }
            return match(segment - 1, Int(view.parent[node]), view)
        }
    }
}
