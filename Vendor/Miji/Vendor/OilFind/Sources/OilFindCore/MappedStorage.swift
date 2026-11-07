import Foundation
import CryptoKit
import Darwin

public enum MappedCacheError: Error { case unreadable, invalid }

/// A private mapping of a whole cache file. Untouched pages stay clean and
/// file-backed, so the system can drop them under memory pressure instead of
/// swapping. Writes land in private copy-on-write pages and never reach the file;
/// writers replace the file by renaming a new one, so a live mapping never changes.
public final class MappedFile {
    public let bytes: UnsafeMutableRawBufferPointer

    public init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MappedCacheError.unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { throw MappedCacheError.unreadable }
        let length = Int(info.st_size)
        guard let pointer = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE, descriptor, 0),
              pointer != MAP_FAILED else { throw MappedCacheError.unreadable }
        bytes = UnsafeMutableRawBufferPointer(start: pointer, count: length)
    }

    deinit { munmap(bytes.baseAddress, bytes.count) }

    /// Asks the system to read the file back in ahead of use; returns at once.
    public func prefetch() { _ = madvise(bytes.baseAddress, bytes.count, MADV_WILLNEED) }
}

/// Named, aligned regions of a `MappedFile`, as recorded by `CacheFileWriter`.
public struct MappedSections {
    public let file: MappedFile
    private let table: [String: [Int]]
    private let limit: Int

    /// `limit` is the end of the section area (the footer follows it).
    public init(file: MappedFile, table: [String: [Int]], limit: Int) throws {
        guard limit >= 0, limit <= file.bytes.count else { throw MappedCacheError.invalid }
        // Mapped columns are written in place, so no two sections may share bytes.
        // An empty section may start where the next one does.
        var end = 0
        for entry in table.values.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard entry.count == 2, entry[0] >= end, entry[1] >= 0, entry[1] <= limit - entry[0] else { throw MappedCacheError.invalid }
            end = entry[0] + entry[1]
        }
        self.file = file; self.table = table; self.limit = limit
    }

    /// The section as `count` elements of `T` (any count when nil), validated for
    /// bounds, alignment and a whole number of elements.
    public func buffer<T>(_ name: String, as type: T.Type, count: Int? = nil) throws -> UnsafeMutableBufferPointer<T> {
        guard let entry = table[name], entry.count == 2 else { throw MappedCacheError.invalid }
        let offset = entry[0], length = entry[1], stride = MemoryLayout<T>.stride
        guard offset >= 0, length >= 0, offset <= limit, length <= limit - offset,
              offset % MemoryLayout<T>.alignment == 0, length % stride == 0,
              count.map({ $0 == length / stride }) ?? true else { throw MappedCacheError.invalid }
        let start = file.bytes.baseAddress!.advanced(by: offset).bindMemory(to: T.self, capacity: length / stride)
        return UnsafeMutableBufferPointer(start: start, count: length / stride)
    }
}

/// Streams an aligned, checksummed cache file: magic, sections, footer, the
/// footer's little-endian UInt64 length and a SHA-256 of everything before it.
public final class CacheFileWriter {
    private let descriptor: Int32
    private var digest = SHA256()
    public private(set) var offset = 0
    /// Section name to [offset, length] in bytes.
    public private(set) var sections: [String: [Int]] = [:]

    public init(descriptor: Int32, magic: Data) throws {
        self.descriptor = descriptor
        try write(magic)
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        digest.update(bufferPointer: bytes)
        try emit(base, bytes.count)
        offset += bytes.count
    }

    public func write(_ data: Data) throws { try data.withUnsafeBytes { try write($0) } }

    public func write<T>(_ values: UnsafeBufferPointer<T>) throws { try write(UnsafeRawBufferPointer(values)) }

    public func section(_ name: String, _ body: () throws -> Void) throws {
        let padding = (16 - offset % 16) % 16
        if padding > 0 { try write(Data(count: padding)) }
        let start = offset
        try body()
        sections[name] = [start, offset - start]
    }

    /// Appends the footer, its length and the checksum. The caller closes and publishes the file.
    public func finish(footer: Data) throws {
        try write(footer)
        var length = UInt64(footer.count).littleEndian
        try withUnsafeBytes(of: &length) { try write($0) }
        let hash = Data(digest.finalize())
        try hash.withUnsafeBytes { try emit($0.baseAddress!, $0.count) }
    }

    private func emit(_ base: UnsafeRawPointer, _ count: Int) throws {
        var written = 0
        while written < count {
            let result = Darwin.write(descriptor, base.advanced(by: written), min(count - written, 1 << 20))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw MappedCacheError.unreadable }
            written += result
        }
    }

    /// Validates the trailer of a mapped cache and returns its footer and the end of the section area.
    public static func footer(of file: MappedFile, magic: Data) throws -> (footer: Data, limit: Int) {
        let bytes = file.bytes
        let total = bytes.count
        guard total >= magic.count + 40,
              magic.elementsEqual(UnsafeRawBufferPointer(rebasing: bytes[0..<magic.count])) else { throw MappedCacheError.invalid }
        let hash = SHA256.hash(data: UnsafeRawBufferPointer(rebasing: bytes[0..<(total - 32)]))
        guard hash.elementsEqual(UnsafeRawBufferPointer(rebasing: bytes[(total - 32)..<total])) else { throw MappedCacheError.invalid }
        let length = UInt64(littleEndian: UnsafeRawBufferPointer(rebasing: bytes[(total - 40)..<(total - 32)]).loadUnaligned(as: UInt64.self))
        guard length <= UInt64(total - 40 - magic.count) else { throw MappedCacheError.invalid }
        let limit = total - 40 - Int(length)
        return (Data(UnsafeRawBufferPointer(rebasing: bytes[limit..<(total - 40)])), limit)
    }
}

/// A column whose first elements may live in a `MappedFile` and whose appended
/// elements live in ordinary memory. Mapped elements can still be assigned:
/// those writes stay private to this process.
public struct SegmentedArray<Element> {
    public private(set) var mapped: UnsafeMutableBufferPointer<Element>
    public private(set) var tail: [Element]
    private var owner: AnyObject?

    public init(_ elements: [Element] = []) {
        mapped = UnsafeMutableBufferPointer(start: nil, count: 0)
        tail = elements
    }

    public init(mapped: UnsafeMutableBufferPointer<Element>, owner: AnyObject) {
        self.mapped = mapped
        tail = []
        self.owner = owner
    }

    public var count: Int { mapped.count + tail.count }
    public var isEmpty: Bool { count == 0 }
    public var indices: Range<Int> { 0..<count }
    /// Mapped elements plus the tail's capacity, for storage accounting.
    public var capacity: Int { mapped.count + tail.capacity }

    public subscript(index: Int) -> Element {
        get { index < mapped.count ? mapped[index] : tail[index - mapped.count] }
        set {
            if index < mapped.count { mapped[index] = newValue } else { tail[index - mapped.count] = newValue }
        }
    }

    public mutating func append(_ element: Element) { tail.append(element) }
    public mutating func append<S: Sequence>(contentsOf elements: S) where S.Element == Element { tail.append(contentsOf: elements) }
    public mutating func reserveCapacity(_ count: Int) { tail.reserveCapacity(max(0, count - mapped.count)) }

    /// Visits the storage as at most two contiguous runs, each with the index of its first element.
    public func forEachSegment(_ body: (Int, UnsafeBufferPointer<Element>) throws -> Void) rethrows {
        if !mapped.isEmpty { try body(0, UnsafeBufferPointer(mapped)) }
        if !tail.isEmpty { try tail.withUnsafeBufferPointer { try body(mapped.count, $0) } }
    }

    public func allSatisfy(_ predicate: (Element) throws -> Bool) rethrows -> Bool {
        var result = true
        try forEachSegment { _, run in if result { result = try run.allSatisfy(predicate) } }
        return result
    }

    /// Writes all elements, mapped first, as raw bytes.
    public func write(to writer: CacheFileWriter) throws {
        try forEachSegment { _, run in try writer.write(run) }
    }
}
