import Darwin
import Foundation
import UniformTypeIdentifiers

/// Reads a local folder with `getattrlistbulk(2)`: one system call returns names, types, dates, flags, sizes,
/// access rights and file IDs for many entries at once. On a 100,000-file folder this is several times faster than
/// prefetching URL resource values. Cloud folders and other volumes keep the resource-value path
/// (`DirectoryLoader` falls back whenever this reader returns nil).
public enum FastDirectoryReader {
    // sys/attr.h
    private static let returnedAttributes: UInt32 = 0x8000_0000
    private static let commonError: UInt32 = 0x2000_0000
    private static let commonName: UInt32 = 0x0000_0001
    private static let commonObjectType: UInt32 = 0x0000_0008
    private static let commonCreationTime: UInt32 = 0x0000_0200
    private static let commonModificationTime: UInt32 = 0x0000_0400
    private static let commonAccessTime: UInt32 = 0x0000_1000
    private static let commonFinderInfo: UInt32 = 0x0000_4000
    private static let commonFlags: UInt32 = 0x0004_0000
    private static let commonUserAccess: UInt32 = 0x0020_0000
    private static let commonFileID: UInt32 = 0x0200_0000
    private static let commonAddedTime: UInt32 = 0x1000_0000
    private static let fileTotalSize: UInt32 = 0x0000_0002
    private static let fileAllocatedSize: UInt32 = 0x0000_0004
    private static let fileDataLength: UInt32 = 0x0000_0200
    private static let bufferSize = 256 * 1024

    /// Volumes whose file IDs and resource identifiers are known to line up (see `resourceIdentifier`).
    private static let supportedFileSystems: Set<String> = ["apfs", "hfs"]

    public static func read(_ directory: URL, limit: Int, isCancelled: () -> Bool = { false }) -> (items: [FileItem], total: Int)? {
        let path = directory.path
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let fileSystem = withUnsafeBytes(of: &info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard supportedFileSystems.contains(fileSystem), let volume = volumeIdentifier(of: directory, path: path) else { return nil }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = returnedAttributes | commonError | commonName | commonObjectType | commonCreationTime | commonModificationTime
            | commonAccessTime | commonFinderInfo | commonFlags | commonUserAccess | commonFileID | commonAddedTime
        request.fileattr = fileTotalSize | fileAllocatedSize | fileDataLength
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var items: [FileItem] = []
        var total = 0
        let base = path.hasSuffix("/") ? path : path + "/"
        var types = TypeCache()
        while true {
            if isCancelled() { break }
            let count = withUnsafeMutablePointer(to: &request) { getattrlistbulk(descriptor, $0, buffer, bufferSize, 0) }
            if count < 0 {
                if errno == EINTR { continue }
                return items.isEmpty ? nil : (items, total)
            }
            if count == 0 { break }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                guard length > 0 else { return nil }
                total += 1
                if items.count < limit, let item = parse(entry, base: base, volume: volume, types: &types) {
                    items.append(item)
                }
                entry += length
            }
        }
        return (items, total)
    }

    /// Volume identifier as `URLResourceKey.volumeIdentifierKey` reports it, verified against the folder's own
    /// resource identifier (`file ID ‖ volume identifier`); nil when the layout differs.
    private static func volumeIdentifier(of directory: URL, path: String) -> Data? {
        guard let values = try? directory.resourceValues(forKeys: [.volumeIdentifierKey, .fileResourceIdentifierKey]),
              let volume = values.volumeIdentifier as? Data, let identifier = values.fileResourceIdentifier as? Data else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, resourceIdentifier(fileID: UInt64(info.st_ino), volume: volume) == identifier else { return nil }
        return volume
    }

    static func resourceIdentifier(fileID: UInt64, volume: Data) -> Data {
        var little = fileID.littleEndian
        var data = Data(bytes: &little, count: 8)
        data.append(volume)
        return data
    }

    private struct TypeCache {
        var files: [String: (identifier: String, isPackage: Bool)] = [:]
        var folders: [String: (identifier: String, isPackage: Bool)] = [:]

        mutating func type(forExtension ext: String, directory: Bool = false) -> (identifier: String, isPackage: Bool) {
            let key = ext.lowercased()
            if let cached = directory ? folders[key] : files[key] { return cached }
            let type = directory ? (UTType(filenameExtension: ext, conformingTo: .directory) ?? .folder) : (UTType(filenameExtension: ext) ?? .data)
            let value = (type.identifier, type.conforms(to: .package))
            if directory { folders[key] = value } else { files[key] = value }
            return value
        }
    }

    private static func parse(_ entry: UnsafeRawPointer, base: String, volume: Data, types: inout TypeCache) -> FileItem? {
        let common = entry.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let file = entry.loadUnaligned(fromByteOffset: 4 + 12, as: UInt32.self)
        var field = entry + 4 + 20
        if common & commonError != 0 {
            let error = field.loadUnaligned(as: UInt32.self)
            field += 4
            if error != 0 { return nil }
        }
        guard common & commonName != 0 else { return nil }
        let nameOffset = Int(field.loadUnaligned(as: Int32.self))
        let nameLength = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let name = String(decoding: UnsafeRawBufferPointer(start: field + nameOffset, count: max(nameLength - 1, 0)), as: UTF8.self)
        field += 8
        var objectType: UInt32 = 0
        if common & commonObjectType != 0 { objectType = field.loadUnaligned(as: UInt32.self); field += 4 }
        func date() -> Date {
            let seconds = field.loadUnaligned(as: Int.self)
            let nanoseconds = field.loadUnaligned(fromByteOffset: MemoryLayout<Int>.size, as: Int.self)
            field += MemoryLayout<timespec>.size
            // Same arithmetic as Foundation's resource values (seconds since 2001), so both paths give equal dates.
            return Date(timeIntervalSinceReferenceDate: Double(seconds - 978_307_200) + Double(nanoseconds) / 1_000_000_000)
        }
        let created = common & commonCreationTime != 0 ? date() : nil
        let modified = common & commonModificationTime != 0 ? date() : nil
        let accessed = common & commonAccessTime != 0 ? date() : nil
        var finderFlags: UInt16 = 0
        if common & commonFinderInfo != 0 {
            // FileInfo/FolderInfo: fdFlags is the big-endian UInt16 at offset 8.
            finderFlags = UInt16(bigEndian: field.loadUnaligned(fromByteOffset: 8, as: UInt16.self))
            field += 32
        }
        var flags: UInt32 = 0
        if common & commonFlags != 0 { flags = field.loadUnaligned(as: UInt32.self); field += 4 }
        var access: UInt32 = 0
        if common & commonUserAccess != 0 { access = field.loadUnaligned(as: UInt32.self); field += 4 }
        var fileID: UInt64 = 0
        if common & commonFileID != 0 { fileID = field.loadUnaligned(as: UInt64.self); field += 8 }
        let added = common & commonAddedTime != 0 ? date() : nil
        var allocated: Int64?
        var dataLength: Int64?
        if file & fileTotalSize != 0 { field += 8 }
        if file & fileAllocatedSize != 0 { allocated = field.loadUnaligned(as: Int64.self); field += 8 }
        if file & fileDataLength != 0 { dataLength = field.loadUnaligned(as: Int64.self) }
        guard !name.isEmpty else { return nil }

        let isDirectory = objectType == 2 // VDIR
        let isLink = objectType == 5 // VLNK
        let ext = (name as NSString).pathExtension
        var typeIdentifier: String
        var isPackage = false
        if isDirectory {
            let kind: (identifier: String, isPackage: Bool) = ext.isEmpty ? (UTType.folder.identifier, false) : types.type(forExtension: ext, directory: true)
            isPackage = (kind.isPackage || finderFlags & 0x2000 != 0) && !ext.isEmpty // kHasBundle
            typeIdentifier = isPackage ? kind.identifier : UTType.folder.identifier
        } else if isLink {
            typeIdentifier = UTType.symbolicLink.identifier
        } else {
            typeIdentifier = ext.isEmpty ? UTType.data.identifier : types.type(forExtension: ext).identifier
        }
        let path = base + name
        let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
        let identity = FileIdentity(volumeIdentifier: volume, resourceIdentifier: resourceIdentifier(fileID: fileID, volume: volume),
                                    fallbackPath: url.path, fileSystemInode: fileID)
        let label = Int((finderFlags & 0x000E) >> 1)
        let isAlias = finderFlags & 0x8000 != 0 && !isLink
        if isAlias { typeIdentifier = UTType.aliasFile.identifier }
        return FileItem(
            id: identity, url: url, name: name, isDirectory: isDirectory, isPackage: isPackage, isSymbolicLink: isLink,
            isAliasFile: isAlias, size: isDirectory ? nil : dataLength,
            allocatedSize: allocated, contentTypeIdentifier: typeIdentifier,
            modificationDate: modified, creationDate: created, addedDate: added, lastOpenedDate: accessed,
            isHidden: flags & UInt32(UF_HIDDEN) != 0 || name.hasPrefix("."),
            isReadable: access & UInt32(R_OK) != 0, isWritable: access & UInt32(W_OK) != 0,
            labelNumber: label == 0 ? nil : label)
    }
}
