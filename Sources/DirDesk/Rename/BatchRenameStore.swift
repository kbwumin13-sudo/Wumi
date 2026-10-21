import AppKit
import DirDeskCore
import SwiftUI

/// Every batch rename, undo and redo runs here, one at a time, in the order it was asked for.
private let batchRenameQueue = DispatchQueue(label: "com.kbwumin13.dirdesk.batch-rename", qos: .userInitiated)
/// The rename log can hold thousands of paths, so it is encoded away from the main thread.
private let batchRenameLogQueue = DispatchQueue(label: "com.kbwumin13.dirdesk.batch-rename-log", qos: .utility)

/// Editable form of one rule. The rule bar offers the eight kinds in this order plus Prefix and Suffix, which adds one
/// prefix and one suffix rule; Number Sequence covers both engine sequence rules (`prependSequence` and `sequence`)
/// through its position.
struct BatchRenameRuleDraft: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case prefix, suffix, replace, regularExpression, fileExtension, lowercase, uppercase, sequence

        var id: String { rawValue }

        var title: String {
            switch self {
            case .prefix: L("Prefix")
            case .suffix: L("Suffix")
            case .replace: L("Find and Replace")
            case .regularExpression: L("Regular Expression")
            case .fileExtension: L("Extension")
            case .lowercase: L("Lowercase")
            case .uppercase: L("Uppercase")
            case .sequence: L("Number Sequence")
            }
        }

        /// Accessibility identifier suffix of the kind's button in the rule bar.
        var modeIdentifier: String {
            self == .fileExtension ? "extensionReplacement" : rawValue
        }
    }

    enum Placement: String, CaseIterable {
        case beginning, end
    }

    static let maximumDigits = 10
    static let maximumStart = 999_999_999

    var id = UUID()
    var kind: Kind
    /// Prefix, suffix, find text, pattern or new extension, depending on the kind.
    var text = ""
    var replacement = ""
    var start = 1
    var digits = 2
    var separator = "-"
    var placement: Placement = .end

    init(kind: Kind) {
        self.kind = kind
    }

    init(rule: BatchRenameRule) {
        switch rule {
        case .addPrefix(let prefix):
            self.init(kind: .prefix)
            text = prefix
        case .addSuffix(let suffix):
            self.init(kind: .suffix)
            text = suffix
        case .replace(let target, let replacement):
            self.init(kind: .replace)
            text = target
            self.replacement = replacement
        case .regularExpression(let pattern, let replacement):
            self.init(kind: .regularExpression)
            text = pattern
            self.replacement = replacement
        case .replaceExtension(let newExtension):
            self.init(kind: .fileExtension)
            text = newExtension
        case .prependSequence(let start, let width, let separator):
            self.init(kind: .sequence)
            self.start = start
            digits = width
            self.separator = separator
            placement = .beginning
        case .sequence(let start, let width, let separator):
            self.init(kind: .sequence)
            self.start = start
            digits = width
            self.separator = separator
            placement = .end
        case .lowercase:
            self.init(kind: .lowercase)
        case .uppercase:
            self.init(kind: .uppercase)
        }
    }

    /// The engine rule, or nil while the rule is incomplete (empty text, or a pattern that does not compile).
    /// An empty extension is complete: it removes the extension.
    var rule: BatchRenameRule? {
        switch kind {
        case .prefix:
            return text.isEmpty ? nil : .addPrefix(text)
        case .suffix:
            return text.isEmpty ? nil : .addSuffix(text)
        case .replace:
            return text.isEmpty ? nil : .replace(target: text, replacement: replacement)
        case .regularExpression:
            return text.isEmpty || hasInvalidPattern ? nil : .regularExpression(pattern: text, replacement: replacement)
        case .fileExtension:
            return .replaceExtension(text)
        case .sequence:
            let first = min(max(start, 0), Self.maximumStart)
            let width = min(max(digits, 1), Self.maximumDigits)
            return placement == .beginning ? .prependSequence(start: first, width: width, separator: separator)
                : .sequence(start: first, width: width, separator: separator)
        case .lowercase:
            return .lowercase
        case .uppercase:
            return .uppercase
        }
    }

    var hasInvalidPattern: Bool {
        kind == .regularExpression && !text.isEmpty && (try? NSRegularExpression(pattern: text, options: [])) == nil
    }

    /// One-line description, used in preset lists.
    var summary: String {
        switch kind {
        case .prefix: LF("Add prefix: %@", text)
        case .suffix: LF("Add suffix: %@", text)
        case .replace: LF("Replace “%@” with “%@”", text, replacement)
        case .regularExpression: LF("Regular expression %@ → %@", text, replacement)
        case .fileExtension: text.isEmpty ? L("Remove the extension") : LF("Change the extension to %@", text)
        case .sequence:
            placement == .beginning ? LF("Number at the beginning, starting at %lld", Int64(start))
                : LF("Number at the end, starting at %lld", Int64(start))
        case .lowercase: L("Lowercase")
        case .uppercase: L("Uppercase")
        }
    }

    static func summary(of rules: [BatchRenameRule], separator: String = " · ") -> String {
        rules.map { BatchRenameRuleDraft(rule: $0).summary }.joined(separator: separator)
    }
}

/// Localized text for the engine's errors.
enum BatchRenameMessages {
    static func preview(_ error: BatchRenamePreviewError) -> String {
        switch error {
        case .invalidName: L("Invalid name")
        case .duplicateDestination: L("Duplicate destination")
        case .destinationExists: L("Destination already exists")
        case .sourceUnavailable: L("The item is no longer available.")
        }
    }

    static func message(_ error: Error) -> String {
        guard let error = error as? BatchRenameError else { return error.localizedDescription }
        switch error {
        case .invalidDestination: return L("Invalid name")
        case .invalidRegularExpression: return L("Invalid regular expression.")
        case .selectionLimitExceeded(let count, let limit):
            return LF("The selection contains %lld items; the limit is %lld.", Int64(count), Int64(limit))
        case .itemLimitExceeded: return L("The transaction contains more items than a batch rename allows.")
        case .sourceUnavailable(let url): return LF("The item is no longer available: %@", url.path)
        case .destinationExists(let url): return LF("Destination already exists: %@", url.path)
        case .invalidPlan: return L("The batch rename plan is invalid.")
        case .elapsedTimeLimitExceeded: return L("The batch rename exceeded its time limit.")
        case .rollbackFailed: return L("The batch rename failed and could not be fully rolled back.")
        }
    }
}

private enum BatchRenameUndoStep: Sendable {
    case undo, redo
}

/// Saved presets, the "Recent Batch Renames" log, and undo for committed batches. Shared by every Batch Rename window.
@MainActor
final class BatchRenameStore: ObservableObject {
    static let shared = BatchRenameStore()
    static let logLimit = 20

    @Published private(set) var presets: [BatchRenamePreset]
    /// Oldest first. A transaction appears again each time it is undone or redone; its newest entry tells whether
    /// its renames are currently applied.
    @Published private(set) var log: [BatchRenameLogEntry]
    /// Transactions whose renamed items are all still where the rename put them, so undoing them can work.
    @Published private(set) var revertibleTransactionIDs: Set<UUID> = []
    /// Renames, undos and redos queued or running.
    @Published private(set) var activeRunCount = 0
    @Published var lastError: String?

    private let presetStore = PersistenceStore<[BatchRenamePreset]>(key: DefaultsKey.batchRenamePresets) { [] }
    private let logStore = PersistenceStore<[BatchRenameLogEntry]>(key: DefaultsKey.batchRenameLog) { [] }
    /// The undo manager does not retain its targets, so the targets of registered batches live here.
    private var undoTargets: [UUID: UndoTarget] = [:]
    private var revertibilityGeneration = 0

    /// The object one batch's undo and redo actions are registered against, so they can be removed together.
    private final class UndoTarget {
        let transaction: BatchRenameTransaction
        weak var undoManager: UndoManager?
        weak var controller: WorkspaceController?

        init(transaction: BatchRenameTransaction, undoManager: UndoManager, controller: WorkspaceController?) {
            self.transaction = transaction
            self.undoManager = undoManager
            self.controller = controller
        }
    }

    private init() {
        let loadedPresets = presetStore.load()
        let loadedLog = logStore.load()
        presets = loadedPresets.value
        log = loadedLog.value
        if loadedPresets.error != nil || loadedLog.error != nil {
            lastError = L("Saved batch rename presets or history could not be read.")
        }
    }

    var isBusy: Bool { activeRunCount > 0 }

    // MARK: Presets

    func preset(named name: String) -> BatchRenamePreset? {
        let key = Self.normalized(name)
        guard !key.isEmpty else { return nil }
        return presets.first { Self.normalized($0.name) == key }
    }

    /// Saves `rules` under `name`. A preset that already has the name (ignoring case) gets the new rules.
    func savePreset(named name: String, rules: [BatchRenameRule]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !rules.isEmpty else { return }
        if let index = presets.firstIndex(where: { Self.normalized($0.name) == Self.normalized(trimmed) }) {
            presets[index].name = trimmed
            presets[index].rules = rules
        } else {
            presets.append(BatchRenamePreset(name: trimmed, rules: rules))
        }
        persistPresets()
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persistPresets()
    }

    private func persistPresets() {
        do {
            try presetStore.save(presets)
        } catch {
            lastError = L("Batch rename presets could not be saved.")
        }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    // MARK: Log

    private func latestEntry(for transactionID: UUID) -> BatchRenameLogEntry? {
        log.last { $0.transactionID == transactionID }
    }

    /// Whether the entry is the current, committed state of its transaction and its items can still be put back.
    func isUndoAvailable(_ entry: BatchRenameLogEntry) -> Bool {
        entry.outcome == .committed && latestEntry(for: entry.transactionID)?.id == entry.id
            && revertibleTransactionIDs.contains(entry.transactionID)
    }

    private func record(_ transaction: BatchRenameTransaction, outcome: BatchRenameLogEntry.Outcome, elapsedTime: TimeInterval) {
        log.append(BatchRenameLogEntry(transaction: transaction, outcome: outcome, elapsedTime: elapsedTime))
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
        let snapshot = log
        let store = logStore
        batchRenameLogQueue.async {
            do {
                try store.save(snapshot)
            } catch {
                Task { @MainActor in BatchRenameStore.shared.lastError = L("The batch rename history could not be saved.") }
            }
        }
        refreshRevertibility()
    }

    /// Re-checks on disk which committed batches can still be undone. Runs after any queued rename.
    func refreshRevertibility() {
        let candidates = log.filter { $0.outcome == .committed && latestEntry(for: $0.transactionID)?.id == $0.id }
        revertibilityGeneration += 1
        let generation = revertibilityGeneration
        Task {
            let result = await Self.run { Set(candidates.filter { Self.isRevertible($0.operations) }.map(\.transactionID)) }
            guard generation == revertibilityGeneration, case .success(let ids) = result else { return }
            revertibleTransactionIDs = ids
        }
    }

    /// Every renamed item is still at its new name, and each original name is free or held by another item of the batch.
    nonisolated static func isRevertible(_ operations: [BatchRenameOperation]) -> Bool {
        guard !operations.isEmpty else { return false }
        var destinations = Set<FileNode>()
        for operation in operations {
            guard let node = FileNode(operation.destination) else { return false }
            destinations.insert(node)
        }
        for operation in operations {
            if let node = FileNode(operation.source), !destinations.contains(node) { return false }
        }
        return true
    }

    /// lstat identity, so a renamed dangling symbolic link still counts as present.
    private struct FileNode: Hashable {
        let device: Int32
        let inode: UInt64

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    // MARK: Running

    /// Runs `work` on the batch rename queue: runs never overlap and finish in the order they started.
    nonisolated static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
        await withCheckedContinuation { continuation in
            batchRenameQueue.async { continuation.resume(returning: Result { try work() }) }
        }
    }

    /// Renames every changed preview, then logs the batch, registers undo in the controller's window and shows the result.
    func commit(_ previews: [BatchRenamePreview], limits: BatchRenameLimits,
                controller: WorkspaceController?) async -> Result<BatchRenameTransaction, Error> {
        activeRunCount += 1
        let started = Date()
        let result = await Self.run { try BatchRenameService.execute(previews, limits: limits) }
        activeRunCount -= 1
        switch result {
        case .success(let transaction):
            if !transaction.operations.isEmpty {
                record(transaction, outcome: .committed, elapsedTime: Date().timeIntervalSince(started))
                registerUndo(for: transaction, controller: controller)
            }
            show(transaction.operations.map(\.destination), controller: controller)
        case .failure:
            // A failed run is rolled back, but the panes may have seen the temporary names.
            show([], refreshing: previews.filter { !$0.isUnchanged }.map(\.source), controller: controller)
        }
        return result
    }

    /// Undoes a logged batch from "Recent Batch Renames".
    func undo(_ entry: BatchRenameLogEntry, controller: WorkspaceController?) {
        guard isUndoAvailable(entry), !isBusy else { return }
        let transaction = BatchRenameTransaction(id: entry.transactionID, createdAt: entry.date, operations: entry.operations)
        if let target = undoTargets[entry.transactionID] {
            // Its Edit > Undo action would now act on names that are already back.
            target.undoManager?.removeAllActions(withTarget: target)
            undoTargets[entry.transactionID] = nil
        }
        lastError = nil
        activeRunCount += 1
        Task {
            let started = Date()
            let result = await Self.run { try BatchRenameService.undo(transaction) }
            activeRunCount -= 1
            switch result {
            case .success:
                record(transaction, outcome: .undone, elapsedTime: Date().timeIntervalSince(started))
                show(transaction.operations.map(\.source), controller: controller)
            case .failure(let error):
                lastError = BatchRenameMessages.message(error)
                show([], refreshing: transaction.operations.map(\.destination), controller: controller)
                refreshRevertibility()
            }
        }
    }

    private func registerUndo(for transaction: BatchRenameTransaction, controller: WorkspaceController?) {
        guard let controller, let undoManager = controller.window?.undoManager else { return }
        let target = UndoTarget(transaction: transaction, undoManager: undoManager, controller: controller)
        undoTargets[transaction.id] = target
        register(.undo, target: target)
    }

    private func register(_ step: BatchRenameUndoStep, target: UndoTarget) {
        guard let undoManager = target.undoManager else { return }
        undoManager.registerUndo(withTarget: target) { target in
            BatchRenameStore.shared.perform(step, target: target)
        }
        undoManager.setActionName(L("Batch Rename"))
    }

    /// Called by the undo manager. Undo applies the inverse renames; redo re-applies the original ones.
    private func perform(_ step: BatchRenameUndoStep, target: UndoTarget) {
        // Registering while the undo manager is undoing (or redoing) puts the opposite step on the right stack.
        register(step == .undo ? .redo : .undo, target: target)
        let transaction = target.transaction
        activeRunCount += 1
        Task {
            let started = Date()
            let result = await Self.run {
                switch step {
                case .undo: try BatchRenameService.undo(transaction)
                case .redo: try BatchRenameService.undo(transaction.inverse)
                }
            }
            activeRunCount -= 1
            let current = undoTargets[transaction.id]
            switch result {
            case .success:
                record(transaction, outcome: step == .undo ? .undone : .committed, elapsedTime: Date().timeIntervalSince(started))
                let urls = step == .undo ? transaction.operations.map(\.source) : transaction.operations.map(\.destination)
                show(urls, controller: current?.controller)
            case .failure(let error):
                // The files no longer match this batch, so neither direction can be trusted any more.
                if let current {
                    current.undoManager?.removeAllActions(withTarget: current)
                    undoTargets[transaction.id] = nil
                }
                let message = BatchRenameMessages.message(error)
                if let controller = current?.controller {
                    controller.presentError(message)
                } else {
                    lastError = message
                }
                refreshRevertibility()
            }
        }
    }

    /// Reloads the panes that show the folders of `urls` (and of `refreshing`), then selects `urls`.
    private func show(_ urls: [URL], refreshing extra: [URL] = [], controller: WorkspaceController?) {
        let folders = Self.folders(of: urls + extra)
        guard !folders.isEmpty else { return }
        guard let controller else {
            NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
            return
        }
        controller.refreshPanes(showing: folders)
        if !urls.isEmpty { controller.activePane.select(urls: urls) }
    }

    nonisolated static func folders(of urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.map { $0.deletingLastPathComponent() }.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
