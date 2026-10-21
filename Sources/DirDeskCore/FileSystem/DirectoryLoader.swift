import Darwin
import Foundation
import UniformTypeIdentifiers

public enum DirectoryLoaderError: Error, Equatable {
    case notDirectory(String)
    case unavailable(String)
    case accessDenied(String)
}

/// Limits for one directory load. Local folders allow far more items than network volumes.
public struct DirectoryLoadingPolicy: Sendable {
    public var maximumItems: Int
    public var batchSize: Int

    public init(maximumItems: Int, batchSize: Int) {
        self.maximumItems = maximumItems
        self.batchSize = batchSize
    }

    public static let local = DirectoryLoadingPolicy(maximumItems: 100_000, batchSize: 400)
    public static let network = DirectoryLoadingPolicy(maximumItems: 20_000, batchSize: 128)
}

public struct DirectoryLoadResult: Sendable {
    public var items: [FileItem]
    /// True when the folder has more entries than the policy allowed.
    public var truncated: Bool
    /// True when Finder tags were not read yet (very large folders); call `DirectoryLoader.fillTags(_:)` later.
    public var tagsPending = false

    public init(items: [FileItem], truncated: Bool, tagsPending: Bool = false) {
        self.items = items
        self.truncated = truncated
        self.tagsPending = tagsPending
    }
}

/// Reads directory entries with one prefetched resource-value pass per item.
public enum DirectoryLoader {
    /// Keys prefetched for every item. The iCloud keys are only requested inside cloud folders: they cost about
    /// three times the rest put together, and with them macOS 27 also stops returning tag names.
    public static let localKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentTypeKey,
        .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey, .contentAccessDateKey,
        .isHiddenKey, .isReadableKey, .isWritableKey, .tagNamesKey, .labelNumberKey,
        .fileResourceIdentifierKey, .volumeIdentifierKey,
    ]
    public static let cloudKeys: [URLResourceKey] = [
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
        .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey,
    ]
    public static let resourceKeys: [URLResourceKey] = localKeys + cloudKeys

    /// iCloud Drive and File Provider folders (paths under ~/Library/Mobile Documents or ~/Library/CloudStorage).
    public static func isCloudLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasSuffix("/Library/Mobile Documents") || path.contains("/Library/Mobile Documents/")
            || path.hasSuffix("/Library/CloudStorage") || path.contains("/Library/CloudStorage/")
    }

    public static func keys(for directory: URL) -> [URLResourceKey] {
        isCloudLocation(directory) ? resourceKeys : localKeys
    }

    /// Refreshes only cloud metadata for the supplied candidates. Call off the main thread.
    /// Non-cloud items and failed reads are omitted; cancellation keeps results already read.
    public static func cloudStatuses(for urls: [URL], isCancelled: () -> Bool = { false }) -> [String: FileCloudStatus] {
        cloudStatuses(for: urls, isCancelled: isCancelled, resourceValuesReader: { url, keys in
            try url.resourceValues(forKeys: keys)
        })
    }

    /// The reader seam keeps metadata scope and cancellation testable without a live cloud account.
    static func cloudStatuses(for urls: [URL], isCancelled: () -> Bool = { false },
                              resourceValuesReader: (URL, Set<URLResourceKey>) throws -> URLResourceValues) -> [String: FileCloudStatus] {
        let keys = Set(cloudKeys)
        var statuses: [String: FileCloudStatus] = [:]
        for url in urls {
            if isCancelled() { break }
            let path = url.standardizedFileURL.path
            // Listed URLs can retain prefetched transfer flags. Rebuild from the path on every read.
            // Supplying isDirectory avoids a filesystem probe in the URL initializer.
            let freshURL = URL(fileURLWithPath: path, isDirectory: false)
            guard let values = try? resourceValuesReader(freshURL, keys) else { continue }
            if let status = FileCloudStatus.resolve(
                isUbiquitous: values.isUbiquitousItem, downloadingStatus: values.ubiquitousItemDownloadingStatus,
                isDownloading: values.ubiquitousItemIsDownloading, isUploading: values.ubiquitousItemIsUploading,
                isUploaded: values.ubiquitousItemIsUploaded,
                hasError: values.ubiquitousItemDownloadingError != nil || values.ubiquitousItemUploadingError != nil
            ) {
                statuses[path] = status
            }
        }
        return statuses
    }

    public static func makeItem(url: URL, values: URLResourceValues?) -> FileItem {
        let name = values?.name ?? url.lastPathComponent
        var device: UInt64?
        var inode: UInt64?
        var st = stat()
        let hasStat = lstat(url.path, &st) == 0
        if hasStat {
            device = UInt64(bitPattern: Int64(st.st_dev))
            inode = UInt64(st.st_ino)
        }
        let identity = FileIdentity(
            volumeIdentifier: values?.volumeIdentifier as? Data,
            resourceIdentifier: values?.fileResourceIdentifier as? Data,
            fallbackPath: url.path,
            fileSystemDevice: device,
            fileSystemInode: inode
        )
        let cloud = FileCloudStatus.resolve(
            isUbiquitous: values?.isUbiquitousItem, downloadingStatus: values?.ubiquitousItemDownloadingStatus,
            isDownloading: values?.ubiquitousItemIsDownloading, isUploading: values?.ubiquitousItemIsUploading,
            isUploaded: values?.ubiquitousItemIsUploaded,
            hasError: values?.ubiquitousItemDownloadingError != nil || values?.ubiquitousItemUploadingError != nil
        )
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        // macOS 27 returns no tag names when they are requested together with the iCloud keys; in cloud folders
        // tags are read straight from the extended attribute.
        var tags = values?.tagNames
        if tags == nil, isCloudLocation(url) { tags = FinderTagReader.tags(atPath: url.path) }
        return FileItem(
            id: identity,
            url: url,
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: values?.isSymbolicLink ?? false,
            isAliasFile: (values?.isAliasFile ?? false) && !(values?.isSymbolicLink ?? false),
            size: isDirectory ? nil : (values?.fileSize).map(Int64.init) ?? (hasStat ? Int64(st.st_size) : nil),
            allocatedSize: (values?.totalFileAllocatedSize).map(Int64.init),
            contentTypeIdentifier: values?.contentType?.identifier,
            modificationDate: values?.contentModificationDate,
            creationDate: values?.creationDate,
            addedDate: values?.addedToDirectoryDate,
            lastOpenedDate: values?.contentAccessDate,
            isHidden: (values?.isHidden ?? false) || name.hasPrefix("."),
            isReadable: values?.isReadable ?? true,
            isWritable: values?.isWritable ?? true,
            tags: tags ?? [],
            labelNumber: values?.labelNumber,
            cloudStatus: cloud
        )
    }

    public static func item(at url: URL) -> FileItem? {
        guard FileManager.default.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true else { return nil }
        let values = try? url.resourceValues(forKeys: Set(keys(for: url)))
        return makeItem(url: url, values: values)
    }

    /// Loads all direct children, hidden items included (views filter them). Runs synchronously; call off the main thread.
    public static func load(directory: URL, policy: DirectoryLoadingPolicy = .local,
                            isCancelled: () -> Bool = { false }) throws -> DirectoryLoadResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) else {
            throw DirectoryLoaderError.unavailable(directory.path)
        }
        guard isDir.boolValue else { throw DirectoryLoaderError.notDirectory(directory.path) }
        guard access(directory.path, R_OK | X_OK) == 0 else {
            throw DirectoryLoaderError.accessDenied(directory.path)
        }
        if !isCloudLocation(directory),
           var fast = FastDirectoryReader.read(directory, limit: policy.maximumItems, isCancelled: isCancelled) {
            // Tags need one extended-attribute read per item (about 30 µs each), so very large folders get them later.
            let deferTags = fast.items.count > tagInlineLimit
            if !deferTags { fillTags(&fast.items) }
            return DirectoryLoadResult(items: fast.items, truncated: fast.total > policy.maximumItems, tagsPending: deferTags)
        }
        let urls: [URL]
        let wanted = keys(for: directory)
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: wanted, options: [])
        } catch let error as NSError where error.code == NSFileReadNoPermissionError {
            throw DirectoryLoaderError.accessDenied(directory.path)
        } catch {
            throw DirectoryLoaderError.unavailable(directory.path)
        }
        let keys = Set(wanted)
        var items: [FileItem] = []
        items.reserveCapacity(min(urls.count, policy.maximumItems))
        for (index, url) in urls.enumerated() {
            if index % policy.batchSize == 0, isCancelled() { break }
            if items.count >= policy.maximumItems { break }
            items.append(makeItem(url: url, values: try? url.resourceValues(forKeys: keys)))
        }
        var total = urls.count
        if ICloudDriveDirectory.isRoot(directory), !isCancelled() {
            let applications = ICloudDriveDirectory.applicationFolders(in: directory, isCancelled: isCancelled)
            let existingPaths = Set(items.map { $0.url.standardizedFileURL.path })
            let additions = applications.filter { !existingPaths.contains($0.url.standardizedFileURL.path) }
            total += additions.count
            items.append(contentsOf: additions.prefix(max(0, policy.maximumItems - items.count)))
        }
        return DirectoryLoadResult(items: items, truncated: total > policy.maximumItems)
    }

    public static let tagInlineLimit = 10_000

    /// Reads Finder tags for items loaded without them.
    public static func fillTags(_ items: inout [FileItem], isCancelled: () -> Bool = { false }) {
        for index in items.indices {
            if index % 2000 == 0, isCancelled() { return }
            if let tags = FinderTagReader.tags(atPath: items[index].url.path, followLinks: items[index].isSymbolicLink) {
                items[index].tags = tags
            }
        }
    }

    /// Subfolders only, sorted for path-bar popovers.
    public static func subfolders(of directory: URL, includeHidden: Bool, limit: Int = 120) -> (folders: [URL], more: Bool) {
        if ICloudDriveDirectory.isRoot(directory), let result = try? load(directory: directory) {
            let folders = result.items.filter { $0.isBrowsableFolder && (includeHidden || !$0.isHidden) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return (Array(folders.prefix(limit).map(\.url)), result.truncated || folders.count > limit)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                       options: includeHidden ? [] : [.skipsHiddenFiles]) else {
            return ([], false)
        }
        let folders = urls.filter {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == true && v?.isPackage != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (Array(folders.prefix(limit)), folders.count > limit)
    }
}

/// Kind text for the Kind column, following the original: folders show a localized "Folder", aliases "Alias",
/// files the upper-cased preferred extension of their type (".jpg" shows "JPEG", ".tif" "TIFF"), and
/// extension-less files a generic "File".
public enum FileKindDescriber {
    public static func describe(_ item: FileItem, folderTitle: String, aliasTitle: String, fileTitle: String = "File") -> String {
        if item.isBrowsableFolder { return folderTitle }
        if item.isAliasFile { return aliasTitle }
        let ext = item.fileExtension
        guard !ext.isEmpty else { return fileTitle }
        return (UTType(filenameExtension: ext)?.preferredFilenameExtension ?? ext).uppercased()
    }
}

/// Reads Finder tag names from the `com.apple.metadata:_kMDItemUserTags` extended attribute
/// (a binary plist of "Name\nlabel" strings).
public enum FinderTagReader {
    public static func tags(atPath path: String, followLinks: Bool = false) -> [String]? {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let options: Int32 = followLinks ? 0 : XATTR_NOFOLLOW
        let size = getxattr(path, name, nil, 0, 0, options)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, options) }
        guard read > 0, let list = try? PropertyListSerialization.propertyList(from: data.prefix(read), format: nil) as? [String] else { return nil }
        return list.map { $0.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? $0 }
    }
}
