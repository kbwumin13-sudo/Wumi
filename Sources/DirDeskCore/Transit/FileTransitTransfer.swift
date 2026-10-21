import Darwin
import Foundation

/// Outcome of copying records into a folder.
public struct FileTransitExportReport: Sendable {
    /// Where each exported record's copy was created.
    public var destinations: [UUID: URL] = [:]
    /// Records that could not be exported, with the reason.
    public var failures: [UUID: String] = [:]
    public var wasCancelled = false

    public init() {}

    public var exportedIDs: Set<UUID> { Set(destinations.keys) }
}

/// Copies File Transit records into a folder. Originals and managed content stay in place; a name that is
/// already taken gets the next free "name 2.ext" form. Runs synchronously: call it off the main thread.
public enum FileTransitExporter {
    public static func export(_ items: [FileTransitItem], managedRoot: URL, to directory: URL,
                              isCancelled: @escaping @Sendable () -> Bool = { false },
                              progress: ((_ completed: Int, _ total: Int) -> Void)? = nil) -> FileTransitExportReport {
        var report = FileTransitExportReport()
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            for item in items { report.failures[item.id] = FileOperationError.destinationNotDirectory.message }
            return report
        }
        let coordinator = FileOperationCoordinator()
        for (index, item) in items.enumerated() {
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            defer { progress?(index + 1, items.count) }
            var info = stat()
            guard let source = item.fileURL(managedRoot: managedRoot), lstat(source.path, &info) == 0 else {
                report.failures[item.id] = FileOperationError.sourceUnavailable(item.name).message
                continue
            }
            if FileOperationCoordinator.isInside(directory, source) {
                report.failures[item.id] = FileOperationError.sourceInsideItself.message
                continue
            }
            var destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: item.kind == .directory)
            if lstat(destination.path, &info) == 0 {
                destination = FileOperationCoordinator.keepBothURL(for: destination)
            }
            do {
                _ = try coordinator.copyItem(from: source, to: destination, isCancelled: isCancelled) { _ in }
                report.destinations[item.id] = destination
            } catch FileOperationCoordinator.CopyError.cancelled {
                report.wasCancelled = true
                break
            } catch {
                report.failures[item.id] = (error as NSError).localizedDescription
            }
        }
        return report
    }
}

/// Temporary stand-ins for a drag out of File Transit.
///
/// Each record is cloned (APFS `clonefile`, no extra space) into a temporary folder on the record's own volume and
/// the clone is what gets dragged. Whatever the destination does with it, move or copy, the original stays where
/// it is. When a record cannot be cloned (other file systems, read-only volumes) the original itself is offered and
/// the drag is limited to copying.
public struct FileTransitDragPreparation: Sendable {
    public struct File: Sendable, Equatable {
        public var itemID: UUID
        public var url: URL
        /// True when `url` is a temporary clone; false when it is the original.
        public var isTemporaryClone: Bool
        /// The clone's modification date when it was made; a later date means an app saved into it.
        public var cloneModificationDate: Date?
    }

    public var files: [File] = []
    /// Records whose file is missing.
    public var unavailableIDs: [UUID] = []
    /// Temporary folders to delete once the drag is over and the destination is done with the clones.
    public var temporaryFolders: [URL] = []

    public init() {}

    /// A move is only offered when every dragged file is a clone, so a moving destination never takes an original.
    public var allowsMove: Bool { !files.isEmpty && files.allSatisfy(\.isTemporaryClone) }
}

public enum FileTransitDragPreparer {
    /// Runs synchronously and touches every record's file: call it off the main thread.
    public static func prepare(_ items: [FileTransitItem], managedRoot: URL, fileManager: FileManager = .default) -> FileTransitDragPreparation {
        var preparation = FileTransitDragPreparation()
        // One temporary folder per volume; nil when the volume cannot hold one (read-only, unsupported).
        var folders: [dev_t: URL?] = [:]
        for item in items {
            var info = stat()
            guard let source = item.fileURL(managedRoot: managedRoot), lstat(source.path, &info) == 0 else {
                preparation.unavailableIDs.append(item.id)
                continue
            }
            if !folders.keys.contains(info.st_dev) {
                let folder = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: source, create: true)
                folders[info.st_dev] = folder
                if let folder { preparation.temporaryFolders.append(folder) }
            }
            let clone = (folders[info.st_dev] ?? nil).flatMap { cloneItem(source, itemID: item.id, into: $0, fileManager: fileManager) }
            let date = clone.flatMap(modificationDate(of:))
            preparation.files.append(.init(itemID: item.id, url: clone ?? source, isTemporaryClone: clone != nil, cloneModificationDate: date))
        }
        // Folders that ended up without a clone (cloning is not supported there) are removed right away.
        for folder in preparation.temporaryFolders {
            let prefix = folder.standardizedFileURL.path + "/"
            if !preparation.files.contains(where: { $0.isTemporaryClone && $0.url.standardizedFileURL.path.hasPrefix(prefix) }) {
                try? fileManager.removeItem(at: folder)
            }
        }
        preparation.temporaryFolders.removeAll { !fileManager.fileExists(atPath: $0.path) }
        return preparation
    }

    /// Deletes the temporary clones. Originals are never touched. A folder whose clone was changed after the drag
    /// (an app that opened the dropped file in place saved into it) is kept, so that work is not lost.
    public static func discard(_ preparation: FileTransitDragPreparation, fileManager: FileManager = .default) {
        for folder in preparation.temporaryFolders {
            let prefix = folder.standardizedFileURL.path + "/"
            let edited = preparation.files.contains { file in
                guard file.isTemporaryClone, file.url.standardizedFileURL.path.hasPrefix(prefix),
                      let now = modificationDate(of: file.url) else { return false }
                return now != file.cloneModificationDate
            }
            if !edited { try? fileManager.removeItem(at: folder) }
        }
    }

    /// Read with stat(2): URL resource values are cached per URL value and would hide a later save.
    private static func modificationDate(of url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    private static func cloneItem(_ source: URL, itemID: UUID, into folder: URL, fileManager: FileManager) -> URL? {
        let parent = folder.appendingPathComponent(itemID.uuidString, isDirectory: true)
        guard (try? fileManager.createDirectory(at: parent, withIntermediateDirectories: true)) != nil else { return nil }
        let target = parent.appendingPathComponent(source.lastPathComponent, isDirectory: source.hasDirectoryPath)
        guard clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            try? fileManager.removeItem(at: parent)
            return nil
        }
        return target
    }
}
