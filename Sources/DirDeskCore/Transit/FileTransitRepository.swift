import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// File Transit on disk: the versioned shelf document plus managed storage for content File Transit owns.
///
/// Layout below `rootURL` (by default `~/Library/Application Support/DirDesk/FileTransit/`):
/// - `FileTransit.json` — `{"schemaVersion": 1, "savedAt": …, "items": […], "removedBatches": […]}`
/// - `FileTransit.unreadable.json` — the last document that could not be read, kept for inspection
/// - `Managed/<UUID>/<file name>` — one folder per managed record (dropped text, images, links, received files)
/// - `Incoming/<UUID>/` — promised files while they are being received
///
/// Not thread-safe: use one instance from one queue at a time.
public final class FileTransitRepository: @unchecked Sendable {
    public static let schemaVersion = 1
    public static let documentName = "FileTransit.json"
    public static let unreadableDocumentName = "FileTransit.unreadable.json"

    public enum LoadResult: Equatable, Sendable {
        /// No document yet.
        case missing
        /// The document was read; `invalidRecords` damaged records were left out.
        case loaded(FileTransitShelf, invalidRecords: Int)
        /// The document could not be decoded; it was moved to `FileTransit.unreadable.json`.
        case unreadable
        /// A newer schema version wrote the document; it was left untouched.
        case newerVersion(Int)
    }

    struct Document: Codable {
        var schemaVersion: Int
        var savedAt: Date
        var items: [FileTransitItem]
        var removedBatches: [FileTransitShelf.RemovedBatch]
    }

    private struct Header: Decodable {
        var schemaVersion: Int
    }

    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public static var defaultRootURL: URL {
        ApplicationSupport.directory
            .appendingPathComponent("DirDesk", isDirectory: true)
            .appendingPathComponent("FileTransit", isDirectory: true)
    }

    public var documentURL: URL { rootURL.appendingPathComponent(Self.documentName, isDirectory: false) }
    public var unreadableDocumentURL: URL { rootURL.appendingPathComponent(Self.unreadableDocumentName, isDirectory: false) }
    public var managedRootURL: URL { rootURL.appendingPathComponent("Managed", isDirectory: true) }
    public var incomingRootURL: URL { rootURL.appendingPathComponent("Incoming", isDirectory: true) }

    // MARK: Document

    public func load() -> LoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: documentURL)
        } catch {
            return fileManager.fileExists(atPath: documentURL.path) ? setAsideUnreadableDocument() : .missing
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return setAsideUnreadableDocument() }
        guard header.schemaVersion <= Self.schemaVersion else { return .newerVersion(header.schemaVersion) }
        guard header.schemaVersion >= 1, let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return setAsideUnreadableDocument()
        }
        var invalid = 0
        var seen = Set<UUID>()
        func accept(_ item: FileTransitItem) -> Bool {
            guard Self.isValid(item), seen.insert(item.id).inserted else {
                invalid += 1
                return false
            }
            return true
        }
        let items = document.items.filter(accept)
        let batches: [FileTransitShelf.RemovedBatch] = document.removedBatches.compactMap { batch in
            var batch = batch
            batch.entries = batch.entries.filter { accept($0.item) && $0.index >= 0 }
            return batch.entries.isEmpty ? nil : batch
        }
        return .loaded(FileTransitShelf(items: items, removedBatches: batches), invalidRecords: invalid)
    }

    public func save(_ shelf: FileTransitShelf, at date: Date = Date()) throws {
        let document = Document(schemaVersion: Self.schemaVersion, savedAt: date, items: shelf.items, removedBatches: shelf.removedBatches)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try data.write(to: documentURL, options: .atomic)
    }

    private func setAsideUnreadableDocument() -> LoadResult {
        try? fileManager.removeItem(at: unreadableDocumentURL)
        try? fileManager.moveItem(at: documentURL, to: unreadableDocumentURL)
        return .unreadable
    }

    /// Records must point either at an absolute original path or at a well-formed managed path, never both.
    static func isValid(_ item: FileTransitItem) -> Bool {
        guard !item.name.isEmpty, item.managedByteCount >= 0 else { return false }
        switch (item.originalPath, item.managedPath) {
        case (let path?, nil):
            return path.hasPrefix("/") && item.managedByteCount == 0
        case (nil, let managed?):
            return isValidManagedPath(managed)
        default:
            return false
        }
    }

    /// `<UUID>/<name>` with a single plain file name, so deleting managed content can never leave managed storage.
    public static func isValidManagedPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else { return false }
        let name = String(parts[1])
        return !name.isEmpty && name != "." && name != ".." && !name.contains("\0")
    }

    // MARK: Managed storage

    /// Writes `data` to `Managed/<id>/<fileName>` and returns the managed path.
    func writeManaged(id: UUID, fileName: String, data: Data) throws -> String {
        let folder = managedRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try data.write(to: folder.appendingPathComponent(fileName, isDirectory: false), options: .withoutOverwriting)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return "\(id.uuidString)/\(fileName)"
    }

    /// Moves a received file or folder to `Managed/<id>/<fileName>` and returns the managed path.
    func adoptManaged(id: UUID, fileName: String, from source: URL) throws -> String {
        let folder = managedRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try fileManager.moveItem(at: source, to: folder.appendingPathComponent(fileName, isDirectory: false))
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return "\(id.uuidString)/\(fileName)"
    }

    /// Deletes the managed folders of records that were finally removed. Referenced originals are never touched.
    public func deleteManagedContent(of items: [FileTransitItem]) {
        for item in items {
            guard let managed = item.managedPath, Self.isValidManagedPath(managed),
                  let folderName = managed.split(separator: "/").first else { continue }
            let folder = managedRootURL.appendingPathComponent(String(folderName), isDirectory: true)
            guard folder.deletingLastPathComponent().standardizedFileURL.path == managedRootURL.standardizedFileURL.path else { continue }
            try? fileManager.removeItem(at: folder)
        }
    }

    /// A fresh folder below `Incoming/` to receive promised files into.
    public func makeIncomingFolder() throws -> URL {
        let folder = incomingRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Whether `url` lies inside the incoming folder.
    func isIncoming(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(incomingRootURL.standardizedFileURL.path + "/")
    }

    /// Removes the folder `url` sits in when it is an incoming folder that became empty.
    func removeIncomingFolderIfEmpty(containing url: URL) {
        let parent = url.deletingLastPathComponent()
        guard parent.deletingLastPathComponent().standardizedFileURL.path == incomingRootURL.standardizedFileURL.path else { return }
        rmdir(parent.path)
    }

    /// Clears files left in `Incoming/` by an interrupted receive.
    public func clearIncoming() {
        try? fileManager.removeItem(at: incomingRootURL)
    }

    // MARK: Content helpers

    /// A file name that is safe on APFS/HFS+: no slashes, colons or control characters, at most 200 UTF-8 bytes.
    public static func safeFileName(_ proposed: String, fallback: String, pathExtension: String? = nil) -> String {
        var base = proposed.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return String(scalar)
        }.joined()
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        if base.isEmpty { base = fallback }
        let suffix = pathExtension.map { $0.isEmpty ? "" : "." + $0 } ?? ""
        if !suffix.isEmpty, base.lowercased().hasSuffix(suffix.lowercased()) { base.removeLast(suffix.count) }
        var limited = ""
        for character in base {
            if limited.utf8.count + String(character).utf8.count + suffix.utf8.count > 200 { break }
            limited.append(character)
        }
        limited = limited.trimmingCharacters(in: .whitespaces)
        if limited.isEmpty { limited = fallback }
        return limited + suffix
    }

    /// Name for dropped text: its first non-empty line, shortened.
    static func textFileName(for text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let short = line.count > 60 ? String(line.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" : line
        return safeFileName(short, fallback: fallback, pathExtension: "txt")
    }

    /// Data and file extension to store for dropped image data. PNG, JPEG, GIF, HEIC/HEIF and WebP are kept as they
    /// are; other decodable formats (TIFF from the pasteboard, BMP, …) are converted to PNG. Returns nil for data
    /// that is not an image.
    static func storableImage(_ data: Data, typeIdentifier: String?) -> (data: Data, type: UTType)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let detected = (CGImageSourceGetType(source) as String?).flatMap(UTType.init) ?? typeIdentifier.flatMap(UTType.init)
        let kept: [UTType] = [.png, .jpeg, .gif, .heic, .heif, .webP]
        if let detected, kept.contains(detected) { return (data, detected) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, .png)
    }

    /// A `.webloc` property list for a web address.
    static func weblocData(for url: URL) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
    }

    /// Size of a file, or of a folder's contents (stops counting once `limit` is passed).
    func byteCount(of url: URL, limit: Int64) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        if (info.st_mode & S_IFMT) != S_IFDIR { return Int64(info.st_size) }
        var total: Int64 = 0
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let child = enumerator?.nextObject() as? URL {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            if total > limit { break }
        }
        return total
    }
}
