import Darwin
import Foundation

public enum FileConflictResolution: String, Codable, Sendable {
    case replace, keepBoth, skip, stop
}

public enum FileOperationKind: String, Codable, Sendable {
    case copy, move
}

public enum FileOperationPhase: String, Codable, Sendable {
    case preparing, copying, moving, committing, deletingSource, completed, cancelled, failed
}

public struct FileOperationPlan: Identifiable, Sendable {
    public var id: UUID
    public var kind: FileOperationKind
    public var sources: [URL]
    public var destinationDirectory: URL
    /// nil asks the conflict handler for each conflict.
    public var conflictResolution: FileConflictResolution?
    public var retainsReplacementForUndo: Bool

    public init(id: UUID = UUID(), kind: FileOperationKind, sources: [URL], destination: URL,
                conflictResolution: FileConflictResolution? = nil, retainsReplacementForUndo: Bool = true) {
        self.id = id
        self.kind = kind
        self.sources = sources
        self.destinationDirectory = destination
        self.conflictResolution = conflictResolution
        self.retainsReplacementForUndo = retainsReplacementForUndo
    }
}

public struct FileOperationProgress: Sendable {
    public var planID: UUID
    public var kind: FileOperationKind
    public var phase: FileOperationPhase
    public var processedItemCount: Int
    public var totalItemCount: Int
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var currentSource: URL?
}

public struct FileOperationMutation: Sendable {
    public enum Kind: String, Sendable { case copied, moved }
    public var kind: Kind
    public var source: URL
    public var destination: URL
    /// Item that was replaced, kept here so undo can put it back.
    public var replacedBackupURL: URL?
}

public struct FileOperationFailure: Sendable {
    public var source: URL
    public var message: String
}

public struct FileOperationReport: Sendable {
    public var planID: UUID
    public var mutations: [FileOperationMutation] = []
    public var skipped: [URL] = []
    public var failures: [FileOperationFailure] = []
    public var wasCancelled = false

    public var createdURLs: [URL] { mutations.map(\.destination) }
}

public enum FileOperationError: Error, Equatable, Sendable {
    case emptySources
    case destinationNotDirectory
    case sourceInsideItself
    case directoryReplaceNotSupported
    case sourceUnavailable(String)
    case destinationNotWritable(String)
    case insufficientSpace(available: Int64, needed: Int64)

    public var message: String {
        switch self {
        case .emptySources: "No readable file or folder was provided."
        case .destinationNotDirectory: "The destination is not a folder."
        case .sourceInsideItself: "A folder cannot be copied or moved into itself."
        case .directoryReplaceNotSupported: "Replacing an existing folder is not supported."
        case .sourceUnavailable(let path): "The source is unavailable: \(path)"
        case .destinationNotWritable(let path): "The destination is not writable: \(path)"
        case .insufficientSpace(let available, let needed):
            "The destination has \(available) bytes available but the operation needs about \(needed) bytes."
        }
    }
}

/// Copy and move engine. Copies use copyfile(3) into a hidden partial name and publish atomically.
public final class FileOperationCoordinator: @unchecked Sendable {
    public typealias ConflictHandler = @Sendable (_ source: URL, _ existing: URL) async -> (FileConflictResolution, applyToAll: Bool)
    public typealias ProgressHandler = @Sendable (FileOperationProgress) -> Void

    public init() {}

    /// "Name 2.ext", "Name 3.ext"… up to 10000, then a UUID suffix; matches the original's keep-both naming.
    public static func keepBothURL(for url: URL, fileManager: FileManager = .default) -> URL {
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        func candidate(_ suffix: String) -> URL {
            directory.appendingPathComponent(ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)")
        }
        for n in 2...10_000 {
            let url = candidate(String(n))
            if !fileManager.fileExists(atPath: url.path) && (try? url.checkResourceIsReachable()) != true { return url }
        }
        return candidate(UUID().uuidString)
    }

    public static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.standardizedFileURL.path, p = parent.standardizedFileURL.path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard lstat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev
    }

    static func totalBytes(of urls: [URL], limit: Int = 200_000) -> Int64 {
        var total: Int64 = 0
        var count = 0
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                continue
            }
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
            while let child = enumerator?.nextObject() as? URL {
                count += 1
                if count > limit { return total }
                let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
            }
        }
        return total
    }

    public func run(_ plan: FileOperationPlan, conflictHandler: ConflictHandler, progress: @escaping ProgressHandler,
                    isCancelled: @escaping @Sendable () -> Bool) async -> FileOperationReport {
        var report = FileOperationReport(planID: plan.id)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard !plan.sources.isEmpty else {
            report.failures.append(.init(source: plan.destinationDirectory, message: FileOperationError.emptySources.message))
            return report
        }
        guard fm.fileExists(atPath: plan.destinationDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            report.failures.append(.init(source: plan.destinationDirectory, message: FileOperationError.destinationNotDirectory.message))
            return report
        }
        guard fm.isWritableFile(atPath: plan.destinationDirectory.path) else {
            report.failures.append(.init(source: plan.destinationDirectory,
                                         message: FileOperationError.destinationNotWritable(plan.destinationDirectory.path).message))
            return report
        }

        var current = FileOperationProgress(planID: plan.id, kind: plan.kind, phase: .preparing, processedItemCount: 0,
                                            totalItemCount: plan.sources.count, completedBytes: 0, totalBytes: nil, currentSource: nil)
        progress(current)
        let crossVolume = plan.sources.filter { !Self.sameVolume($0, plan.destinationDirectory) }
        let needsCopy = plan.kind == .copy ? plan.sources : crossVolume
        let total = Self.totalBytes(of: needsCopy)
        current.totalBytes = total
        if total > 0, let values = try? plan.destinationDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage, available < total,
           plan.sources.allSatisfy({ !Self.sameVolume($0, plan.destinationDirectory) || plan.kind == .copy }) {
            report.failures.append(.init(source: plan.destinationDirectory,
                                         message: FileOperationError.insufficientSpace(available: available, needed: total).message))
            return report
        }

        var sticky: FileConflictResolution? = plan.conflictResolution
        var bytesDone: Int64 = 0
        for source in plan.sources {
            if isCancelled() {
                report.wasCancelled = true
                break
            }
            current.currentSource = source
            current.phase = plan.kind == .copy ? .copying : .moving
            progress(current)
            guard fm.fileExists(atPath: source.path) || (try? source.checkResourceIsReachable()) == true else {
                report.failures.append(.init(source: source, message: FileOperationError.sourceUnavailable(source.path).message))
                continue
            }
            if Self.isInside(plan.destinationDirectory, source) {
                report.failures.append(.init(source: source, message: FileOperationError.sourceInsideItself.message))
                continue
            }
            var destination = plan.destinationDirectory.appendingPathComponent(source.lastPathComponent)
            let sameParent = source.deletingLastPathComponent().standardizedFileURL == plan.destinationDirectory.standardizedFileURL
            if sameParent && plan.kind == .move {
                report.skipped.append(source)
                continue
            }
            var replacedBackup: URL?
            // Pasting into the item's own folder asks too, as in the original; "Replace" then has nothing to do.
            if fm.fileExists(atPath: destination.path) || (try? destination.checkResourceIsReachable()) == true {
                var decision = sticky
                if decision == nil {
                    let answer = await conflictHandler(source, destination)
                    decision = answer.0
                    if answer.applyToAll { sticky = answer.0 }
                }
                switch decision ?? .stop {
                case .skip:
                    report.skipped.append(source)
                    current.processedItemCount += 1
                    continue
                case .stop:
                    report.wasCancelled = true
                    current.phase = .cancelled
                    progress(current)
                    return report
                case .keepBoth:
                    destination = Self.keepBothURL(for: destination)
                case .replace where sameParent:
                    report.skipped.append(source)
                    current.processedItemCount += 1
                    continue
                case .replace:
                    var existingIsDirectory: ObjCBool = false
                    fm.fileExists(atPath: destination.path, isDirectory: &existingIsDirectory)
                    if existingIsDirectory.boolValue {
                        report.failures.append(.init(source: source, message: FileOperationError.directoryReplaceNotSupported.message))
                        continue
                    }
                    let backup = plan.destinationDirectory.appendingPathComponent(".dirdesk-replaced-\(UUID().uuidString)-\(destination.lastPathComponent)")
                    do {
                        try fm.moveItem(at: destination, to: backup)
                        replacedBackup = backup
                    } catch {
                        report.failures.append(.init(source: source, message: error.localizedDescription))
                        continue
                    }
                }
            }

            do {
                if plan.kind == .move && Self.sameVolume(source, plan.destinationDirectory) {
                    try fm.moveItem(at: source, to: destination)
                    report.mutations.append(.init(kind: .moved, source: source, destination: destination, replacedBackupURL: replacedBackup))
                } else {
                    let base = bytesDone
                    let copied = try copyItem(from: source, to: destination, isCancelled: isCancelled) { bytes in
                        current.completedBytes = base + bytes
                        progress(current)
                    }
                    bytesDone += copied
                    if plan.kind == .move {
                        current.phase = .deletingSource
                        progress(current)
                        try fm.removeItem(at: source)
                        report.mutations.append(.init(kind: .moved, source: source, destination: destination, replacedBackupURL: replacedBackup))
                    } else {
                        report.mutations.append(.init(kind: .copied, source: source, destination: destination, replacedBackupURL: replacedBackup))
                    }
                }
                if let replacedBackup, !plan.retainsReplacementForUndo { try? fm.removeItem(at: replacedBackup) }
            } catch CopyError.cancelled {
                if let replacedBackup { try? fm.moveItem(at: replacedBackup, to: destination) }
                report.wasCancelled = true
                break
            } catch {
                if let replacedBackup, !fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: replacedBackup, to: destination) }
                report.failures.append(.init(source: source, message: (error as NSError).localizedDescription))
            }
            current.processedItemCount += 1
            current.completedBytes = bytesDone
            progress(current)
        }
        current.phase = report.wasCancelled ? .cancelled : .completed
        progress(current)
        return report
    }

    enum CopyError: Error { case cancelled, failed(Int32) }

    private final class CopyContext {
        let isCancelled: @Sendable () -> Bool
        let onBytes: (Int64) -> Void
        var lastReported: Int64 = 0
        var accumulated: Int64 = 0
        var currentFileBytes: Int64 = 0
        init(isCancelled: @escaping @Sendable () -> Bool, onBytes: @escaping (Int64) -> Void) {
            self.isCancelled = isCancelled
            self.onBytes = onBytes
        }
    }

    /// copyfile(3) with ALL|RECURSIVE|EXCL|NOFOLLOW|CLONE into a partial name, then rename into place.
    func copyItem(from source: URL, to destination: URL, isCancelled: @escaping @Sendable () -> Bool,
                  onBytes: @escaping (Int64) -> Void) throws -> Int64 {
        let partial = destination.deletingLastPathComponent().appendingPathComponent(".dirdesk-partial-\(UUID().uuidString)")
        let context = CopyContext(isCancelled: isCancelled, onBytes: onBytes)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { what, stage, state, _, _, ctx in
            guard let ctx else { return COPYFILE_CONTINUE }
            let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
            if context.isCancelled() { return COPYFILE_QUIT }
            if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                context.currentFileBytes = Int64(copied)
                let total = context.accumulated + context.currentFileBytes
                if total - context.lastReported > 1_048_576 {
                    context.lastReported = total
                    context.onBytes(total)
                }
            } else if what == COPYFILE_COPY_DATA && stage == COPYFILE_FINISH {
                context.accumulated += context.currentFileBytes
                context.currentFileBytes = 0
            }
            return COPYFILE_CONTINUE
        }
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), unmanaged.toOpaque())
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW | COPYFILE_CLONE)
        let result = copyfile(source.path, partial.path, state, flags)
        if result != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: partial)
            if context.isCancelled() || code == ECANCELED { throw CopyError.cancelled }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        let total = context.accumulated + context.currentFileBytes
        onBytes(total)
        return total
    }
}
