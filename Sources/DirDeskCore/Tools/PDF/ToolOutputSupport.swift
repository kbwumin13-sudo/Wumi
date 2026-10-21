import Darwin
import Foundation

/// Output handling shared by the PDF and image tools: sibling names that never collide, free-space
/// checks, and publishing a finished staging item without ever replacing an existing one.
enum ToolOutputSupport {
    /// Reports reserved paths as taken so outputs planned together get distinct keep-both names.
    private final class ReservingFileManager: FileManager {
        let reserved: Set<String>

        init(reserved: Set<String>) {
            self.reserved = reserved
            super.init()
        }

        override func fileExists(atPath path: String) -> Bool {
            reserved.contains(path) || super.fileExists(atPath: path)
        }
    }

    /// Longest file name (in UTF-8 bytes) the tools produce, leaving room for a keep-both suffix.
    static let maximumNameBytes = 230

    static func isTaken(_ url: URL, reserved: Set<String> = []) -> Bool {
        reserved.contains(url.path) || FileManager.default.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true
    }

    /// `desired` when it is free, otherwise its keep-both name ("name 2.ext"), skipping `reserved` paths.
    static func availableURL(for desired: URL, reserved: Set<String> = []) -> URL {
        guard isTaken(desired, reserved: reserved) else { return desired }
        guard !reserved.isEmpty else { return FileOperationCoordinator.keepBothURL(for: desired) }
        return FileOperationCoordinator.keepBothURL(for: desired, fileManager: ReservingFileManager(reserved: reserved))
    }

    /// "<base><suffix>.<ext>", shortening the base so the name stays within `maximumNameBytes`.
    static func fileName(base: String, suffix: String = "", extension ext: String) -> String {
        let tail = suffix + (ext.isEmpty ? "" : "." + ext)
        var trimmed = base
        while !trimmed.isEmpty && trimmed.utf8.count + tail.utf8.count > maximumNameBytes { trimmed.removeLast() }
        return trimmed + tail
    }

    static func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    static func isReadableFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }

    static func byteCount(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Free space for important usage, falling back to plain available capacity; nil when unknown.
    static func availableCapacity(of directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func removeIfPresent(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Moves `staged` to `desired`, or to the next keep-both name when it is taken. Uses
    /// `renamex_np(RENAME_EXCL)` so an item that appears concurrently is never replaced.
    static func publish(_ staged: URL, as desired: URL) throws -> URL {
        var candidate = availableURL(for: desired)
        for _ in 0..<32 {
            if renamex_np(staged.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let code = errno
            switch code {
            case EEXIST:
                candidate = FileOperationCoordinator.keepBothURL(for: desired)
            case ENOTSUP, EINVAL:
                // Some file systems lack exclusive renames; moveItem also refuses to replace an item.
                do {
                    try FileManager.default.moveItem(at: staged, to: candidate)
                    return candidate
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    candidate = FileOperationCoordinator.keepBothURL(for: desired)
                }
            default:
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        throw POSIXError(.EEXIST)
    }
}
