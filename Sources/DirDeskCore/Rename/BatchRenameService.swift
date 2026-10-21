import Darwin
import Foundation

/// Plans and runs batch renames. A run is two-phase: every source first moves to a hidden temporary name in its folder,
/// then every temporary moves to its final name. That makes swaps and cycles (a→b, b→a) work, and a failure part-way
/// puts every name back.
public enum BatchRenameService {
    static let temporaryPrefix = ".dirdesk-rename-"

    /// The name `rules` produce for `name`; `index` is the item's position in the selection, used by sequence rules.
    public static func proposedName(for name: String, at index: Int, rules: [BatchRenameRule]) throws -> String {
        apply(try compile(rules), to: name, index: index)
    }

    /// One preview per source, in the given order. Problems with single items are reported on the previews;
    /// limits and an invalid regular expression throw.
    public static func plan(sources: [URL], rules: [BatchRenameRule], limits: BatchRenameLimits = .default) throws -> [BatchRenamePreview] {
        guard sources.count <= limits.maximumSelectionCount else {
            throw BatchRenameError.selectionLimitExceeded(count: sources.count, limit: limits.maximumSelectionCount)
        }
        guard sources.count <= limits.maximumPlannedItems else { throw BatchRenameError.itemLimitExceeded }
        let compiled = try compile(rules)
        let deadline = Deadline(seconds: limits.maximumPlanningDuration)

        var previews: [BatchRenamePreview] = []
        previews.reserveCapacity(sources.count)
        for (index, source) in sources.enumerated() {
            try deadline.check()
            let name = source.lastPathComponent
            let newName = apply(compiled, to: name, index: index)
            let destination = newName == name ? source : source.deletingLastPathComponent().appendingPathComponent(newName)
            var preview = BatchRenamePreview(source: source, destination: destination, destinationName: newName)
            if identity(of: source) == nil {
                preview.error = .sourceUnavailable
            } else if !isValidName(newName) {
                preview.error = .invalidName
            }
            previews.append(preview)
        }

        // Unchanged items keep their names, so they take part in the duplicate check too.
        var claims: [String: [Int]] = [:]
        for (index, preview) in previews.enumerated() where preview.error != .invalidName {
            claims[key(directory: preview.source, name: preview.destinationName), default: []].append(index)
        }
        for indices in claims.values where indices.count > 1 {
            for index in indices where previews[index].error == nil { previews[index].error = .duplicateDestination }
        }

        // An existing destination is only acceptable when it is one of the sources being renamed away,
        // which includes the item itself on a case-insensitive volume (Foo.txt → foo.txt).
        var renamedAway: [String: FileID] = [:]
        for preview in previews where !preview.isUnchanged {
            if let id = identity(of: preview.source) {
                renamedAway[key(directory: preview.source, name: preview.source.lastPathComponent)] = id
            }
        }
        for index in previews.indices where previews[index].error == nil && !previews[index].isUnchanged {
            try deadline.check()
            let preview = previews[index]
            guard let existing = identity(of: preview.destination) else { continue }
            if renamedAway[key(directory: preview.source, name: preview.destinationName)] != existing {
                previews[index].error = .destinationExists
            }
        }
        return previews
    }

    /// Renames every changed preview. Throws `invalidPlan` when any preview carries an error.
    @discardableResult
    public static func execute(_ previews: [BatchRenamePreview], limits: BatchRenameLimits = .default) throws -> BatchRenameTransaction {
        guard previews.allSatisfy({ $0.error == nil }) else { throw BatchRenameError.invalidPlan }
        let operations = previews.filter { !$0.isUnchanged }.map { BatchRenameOperation(source: $0.source, destination: $0.destination) }
        return try run(operations, limits: limits)
    }

    /// Applies the transaction's inverse with the same two-phase method and returns it, so it can itself be undone.
    @discardableResult
    public static func undo(_ transaction: BatchRenameTransaction, limits: BatchRenameLimits = .default) throws -> BatchRenameTransaction {
        try run(transaction.inverse.operations, limits: limits)
    }

    // MARK: - Execution

    private struct StagedRename {
        let operation: BatchRenameOperation
        let temporary: URL
        var isCommitted = false
    }

    static func run(_ operations: [BatchRenameOperation], limits: BatchRenameLimits) throws -> BatchRenameTransaction {
        guard operations.count <= limits.maximumExecutedItems else { throw BatchRenameError.itemLimitExceeded }
        try validate(operations)
        for operation in operations where identity(of: operation.source) == nil {
            throw BatchRenameError.sourceUnavailable(operation.source)
        }

        let fm = FileManager.default
        let deadline = Deadline(seconds: limits.maximumExecutionDuration)
        var stages: [StagedRename] = []
        stages.reserveCapacity(operations.count)
        do {
            for operation in operations {
                try deadline.check()
                let temporary = operation.source.deletingLastPathComponent().appendingPathComponent(temporaryPrefix + UUID().uuidString)
                try fm.moveItem(at: operation.source, to: temporary)
                stages.append(StagedRename(operation: operation, temporary: temporary))
            }
            for index in stages.indices {
                try deadline.check()
                let destination = stages[index].operation.destination
                guard identity(of: destination) == nil else { throw BatchRenameError.destinationExists(destination) }
                do {
                    try fm.moveItem(at: stages[index].temporary, to: destination)
                } catch CocoaError.fileWriteFileExists {
                    throw BatchRenameError.destinationExists(destination)
                }
                stages[index].isCommitted = true
            }
        } catch {
            guard rollBack(stages) else { throw BatchRenameError.rollbackFailed }
            throw error
        }
        return BatchRenameTransaction(operations: operations)
    }

    /// Committed items go back to their temporary names first, so a source name another item has just taken is free
    /// again; then every temporary returns to its source.
    private static func rollBack(_ stages: [StagedRename]) -> Bool {
        let fm = FileManager.default
        var succeeded = true
        var restorable: [StagedRename] = []
        for stage in stages.reversed() {
            if stage.isCommitted {
                do {
                    try fm.moveItem(at: stage.operation.destination, to: stage.temporary)
                } catch {
                    succeeded = false
                    continue
                }
            }
            restorable.append(stage)
        }
        for stage in restorable {
            do {
                try fm.moveItem(at: stage.temporary, to: stage.operation.source)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    /// Re-validates operations that may not come from `plan`, such as a stored transaction being undone.
    private static func validate(_ operations: [BatchRenameOperation]) throws {
        var sources = Set<String>()
        var destinations = Set<String>()
        for operation in operations {
            let name = operation.destination.lastPathComponent
            guard isValidName(name),
                  operation.destination.deletingLastPathComponent().standardizedFileURL.path
                    == operation.source.deletingLastPathComponent().standardizedFileURL.path else {
                throw BatchRenameError.invalidDestination
            }
            guard sources.insert(operation.source.standardizedFileURL.path).inserted,
                  destinations.insert(key(directory: operation.source, name: name)).inserted else {
                throw BatchRenameError.invalidPlan
            }
        }
    }

    // MARK: - Rules

    private enum CompiledRule {
        case prefix(String)
        case suffix(String)
        case replace(String, String)
        case regularExpression(NSRegularExpression, String)
        case fileExtension(String)
        case sequence(start: Int, width: Int, separator: String, leading: Bool)
        case lowercase, uppercase
    }

    private static func compile(_ rules: [BatchRenameRule]) throws -> [CompiledRule] {
        try rules.map { rule in
            switch rule {
            case .addPrefix(let prefix):
                return .prefix(prefix)
            case .addSuffix(let suffix):
                return .suffix(suffix)
            case .replace(let target, let replacement):
                return .replace(target, replacement)
            case .regularExpression(let pattern, let replacement):
                guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
                    throw BatchRenameError.invalidRegularExpression
                }
                return .regularExpression(expression, replacement)
            case .replaceExtension(let newExtension):
                return .fileExtension(newExtension.hasPrefix(".") ? String(newExtension.dropFirst()) : newExtension)
            case .prependSequence(let start, let width, let separator):
                return .sequence(start: start, width: width, separator: separator, leading: true)
            case .sequence(let start, let width, let separator):
                return .sequence(start: start, width: width, separator: separator, leading: false)
            case .lowercase:
                return .lowercase
            case .uppercase:
                return .uppercase
            }
        }
    }

    private static func apply(_ rules: [CompiledRule], to name: String, index: Int) -> String {
        var base = (name as NSString).deletingPathExtension
        var fileExtension = (name as NSString).pathExtension
        for rule in rules {
            switch rule {
            case .prefix(let prefix):
                base = prefix + base
            case .suffix(let suffix):
                base += suffix
            case .replace(let target, let replacement):
                base = base.replacingOccurrences(of: target, with: replacement, options: [])
            case .regularExpression(let expression, let template):
                base = expression.stringByReplacingMatches(in: base, options: [], range: NSRange(location: 0, length: (base as NSString).length),
                                                           withTemplate: template)
            case .fileExtension(let newExtension):
                fileExtension = newExtension
            case .sequence(let start, let width, let separator, let leading):
                // "%0*d" with a 64-bit argument; the width is capped because longer names are invalid anyway.
                let number = String(format: "%0*ld", Int32(min(max(width, 0), 255)), start &+ index)
                base = leading ? number + separator + base : base + separator + number
            case .lowercase:
                base = base.lowercased()
            case .uppercase:
                base = base.uppercased()
            }
        }
        return fileExtension.isEmpty ? base : base + "." + fileExtension
    }

    // MARK: - Helpers

    /// Rejects names no file system accepts: empty, "." and "..", "/" or ":", NUL, and more than 255 UTF-8 bytes.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") && !name.contains("\0")
            && name.utf8.count <= 255
    }

    /// Folder plus NFC-normalized, lowercased name: two names with the same key cannot coexist on a case-insensitive volume.
    private static func key(directory item: URL, name: String) -> String {
        item.deletingLastPathComponent().standardizedFileURL.path + "/" + name.precomposedStringWithCanonicalMapping.lowercased()
    }

    struct FileID: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    /// lstat identity, so a dangling symbolic link still counts as an existing item.
    static func identity(of url: URL) -> FileID? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileID(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    private struct Deadline {
        let start = ContinuousClock.now
        let limit: Duration

        init(seconds: TimeInterval) {
            limit = .seconds(seconds)
        }

        func check() throws {
            if ContinuousClock.now - start > limit { throw BatchRenameError.elapsedTimeLimitExceeded }
        }
    }
}
