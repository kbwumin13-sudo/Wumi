import CArchive
import Darwin
import Foundation

public enum ArchiveFormat: String, Codable, CaseIterable, Sendable {
    case zip, sevenZip
}

public enum ArchiveCompressionPriority: String, Codable, CaseIterable, Sendable {
    case faster, smaller
}

public struct ArchiveCreationOptions: Sendable {
    public var format: ArchiveFormat
    public var priority: ArchiveCompressionPriority
    public var password: String?
    /// Split size in bytes; nil writes a single file.
    public var volumeSize: Int64?

    public init(format: ArchiveFormat = .zip, priority: ArchiveCompressionPriority = .faster, password: String? = nil, volumeSize: Int64? = nil) {
        self.format = format
        self.priority = priority
        self.password = password
        self.volumeSize = volumeSize
    }
}

public struct ArchiveEntryMetadata: Sendable, Hashable {
    public enum Kind: String, Sendable { case file, directory, symbolicLink, hardLink, other }
    public var path: String
    public var compressedSize: Int64?
    public var uncompressedSize: Int64
    public var isEncrypted: Bool
    public var kind: Kind
    public var modified: Date?

    public var pathComponents: [String] { Self.components(of: path) }

    /// Path components without empty and "." segments, so "./a/b.txt" (tar, 7z) and "a/b.txt" (zip) name the same
    /// entry and an archive's "./" root is not listed as a folder.
    public static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." }
    }
}

public struct ArchiveIndex: Sendable {
    public var formatName: String
    public var entries: [ArchiveEntryMetadata]
    public var truncated: Bool
    public var expandedSize: Int64 { entries.reduce(0) { $0 + $1.uncompressedSize } }
}

public enum ArchiveError: Error, Equatable, Sendable {
    case unsupportedArchive, damagedArchive(String), encryptedArchive, decryptionFailed, unsafeEntry(String)
    case tooManyEntries, tooLarge, symbolicLinkUnsupported, passwordUnsupportedForFormat, invalidVolumeSize
    case writeFailed(String), cancelled, entryNotFound(String)
}

/// libarchive-based archive inspection, extraction and creation.
public enum ArchiveService {
    public static let recognizedExtensions: Set<String> = [
        "zip", "zipx", "tar", "tgz", "gz", "bz2", "xz", "lzma", "lz4", "zst", "7z", "rar", "cab", "cpio", "xar", "lha", "lzh", "ar", "a", "iso", "warc", "tbz", "tbz2", "txz",
    ]

    public struct Limits: Sendable {
        public var maximumEntries = 65_535
        public var maximumExpandedBytes: Int64 = 64 << 30
        public var maximumDepth = 128
        public var maximumRatio: Double = 1000
        public static let `default` = Limits()
    }

    public static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz") || name.hasSuffix(".tar.zst") { return true }
        return recognizedExtensions.contains(url.pathExtension.lowercased())
    }

    static func errorText(_ archive: OpaquePointer) -> String {
        guard let text = archive_error_string(archive) else { return "unknown error" }
        return String(cString: text)
    }

    private static func openReader(_ url: URL, password: String?) throws -> OpaquePointer {
        guard let reader = archive_read_new() else { throw ArchiveError.unsupportedArchive }
        archive_read_support_filter_all(reader)
        archive_read_support_format_all(reader)
        if let password { archive_read_add_passphrase(reader, password) }
        guard archive_read_open_filename(reader, url.path, 65_536) == ARCHIVE_OK else {
            let message = errorText(reader)
            archive_read_free(reader)
            throw ArchiveError.damagedArchive(message)
        }
        return reader
    }

    static func entryPath(_ entry: OpaquePointer) -> String? {
        if let utf8 = archive_entry_pathname_utf8(entry) { return String(cString: utf8) }
        if let raw = archive_entry_pathname(entry) { return String(cString: raw) }
        return nil
    }

    static func kind(_ entry: OpaquePointer) -> ArchiveEntryMetadata.Kind {
        switch archive_entry_filetype(entry) & UInt32(AE_IFMT) {
        case UInt32(AE_IFREG): archive_entry_hardlink(entry) != nil ? .hardLink : .file
        case UInt32(AE_IFDIR): .directory
        case UInt32(AE_IFLNK): .symbolicLink
        default: .other
        }
    }

    /// Lists entries without extracting.
    public static func index(of url: URL, password: String? = nil, limits: Limits = .default) throws -> ArchiveIndex {
        let reader = try openReader(url, password: password)
        defer { archive_read_free(reader) }
        var entries: [ArchiveEntryMetadata] = []
        var entry: OpaquePointer?
        var truncated = false
        while true {
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else {
                if entries.isEmpty { throw ArchiveError.damagedArchive(errorText(reader)) }
                break
            }
            guard let path = entryPath(entry), !ArchiveEntryMetadata.components(of: path).isEmpty else { continue }
            entries.append(ArchiveEntryMetadata(path: path, compressedSize: nil, uncompressedSize: archive_entry_size(entry),
                                                isEncrypted: archive_entry_is_encrypted(entry) != 0, kind: kind(entry),
                                                modified: Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry)))))
            if entries.count >= limits.maximumEntries {
                truncated = true
                break
            }
            archive_read_data_skip(reader)
        }
        let format = archive_format_name(reader).map { String(cString: $0) } ?? url.pathExtension.uppercased()
        return ArchiveIndex(formatName: format, entries: entries, truncated: truncated)
    }

    /// Rejects absolute paths, `..` components and overly deep paths.
    public static func safeRelativePath(_ path: String, maximumDepth: Int = 128) -> String? {
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            components.append(String(part))
        }
        guard !components.isEmpty, components.count <= maximumDepth, !path.hasPrefix("/") else { return nil }
        return components.joined(separator: "/")
    }

    /// Extracts into a hidden staging folder next to `destinationDirectory`, then publishes one
    /// top-level item (or a folder named after the archive when it has several roots).
    @discardableResult
    public static func extract(_ url: URL, to destinationDirectory: URL, password: String? = nil, limits: Limits = .default,
                               isCancelled: () -> Bool = { false }) throws -> URL {
        let fm = FileManager.default
        let (staging, _) = try extractToStaging(url, in: destinationDirectory, password: password, limits: limits, isCancelled: isCancelled)
        var published = false
        defer { if !published { try? fm.removeItem(at: staging) } }
        let roots = try fm.contentsOfDirectory(atPath: staging.path)
        let output: URL
        if roots.count == 1, let only = roots.first {
            output = FileOperationCoordinator.keepBothURLIfNeeded(destinationDirectory.appendingPathComponent(only))
            try fm.moveItem(at: staging.appendingPathComponent(only), to: output)
            try? fm.removeItem(at: staging)
        } else {
            let base = url.lastPathComponent.replacingOccurrences(of: "\\.(tar\\.)?[A-Za-z0-9]+$", with: "", options: .regularExpression)
            output = FileOperationCoordinator.keepBothURLIfNeeded(destinationDirectory.appendingPathComponent(base.isEmpty ? "Archive" : base))
            try fm.moveItem(at: staging, to: output)
        }
        published = true
        return output
    }

    /// Extracts the archive's top-level items straight into `destinationDirectory`, as the original does when an
    /// archive is double-clicked; names already taken get " 2", " 3"…. Returns the published items in archive
    /// order (the first one is what the original selects).
    @discardableResult
    public static func extractMerging(_ url: URL, into destinationDirectory: URL, password: String? = nil, limits: Limits = .default,
                                      isCancelled: () -> Bool = { false }) throws -> [URL] {
        let fm = FileManager.default
        let (staging, order) = try extractToStaging(url, in: destinationDirectory, password: password, limits: limits, isCancelled: isCancelled)
        defer { try? fm.removeItem(at: staging) }
        let present = Set(try fm.contentsOfDirectory(atPath: staging.path))
        let roots = order.filter(present.contains) + present.subtracting(order).sorted()
        var outputs: [URL] = []
        for root in roots {
            let output = FileOperationCoordinator.keepBothURLIfNeeded(destinationDirectory.appendingPathComponent(root))
            try fm.moveItem(at: staging.appendingPathComponent(root), to: output)
            outputs.append(output)
        }
        return outputs
    }

    /// Reads every entry into a new hidden folder inside `destinationDirectory` (removed again on failure) and
    /// returns it with the top-level names in the order the archive lists them.
    private static func extractToStaging(_ url: URL, in destinationDirectory: URL, password: String?, limits: Limits,
                                         isCancelled: () -> Bool) throws -> (URL, [String]) {
        let fm = FileManager.default
        let staging = destinationDirectory.appendingPathComponent(".dirdesk-extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var published = false
        defer { if !published { try? fm.removeItem(at: staging) } }
        var rootOrder: [String] = []
        let reader = try openReader(url, password: password)
        defer { archive_read_free(reader) }
        let archiveSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var entry: OpaquePointer?
        var count = 0
        var written: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if isCancelled() { throw ArchiveError.cancelled }
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw ArchiveError.damagedArchive(errorText(reader)) }
            count += 1
            guard count <= limits.maximumEntries else { throw ArchiveError.tooManyEntries }
            guard let raw = entryPath(entry) else { continue }
            if raw.hasPrefix("__MACOSX/") || raw.hasSuffix("/.DS_Store") || raw == ".DS_Store" { archive_read_data_skip(reader); continue }
            guard let relative = safeRelativePath(raw, maximumDepth: limits.maximumDepth) else { throw ArchiveError.unsafeEntry(raw) }
            if let root = relative.split(separator: "/").first.map(String.init), !rootOrder.contains(root) { rootOrder.append(root) }
            let target = staging.appendingPathComponent(relative)
            switch kind(entry) {
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .file, .hardLink:
                if archive_entry_is_encrypted(entry) != 0 && password == nil { throw ArchiveError.encryptedArchive }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: target.path, contents: nil), let handle = try? FileHandle(forWritingTo: target) else {
                    throw ArchiveError.writeFailed(target.path)
                }
                defer { try? handle.close() }
                while true {
                    let n = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                    if n == 0 { break }
                    if n < 0 {
                        let message = errorText(reader)
                        if message.localizedCaseInsensitiveContains("passphrase") || message.localizedCaseInsensitiveContains("decrypt") {
                            throw password == nil ? ArchiveError.encryptedArchive : ArchiveError.decryptionFailed
                        }
                        throw ArchiveError.damagedArchive(message)
                    }
                    written += Int64(n)
                    if written > limits.maximumExpandedBytes || (archiveSize > 0 && Double(written) / Double(archiveSize) > limits.maximumRatio && written > 1 << 30) {
                        throw ArchiveError.tooLarge
                    }
                    try handle.write(contentsOf: Data(buffer[0..<n]))
                }
                let perm = archive_entry_perm(entry)
                if perm != 0 { chmod(target.path, mode_t(perm & 0o777)) }
                let mtime = archive_entry_mtime(entry)
                if mtime > 0 { try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime))], ofItemAtPath: target.path) }
            case .symbolicLink:
                if let link = archive_entry_symlink(entry) {
                    let destination = String(cString: link)
                    // Only links that stay inside the extracted tree are created.
                    let resolved = (target.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path)
                    if !destination.hasPrefix("/"), resolved.hasPrefix(staging.standardizedFileURL.path) {
                        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: destination)
                    }
                }
            case .other:
                archive_read_data_skip(reader)
            }
        }
        published = true
        return (staging, rootOrder)
    }

    /// Archive formats the app reads (ZIP, 7Z, RAR); double-clicking one extracts it in place.
    public static let browsableExtensions: Set<String> = ["zip", "7z", "rar"]

    /// Writes one regular file entry into `directory` for previewing. Entries larger than `maximumBytes`
    /// (the preview safety limit) throw `tooLarge`; the output keeps the entry's file name.
    public static func extractEntry(_ path: String, from url: URL, to directory: URL, password: String? = nil,
                                    maximumBytes: Int64 = 64 << 20) throws -> URL {
        let wanted = ArchiveEntryMetadata.components(of: path)
        let reader = try openReader(url, password: password)
        defer { archive_read_free(reader) }
        let fm = FileManager.default
        var entry: OpaquePointer?
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let status = archive_read_next_header(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw ArchiveError.damagedArchive(errorText(reader)) }
            guard let raw = entryPath(entry), ArchiveEntryMetadata.components(of: raw) == wanted else {
                archive_read_data_skip(reader)
                continue
            }
            guard kind(entry) == .file || kind(entry) == .hardLink else { throw ArchiveError.unsupportedArchive }
            guard let relative = safeRelativePath(raw) else { throw ArchiveError.unsafeEntry(raw) }
            if archive_entry_size(entry) > maximumBytes { throw ArchiveError.tooLarge }
            if archive_entry_is_encrypted(entry) != 0 && password == nil { throw ArchiveError.encryptedArchive }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent((relative as NSString).lastPathComponent)
            try? fm.removeItem(at: target)
            guard fm.createFile(atPath: target.path, contents: nil), let handle = try? FileHandle(forWritingTo: target) else {
                throw ArchiveError.writeFailed(target.path)
            }
            defer { try? handle.close() }
            var written: Int64 = 0
            while true {
                let n = buffer.withUnsafeMutableBytes { archive_read_data(reader, $0.baseAddress, $0.count) }
                if n == 0 { break }
                if n < 0 {
                    let message = errorText(reader)
                    if message.localizedCaseInsensitiveContains("passphrase") || message.localizedCaseInsensitiveContains("decrypt") {
                        throw password == nil ? ArchiveError.encryptedArchive : ArchiveError.decryptionFailed
                    }
                    throw ArchiveError.damagedArchive(message)
                }
                written += Int64(n)
                if written > maximumBytes { throw ArchiveError.tooLarge }
                try handle.write(contentsOf: Data(buffer[0..<n]))
            }
            return target
        }
        throw ArchiveError.entryNotFound(path)
    }

    /// Writes ZIP or 7z. Level 1 favors speed, 9 favors size; passwords use ZIP AES-256.
    @discardableResult
    public static func create(from sources: [URL], to destination: URL, options: ArchiveCreationOptions,
                              isCancelled: () -> Bool = { false }) throws -> [URL] {
        if options.password != nil && options.format != .zip { throw ArchiveError.passwordUnsupportedForFormat }
        if let size = options.volumeSize, size < 1 << 20 { throw ArchiveError.invalidVolumeSize }
        let fm = FileManager.default
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".dirdesk-archive-\(UUID().uuidString)")
        guard let writer = archive_write_new() else { throw ArchiveError.writeFailed("archive_write_new") }
        defer { archive_write_free(writer) }
        let level = options.priority == .smaller ? "9" : "1"
        switch options.format {
        case .zip:
            archive_write_set_format_zip(writer)
            archive_write_set_options(writer, "zip:compression-level=\(level)")
            if let password = options.password, !password.isEmpty {
                archive_write_set_options(writer, "zip:encryption=aes256")
                archive_write_set_passphrase(writer, password)
            }
        case .sevenZip:
            archive_write_set_format_7zip(writer)
            archive_write_set_options(writer, "7zip:compression=lzma2,7zip:compression-level=\(level)")
        }
        guard archive_write_open_filename(writer, partial.path) == ARCHIVE_OK else {
            throw ArchiveError.writeFailed(errorText(writer))
        }
        var count = 0
        func add(_ url: URL, name: String) throws {
            if isCancelled() { throw ArchiveError.cancelled }
            count += 1
            guard count <= 65_535 || options.format != .zip else { throw ArchiveError.tooManyEntries }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { throw ArchiveError.symbolicLinkUnsupported }
            guard let entry = archive_entry_new() else { throw ArchiveError.writeFailed("entry") }
            defer { archive_entry_free(entry) }
            let isDirectory = values.isDirectory == true
            archive_entry_set_pathname_utf8(entry, isDirectory ? name + "/" : name)
            archive_entry_set_filetype(entry, UInt32(isDirectory ? AE_IFDIR : AE_IFREG))
            archive_entry_set_perm(entry, isDirectory ? 0o755 : 0o644)
            archive_entry_set_mtime(entry, time_t(values.contentModificationDate?.timeIntervalSince1970 ?? 0), 0)
            archive_entry_set_size(entry, isDirectory ? 0 : Int64(values.fileSize ?? 0))
            guard archive_write_header(writer, entry) == ARCHIVE_OK else { throw ArchiveError.writeFailed(errorText(writer)) }
            if isDirectory {
                let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.lastPathComponent != ".DS_Store" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { try add(child, name: name + "/" + child.lastPathComponent) }
            } else if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                    if isCancelled() { throw ArchiveError.cancelled }
                    let wrote = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, data.count) }
                    if wrote < 0 { throw ArchiveError.writeFailed(errorText(writer)) }
                }
            }
        }
        do {
            for source in sources { try add(source, name: source.lastPathComponent) }
            guard archive_write_close(writer) == ARCHIVE_OK else { throw ArchiveError.writeFailed(errorText(writer)) }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        let final = FileOperationCoordinator.keepBothURLIfNeeded(destination)
        guard let volumeSize = options.volumeSize else {
            try fm.moveItem(at: partial, to: final)
            return [final]
        }
        defer { try? fm.removeItem(at: partial) }
        return try split(partial, into: final, volumeSize: volumeSize)
    }

    /// Splits a finished archive into `name.001`, `name.002`… (7-Zip compatible).
    static func split(_ source: URL, into final: URL, volumeSize: Int64) throws -> [URL] {
        guard let input = try? FileHandle(forReadingFrom: source) else { throw ArchiveError.writeFailed(source.path) }
        defer { try? input.close() }
        var parts: [URL] = []
        var index = 1
        while true {
            guard let data = try input.read(upToCount: Int(volumeSize)), !data.isEmpty else { break }
            let part = URL(fileURLWithPath: String(format: "%@.%03d", final.path, index))
            try data.write(to: part)
            parts.append(part)
            index += 1
        }
        return parts
    }
}

extension FileOperationCoordinator {
    /// Returns `url` when free, otherwise the keep-both name.
    public static func keepBothURLIfNeeded(_ url: URL) -> URL {
        FileManager.default.fileExists(atPath: url.path) ? keepBothURL(for: url) : url
    }
}
