import Foundation

/// What a File Transit record stands for.
public enum FileTransitItemKind: String, Codable, CaseIterable, Sendable {
    /// A file referenced where it is, or a promised file received into managed storage.
    case file
    /// A folder referenced where it is, or a promised folder received into managed storage.
    case directory
    /// Dropped text, kept as a .txt file in managed storage.
    case text
    /// A dropped image, kept as an image file in managed storage.
    case image
    /// A dropped web link, kept as a .webloc file in managed storage.
    case link
}

/// One record on the File Transit shelf. A record either references an original file or folder
/// (`originalPath`, which File Transit never moves or deletes) or owns content in managed storage
/// (`managedPath`, deleted once the record is finally removed).
public struct FileTransitItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: FileTransitItemKind
    /// Items dropped together share a stack identifier.
    public var stackID: UUID
    /// Locked records survive "Clear Unlocked Items", "Export & Clear" and move drags.
    public var isLocked: Bool
    public var addedAt: Date
    /// File name of the original or of the managed file.
    public var name: String
    /// Absolute path of a referenced original.
    public var originalPath: String?
    /// `<UUID>/<file name>` below the managed-storage folder.
    public var managedPath: String?
    /// Bytes of managed content (0 for referenced originals); counts toward the storage limit.
    public var managedByteCount: Int64
    /// Address of a link record.
    public var linkURL: URL?
    /// Uniform type identifier, when known.
    public var contentType: String?

    public init(id: UUID = UUID(), kind: FileTransitItemKind, stackID: UUID, isLocked: Bool = false, addedAt: Date,
                name: String, originalPath: String? = nil, managedPath: String? = nil, managedByteCount: Int64 = 0,
                linkURL: URL? = nil, contentType: String? = nil) {
        self.id = id
        self.kind = kind
        self.stackID = stackID
        self.isLocked = isLocked
        self.addedAt = addedAt
        self.name = name
        self.originalPath = originalPath
        self.managedPath = managedPath
        self.managedByteCount = managedByteCount
        self.linkURL = linkURL
        self.contentType = contentType
    }

    public var isManaged: Bool { managedPath != nil }

    /// The file or folder that represents this record on disk. Built without touching the file system.
    public func fileURL(managedRoot: URL) -> URL? {
        if let originalPath {
            return URL(fileURLWithPath: originalPath, isDirectory: kind == .directory)
        }
        guard let managedPath, FileTransitRepository.isValidManagedPath(managedPath) else { return nil }
        let parts = managedPath.split(separator: "/")
        return managedRoot.appendingPathComponent(String(parts[0]), isDirectory: true)
            .appendingPathComponent(String(parts[1]), isDirectory: kind == .directory)
    }
}

/// Records that were dropped together, in shelf order.
public struct FileTransitStack: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var items: [FileTransitItem]

    public init(id: UUID, items: [FileTransitItem]) {
        self.id = id
        self.items = items
    }

    /// More than one record: shown as a stack tile with a count badge.
    public var isGroup: Bool { items.count > 1 }
    public var lockedCount: Int { items.filter(\.isLocked).count }
}

/// Shelf limits. The item count matches the original's default; the storage values are inferred
/// (the original does not reveal them) and sized for screenshots, photos and short clips.
public struct FileTransitLimits: Equatable, Sendable {
    /// Records on the shelf (the original's default is 500).
    public var maximumItemCount: Int
    /// Inferred: total size of content File Transit keeps itself (dropped text, images, links, received files),
    /// including content of removed records that can still be restored.
    public var maximumManagedBytes: Int64
    /// Inferred: largest single piece of content one drop may import.
    public var maximumImportBytes: Int64
    /// Inferred: how many removals "Restore Recently Removed" can step back through.
    public var maximumRemovedBatches: Int
    /// Inferred: removed records kept for restoring, across all removals.
    public var maximumRemovedItems: Int

    public init(maximumItemCount: Int, maximumManagedBytes: Int64, maximumImportBytes: Int64,
                maximumRemovedBatches: Int, maximumRemovedItems: Int) {
        self.maximumItemCount = maximumItemCount
        self.maximumManagedBytes = maximumManagedBytes
        self.maximumImportBytes = maximumImportBytes
        self.maximumRemovedBatches = maximumRemovedBatches
        self.maximumRemovedItems = maximumRemovedItems
    }

    public static let standard = FileTransitLimits(maximumItemCount: 500, maximumManagedBytes: 2 << 30, maximumImportBytes: 512 << 20,
                                                   maximumRemovedBatches: 20, maximumRemovedItems: 500)
}

public enum FileTransitError: Error, Equatable, Sendable {
    /// The shelf holds `maximumItemCount` records.
    case shelfFull
    /// Managed storage cannot take more content.
    case managedStorageFull
    /// One piece of content is larger than `maximumImportBytes`.
    case importLimitExceeded
    /// Missing files, empty text, undecodable images, non-web links.
    case unsupportedItem
    /// Writing managed content failed.
    case importFailed
    case itemMissing
    case stackMissing
    case nothingToRestore
    /// The saved data comes from a newer schema version; nothing may change.
    case readOnly
}

/// Something to put on the shelf.
public enum FileTransitSource: Sendable {
    /// A file or folder referenced where it is.
    case file(URL)
    case text(String)
    /// Image data and its type identifier when the pasteboard said which type it is.
    case image(Data, typeIdentifier: String?, name: String?)
    case link(URL, title: String?)
    /// A file that was just written into the incoming folder (a received file promise); it is moved into managed storage.
    case receivedFile(URL)
}

/// Fallback names for managed content without a usable name (the app passes localized names).
public struct FileTransitNaming: Sendable {
    public var text: String
    public var image: String
    public var file: String
    public var link: String

    public init(text: String = "Dropped Text", image: String = "Dropped Image", file: String = "Dropped File", link: String = "Web Link") {
        self.text = text
        self.image = image
        self.file = file
        self.link = link
    }
}

/// Result of one shelf operation.
public struct FileTransitChange: Equatable, Sendable {
    public var added: [UUID] = []
    public var removed: [UUID] = []
    public var restored: [UUID] = []
    /// One entry per source or request that failed.
    public var failures: [FileTransitError] = []
    /// References that were already on the shelf.
    public var skippedDuplicates = 0
    /// The change is in memory but could not be written to disk.
    public var saveFailed = false

    public init() {}
}
