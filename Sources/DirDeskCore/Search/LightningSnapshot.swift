import Darwin
import Foundation
import zlib

public enum LightningSnapshotError: Error, Equatable {
    case missing
    /// The file is damaged; the index moves it aside and rebuilds.
    case corrupt(String)
    /// Written for other roots, rules or volumes; the index rebuilds and overwrites it.
    case incompatible
}

struct LightningSnapshotHeader: Equatable {
    var fingerprint: UInt64
    var lastEventID: UInt64
    var savedAt: Double
    var limit: LightningIndexLimit?
    var roots: [String]
    var volumeUUIDs: [String]
}

/// Binary index snapshot: a fixed header, then a payload of raw little-endian arrays compressed with
/// LZFSE in independent blocks (compressed and decompressed in parallel).
///
/// Layout: magic `DDLIGHT1`, format version, flags, payload length, CRC-32 of the payload, block count,
/// one (compressed length, payload length) pair per block, then the blocks. Decoding checks every offset,
/// parent link and extension id before an index is built from it, so a damaged file is rejected instead
/// of producing a broken index.
enum LightningSnapshot {
    private static let magic = Array("DDLIGHT1".utf8)
    private static let formatVersion: UInt32 = 1
    private static let compressedFlag: UInt32 = 1
    private static let headerSize = 32
    private static let blockSize = 8 << 20
    private static let maximumEntries = 64_000_000

    static func write(_ storage: LightningStorage, header: LightningSnapshotHeader, to url: URL) throws {
        let payload = encode(storage, header: header)
        let blockCount = max(1, (payload.count + blockSize - 1) / blockSize)
        var blocks = [Data?](repeating: nil, count: blockCount)
        blocks.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: blockCount) { block in
                let range = (block * blockSize)..<min(payload.count, (block + 1) * blockSize)
                results[block] = try? (payload.subdata(in: range) as NSData).compressed(using: .lzfse) as Data
            }
        }
        let compressed = blocks.compactMap { $0 }
        guard compressed.count == blockCount else { throw CocoaError(.fileWriteUnknown) }
        var file = Data(capacity: headerSize + blockCount * 8 + compressed.reduce(0) { $0 + $1.count })
        file.append(contentsOf: magic)
        file.appendLittleEndian(formatVersion)
        file.appendLittleEndian(compressedFlag)
        file.appendLittleEndian(UInt64(payload.count))
        file.appendLittleEndian(checksum(payload))
        file.appendLittleEndian(UInt32(blockCount))
        for (block, data) in compressed.enumerated() {
            file.appendLittleEndian(UInt32(data.count))
            file.appendLittleEndian(UInt32(min(payload.count, (block + 1) * blockSize) - block * blockSize))
        }
        for data in compressed { file.append(data) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A fixed sibling name keeps our own writes recognizable; rename makes the replacement atomic.
        let staging = url.path + ".tmp"
        let descriptor = open(staging, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        file.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if failure == 0, rename(staging, url.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(staging)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    static func read(from url: URL) throws -> (LightningStorage, LightningSnapshotHeader) {
        let file: Data
        do {
            file = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw FileManager.default.fileExists(atPath: url.path) ? LightningSnapshotError.corrupt("unreadable") : LightningSnapshotError.missing
        }
        guard file.count >= headerSize, Array(file.prefix(8)) == magic else { throw LightningSnapshotError.corrupt("header") }
        var reader = ByteReader(file)
        reader.position = 8
        let version: UInt32 = try reader.scalar()
        guard version == formatVersion else { throw LightningSnapshotError.incompatible }
        let flags: UInt32 = try reader.scalar()
        let payloadLength: UInt64 = try reader.scalar()
        let expectedChecksum: UInt32 = try reader.scalar()
        let blockCount = Int(try reader.scalar() as UInt32)
        guard flags & compressedFlag != 0, payloadLength <= UInt64(Int.max / 2),
              blockCount == max(1, (Int(payloadLength) + blockSize - 1) / blockSize) else {
            throw LightningSnapshotError.corrupt("header")
        }
        var blocks: [(start: Int, compressed: Int, length: Int)] = []
        var start = headerSize + blockCount * 8
        var total = 0
        for _ in 0..<blockCount {
            let compressed = Int(try reader.scalar() as UInt32), length = Int(try reader.scalar() as UInt32)
            guard length <= blockSize, start + compressed <= file.count else { throw LightningSnapshotError.corrupt("blocks") }
            blocks.append((start, compressed, length))
            start += compressed
            total += length
        }
        guard start == file.count, total == Int(payloadLength) else { throw LightningSnapshotError.corrupt("blocks") }
        var parts = [Data?](repeating: nil, count: blockCount)
        parts.withUnsafeMutableBufferPointer { results in
            DispatchQueue.concurrentPerform(iterations: blockCount) { index in
                let block = blocks[index]
                let data = file.subdata(in: block.start..<(block.start + block.compressed))
                if let decompressed = try? (data as NSData).decompressed(using: .lzfse) as Data, decompressed.count == block.length {
                    results[index] = decompressed
                }
            }
        }
        var payload = Data(capacity: total)
        for part in parts {
            guard let part else { throw LightningSnapshotError.corrupt("compression") }
            payload.append(part)
        }
        guard checksum(payload) == expectedChecksum else { throw LightningSnapshotError.corrupt("checksum") }
        return try decode(payload)
    }

    // MARK: Payload

    static func encode(_ storage: LightningStorage, header: LightningSnapshotHeader) -> Data {
        var data = Data()
        data.reserveCapacity(storage.bytes.count + storage.count * 46 + 1024)
        data.appendLittleEndian(UInt32(0x0102_0304)) // byte-order mark
        data.appendLittleEndian(header.fingerprint)
        data.appendLittleEndian(header.lastEventID)
        data.appendLittleEndian(header.savedAt.bitPattern)
        let limitCode: UInt8 = switch header.limit {
        case nil: 0
        case .entries?: 1
        case .elapsedTime?: 2
        case .memory?: 3
        }
        data.append(limitCode)
        data.appendLittleEndian(UInt32(header.roots.count))
        for (root, uuid) in zip(header.roots, header.volumeUUIDs) {
            data.appendString(root)
            data.appendString(uuid)
        }
        data.appendLittleEndian(UInt32(storage.extensions.count))
        for name in storage.extensions.names {
            data.appendLittleEndian(UInt16(name.count))
            data.append(contentsOf: name)
        }
        data.appendLittleEndian(UInt32(storage.count))
        data.appendLittleEndian(UInt64(storage.bytes.count))
        data.append(contentsOf: storage.bytes)
        data.appendArray(storage.nameOffset)
        data.appendArray(storage.nameLength)
        data.appendArray(storage.foldedOffset)
        data.appendArray(storage.foldedLength)
        data.appendArray(storage.parent)
        data.appendArray(storage.flags)
        data.appendArray(storage.size)
        data.appendArray(storage.modified)
        data.appendArray(storage.created)
        data.appendArray(storage.extensionID)
        return data
    }

    static func decode(_ payload: Data) throws -> (LightningStorage, LightningSnapshotHeader) {
        var reader = ByteReader(payload)
        let byteOrder: UInt32 = try reader.scalar()
        guard byteOrder == 0x0102_0304 else { throw LightningSnapshotError.incompatible }
        let fingerprint: UInt64 = try reader.scalar()
        let lastEventID: UInt64 = try reader.scalar()
        let savedAt = Double(bitPattern: try reader.scalar() as UInt64)
        let limit: LightningIndexLimit?
        switch try reader.scalar() as UInt8 {
        case 0: limit = nil
        case 1: limit = .entries
        case 2: limit = .elapsedTime
        case 3: limit = .memory
        default: throw LightningSnapshotError.corrupt("limit")
        }
        let rootCount = Int(try reader.scalar() as UInt32)
        guard rootCount <= 4096 else { throw LightningSnapshotError.corrupt("roots") }
        var roots: [String] = [], uuids: [String] = []
        for _ in 0..<rootCount {
            roots.append(try reader.string())
            uuids.append(try reader.string())
        }
        let extensionCount = Int(try reader.scalar() as UInt32)
        guard extensionCount >= 1, extensionCount < Int(LightningExtensionTable.overflow) else {
            throw LightningSnapshotError.corrupt("extensions")
        }
        var extensionNames: [[UInt8]] = []
        extensionNames.reserveCapacity(extensionCount)
        for index in 0..<extensionCount {
            let length = Int(try reader.scalar() as UInt16)
            guard index == 0 ? length == 0 : (length > 0 && length <= LightningExtensionTable.maximumLength) else {
                throw LightningSnapshotError.corrupt("extension name")
            }
            extensionNames.append(try reader.bytes(length))
        }
        let count = Int(try reader.scalar() as UInt32)
        guard count <= maximumEntries else { throw LightningSnapshotError.corrupt("entry count") }
        let byteCount = try reader.scalar() as UInt64
        guard byteCount >= 1, byteCount <= UInt64(UInt32.max) else { throw LightningSnapshotError.corrupt("name bytes") }
        var storage = LightningStorage()
        storage.bytes = try reader.bytes(Int(byteCount))
        storage.nameOffset = try reader.array(count)
        storage.nameLength = try reader.array(count)
        storage.foldedOffset = try reader.array(count)
        storage.foldedLength = try reader.array(count)
        storage.parent = try reader.array(count)
        storage.flags = try reader.array(count)
        storage.size = try reader.array(count)
        storage.modified = try reader.array(count)
        storage.created = try reader.array(count)
        storage.extensionID = try reader.array(count)
        guard reader.position == payload.count else { throw LightningSnapshotError.corrupt("trailing data") }
        let nameBytes = storage.bytes.count
        for index in 0..<count {
            let flags = storage.flags[index]
            guard flags & ~LightningEntryFlag.persistentMask == 0 else { throw LightningSnapshotError.corrupt("flags") }
            guard Int(storage.nameOffset[index]) + Int(storage.nameLength[index]) <= nameBytes,
                  Int(storage.foldedOffset[index]) + Int(storage.foldedLength[index]) <= nameBytes else {
                throw LightningSnapshotError.corrupt("name range")
            }
            let parent = storage.parent[index]
            guard parent == -1 || (parent >= 0 && Int(parent) < index) else { throw LightningSnapshotError.corrupt("parent") }
            if parent >= 0, storage.flags[Int(parent)] & LightningEntryFlag.directory == 0 {
                throw LightningSnapshotError.corrupt("parent kind")
            }
            let extensionID = storage.extensionID[index]
            guard Int(extensionID) < extensionCount || extensionID == LightningExtensionTable.overflow else {
                throw LightningSnapshotError.corrupt("extension id")
            }
            guard storage.size[index] >= 0 else { throw LightningSnapshotError.corrupt("size") }
        }
        storage.extensions = LightningExtensionTable(names: extensionNames)
        storage.rebuildDerivedState()
        let header = LightningSnapshotHeader(fingerprint: fingerprint, lastEventID: lastEventID, savedAt: savedAt, limit: limit,
                                             roots: roots, volumeUUIDs: uuids)
        return (storage, header)
    }

    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw -> UInt32 in
            var value = crc32(0, nil, 0)
            var offset = 0
            while offset < raw.count {
                let length = min(raw.count - offset, 1 << 30)
                value = crc32(value, raw.baseAddress!.assumingMemoryBound(to: Bytef.self) + offset, uInt(length))
                offset += length
            }
            return UInt32(truncatingIfNeeded: value)
        }
    }
}

private struct ByteReader {
    let data: Data
    var position = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func scalar<T: FixedWidthInteger>() throws -> T {
        let size = MemoryLayout<T>.size
        guard position + size <= data.count else { throw LightningSnapshotError.corrupt("truncated") }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: position, as: T.self) }
        position += size
        return T(littleEndian: value)
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= data.count else { throw LightningSnapshotError.corrupt("truncated") }
        let result = [UInt8](data[(data.startIndex + position)..<(data.startIndex + position + count)])
        position += count
        return result
    }

    mutating func array<T>(_ count: Int) throws -> [T] {
        let length = count * MemoryLayout<T>.stride
        guard length >= 0, position + length <= data.count else { throw LightningSnapshotError.corrupt("truncated") }
        let result = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.withUnsafeBytes { raw in
                if length > 0 {
                    memcpy(UnsafeMutableRawPointer(buffer.baseAddress!), raw.baseAddress! + position, length)
                }
            }
            initialized = count
        }
        position += length
        return result
    }

    mutating func string() throws -> String {
        let length = Int(try scalar() as UInt32)
        guard length <= 1 << 20 else { throw LightningSnapshotError.corrupt("string") }
        return String(decoding: try bytes(length), as: UTF8.self)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendArray<T>(_ array: [T]) {
        array.withUnsafeBytes { append(contentsOf: $0) }
    }

    mutating func appendString(_ string: String) {
        let bytes = Array(string.utf8)
        appendLittleEndian(UInt32(bytes.count))
        append(contentsOf: bytes)
    }
}
