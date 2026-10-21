import Foundation
import UniformTypeIdentifiers

/// Stable identity of a file-system object, used to restore selections and to detect replacement.
public struct FileIdentity: Hashable, Codable, Sendable {
    public var volumeIdentifier: Data?
    public var resourceIdentifier: Data?
    public var fallbackPath: String
    public var fileSystemDevice: UInt64?
    public var fileSystemInode: UInt64?

    public init(volumeIdentifier: Data? = nil, resourceIdentifier: Data? = nil, fallbackPath: String,
                fileSystemDevice: UInt64? = nil, fileSystemInode: UInt64? = nil) {
        self.volumeIdentifier = volumeIdentifier
        self.resourceIdentifier = resourceIdentifier
        self.fallbackPath = fallbackPath
        self.fileSystemDevice = fileSystemDevice
        self.fileSystemInode = fileSystemInode
    }

    private enum CodingKeys: String, CodingKey {
        case volumeIdentifier, resourceIdentifier, fallbackPath, fileSystemDevice, fileSystemInode
    }

    /// Lenient decoding: identifiers stored in another representation are dropped, the path is kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeIdentifier = try? c.decodeIfPresent(Data.self, forKey: .volumeIdentifier)
        resourceIdentifier = try? c.decodeIfPresent(Data.self, forKey: .resourceIdentifier)
        fallbackPath = try c.decode(String.self, forKey: .fallbackPath)
        fileSystemDevice = try? c.decodeIfPresent(UInt64.self, forKey: .fileSystemDevice)
        fileSystemInode = try? c.decodeIfPresent(UInt64.self, forKey: .fileSystemInode)
    }

    public static func == (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        if let l = lhs.resourceIdentifier, let r = rhs.resourceIdentifier,
           let lv = lhs.volumeIdentifier, let rv = rhs.volumeIdentifier {
            return l == r && lv == rv
        }
        return lhs.fallbackPath == rhs.fallbackPath
    }

    public func hash(into hasher: inout Hasher) {
        if let resourceIdentifier, volumeIdentifier != nil {
            hasher.combine(resourceIdentifier)
        } else {
            hasher.combine(fallbackPath)
        }
    }
}

public enum FileCloudStatus: String, Codable, Sendable {
    case local, cloudOnly, downloading, synchronized, uploading, failed

    /// File Provider does not always emit a file-system event when a transfer finishes.
    public var needsStatusRefresh: Bool {
        self == .local || self == .downloading || self == .uploading
    }

    /// A local copy alone does not prove that the latest version has reached iCloud.
    static func resolve(isUbiquitous: Bool?, downloadingStatus: URLUbiquitousItemDownloadingStatus?,
                        isDownloading: Bool?, isUploading: Bool?, isUploaded: Bool?, hasError: Bool) -> Self? {
        guard isUbiquitous == true else { return nil }
        // iCloud can retain the previous attempt's error while a new transfer is actively progressing.
        // The live transfer flags take precedence; a stopped transfer with an error is a failure.
        if isDownloading == true { return .downloading }
        if isUploading == true { return .uploading }
        if hasError { return .failed }
        if downloadingStatus == .notDownloaded { return .cloudOnly }
        if downloadingStatus == .current, isUploaded == true { return .synchronized }
        return .local
    }
}

public enum FilePresentationRole: String, Codable, Sendable {
    case standard, navigationAlias
}

/// One directory entry with the metadata every view needs; loaded in a single resource-value pass.
public struct FileItem: Identifiable, Hashable, Sendable {
    public var id: FileIdentity
    public var url: URL
    public var name: String
    public var isDirectory: Bool
    public var isPackage: Bool
    public var isSymbolicLink: Bool
    public var isAliasFile: Bool
    public var size: Int64?
    public var allocatedSize: Int64?
    public var contentTypeIdentifier: String?
    public var localizedTypeDescription: String?
    public var modificationDate: Date?
    public var creationDate: Date?
    public var addedDate: Date?
    public var lastOpenedDate: Date?
    public var isHidden: Bool
    public var isReadable: Bool
    public var isWritable: Bool
    public var tags: [String]
    public var labelNumber: Int?
    public var cloudStatus: FileCloudStatus?
    public var presentationRole: FilePresentationRole

    public init(id: FileIdentity, url: URL, name: String, isDirectory: Bool, isPackage: Bool = false,
                isSymbolicLink: Bool = false, isAliasFile: Bool = false, size: Int64? = nil,
                allocatedSize: Int64? = nil, contentTypeIdentifier: String? = nil,
                localizedTypeDescription: String? = nil, modificationDate: Date? = nil,
                creationDate: Date? = nil, addedDate: Date? = nil, lastOpenedDate: Date? = nil,
                isHidden: Bool = false, isReadable: Bool = true, isWritable: Bool = true,
                tags: [String] = [], labelNumber: Int? = nil, cloudStatus: FileCloudStatus? = nil,
                presentationRole: FilePresentationRole = .standard) {
        self.id = id
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isAliasFile = isAliasFile
        self.size = size
        self.allocatedSize = allocatedSize
        self.contentTypeIdentifier = contentTypeIdentifier
        self.localizedTypeDescription = localizedTypeDescription
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.addedDate = addedDate
        self.lastOpenedDate = lastOpenedDate
        self.isHidden = isHidden
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.tags = tags
        self.labelNumber = labelNumber
        self.cloudStatus = cloudStatus
        self.presentationRole = presentationRole
    }

    /// Folders that browse as containers. Packages (apps, bundles) behave like files.
    public var isBrowsableFolder: Bool { isDirectory && !isPackage }

    /// Application document containers have a fixed on-disk name; their Drive title is a display alias.
    public var allowsRenaming: Bool {
        presentationRole != .navigationAlias && ICloudDriveDirectory.root(forApplicationDocuments: url) == nil
    }

    public var fileExtension: String { (name as NSString).pathExtension }

    public var contentType: UTType? { contentTypeIdentifier.flatMap(UTType.init) }

    public static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.name == rhs.name && lhs.size == rhs.size
            && lhs.modificationDate == rhs.modificationDate && lhs.tags == rhs.tags
            && lhs.isHidden == rhs.isHidden && lhs.lastOpenedDate == rhs.lastOpenedDate
            && lhs.cloudStatus == rhs.cloudStatus && lhs.presentationRole == rhs.presentationRole
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
