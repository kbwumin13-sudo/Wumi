import Foundation

/// One step of a batch rename. Rules run top to bottom on the base name (the name without its extension);
/// only `replaceExtension` changes the extension.
public enum BatchRenameRule: Codable, Equatable, Hashable, Sendable {
    case addPrefix(String)
    case addSuffix(String)
    /// Literal, case-sensitive find and replace.
    case replace(target: String, replacement: String)
    /// NSRegularExpression without options; the replacement is a template, so `$1` refers to a capture group.
    case regularExpression(pattern: String, replacement: String)
    /// The new extension, with or without a leading dot. An empty string removes the extension.
    case replaceExtension(String)
    /// `<number><separator><base>`; numbers count up from `start` in selection order, zero-padded to `width` digits.
    case prependSequence(start: Int, width: Int, separator: String)
    /// `<base><separator><number>`.
    case sequence(start: Int, width: Int, separator: String)
    case lowercase
    case uppercase
}

/// Why one planned rename cannot run. A plan with any error cannot be executed.
public enum BatchRenamePreviewError: String, Codable, Equatable, Sendable {
    case invalidName, duplicateDestination, destinationExists, sourceUnavailable

    public var message: String {
        switch self {
        case .invalidName: "Invalid name"
        case .duplicateDestination: "Duplicate destination"
        case .destinationExists: "Destination already exists"
        case .sourceUnavailable: "The item is no longer available."
        }
    }
}

public struct BatchRenamePreview: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var source: URL
    /// Equal to `source` when the rules leave the name unchanged.
    public var destination: URL
    /// The proposed name. Kept apart from `destination` because an invalid name (one containing "/", say) has no faithful URL.
    public var destinationName: String
    public var error: BatchRenamePreviewError?

    public init(id: UUID = UUID(), source: URL, destination: URL, destinationName: String, error: BatchRenamePreviewError? = nil) {
        self.id = id
        self.source = source
        self.destination = destination
        self.destinationName = destinationName
        self.error = error
    }

    /// Unchanged names are no-ops: they are never moved, but they still count when looking for duplicates.
    public var isUnchanged: Bool { destination == source }
}

public struct BatchRenameLimits: Codable, Equatable, Sendable {
    public var maximumSelectionCount: Int
    public var maximumPlannedItems: Int
    public var maximumExecutedItems: Int
    public var maximumPlanningDuration: TimeInterval
    public var maximumExecutionDuration: TimeInterval

    public init(maximumSelectionCount: Int = 10_000, maximumPlannedItems: Int = 10_000, maximumExecutedItems: Int = 10_000,
                maximumPlanningDuration: TimeInterval = 2.0, maximumExecutionDuration: TimeInterval = 60.0) {
        self.maximumSelectionCount = maximumSelectionCount
        self.maximumPlannedItems = maximumPlannedItems
        self.maximumExecutedItems = maximumExecutedItems
        self.maximumPlanningDuration = maximumPlanningDuration
        self.maximumExecutionDuration = maximumExecutionDuration
    }

    public static let `default` = BatchRenameLimits()
}

public struct BatchRenameOperation: Codable, Equatable, Hashable, Sendable {
    public var source: URL
    public var destination: URL

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }
}

/// The renames of one committed batch, in the order they were planned.
public struct BatchRenameTransaction: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var operations: [BatchRenameOperation]

    public init(id: UUID = UUID(), createdAt: Date = Date(), operations: [BatchRenameOperation]) {
        self.id = id
        self.createdAt = createdAt
        self.operations = operations
    }

    /// The renames that put every item back. Keeps this transaction's id so the undo can be logged against it.
    public var inverse: BatchRenameTransaction {
        BatchRenameTransaction(id: id, createdAt: createdAt,
                               operations: operations.reversed().map { BatchRenameOperation(source: $0.destination, destination: $0.source) })
    }
}

/// One row of "Recent Batch Renames". Persistence belongs to the app.
public struct BatchRenameLogEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case committed, undone
    }

    public var id: UUID
    public var date: Date
    public var transactionID: UUID
    public var operations: [BatchRenameOperation]
    public var outcome: Outcome
    public var elapsedTime: TimeInterval

    public init(id: UUID = UUID(), date: Date = Date(), transactionID: UUID, operations: [BatchRenameOperation],
                outcome: Outcome, elapsedTime: TimeInterval) {
        self.id = id
        self.date = date
        self.transactionID = transactionID
        self.operations = operations
        self.outcome = outcome
        self.elapsedTime = elapsedTime
    }

    public init(transaction: BatchRenameTransaction, outcome: Outcome, elapsedTime: TimeInterval, date: Date = Date()) {
        self.init(date: date, transactionID: transaction.id, operations: transaction.operations, outcome: outcome, elapsedTime: elapsedTime)
    }
}

public struct BatchRenamePreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var rules: [BatchRenameRule]

    public init(id: UUID = UUID(), name: String, rules: [BatchRenameRule]) {
        self.id = id
        self.name = name
        self.rules = rules
    }
}

public enum BatchRenameError: Error, Equatable, Sendable {
    case invalidDestination
    case invalidRegularExpression
    case selectionLimitExceeded(count: Int, limit: Int)
    case itemLimitExceeded
    case sourceUnavailable(URL)
    case destinationExists(URL)
    case invalidPlan
    case elapsedTimeLimitExceeded
    case rollbackFailed

    public var message: String {
        switch self {
        case .invalidDestination: "Invalid name"
        case .invalidRegularExpression: "Invalid regular expression."
        case .selectionLimitExceeded(let count, let limit): "The selection contains \(count) items; the limit is \(limit)."
        case .itemLimitExceeded: "The transaction contains more items than a batch rename allows."
        case .sourceUnavailable(let url): "The item is no longer available: \(url.path)"
        case .destinationExists(let url): "Destination already exists: \(url.path)"
        case .invalidPlan: "The batch rename plan is invalid."
        case .elapsedTimeLimitExceeded: "The batch rename exceeded its time limit."
        case .rollbackFailed: "The batch rename failed and could not be fully rolled back."
        }
    }
}
