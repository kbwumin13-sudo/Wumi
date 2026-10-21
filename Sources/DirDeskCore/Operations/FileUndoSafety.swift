import Darwin
import Foundation

/// What an item looked like when DirDesk last changed it, to notice changes made elsewhere before undoing.
/// Files compare volume, file ID, size and modification time; folders compare volume and file ID only, so adding
/// files to a new folder does not block undoing its creation.
public struct FileFingerprint: Equatable, Sendable {
    public var device: Int64
    public var inode: UInt64
    public var size: Int64
    public var modified: TimeInterval
    public var isDirectory: Bool

    public init(device: Int64, inode: UInt64, size: Int64, modified: TimeInterval, isDirectory: Bool) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
    }

    /// The item at `url` itself (a symbolic link is not followed), or nil when nothing is there.
    public static func of(_ url: URL) -> FileFingerprint? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileFingerprint(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: modified,
                               isDirectory: (info.st_mode & S_IFMT) == S_IFDIR)
    }

    public func matches(_ other: FileFingerprint) -> Bool {
        guard device == other.device, inode == other.inode, isDirectory == other.isDirectory else { return false }
        return isDirectory || (size == other.size && modified == other.modified)
    }
}

/// One step of undoing or redoing a file change: move the item at `from` to `to`, or move it to the Trash.
public struct FileUndoStep: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case move(to: URL)
        case trash
        /// Create an empty folder at `from`.
        case createFolder
        /// Remove the folder at `from` if it is empty (a `.DS_Store` aside) when the step runs.
        case removeEmptyFolder
    }

    public var from: URL
    public var action: Action
    /// The item at `from` as DirDesk left it; nil skips the comparison.
    public var expected: FileFingerprint?

    public init(from: URL, action: Action, expected: FileFingerprint?) {
        self.from = from
        self.action = action
        self.expected = expected
    }

    public static func move(_ from: URL, to: URL) -> FileUndoStep {
        FileUndoStep(from: from, action: .move(to: to), expected: FileFingerprint.of(from))
    }

    public static func trash(_ url: URL) -> FileUndoStep {
        FileUndoStep(from: url, action: .trash, expected: FileFingerprint.of(url))
    }

    public static func createFolder(_ url: URL) -> FileUndoStep {
        FileUndoStep(from: url, action: .createFolder, expected: nil)
    }

    public static func removeEmptyFolder(_ url: URL) -> FileUndoStep {
        FileUndoStep(from: url, action: .removeEmptyFolder, expected: nil)
    }

    /// Undo of collecting items into a new folder or dissolving a folder: items return, and the folder is removed
    /// again (collect, when empty) or recreated first (dissolve).
    public static func undoing(_ transaction: FolderOrganizationService.Transaction) -> [FileUndoStep] {
        let moves = transaction.moves.reversed().map { FileUndoStep.move($0.to, to: $0.from) }
        return transaction.createdFolder ? moves + [.removeEmptyFolder(transaction.folder)] : [.createFolder(transaction.folder)] + moves
    }
}

/// Why an undo or redo was not started. Nothing has been changed when one of these is reported.
public enum FileUndoStop: Error, Equatable, Sendable {
    /// The item to put back is gone.
    case missing(String)
    /// Something else now uses the name the item would return to.
    case occupied(String)
    /// The item was modified after DirDesk changed it.
    case changed(String)
}

public enum FileUndoSafety {
    /// Checks every step before any runs, in order, treating places that earlier steps vacate as free.
    public static func verify(_ steps: [FileUndoStep]) -> FileUndoStop? {
        var vacated = Set<String>()
        var filled = Set<String>()
        for step in steps {
            let fromPath = step.from.standardizedFileURL.path
            let name = step.from.lastPathComponent
            if step.action == .createFolder {
                if !vacated.contains(fromPath), FileFingerprint.of(step.from) != nil { return .occupied(name) }
                vacated.remove(fromPath)
                filled.insert(fromPath)
                continue
            }
            if step.action == .removeEmptyFolder { continue }
            if !filled.contains(fromPath) {
                guard let current = FileFingerprint.of(step.from) else { return .missing(name) }
                if let expected = step.expected, !current.matches(expected) { return .changed(name) }
            }
            vacated.insert(fromPath)
            filled.remove(fromPath)
            if case .move(let destination) = step.action {
                let toPath = destination.standardizedFileURL.path
                if !vacated.contains(toPath), let occupant = FileFingerprint.of(destination) {
                    // A case-only rename finds the item itself under the new name.
                    let isSameItem = FileFingerprint.of(step.from).map { $0.device == occupant.device && $0.inode == occupant.inode } ?? false
                    if !isSameItem { return .occupied(destination.lastPathComponent) }
                }
                vacated.remove(toPath)
                filled.insert(toPath)
            }
        }
        return nil
    }

    /// Runs verified steps and returns the steps that reverse them, in the order they must run. When a step fails,
    /// the steps already done are put back before the error is rethrown.
    public static func perform(_ steps: [FileUndoStep], fileManager: FileManager = .default) throws -> [FileUndoStep] {
        var done: [FileUndoStep] = []
        do {
            for step in steps {
                if let reverse = try run(step, fileManager: fileManager) { done.append(reverse) }
            }
        } catch {
            for step in done.reversed() { _ = try? run(step, fileManager: fileManager) }
            throw error
        }
        return done.reversed()
    }

    /// Runs one step and returns the step that reverses it (nil when the step had nothing to do).
    private static func run(_ step: FileUndoStep, fileManager: FileManager) throws -> FileUndoStep? {
        switch step.action {
        case .createFolder:
            try fileManager.createDirectory(at: step.from, withIntermediateDirectories: true)
            return .removeEmptyFolder(step.from)
        case .removeEmptyFolder:
            let contents = (try? fileManager.contentsOfDirectory(atPath: step.from.path)) ?? ["?"]
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return nil }
            try fileManager.removeItem(at: step.from)
            return .createFolder(step.from)
        case .move(let destination):
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: step.from, to: destination)
            return .move(destination, to: step.from)
        case .trash:
            var resulting: NSURL?
            try fileManager.trashItem(at: step.from, resultingItemURL: &resulting)
            guard let trashed = resulting as URL? else { throw CocoaError(.fileWriteUnknown) }
            return .move(trashed, to: step.from)
        }
    }
}
