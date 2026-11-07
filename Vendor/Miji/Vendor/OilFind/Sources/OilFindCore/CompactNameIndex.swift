import Foundation
import CryptoKit
import COilFind

/// Miji-specific streaming builder over Oil Find's matching and pinyin core.
/// Publish only after building; concurrent readers must not append.
/// Names restored from a mappable cache stay in the file mapping; names appended
/// afterwards live in ordinary memory, and searches visit both runs.
public final class CompactNameIndex {
    public struct Term {
        public let value: String
        public let excluded: Bool
        public init(value: String, excluded: Bool) { self.value = value; self.excluded = excluded }
    }
    public enum BuildError: Error { case capacityExceeded, invalidSerializedData }
    private struct Column {
        // The mapped run: `mappedOffsets` holds one more entry than it has names.
        var mappedBytes = UnsafeMutableBufferPointer<UInt8>(start: nil, count: 0)
        var mappedOffsets = UnsafeMutableBufferPointer<UInt32>(start: nil, count: 0)
        // Keep a valid base address even for an empty index/alternate column.
        var bytes: [UInt8] = [0]
        var offsets: [UInt32] = [1]
        var mappedCount: Int { max(mappedOffsets.count - 1, 0) }
        var count: Int { mappedCount + offsets.count - 1 }
        var byteCount: Int { mappedBytes.count + bytes.count }
        mutating func append(_ key: [UInt8]) throws {
            guard bytes.count <= Int(UInt32.max) - key.count else { throw BuildError.capacityExceeded }
            bytes.append(contentsOf: key)
            offsets.append(UInt32(bytes.count))
        }
        func entryLength(_ index: Int) -> Int {
            if index < mappedCount { return Int(mappedOffsets[index + 1] - mappedOffsets[index]) }
            let local = index - mappedCount
            return Int(offsets[local + 1] - offsets[local])
        }
        func withEntry<R>(_ index: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
            if index < mappedCount {
                let start = Int(mappedOffsets[index]), end = Int(mappedOffsets[index + 1])
                return try body(UnsafeBufferPointer(rebasing: UnsafeBufferPointer(mappedBytes)[start..<end]))
            }
            let local = index - mappedCount
            let start = Int(offsets[local]), end = Int(offsets[local + 1])
            return try bytes.withUnsafeBufferPointer { try body(UnsafeBufferPointer(rebasing: $0[start..<end])) }
        }
        /// One contiguous column in the stand-alone layout: the mapped run, then the
        /// in-memory names with their offsets moved past the mapped bytes.
        func write(bytesTo writer: CacheFileWriter) throws {
            if mappedBytes.isEmpty { try bytes.withUnsafeBufferPointer { try writer.write($0) }; return }
            try writer.write(UnsafeBufferPointer(mappedBytes))
            try bytes.withUnsafeBufferPointer { try writer.write(UnsafeBufferPointer(rebasing: $0.dropFirst())) }
        }
        func write(offsetsTo writer: CacheFileWriter) throws {
            if mappedOffsets.isEmpty { try offsets.withUnsafeBufferPointer { try writer.write($0) }; return }
            try writer.write(UnsafeBufferPointer(mappedOffsets))
            let shift = UInt32(mappedBytes.count - 1)
            var chunk: [UInt32] = []
            chunk.reserveCapacity(min(offsets.count, 65_536))
            for offset in offsets.dropFirst() {
                chunk.append(offset + shift)
                if chunk.count == 65_536 { try chunk.withUnsafeBufferPointer { try writer.write($0) }; chunk.removeAll(keepingCapacity: true) }
            }
            try chunk.withUnsafeBufferPointer { try writer.write($0) }
        }
        /// The serialized v1 layout: merged bytes and offsets.
        func merged() -> (bytes: [UInt8], offsets: [UInt32]) {
            if mappedOffsets.isEmpty { return (bytes, offsets) }
            let shift = UInt32(mappedBytes.count - 1)
            return (Array(mappedBytes) + bytes.dropFirst(), Array(mappedOffsets) + offsets.dropFirst().map { $0 + shift })
        }
    }
    private var names = Column(), full = Column(), initials = Column()
    private var live = SegmentedArray<UInt8>()
    private var aliases = SegmentedArray<UInt8>()
    private var fullKey: [UInt8] = [], initialKey: [UInt8] = []
    public var count: Int { names.count }
    public init() {}

    /// Array element bytes, including reusable builder scratch; excludes object
    /// headers, allocator overhead and temporary query/serialization buffers.
    public var storageBytes: Int {
        let columns = [names, full, initials]
        let bytes: Int = columns.reduce(0) { $0 + $1.byteCount }
        let offsets: Int = columns.reduce(0) { $0 + $1.mappedOffsets.count + $1.offsets.count }
        let flags: Int = live.count + aliases.count
        return bytes + offsets * MemoryLayout<UInt32>.stride + flags + fullKey.count + initialKey.count
    }
    public var allocatedStorageBytes: Int {
        let columns = [names, full, initials]
        let bytes: Int = columns.reduce(0) { $0 + $1.mappedBytes.count + $1.bytes.capacity }
        let offsets: Int = columns.reduce(0) { $0 + $1.mappedOffsets.count + $1.offsets.capacity }
        let flags: Int = live.capacity + aliases.capacity
        return bytes + offsets * MemoryLayout<UInt32>.stride + flags + fullKey.capacity + initialKey.capacity
    }

    /// Stable FNV-1a over the stored normalized UTF-8, including embedded NUL.
    /// Equality must still be checked when hashes collide.
    public func normalizedNameHash(_ index: UInt32) -> UInt64 {
        names.withEntry(Int(index)) { Self.hashNameBytes($0) }
    }
    static func hashNameBytes<Bytes: Sequence>(_ bytes: Bytes) -> UInt64 where Bytes.Element == UInt8 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return hash
    }

    /// Stable v1, little-endian: magic/version/count, then three columns
    /// (byteCount/bytes/count+1 offsets), live/aliases, and SHA-256 of all prior
    /// bytes. No Swift object layout or metadata is persisted.
    public func serialized() -> Data {
        let columns = [names.merged(), full.merged(), initials.merged()]
        var data = Data()
        data.reserveCapacity(72 + columns.reduce(0) { $0 + $1.bytes.count } + count * 14)
        data.append(contentsOf: "MIJINAME".utf8)
        func word(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(1); word(UInt32(count))
        for column in columns {
            word(UInt32(column.bytes.count))
            data.append(contentsOf: column.bytes)
            for offset in column.offsets { word(offset) }
        }
        live.forEachSegment { _, run in data.append(contentsOf: run) }
        aliases.forEachSegment { _, run in data.append(contentsOf: run) }
        data.append(contentsOf: SHA256.hash(data: data))
        return data
    }

    /// Reject corrupt/incompatible caches. The owner decides when to rebuild.
    public convenience init(serialized data: Data) throws {
        self.init()
        guard data.count >= 75,
              SHA256.hash(data: data.dropLast(32)).elementsEqual(data.suffix(32)) else {
            throw BuildError.invalidSerializedData
        }
        try data.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            let end = bytes.count - 32
            guard bytes.prefix(8).elementsEqual("MIJINAME".utf8) else { throw BuildError.invalidSerializedData }
            var position = 8
            func word() throws -> UInt32 {
                guard position <= end - 4 else { throw BuildError.invalidSerializedData }
                defer { position += 4 }
                return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
                    | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
            }
            guard try word() == 1 else { throw BuildError.invalidSerializedData }
            let rows = Int(try word())
            // Check the minimum size before allocating anything proportional to
            // an untrusted count. Every column includes its sentinel byte.
            guard rows <= (end - 43) / 14 else { throw BuildError.invalidSerializedData }
            func column() throws -> Column {
                let length = Int(try word())
                guard length >= 1, length <= end - position,
                      (rows + 1) <= (end - position - length) / 4 else { throw BuildError.invalidSerializedData }
                let contents = Array(bytes[position..<(position + length)])
                position += length
                var offsets: [UInt32] = []
                offsets.reserveCapacity(rows + 1)
                for _ in 0...rows { offsets.append(try word()) }
                var column = Column()
                column.bytes = contents; column.offsets = offsets
                return column
            }
            let names = try column(), full = try column(), initials = try column()
            guard end - position == rows * 2 else { throw BuildError.invalidSerializedData }
            let live = Array(bytes[position..<(position + rows)])
            position += rows
            let aliases = Array(bytes[position..<end])
            try Self.validate(names: names, full: full, initials: initials, live: live, aliases: aliases, rows: rows)
            self.names = names; self.full = full; self.initials = initials
            self.live = SegmentedArray(live); self.aliases = SegmentedArray(aliases)
        }
    }

    /// Restores names from `CacheFileWriter` sections written by `write(to:prefix:)`.
    /// The bytes stay in the mapping; the same structural checks as `init(serialized:)` apply.
    public convenience init(mapped sections: MappedSections, prefix: String, count rows: Int) throws {
        self.init()
        guard rows >= 0, rows < Int(UInt32.max) else { throw BuildError.invalidSerializedData }
        func column(_ name: String) throws -> Column {
            var column = Column()
            column.mappedBytes = try sections.buffer(prefix + name + ".bytes", as: UInt8.self)
            column.mappedOffsets = try sections.buffer(prefix + name + ".offsets", as: UInt32.self, count: rows + 1)
            column.bytes = [0]; column.offsets = [1]
            return column
        }
        let names = try column("names"), full = try column("full"), initials = try column("initials")
        let live = try sections.buffer(prefix + "live", as: UInt8.self, count: rows)
        let aliases = try sections.buffer(prefix + "aliases", as: UInt8.self, count: rows)
        try Self.validate(names: names, full: full, initials: initials, live: UnsafeBufferPointer(live), aliases: UnsafeBufferPointer(aliases), rows: rows)
        self.names = names; self.full = full; self.initials = initials
        self.live = SegmentedArray(mapped: live, owner: sections.file)
        self.aliases = SegmentedArray(mapped: aliases, owner: sections.file)
    }

    /// Writes this index as mappable sections named with `prefix`.
    public func write(to writer: CacheFileWriter, prefix: String) throws {
        for (name, column) in [("names", names), ("full", full), ("initials", initials)] {
            try writer.section(prefix + name + ".bytes") { try column.write(bytesTo: writer) }
            try writer.section(prefix + name + ".offsets") { try column.write(offsetsTo: writer) }
        }
        try writer.section(prefix + "live") { try live.write(to: writer) }
        try writer.section(prefix + "aliases") { try aliases.write(to: writer) }
    }

    /// Bounds every offset and alias flag the matcher relies on. Columns hold either
    /// only the in-memory run or only the mapped run here.
    private static func validate<Flags: Collection>(names: Column, full: Column, initials: Column, live: Flags, aliases: Flags, rows: Int) throws
        where Flags.Element == UInt8, Flags.Index == Int {
        func check(_ column: Column) throws {
            func walk(_ bytes: UnsafeBufferPointer<UInt8>, _ offsets: UnsafeBufferPointer<UInt32>) throws {
                guard bytes.count >= 1, bytes[0] == 0, offsets.count == rows + 1, offsets[0] == 1 else { throw BuildError.invalidSerializedData }
                var previous: UInt32 = 1
                for offset in offsets {
                    guard offset >= previous else { throw BuildError.invalidSerializedData }
                    previous = offset
                }
                guard Int(previous) == bytes.count else { throw BuildError.invalidSerializedData }
            }
            if column.mappedOffsets.isEmpty {
                try column.bytes.withUnsafeBufferPointer { b in try column.offsets.withUnsafeBufferPointer { try walk(b, $0) } }
            } else {
                try walk(UnsafeBufferPointer(column.mappedBytes), UnsafeBufferPointer(column.mappedOffsets))
            }
        }
        try check(names); try check(full); try check(initials)
        guard live.count == rows, aliases.count == rows else { throw BuildError.invalidSerializedData }
        for i in 0..<rows {
            let flag = aliases[aliases.startIndex + i]
            guard live[live.startIndex + i] <= 1, flag & ~31 == 0,
                  flag & 18 != 18, flag & 12 != 12,
                  flag & 16 == 0 || flag & 1 != 0,
                  flag & 18 == 0 || full.entryLength(i) == 0,
                  flag & 12 == 0 || initials.entryLength(i) == 0 else {
                throw BuildError.invalidSerializedData
            }
            if flag & 1 != 0 {
                guard names.withEntry(i, { $0.allSatisfy { $0 < 128 } }) else { throw BuildError.invalidSerializedData }
                for key in [full, initials] {
                    guard key.withEntry(i, { $0.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) } }) else {
                        throw BuildError.invalidSerializedData
                    }
                }
            }
        }
    }

    public func remove(_ index: UInt32) { live[Int(index)] = 0 }
    public func nameEquals(_ index: UInt32, _ normalized: String) -> Bool {
        names.withEntry(Int(index)) { $0.elementsEqual(normalized.utf8) }
    }

    /// Names must already use Miji's NFC + lowercase normalization.
    public func append(_ name: String) throws {
        guard count < Int(UInt32.max) else { throw BuildError.capacityExceeded }
        let raw = Array(name.utf8)
        if raw.allSatisfy({ $0 < 128 }) {
            // Derive once, rather than walking every ASCII name twice per query.
            fullKey.removeAll(keepingCapacity: true)
            initialKey.removeAll(keepingCapacity: true)
            var wordStart = true
            for byte in raw {
                let word = (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                if word {
                    fullKey.append(byte)
                    if wordStart { initialKey.append(byte) }
                }
                wordStart = !word
            }
            try append(raw, ascii: true)
            return
        }
        let hasHan = raw.withUnsafeBufferPointer { Pinyin.shared.keys(for: $0, full: &fullKey, initials: &initialKey, wordInitials: true) }
        if !hasHan {
            // Also preserve Miji's Latin filename abbreviations (e.g. rnt).
            let latin = (name.applyingTransform(.toLatin, reverse: false) ?? name).applyingTransform(.stripDiacritics, reverse: false) ?? name
            let words = latin.lowercased().split { !$0.isLetter && !$0.isNumber }
            fullKey = Array(words.joined().utf8)
            initialKey = Array(String(words.compactMap(\.first)).utf8)
        } else {
            // Oil Find retains punctuation; Miji historically joins words.
            fullKey = Array(String(decoding: fullKey, as: UTF8.self).filter { $0.isLetter || $0.isNumber }.utf8)
            initialKey = Array(String(decoding: initialKey, as: UTF8.self).filter { $0.isLetter || $0.isNumber }.utf8)
            // Preserve both Oil Find's character readings and Miji's contextual
            // CFString readings (重庆: zhongqing / chongqing). Only distinct keys
            // consume extra bytes. 0xff cannot occur in a valid UTF-8 query, so
            // a literal can never accidentally span two alternative keys.
            let latin = (name.applyingTransform(.toLatin, reverse: false) ?? name)
                .applyingTransform(.stripDiacritics, reverse: false) ?? name
            let words = latin.lowercased().split { !$0.isLetter && !$0.isNumber }
            let contextualFull = Array(words.joined().utf8)
            let contextualInitials = Array(String(words.compactMap(\.first)).utf8)
            if !contextualFull.isEmpty, contextualFull != fullKey {
                fullKey.append(0xff); fullKey.append(contentsOf: contextualFull)
            }
            if !contextualInitials.isEmpty, contextualInitials != initialKey {
                initialKey.append(0xff); initialKey.append(contentsOf: contextualInitials)
            }
        }
        try append(raw, ascii: false)
    }

    private func append(_ raw: [UInt8], ascii: Bool) throws {
        try names.append(raw)
        var alias: UInt8 = ascii ? 1 : 0
        if fullKey == raw { alias |= 2 }
        if initialKey == raw { alias |= 4 }
        else if initialKey == fullKey { alias |= 8 }
        // For an ASCII alphanumeric needle, one word has exactly the same
        // matches in the name and full key, even with surrounding punctuation.
        if ascii && initialKey.count == 1 { alias |= 2 }
        // Long ASCII full keys would duplicate most of the largest name column.
        // Store short keys; verify long ones in-place only after literal misses.
        if ascii && alias & 2 == 0 && fullKey.count > 8 { alias |= 16 }
        try full.append(alias & 18 != 0 ? [] : fullKey)
        try initials.append(alias & 12 != 0 ? [] : initialKey)
        live.append(1)
        aliases.append(alias)
    }

    @inline(__always)
    public func compareNames(_ lhs: UInt32, _ rhs: UInt32) -> Int {
        // SQLite BINARY ordering of normalized UTF-8, including embedded NUL.
        names.withEntry(Int(lhs)) { a in
            names.withEntry(Int(rhs)) { b in
                let common = min(a.count, b.count)
                let order = common == 0 ? 0 : memcmp(a.baseAddress!, b.baseAddress!, common)
                return order == 0 ? a.count - b.count : Int(order)
            }
        }
    }

    /// Bounded scratch (256 KiB), synchronous scan, serial callbacks in row order.
    public func forEachMatch(_ terms: [Term], cancelled: () -> Bool,
                             _ body: (UInt32, Int32) throws -> Void) throws {
        let needleBytes: [UInt8] = terms.flatMap { Array($0.value.utf8) } + [UInt8(0)]
        try needleBytes.withUnsafeBufferPointer { needles in
            var position = 0
            let compiled = terms.map { term -> MijiNameTerm in
                let length = term.value.utf8.count
                defer { position += length }
                let asciiKey = term.value.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) }
                return MijiNameTerm(needle: needles.baseAddress!.advanced(by: position), length: length, excluded: term.excluded ? 1 : 0, ascii_key: asciiKey ? 1 : 0)
            }
            let batch = count >= 32768 ? 32768 : 4096
            var ids = [UInt32](repeating: 0, count: batch)
            var scores = [Int32](repeating: 0, count: batch)
            try compiled.withUnsafeBufferPointer { terms in
                // One contiguous run of every column; `base` is the run's first name.
                func scan(base: Int, rows: Int,
                          _ names: UnsafePointer<UInt8>, _ nameOff: UnsafePointer<UInt32>,
                          _ full: UnsafePointer<UInt8>, _ fullOff: UnsafePointer<UInt32>,
                          _ initials: UnsafePointer<UInt8>, _ initialOff: UnsafePointer<UInt32>,
                          _ live: UnsafePointer<UInt8>, _ aliases: UnsafePointer<UInt8>) throws {
                    for first in stride(from: 0, to: rows, by: batch) {
                        if cancelled() { throw CancellationError() }
                        let n = miji_match_names_batch(names, nameOff, full, fullOff, initials, initialOff, live, aliases,
                                                       UInt32(first), UInt32(min(first + batch, rows)),
                                                       terms.baseAddress, terms.count, &ids, &scores)
                        for j in 0..<n {
                            if j % 4096 == 0, cancelled() { throw CancellationError() }
                            try body(UInt32(base) + ids[j], scores[j])
                        }
                    }
                }
                let mappedRows = names.mappedCount
                if mappedRows > 0 {
                    try scan(base: 0, rows: mappedRows,
                             names.mappedBytes.baseAddress!, names.mappedOffsets.baseAddress!,
                             full.mappedBytes.baseAddress!, full.mappedOffsets.baseAddress!,
                             initials.mappedBytes.baseAddress!, initials.mappedOffsets.baseAddress!,
                             live.mapped.baseAddress!, aliases.mapped.baseAddress!)
                }
                let tailRows = count - mappedRows
                guard tailRows > 0 else { return }
                try self.names.bytes.withUnsafeBufferPointer { names in
                    try self.names.offsets.withUnsafeBufferPointer { nameOff in
                        try self.full.bytes.withUnsafeBufferPointer { full in
                            try self.full.offsets.withUnsafeBufferPointer { fullOff in
                                try self.initials.bytes.withUnsafeBufferPointer { initials in
                                    try self.initials.offsets.withUnsafeBufferPointer { initialOff in
                                        try self.live.tail.withUnsafeBufferPointer { live in
                                            try self.aliases.tail.withUnsafeBufferPointer { aliases in
                                                try scan(base: mappedRows, rows: tailRows,
                                                         names.baseAddress!, nameOff.baseAddress!, full.baseAddress!, fullOff.baseAddress!,
                                                         initials.baseAddress!, initialOff.baseAddress!, live.baseAddress!, aliases.baseAddress!)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if cancelled() { throw CancellationError() }
    }
}
