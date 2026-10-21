import Foundation

/// Per-entry flag bits of `LightningStorage.flags`.
enum LightningEntryFlag {
    static let directory: UInt8 = 1 << 0
    static let package: UInt8 = 1 << 1
    static let symlink: UInt8 = 1 << 2
    static let hidden: UInt8 = 1 << 3
    /// A folder above a watched root, kept so paths and path queries see every component. Never a result.
    static let ancestor: UInt8 = 1 << 4
    /// A watched root.
    static let root: UInt8 = 1 << 5
    /// The raw name is pure ASCII.
    static let ascii: UInt8 = 1 << 6
    /// Removed; the slot is reclaimed by the next compaction.
    static let dead: UInt8 = 1 << 7

    static let notSearchable: UInt8 = ancestor | dead
    static let persistentMask: UInt8 = directory | package | symlink | hidden | ancestor | root | ascii
}

/// Distinct lowercased extensions, so `ext:` and `type:` compare small integers instead of bytes.
struct LightningExtensionTable {
    static let none: UInt16 = 0
    /// Assigned once the table is full; such entries fall back to comparing bytes.
    static let overflow: UInt16 = .max
    static let maximumLength = 24

    /// Up to 16 extension bytes packed into integers, so lookups while indexing allocate nothing.
    private struct PackedKey: Hashable {
        var low: UInt64
        var high: UInt64
        var length: Int
    }

    private(set) var names: [[UInt8]] = [[]]
    private var ids: [[UInt8]: UInt16] = [:]
    private var packed: [PackedKey: UInt16] = [:]

    init() {}

    init(names: [[UInt8]]) {
        self.names = names.isEmpty ? [[]] : names
        for (index, name) in self.names.enumerated() where index > 0 {
            ids[name] = UInt16(index)
            if let key = Self.pack(name, 0..<name.count) { packed[key] = UInt16(index) }
        }
    }

    var count: Int { names.count }

    func lookup(_ name: [UInt8]) -> UInt16? {
        name.isEmpty ? Self.none : ids[name]
    }

    private static func pack(_ bytes: [UInt8], _ range: Range<Int>) -> PackedKey? {
        let count = range.count
        guard count <= 16 else { return nil }
        return bytes.withUnsafeBufferPointer { buffer in
            var low: UInt64 = 0, high: UInt64 = 0
            var index = range.lowerBound
            var shift: UInt64 = 0
            let split = min(range.upperBound, index + 8)
            while index < split {
                low |= UInt64(buffer[index]) << shift
                shift += 8
                index += 1
            }
            shift = 0
            while index < range.upperBound {
                high |= UInt64(buffer[index]) << shift
                shift += 8
                index += 1
            }
            return PackedKey(low: low, high: high, length: count)
        }
    }

    /// The id of the extension stored at `bytes[range]`, adding it when new.
    mutating func id(in bytes: [UInt8], range: Range<Int>) -> UInt16 {
        guard !range.isEmpty else { return Self.none }
        let key = Self.pack(bytes, range)
        if let key, let existing = packed[key] { return existing }
        let name = Array(bytes[range])
        if key == nil, let existing = ids[name] { return existing }
        guard names.count < Int(Self.overflow) else { return Self.overflow }
        let id = UInt16(names.count)
        names.append(name)
        ids[name] = id
        if let key { packed[key] = id }
        return id
    }

    mutating func id(for name: [UInt8]) -> UInt16 {
        id(in: name, range: 0..<name.count)
    }

    /// The extension of a folded name stored at `bytes[start..<start+count]`: the bytes after the last dot,
    /// unless that dot leads or ends the name. Returns absolute indices into `bytes`.
    static func extensionRange(in bytes: [UInt8], start: Int, count: Int) -> Range<Int>? {
        let end = start + count
        var index = end - 1
        while index > start {
            if bytes[index] == 0x2E {
                let length = end - index - 1
                guard length > 0, length <= maximumLength else { return nil }
                return (index + 1)..<end
            }
            index -= 1
        }
        return nil
    }

    /// Same rule on an unsafe buffer (used while matching).
    static func extensionRange(of folded: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
        var index = folded.count - 1
        while index > 0 {
            if folded[index] == 0x2E {
                let length = folded.count - index - 1
                guard length > 0, length <= maximumLength else { return nil }
                return (index + 1)..<folded.count
            }
            index -= 1
        }
        return nil
    }

    var estimatedBytes: Int { names.reduce(0) { $0 + $1.count + 64 } }
}

/// The in-memory index: one compact array per field instead of one object per entry.
///
/// Names live in one byte buffer. Each entry has its raw on-disk name and a folded (NFC + lowercase)
/// name used for case-insensitive matching; the two share bytes when they are identical. Parents
/// always precede their children (`parent[i] < i`), which keeps compaction and validation linear.
/// The value type gives searches a copy-on-write snapshot: a writer that mutates while a search holds
/// a copy pays for one array copy, the search never sees a half-applied update.
struct LightningStorage {
    /// Name bytes. Index 0 is a sentinel so the buffer always has a base address.
    var bytes: [UInt8] = [0]
    var nameOffset: [UInt32] = []
    var nameLength: [UInt16] = []
    var foldedOffset: [UInt32] = []
    var foldedLength: [UInt16] = []
    var parent: [Int32] = []
    var flags: [UInt8] = []
    /// Logical size in bytes; 0 for folders.
    var size: [Int64] = []
    /// Seconds since 1970; NaN when unknown.
    var modified: [Double] = []
    var created: [Double] = []
    var extensionID: [UInt16] = []
    // Child links, rebuilt on load rather than persisted.
    var firstChild: [Int32] = []
    var nextSibling: [Int32] = []
    var previousSibling: [Int32] = []
    var topLevel: [Int32] = []
    var extensions = LightningExtensionTable()
    /// Entries that are not dead (ancestors included).
    private(set) var liveCount = 0
    private(set) var deadCount = 0
    private(set) var ancestorCount = 0
    private(set) var garbageBytes = 0
    /// Unique per storage instance (new for every build, load and compaction); with `generation` it keys
    /// caches derived from the storage.
    private(set) var identity = LightningStorage.nextIdentity()
    /// Changes on every mutation.
    var generation: UInt64 = 0

    private static let identityLock = NSLock()
    nonisolated(unsafe) private static var lastIdentity: UInt64 = 0

    private static func nextIdentity() -> UInt64 {
        identityLock.lock()
        defer { identityLock.unlock() }
        lastIdentity += 1
        return lastIdentity
    }

    var count: Int { flags.count }

    mutating func reserveCapacity(_ entries: Int, nameBytes: Int) {
        bytes.reserveCapacity(nameBytes)
        nameOffset.reserveCapacity(entries)
        foldedOffset.reserveCapacity(entries)
        nameLength.reserveCapacity(entries)
        foldedLength.reserveCapacity(entries)
        parent.reserveCapacity(entries)
        firstChild.reserveCapacity(entries)
        nextSibling.reserveCapacity(entries)
        previousSibling.reserveCapacity(entries)
        flags.reserveCapacity(entries)
        size.reserveCapacity(entries)
        modified.reserveCapacity(entries)
        created.reserveCapacity(entries)
        extensionID.reserveCapacity(entries)
    }

    // MARK: Appending

    /// Appends an entry, folding its name and linking it under `parent`. Returns its index.
    @discardableResult
    mutating func append(name: UnsafeBufferPointer<UInt8>, parent: Int32, flags entryFlags: UInt8,
                         size entrySize: Int64, modified entryModified: Double, created entryCreated: Double) -> Int32 {
        let rawStart = bytes.count
        bytes.append(contentsOf: name)
        var isASCII = true
        var hasUpper = false
        for byte in name {
            if byte >= 0x80 { isASCII = false; break }
            if byte >= 0x41, byte <= 0x5A { hasUpper = true }
        }
        var foldedStart = rawStart
        var foldedCount = name.count
        if isASCII {
            if hasUpper {
                foldedStart = bytes.count
                for byte in name { bytes.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte) }
            }
        } else {
            let folded = LightningText.fold(name)
            if !folded.elementsEqual(name) {
                foldedStart = bytes.count
                foldedCount = min(folded.count, Int(UInt16.max))
                bytes.append(contentsOf: folded.prefix(foldedCount))
            }
        }
        var extensionID = LightningExtensionTable.none
        if let range = LightningExtensionTable.extensionRange(in: bytes, start: foldedStart, count: foldedCount) {
            extensionID = extensions.id(in: bytes, range: range)
        }
        return appendRecord(nameStart: rawStart, nameCount: name.count, foldedStart: foldedStart, foldedCount: foldedCount,
                            parent: parent, flags: (entryFlags & ~LightningEntryFlag.ascii) | (isASCII ? LightningEntryFlag.ascii : 0),
                            size: entrySize, modified: entryModified, created: entryCreated, extensionID: extensionID)
    }

    /// The folded form of a name, or nil when it equals the raw bytes, plus whether the name is ASCII.
    /// The crawler computes this on its worker threads before taking the shared lock.
    static func fold(_ name: UnsafeBufferPointer<UInt8>) -> (folded: [UInt8]?, ascii: Bool) {
        var hasUpper = false
        for byte in name {
            if byte >= 0x80 {
                let folded = LightningText.fold(name)
                return (folded.elementsEqual(name) ? nil : folded, false)
            }
            if byte >= 0x41, byte <= 0x5A { hasUpper = true }
        }
        return (hasUpper ? name.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 } : nil, true)
    }

    /// Appends an entry whose name was folded beforehand (`folded` nil = same as `name`).
    @discardableResult
    mutating func append(name: UnsafeBufferPointer<UInt8>, folded: UnsafeBufferPointer<UInt8>?, ascii: Bool, parent: Int32,
                         flags entryFlags: UInt8, size entrySize: Int64, modified entryModified: Double,
                         created entryCreated: Double) -> Int32 {
        let rawStart = bytes.count
        bytes.append(contentsOf: name)
        var foldedStart = rawStart, foldedCount = name.count
        if let folded {
            foldedStart = bytes.count
            foldedCount = min(folded.count, Int(UInt16.max))
            bytes.append(contentsOf: UnsafeBufferPointer(rebasing: folded[0..<foldedCount]))
        }
        var extensionID = LightningExtensionTable.none
        if let range = LightningExtensionTable.extensionRange(in: bytes, start: foldedStart, count: foldedCount) {
            extensionID = extensions.id(in: bytes, range: range)
        }
        return appendRecord(nameStart: rawStart, nameCount: name.count, foldedStart: foldedStart, foldedCount: foldedCount,
                            parent: parent, flags: (entryFlags & ~LightningEntryFlag.ascii) | (ascii ? LightningEntryFlag.ascii : 0),
                            size: entrySize, modified: entryModified, created: entryCreated, extensionID: extensionID)
    }

    @discardableResult
    mutating func append(name: String, parent: Int32, flags entryFlags: UInt8, size: Int64 = 0,
                         modified: Double = .nan, created: Double = .nan) -> Int32 {
        var name = name
        return name.withUTF8 { append(name: $0, parent: parent, flags: entryFlags, size: size, modified: modified, created: created) }
    }

    /// Copies entry `index` of `other` (already folded) under `parent`. `extensionMap` translates
    /// `other`'s extension ids into this table.
    @discardableResult
    mutating func appendCopy(of index: Int, from other: LightningStorage, parent: Int32, extensionMap: [UInt16]) -> Int32 {
        let rawStart = bytes.count
        let rawOffset = Int(other.nameOffset[index]), rawCount = Int(other.nameLength[index])
        bytes.append(contentsOf: other.bytes[rawOffset..<(rawOffset + rawCount)])
        var foldedStart = rawStart
        let foldedOffset = Int(other.foldedOffset[index]), foldedCount = Int(other.foldedLength[index])
        if foldedOffset != rawOffset || foldedCount != rawCount {
            foldedStart = bytes.count
            bytes.append(contentsOf: other.bytes[foldedOffset..<(foldedOffset + foldedCount)])
        }
        let sourceID = other.extensionID[index]
        let mapped = sourceID == LightningExtensionTable.overflow || Int(sourceID) >= extensionMap.count
            ? LightningExtensionTable.overflow : extensionMap[Int(sourceID)]
        return appendRecord(nameStart: rawStart, nameCount: rawCount, foldedStart: foldedStart, foldedCount: foldedCount,
                            parent: parent, flags: other.flags[index] & ~LightningEntryFlag.dead,
                            size: other.size[index], modified: other.modified[index], created: other.created[index],
                            extensionID: mapped)
    }

    /// Maps `other`'s extension ids to ids of this table, adding missing extensions.
    mutating func extensionMap(from other: LightningStorage) -> [UInt16] {
        other.extensions.names.map { name in
            name.isEmpty ? LightningExtensionTable.none : extensions.id(for: name)
        }
    }

    private mutating func appendRecord(nameStart: Int, nameCount: Int, foldedStart: Int, foldedCount: Int, parent entryParent: Int32,
                                       flags entryFlags: UInt8, size entrySize: Int64, modified entryModified: Double,
                                       created entryCreated: Double, extensionID entryExtension: UInt16) -> Int32 {
        let index = Int32(flags.count)
        nameOffset.append(UInt32(nameStart))
        nameLength.append(UInt16(min(nameCount, Int(UInt16.max))))
        foldedOffset.append(UInt32(foldedStart))
        foldedLength.append(UInt16(foldedCount))
        parent.append(entryParent)
        flags.append(entryFlags)
        size.append(entrySize)
        modified.append(entryModified)
        created.append(entryCreated)
        extensionID.append(entryExtension)
        firstChild.append(-1)
        previousSibling.append(-1)
        if entryParent >= 0 {
            let head = firstChild[Int(entryParent)]
            nextSibling.append(head)
            if head >= 0 { previousSibling[Int(head)] = index }
            firstChild[Int(entryParent)] = index
        } else {
            nextSibling.append(-1)
            topLevel.append(index)
        }
        liveCount += 1
        if entryFlags & LightningEntryFlag.ancestor != 0 { ancestorCount += 1 }
        generation &+= 1
        return index
    }

    // MARK: Mutation

    mutating func updateMetadata(_ index: Int32, size newSize: Int64, modified newModified: Double, created newCreated: Double,
                                 flags newFlags: UInt8) {
        let i = Int(index)
        let keep = flags[i] & (LightningEntryFlag.ancestor | LightningEntryFlag.root | LightningEntryFlag.ascii)
        let changed = size[i] != newSize || !Self.same(modified[i], newModified) || !Self.same(created[i], newCreated)
            || flags[i] != (keep | newFlags)
        guard changed else { return }
        size[i] = newSize
        modified[i] = newModified
        created[i] = newCreated
        flags[i] = keep | newFlags
        generation &+= 1
    }

    private static func same(_ a: Double, _ b: Double) -> Bool { a == b || (a.isNaN && b.isNaN) }

    /// Marks `index` and every descendant dead and unlinks `index` from its parent.
    mutating func removeSubtree(_ index: Int32) {
        guard index >= 0, Int(index) < count, flags[Int(index)] & LightningEntryFlag.dead == 0 else { return }
        unlink(index)
        var stack: [Int32] = [index]
        while let current = stack.popLast() {
            let i = Int(current)
            guard flags[i] & LightningEntryFlag.dead == 0 else { continue }
            if flags[i] & LightningEntryFlag.ancestor != 0 { ancestorCount -= 1 }
            flags[i] |= LightningEntryFlag.dead
            liveCount -= 1
            deadCount += 1
            garbageBytes += Int(nameLength[i]) + (foldedOffset[i] == nameOffset[i] ? 0 : Int(foldedLength[i]))
            var child = firstChild[i]
            while child >= 0 {
                stack.append(child)
                child = nextSibling[Int(child)]
            }
            firstChild[i] = -1
        }
        generation &+= 1
    }

    /// Removes every descendant of `index`, keeping the entry itself.
    mutating func removeChildren(of index: Int32) {
        for child in children(of: index) { removeSubtree(child) }
    }

    private mutating func unlink(_ index: Int32) {
        let i = Int(index)
        let previous = previousSibling[i], next = nextSibling[i]
        if previous >= 0 {
            nextSibling[Int(previous)] = next
        } else if parent[i] >= 0 {
            firstChild[Int(parent[i])] = next
        } else {
            topLevel.removeAll { $0 == index }
        }
        if next >= 0 { previousSibling[Int(next)] = previous }
        previousSibling[i] = -1
        nextSibling[i] = -1
    }

    var needsCompaction: Bool {
        deadCount > max(65_536, count / 4)
    }

    /// A copy without dead entries, in the same order, with parents remapped.
    func compacted() -> LightningStorage {
        var result = LightningStorage()
        result.extensions = extensions
        result.reserveCapacity(liveCount, nameBytes: max(bytes.count - garbageBytes, 1))
        let identity = (0..<extensions.count).map { UInt16($0) }
        var map = [Int32](repeating: -1, count: count)
        for i in 0..<count where flags[i] & LightningEntryFlag.dead == 0 {
            let oldParent = parent[i]
            let newParent = oldParent >= 0 ? map[Int(oldParent)] : -1
            map[i] = result.appendCopy(of: i, from: self, parent: newParent, extensionMap: identity)
        }
        result.generation = generation &+ 1
        return result
    }

    // MARK: Reading

    func children(of index: Int32) -> [Int32] {
        if index < 0 { return topLevel }
        var result: [Int32] = []
        var child = firstChild[Int(index)]
        while child >= 0 {
            result.append(child)
            child = nextSibling[Int(child)]
        }
        return result
    }

    func rawName(_ index: Int32) -> ArraySlice<UInt8> {
        let offset = Int(nameOffset[Int(index)])
        return bytes[offset..<(offset + Int(nameLength[Int(index)]))]
    }

    func foldedName(_ index: Int32) -> ArraySlice<UInt8> {
        let offset = Int(foldedOffset[Int(index)])
        return bytes[offset..<(offset + Int(foldedLength[Int(index)]))]
    }

    /// The absolute path of `index`, built from the parent chain. The root folder "/" has an empty name.
    func path(_ index: Int32) -> String {
        var chain: [Int32] = []
        var current = index
        while current >= 0 {
            chain.append(current)
            current = parent[Int(current)]
        }
        var result: [UInt8] = []
        result.reserveCapacity(chain.count * 16)
        for entry in chain.reversed() where nameLength[Int(entry)] > 0 {
            result.append(0x2F)
            result.append(contentsOf: rawName(entry))
        }
        return result.isEmpty ? "/" : String(decoding: result, as: UTF8.self)
    }

    /// The child of `parent` (or a top-level entry when `parent` is -1) named `name`: an exact byte match
    /// wins, otherwise a case- and normalization-insensitive match.
    func child(of parentIndex: Int32, named name: [UInt8], folded: [UInt8]? = nil) -> Int32? {
        let wanted = folded ?? LightningText.fold(string: String(decoding: name, as: UTF8.self))
        var insensitive: Int32?
        func check(_ candidate: Int32) -> Bool {
            guard flags[Int(candidate)] & LightningEntryFlag.dead == 0 else { return false }
            if rawName(candidate).elementsEqual(name) { return true }
            if insensitive == nil, wanted.elementsEqual(foldedName(candidate)) { insensitive = candidate }
            return false
        }
        if parentIndex < 0 {
            for top in topLevel {
                if check(top) { return top }
                // The root folder "/" (empty name) is transparent: its children are top-level too.
                if nameLength[Int(top)] == 0 {
                    var child = firstChild[Int(top)]
                    while child >= 0 {
                        if check(child) { return child }
                        child = nextSibling[Int(child)]
                    }
                }
            }
            return insensitive
        }
        var child = firstChild[Int(parentIndex)]
        while child >= 0 {
            if check(child) { return child }
            child = nextSibling[Int(child)]
        }
        return insensitive
    }

    /// Resolves an absolute path to an entry.
    func lookup(path: String) -> Int32? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.isEmpty {
            return topLevel.first { nameLength[Int($0)] == 0 && flags[Int($0)] & LightningEntryFlag.dead == 0 }
        }
        var current: Int32 = -1
        for component in components {
            guard let next = child(of: current, named: Array(component.utf8)) else { return nil }
            current = next
        }
        return current
    }

    /// Approximate bytes held by the arrays, used for the index memory limit.
    var estimatedMemoryBytes: Int {
        bytes.capacity
            + (nameOffset.capacity + foldedOffset.capacity + parent.capacity) * 4
            + (nameLength.capacity + foldedLength.capacity + extensionID.capacity) * 2
            + flags.capacity
            + (size.capacity + modified.capacity + created.capacity) * 8
            + (firstChild.capacity + nextSibling.capacity + previousSibling.capacity) * 4
            + extensions.estimatedBytes
    }

    /// Searchable entries: live and not a synthetic ancestor.
    var searchableCount: Int { liveCount - ancestorCount }

    /// Rebuilds child links, counters and the extension lookup after decoding.
    mutating func rebuildDerivedState() {
        firstChild = [Int32](repeating: -1, count: count)
        nextSibling = [Int32](repeating: -1, count: count)
        previousSibling = [Int32](repeating: -1, count: count)
        topLevel = []
        liveCount = 0
        deadCount = 0
        ancestorCount = 0
        garbageBytes = 0
        for i in 0..<count {
            if flags[i] & LightningEntryFlag.dead != 0 {
                deadCount += 1
                continue
            }
            liveCount += 1
            if flags[i] & LightningEntryFlag.ancestor != 0 { ancestorCount += 1 }
            let index = Int32(i)
            let entryParent = parent[i]
            if entryParent >= 0 {
                let head = firstChild[Int(entryParent)]
                nextSibling[i] = head
                if head >= 0 { previousSibling[Int(head)] = index }
                firstChild[Int(entryParent)] = index
            } else {
                topLevel.append(index)
            }
        }
        generation &+= 1
    }

    /// Read-only unsafe views of the arrays for the duration of `body`.
    func withView<R>(_ body: (LightningStorageView) throws -> R) rethrows -> R {
        try bytes.withUnsafeBufferPointer { bytes in
            try nameOffset.withUnsafeBufferPointer { nameOffset in
                try nameLength.withUnsafeBufferPointer { nameLength in
                    try foldedOffset.withUnsafeBufferPointer { foldedOffset in
                        try foldedLength.withUnsafeBufferPointer { foldedLength in
                            try parent.withUnsafeBufferPointer { parent in
                                try flags.withUnsafeBufferPointer { flags in
                                    try size.withUnsafeBufferPointer { size in
                                        try modified.withUnsafeBufferPointer { modified in
                                            try created.withUnsafeBufferPointer { created in
                                                try extensionID.withUnsafeBufferPointer { extensionID in
                                                    try body(LightningStorageView(
                                                        bytes: bytes, nameOffset: nameOffset, nameLength: nameLength,
                                                        foldedOffset: foldedOffset, foldedLength: foldedLength, parent: parent,
                                                        flags: flags, size: size, modified: modified, created: created,
                                                        extensionID: extensionID))
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
        }
    }
}

/// Unsafe, read-only pointers into a `LightningStorage`, valid inside `withView`.
struct LightningStorageView {
    let bytes: UnsafeBufferPointer<UInt8>
    let nameOffset: UnsafeBufferPointer<UInt32>
    let nameLength: UnsafeBufferPointer<UInt16>
    let foldedOffset: UnsafeBufferPointer<UInt32>
    let foldedLength: UnsafeBufferPointer<UInt16>
    let parent: UnsafeBufferPointer<Int32>
    let flags: UnsafeBufferPointer<UInt8>
    let size: UnsafeBufferPointer<Int64>
    let modified: UnsafeBufferPointer<Double>
    let created: UnsafeBufferPointer<Double>
    let extensionID: UnsafeBufferPointer<UInt16>

    var count: Int { flags.count }

    @inline(__always)
    func raw(_ index: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: bytes.baseAddress! + Int(nameOffset[index]), count: Int(nameLength[index]))
    }

    @inline(__always)
    func folded(_ index: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: bytes.baseAddress! + Int(foldedOffset[index]), count: Int(foldedLength[index]))
    }

    @inline(__always)
    func isDirectory(_ index: Int) -> Bool { flags[index] & LightningEntryFlag.directory != 0 }

    /// Folders that browse as containers; packages count as files, like `FileItem.isBrowsableFolder`.
    @inline(__always)
    func isFolder(_ index: Int) -> Bool {
        flags[index] & (LightningEntryFlag.directory | LightningEntryFlag.package) == LightningEntryFlag.directory
    }

    func path(_ index: Int) -> String {
        var chain: [Int] = []
        var current = index
        while current >= 0 {
            chain.append(current)
            current = Int(parent[current])
        }
        var result: [UInt8] = []
        result.reserveCapacity(chain.count * 16)
        for entry in chain.reversed() where nameLength[entry] > 0 {
            result.append(0x2F)
            result.append(contentsOf: raw(entry))
        }
        return result.isEmpty ? "/" : String(decoding: result, as: UTF8.self)
    }
}
