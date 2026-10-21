import AppKit
import DirDeskCore
import SwiftUI

/// UserDefaults keys owned by Folder Sync.
enum FolderSyncStorageKey {
    static let presets = "dirdesk-folder-sync-presets-v1"
    static let baselines = "dirdesk-folder-sync-baselines-v1"
    static let history = "dirdesk-folder-sync-history-v1"
    /// When the scheduler last looked at each task's schedule, so a due run is noticed once.
    static let scheduleAnchors = "dirdesk-folder-sync-schedule-anchors-v1"
}

/// One finished (or skipped) run, kept in the last-50 history.
struct FolderSyncHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Trigger: String, Codable, Sendable {
        case manual, scheduled
    }

    enum Result: String, Codable, Sendable {
        case completed, completedWithIssues, cancelled, failed
        /// A scheduled run found conflicts and synced nothing.
        case needsAttention

        init(_ outcome: FolderSyncRunOutcome) {
            switch outcome {
            case .completed: self = .completed
            case .completedWithIssues: self = .completedWithIssues
            case .cancelled: self = .cancelled
            case .failed: self = .failed
            }
        }
    }

    static let storedFailureLimit = 20

    var id = UUID()
    var presetID: UUID
    var presetName: String
    var trigger: Trigger
    var startedAt: Date
    var finishedAt: Date
    var result: Result
    var copiedToLeftCount = 0
    var copiedToRightCount = 0
    var failureCount = 0
    /// The first few failures; `failureCount` has the total.
    var failures: [FolderSyncItemFailure] = []
    var conflictCount = 0
    /// Why a run failed before copying anything, localized when it was recorded.
    var message: String?
}

/// Saved sync tasks, their run history and the live run of each task. Shared by the settings page, the run
/// sheets and the scheduler.
@MainActor
final class FolderSyncStore: ObservableObject {
    static let shared = FolderSyncStore()
    static let historyLimit = 50

    @Published private(set) var presets: [FolderSyncPreset]
    /// Oldest first.
    @Published private(set) var history: [FolderSyncHistoryEntry]
    @Published private(set) var runningPresetIDs: Set<UUID> = []
    @Published var saveError: String?

    private let presetStore = PersistenceStore<[FolderSyncPreset]>(key: FolderSyncStorageKey.presets) { [] }
    private let historyStore = PersistenceStore<[FolderSyncHistoryEntry]>(key: FolderSyncStorageKey.history) { [] }
    private let anchorStore = PersistenceStore<[String: Date]>(key: FolderSyncStorageKey.scheduleAnchors) { [:] }
    private var scheduleAnchors: [String: Date]
    private var runs: [UUID: FolderSyncRun] = [:]

    private init() {
        let loadedPresets = presetStore.load()
        let loadedHistory = historyStore.load()
        presets = loadedPresets.value
        history = loadedHistory.value
        scheduleAnchors = anchorStore.load().value
        if loadedPresets.error != nil || loadedHistory.error != nil {
            saveError = L("Saved folder sync tasks could not be read.")
        }
    }

    func preset(_ id: UUID) -> FolderSyncPreset? {
        presets.first { $0.id == id }
    }

    /// The run state of a task, created on first use and kept while the app runs.
    func run(for id: UUID) -> FolderSyncRun {
        if let run = runs[id] { return run }
        let run = FolderSyncRun(presetID: id)
        runs[id] = run
        return run
    }

    func isNameTaken(_ name: String, excluding id: UUID?) -> Bool {
        let key = Self.normalized(name)
        return presets.contains { $0.id != id && Self.normalized($0.name) == key }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Adds or replaces a task. A new or changed schedule starts counting from now.
    @discardableResult
    func save(_ preset: FolderSyncPreset) -> Bool {
        var updated = presets
        let previous = updated.firstIndex { $0.id == preset.id }.map { updated[$0] }
        if let index = updated.firstIndex(where: { $0.id == preset.id }) {
            updated[index] = preset
        } else {
            updated.append(preset)
        }
        do {
            try presetStore.save(updated)
        } catch {
            saveError = L("Folder sync settings could not be saved.")
            return false
        }
        presets = updated
        saveError = nil
        if previous?.schedule != preset.schedule { setScheduleAnchor(Date(), for: preset.id) }
        if previous != nil, previous != preset { runs[preset.id]?.settingsChanged() }
        return true
    }

    func delete(_ id: UUID) {
        guard !runningPresetIDs.contains(id) else { return }
        let updated = presets.filter { $0.id != id }
        do {
            try presetStore.save(updated)
        } catch {
            saveError = L("Folder sync settings could not be saved.")
            return
        }
        presets = updated
        history.removeAll { $0.presetID == id }
        persist(history, in: historyStore)
        scheduleAnchors[id.uuidString] = nil
        persist(scheduleAnchors, in: anchorStore)
        runs[id] = nil
        Task { await FolderSyncBaselineStore.shared.remove(id) }
    }

    // MARK: History

    func record(_ entry: FolderSyncHistoryEntry) {
        history.append(entry)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        persist(history, in: historyStore)
    }

    /// Newest first.
    func history(for id: UUID) -> [FolderSyncHistoryEntry] {
        history.filter { $0.presetID == id }.reversed()
    }

    func lastRun(for id: UUID) -> FolderSyncHistoryEntry? {
        history.last { $0.presetID == id }
    }

    // MARK: Running and scheduling

    func setRunning(_ id: UUID, _ running: Bool) {
        if running { runningPresetIDs.insert(id) } else { runningPresetIDs.remove(id) }
    }

    func scheduleAnchor(for id: UUID) -> Date? {
        scheduleAnchors[id.uuidString]
    }

    func setScheduleAnchor(_ date: Date, for id: UUID) {
        scheduleAnchors[id.uuidString] = date
        persist(scheduleAnchors, in: anchorStore)
    }

    private func persist<Value: Codable & Sendable>(_ value: Value, in store: PersistenceStore<Value>) {
        do {
            try store.save(value)
        } catch {
            saveError = L("Folder sync settings could not be saved.")
        }
    }
}

/// Baselines can list every file of a task, so they are loaded and saved off the main thread. Each one remembers
/// the folders it was made for and is ignored once a task points elsewhere.
actor FolderSyncBaselineStore {
    static let shared = FolderSyncBaselineStore()

    private struct Stored: Codable, Sendable {
        var leftPath: String
        var rightPath: String
        var baseline: FolderSyncBaseline
    }

    private let store = PersistenceStore<[String: Stored]>(key: FolderSyncStorageKey.baselines) { [:] }
    private var cache: [String: Stored]?

    func baseline(for preset: FolderSyncPreset) -> FolderSyncBaseline? {
        guard let stored = entries()[preset.id.uuidString], stored.leftPath == Self.path(preset.leftURL),
              stored.rightPath == Self.path(preset.rightURL) else { return nil }
        return stored.baseline
    }

    func save(_ baseline: FolderSyncBaseline, for preset: FolderSyncPreset) {
        var all = entries()
        all[preset.id.uuidString] = Stored(leftPath: Self.path(preset.leftURL), rightPath: Self.path(preset.rightURL), baseline: baseline)
        cache = all
        try? store.save(all)
    }

    func remove(_ id: UUID) {
        var all = entries()
        guard all.removeValue(forKey: id.uuidString) != nil else { return }
        cache = all
        try? store.save(all)
    }

    private func entries() -> [String: Stored] {
        if let cache { return cache }
        let loaded = store.load().value
        cache = loaded
        return loaded
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

/// Thread-safe cancellation flag passed to the engine.
final class FolderSyncCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Lets progress through at most every `interval` seconds, so a large run does not flood the main thread.
final class FolderSyncThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var last = Date.distantPast

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    func allows() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= interval else { return false }
        last = now
        return true
    }
}

/// An analysis sorted for display: conflicts, then capped groups by action.
struct FolderSyncPresentation: Sendable {
    enum GroupKind: Int, CaseIterable, Sendable {
        case copyToRight, copyToLeft, updateRight, updateLeft, skipped
    }

    struct Group: Identifiable, Sendable {
        let kind: GroupKind
        /// At most `rowLimit` items.
        let items: [FolderSyncAnalysisItem]
        let totalCount: Int
        var id: Int { kind.rawValue }
    }

    static let rowLimit = 1_000

    let conflicts: [FolderSyncAnalysisItem]
    let groups: [Group]
    /// Files present and identical on both sides.
    let unchangedCount: Int
    let skippedCount: Int

    init(_ analysis: FolderSyncAnalysis) {
        var buckets: [GroupKind: [FolderSyncAnalysisItem]] = [:]
        var conflicts: [FolderSyncAnalysisItem] = []
        var unchanged = 0
        let tolerance = analysis.preset.modificationTimeTolerance
        for item in analysis.items {
            switch item.action {
            case .conflict: conflicts.append(item)
            case .copyToRight: buckets[.copyToRight, default: []].append(item)
            case .copyToLeft: buckets[.copyToLeft, default: []].append(item)
            case .updateRight: buckets[.updateRight, default: []].append(item)
            case .updateLeft: buckets[.updateLeft, default: []].append(item)
            case .skip:
                if Self.isIdentical(item, tolerance: tolerance) {
                    unchanged += 1
                } else {
                    buckets[.skipped, default: []].append(item)
                }
            }
        }
        self.conflicts = conflicts
        groups = GroupKind.allCases.compactMap { kind in
            guard let items = buckets[kind], !items.isEmpty else { return nil }
            return Group(kind: kind, items: Array(items.prefix(Self.rowLimit)), totalCount: items.count)
        }
        unchangedCount = unchanged
        skippedCount = buckets[.skipped]?.count ?? 0
    }

    static func isIdentical(_ item: FolderSyncAnalysisItem, tolerance: TimeInterval) -> Bool {
        guard item.conflictReason == nil, let left = item.left, let right = item.right, left.kind == right.kind else { return false }
        return left.kind == .directory || left.fingerprint.matches(right.fingerprint, tolerance: tolerance)
    }
}

/// Runs the engine off the main thread.
enum FolderSyncEngine {
    static func analyze(_ preset: FolderSyncPreset, cancel: FolderSyncCancelFlag) async -> Result<(FolderSyncAnalysis, FolderSyncPresentation), Error> {
        let baseline = await FolderSyncBaselineStore.shared.baseline(for: preset)
        return await Task.detached(priority: .userInitiated) {
            Result {
                let analysis = try FolderSyncService.analyze(preset: preset, baseline: baseline, isCancelled: { cancel.isCancelled })
                return (analysis, FolderSyncPresentation(analysis))
            }
        }.value
    }

    /// Applies the analysis and stores the new baseline, whatever the outcome.
    static func apply(_ analysis: FolderSyncAnalysis, decisions: [String: FolderSyncConflictDecision], cancel: FolderSyncCancelFlag,
                      progress: @escaping @Sendable (FolderSyncProgress) -> Void) async -> Result<FolderSyncRunSummary, Error> {
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try FolderSyncService.apply(analysis, decisions: decisions, progress: progress, isCancelled: { cancel.isCancelled })
            }
        }.value
        if case .success(let summary) = result {
            await FolderSyncBaselineStore.shared.save(summary.baseline, for: analysis.preset)
        }
        return result
    }
}

/// The live state of one task: analyzing, waiting for review, syncing, or showing a result.
@MainActor
final class FolderSyncRun: ObservableObject {
    enum Phase {
        case idle
        case analyzing
        case analyzed(FolderSyncAnalysis, FolderSyncPresentation)
        case syncing(FolderSyncAnalysis, FolderSyncPresentation)
        case finished(FolderSyncRunSummary)
        case failed(String)
    }

    /// What happens once an analysis is ready.
    enum NextStep {
        /// Show the preview.
        case review
        /// A run without preview: ask for confirmation unless conflicts need a decision first.
        case confirm
        /// A scheduled run: sync unless conflicts need a decision, then record the result.
        case automatic
    }

    let presetID: UUID
    @Published private(set) var phase: Phase = .idle
    @Published var decisions: [String: FolderSyncConflictDecision] = [:]
    @Published private(set) var progress: FolderSyncProgress?
    /// A note shown above the preview, such as why a sync did not start.
    @Published private(set) var notice: String?
    /// Set when a run without preview has an analysis ready to confirm; the run view shows the confirmation and
    /// clears it.
    @Published var confirmationRequested = false
    private var cancelFlag = FolderSyncCancelFlag()
    /// The conflicts the current decisions were made for. A decision carries over to a new analysis only while its
    /// conflict looks exactly the same.
    private var decidedConflicts: [String: FolderSyncAnalysisItem] = [:]

    init(presetID: UUID) {
        self.presetID = presetID
    }

    var isBusy: Bool {
        switch phase {
        case .analyzing, .syncing: true
        default: false
        }
    }

    var analysis: FolderSyncAnalysis? {
        switch phase {
        case .analyzed(let analysis, _), .syncing(let analysis, _): analysis
        default: nil
        }
    }

    /// Runs the task by hand: the preview first when the task asks for one, otherwise straight to the confirmation.
    /// Does nothing while the task is analyzing or syncing.
    func start(_ preset: FolderSyncPreset) {
        analyze(preset, then: preset.previewSyncDetails ? .review : .confirm)
    }

    func analyze(_ preset: FolderSyncPreset, trigger: FolderSyncHistoryEntry.Trigger = .manual, then next: NextStep = .review) {
        guard !isBusy else { return }
        let store = FolderSyncStore.shared
        let flag = FolderSyncCancelFlag()
        let startedAt = Date()
        cancelFlag = flag
        phase = .analyzing
        progress = nil
        notice = nil
        confirmationRequested = false
        store.setRunning(presetID, true)
        Task {
            let result = await FolderSyncEngine.analyze(preset, cancel: flag)
            store.setRunning(presetID, false)
            switch result {
            case .success(let (analysis, presentation)):
                let previous = decidedConflicts
                decidedConflicts = Dictionary(presentation.conflicts.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
                decisions = decisions.filter { path, _ in previous[path] != nil && previous[path] == decidedConflicts[path] }
                phase = .analyzed(analysis, presentation)
                proceed(after: analysis, presentation: presentation, next: next, startedAt: startedAt)
            case .failure(let error):
                if error is CancellationError || flag.isCancelled {
                    phase = .idle
                    return
                }
                let message = FolderSyncMessages.message(error)
                phase = .failed(message)
                if trigger == .scheduled {
                    store.record(FolderSyncHistoryEntry(presetID: preset.id, presetName: preset.name, trigger: .scheduled, startedAt: startedAt,
                                                        finishedAt: Date(), result: .failed, message: message))
                }
            }
        }
    }

    private func proceed(after analysis: FolderSyncAnalysis, presentation: FolderSyncPresentation, next: NextStep, startedAt: Date) {
        let unresolved = presentation.conflicts.contains { decisions[$0.relativePath] == nil }
        switch next {
        case .review:
            break
        case .confirm:
            if unresolved {
                notice = L("Choose how to handle every conflict before syncing.")
            } else if analysis.hasChanges {
                confirmationRequested = true
            }
        case .automatic:
            if !presentation.conflicts.isEmpty {
                // Decisions made earlier in a run sheet are not reused without the user looking at them.
                FolderSyncStore.shared.record(FolderSyncHistoryEntry(presetID: analysis.preset.id, presetName: analysis.preset.name,
                                                                     trigger: .scheduled, startedAt: startedAt, finishedAt: Date(),
                                                                     result: .needsAttention, conflictCount: presentation.conflicts.count))
                notice = L("Automatic sync skipped this task because some conflicts need a decision.")
            } else if !analysis.hasChanges {
                FolderSyncStore.shared.record(FolderSyncHistoryEntry(presetID: analysis.preset.id, presetName: analysis.preset.name,
                                                                     trigger: .scheduled, startedAt: startedAt, finishedAt: Date(),
                                                                     result: .completed))
                phase = .idle
            } else {
                sync(trigger: .scheduled)
            }
        }
    }

    /// Applies the current analysis with the chosen conflict decisions.
    func sync(trigger: FolderSyncHistoryEntry.Trigger = .manual) {
        guard case .analyzed(let analysis, let presentation) = phase else { return }
        let decisions = decisions
        guard presentation.conflicts.allSatisfy({ decisions[$0.relativePath] != nil }) else {
            notice = L("Choose how to handle every conflict before syncing.")
            return
        }
        let store = FolderSyncStore.shared
        let flag = FolderSyncCancelFlag()
        let throttle = FolderSyncThrottle()
        cancelFlag = flag
        notice = nil
        progress = nil
        phase = .syncing(analysis, presentation)
        store.setRunning(presetID, true)
        let run = self
        let report: @Sendable (FolderSyncProgress) -> Void = { value in
            guard throttle.allows() else { return }
            Task { @MainActor in
                if case .syncing = run.phase { run.progress = value }
            }
        }
        Task {
            let started = Date()
            let result = await FolderSyncEngine.apply(analysis, decisions: decisions, cancel: flag, progress: report)
            store.setRunning(presetID, false)
            let preset = analysis.preset
            switch result {
            case .success(let summary):
                phase = .finished(summary)
                store.record(FolderSyncHistoryEntry(presetID: preset.id, presetName: preset.name, trigger: trigger,
                                                    startedAt: summary.startedAt, finishedAt: summary.finishedAt,
                                                    result: FolderSyncHistoryEntry.Result(summary.outcome),
                                                    copiedToLeftCount: summary.copiedToLeftCount, copiedToRightCount: summary.copiedToRightCount,
                                                    failureCount: summary.failures.count,
                                                    failures: Array(summary.failures.prefix(FolderSyncHistoryEntry.storedFailureLimit))))
                if summary.copiedToLeftCount + summary.copiedToRightCount > 0 {
                    NotificationCenter.default.post(name: .dirDeskFilesChanged, object: nil)
                }
            case .failure(let error):
                let message = FolderSyncMessages.message(error, unit: AppModel.shared.preferences.fileSizeUnit)
                if (error as? FolderSyncError) == .staleAnalysis, trigger == .manual {
                    // Nothing was copied; the folders changed since the preview. Show a fresh one with the reason on top.
                    phase = .idle
                    analyze(store.preset(presetID) ?? preset)
                    notice = message
                } else {
                    store.record(FolderSyncHistoryEntry(presetID: preset.id, presetName: preset.name, trigger: trigger, startedAt: started,
                                                        finishedAt: Date(), result: .failed, message: message))
                    phase = .failed(message)
                }
            }
        }
    }

    func cancel() {
        cancelFlag.cancel()
    }

    /// Back to the idle page. Ignored while a run is in progress.
    func reset() {
        guard !isBusy else { return }
        phase = .idle
        progress = nil
        notice = nil
    }

    func applyToAllConflicts(_ decision: FolderSyncConflictDecision) {
        guard case .analyzed(_, let presentation) = phase else { return }
        var updated = decisions
        for item in presentation.conflicts { updated[item.relativePath] = decision }
        decisions = updated
        notice = nil
    }

    /// The task was edited: a preview or result shown for the old settings no longer applies.
    func settingsChanged() {
        guard !isBusy else { return }
        decisions = [:]
        decidedConflicts = [:]
        reset()
    }
}

/// Localized text for Folder Sync values and errors.
enum FolderSyncMessages {
    /// `unit` formats the sizes of an insufficient-space error.
    static func message(_ error: Error, unit: FileSizeUnit = .decimal) -> String {
        if error is CancellationError { return L("The analysis was cancelled.") }
        guard let error = error as? FolderSyncError else { return error.localizedDescription }
        switch error {
        case .invalidName: return L("Enter a name for this sync preset.")
        case .folderMissing(let url): return LF("The folder could not be found: %@", url.path)
        case .folderUnreadable(let url): return LF("The folder could not be read. Check its permissions and connection: %@", url.path)
        case .folderNotWritable(let url): return LF("The folder is not writable: %@", url.path)
        case .sameFolder: return L("Choose two different folders.")
        case .nestedFolders: return L("One sync folder cannot be inside the other.")
        case .scanLimitExceeded: return L("This folder contains too many items to sync safely.")
        case .insufficientSpace(let needed, let available):
            return LF("There is not enough free space to complete this sync: %@ needed, %@ available.",
                      FileSizeFormatter.string(needed, unit: unit), FileSizeFormatter.string(available, unit: unit))
        case .staleAnalysis: return L("The folder contents changed. Review the updated preview before syncing.")
        case .unresolvedConflicts: return L("Choose how to handle every conflict before syncing.")
        }
    }

    /// Problems with the task itself; missing or read-only folders may only be temporary.
    static func isBlocking(_ error: Error) -> Bool {
        switch error as? FolderSyncError {
        case .folderMissing, .folderUnreadable, .folderNotWritable: false
        default: true
        }
    }

    static func direction(_ direction: FolderSyncDirection) -> String {
        switch direction {
        case .updateRight: L("Update Right")
        case .updateLeft: L("Update Left")
        case .updateBoth: L("Update Both")
        }
    }

    static func directionSymbol(_ direction: FolderSyncDirection) -> String {
        switch direction {
        case .updateRight: "arrow.right"
        case .updateLeft: "arrow.left"
        case .updateBoth: "arrow.left.arrow.right"
        }
    }

    static func directionArrow(_ direction: FolderSyncDirection) -> String {
        switch direction {
        case .updateRight: "→"
        case .updateLeft: "←"
        case .updateBoth: "↔"
        }
    }

    static func directionHelp(_ direction: FolderSyncDirection) -> String {
        switch direction {
        case .updateRight:
            L("Copies new and changed items from the left folder to the right one. Items only on the right stay as they are.")
        case .updateLeft:
            L("Copies new and changed items from the right folder to the left one. Items only on the left stay as they are.")
        case .updateBoth:
            L("Copies changes in both directions. Items changed on both sides since the last sync become conflicts for you to decide.")
        }
    }

    static func reason(_ reason: FolderSyncConflictReason) -> String {
        switch reason {
        case .bothChanged: L("Changed in both folders since the last sync")
        case .differentWithoutBaseline: L("Different in each folder, and there is no earlier sync to compare with")
        case .typeMismatch: L("A different kind of item in each folder")
        case .caseCollision: L("Names that differ only in letter case")
        }
    }

    static let decisions: [FolderSyncConflictDecision] = [.keepLeft, .keepRight, .keepBoth, .skip]

    static func decision(_ decision: FolderSyncConflictDecision) -> String {
        switch decision {
        case .keepLeft: L("Keep Left")
        case .keepRight: L("Keep Right")
        case .keepBoth: L("Keep Both")
        case .skip: L("Skip")
        }
    }

    static func frequency(_ frequency: FolderSyncScheduleFrequency) -> String {
        switch frequency {
        case .off: L("Off")
        case .daily: L("Daily")
        case .weekly: L("Weekly")
        case .monthly: L("Monthly")
        }
    }

    static func schedule(_ schedule: FolderSyncSchedule) -> String {
        var calendar = Calendar.current
        calendar.locale = Localizer.shared.locale
        let time = timeText(hour: schedule.hour, minute: schedule.minute)
        switch schedule.frequency {
        case .off:
            return L("Automatic sync is off")
        case .daily:
            return LF("Daily at %@", time)
        case .weekly:
            let weekday = min(max(schedule.weekday, 1), 7)
            return LF("Weekly on %@ at %@", calendar.weekdaySymbols[weekday - 1], time)
        case .monthly:
            return LF("Monthly on day %lld at %@", Int64(min(max(schedule.dayOfMonth, 1), 31)), time)
        }
    }

    static func timeText(hour: Int, minute: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Localizer.shared.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let date = Calendar.current.date(bySettingHour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0, of: Date()) ?? Date()
        return formatter.string(from: date)
    }

    static func dateText(_ date: Date) -> String {
        FileDateFormatter(locale: Localizer.shared.locale, absolute: true).absoluteString(date)
    }

    static func relativeText(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return L("Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Localizer.shared.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func result(_ result: FolderSyncHistoryEntry.Result) -> String {
        switch result {
        case .completed: L("Completed")
        case .completedWithIssues: L("Completed with issues")
        case .cancelled: L("Cancelled")
        case .failed: L("Failed")
        case .needsAttention: L("Needs attention")
        }
    }

    static func resultSymbol(_ result: FolderSyncHistoryEntry.Result) -> String {
        switch result {
        case .completed: "checkmark.circle.fill"
        case .completedWithIssues, .needsAttention: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    static func resultColor(_ result: FolderSyncHistoryEntry.Result) -> Color {
        switch result {
        case .completed: .green
        case .completedWithIssues, .needsAttention: .orange
        case .cancelled: .secondary
        case .failed: .red
        }
    }

    /// "Never run", or the last result and when it happened.
    static func lastRun(_ entry: FolderSyncHistoryEntry?) -> String {
        guard let entry else { return L("Never run") }
        return result(entry.result) + " · " + relativeText(entry.finishedAt)
    }

    /// What a history entry did, in one line.
    static func details(_ entry: FolderSyncHistoryEntry) -> String {
        switch entry.result {
        case .needsAttention:
            return entry.conflictCount == 1 ? L("1 conflict needs a decision") : LF("%lld conflicts need a decision", Int64(entry.conflictCount))
        case .failed where entry.message != nil:
            return entry.message ?? ""
        default:
            var parts = [LF("Copied to left: %lld", Int64(entry.copiedToLeftCount)), LF("Copied to right: %lld", Int64(entry.copiedToRightCount))]
            if entry.failureCount > 0 { parts.append(LF("Failed: %lld", Int64(entry.failureCount))) }
            return parts.joined(separator: " · ")
        }
    }

    /// The path with the home folder shortened to "~". No disk access.
    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    @MainActor
    static func size(_ bytes: Int64) -> String {
        FileSizeFormatter.string(bytes, unit: AppModel.shared.preferences.fileSizeUnit)
    }
}
