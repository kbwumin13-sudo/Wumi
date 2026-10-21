import AppKit
import Combine
import DirDeskCore
import SwiftUI

/// Runs copy/move plans, shows the progress window for longer operations, asks about conflicts
/// and registers undo.
@MainActor
final class OperationCenter: ObservableObject {
    /// What a task does; extraction and compression share the copy window, as in the original.
    enum Activity {
        case copy, move, extract, compress
    }

    struct Task: Identifiable {
        let id: UUID
        let plan: FileOperationPlan
        var activity: Activity
        var progress: FileOperationProgress?
        var finished = false
        var report: FileOperationReport?
        let cancelFlag = CancelFlag()

        init(id: UUID, plan: FileOperationPlan, activity: Activity? = nil) {
            self.id = id
            self.plan = plan
            self.activity = activity ?? (plan.kind == .move ? .move : .copy)
        }
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    @Published private(set) var tasks: [Task] = []
    private let coordinator = FileOperationCoordinator()
    private var progressWindow: NSWindow?

    func start(_ plan: FileOperationPlan, undoManager: UndoManager?, completion: @escaping (FileOperationReport) -> Void) {
        let task = Task(id: plan.id, plan: plan)
        tasks.append(task)
        let flag = task.cancelFlag
        let coordinator = self.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.tasks.contains(where: { $0.id == plan.id && !$0.finished }) else { return }
            self.showProgressWindow()
        }
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            let report = await coordinator.run(plan, conflictHandler: { source, existing in
                await MainActor.run { ConflictPrompt.ask(source: source, existing: existing) }
            }, progress: { progress in
                Task.updateOnMain(self, id: plan.id, progress: progress)
            }, isCancelled: { flag.isCancelled })
            await MainActor.run {
                guard let self else { return }
                if let index = self.tasks.firstIndex(where: { $0.id == plan.id }) {
                    self.tasks[index].finished = true
                    self.tasks[index].report = report
                }
                self.tasks.removeAll { $0.finished && $0.report?.failures.isEmpty != false }
                if self.tasks.isEmpty { self.progressWindow?.orderOut(nil) }
                self.registerUndo(report, plan: plan, undoManager: undoManager)
                completion(report)
            }
        }
    }

    func cancel(_ id: UUID) {
        tasks.first { $0.id == id }?.cancelFlag.cancel()
    }

    /// Shows an extraction or compression in the progress window when it takes longer than a second.
    /// Call `endActivity` when it is over; the returned flag reports Cancel.
    func beginActivity(_ activity: Activity, items: [URL], destination: URL) -> (id: UUID, cancel: CancelFlag) {
        let plan = FileOperationPlan(kind: .copy, sources: items, destination: destination)
        let task = Task(id: plan.id, plan: plan, activity: activity)
        tasks.append(task)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.tasks.contains(where: { $0.id == plan.id && !$0.finished }) else { return }
            self.showProgressWindow()
        }
        return (plan.id, task.cancelFlag)
    }

    func endActivity(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        if tasks.isEmpty { progressWindow?.orderOut(nil) }
    }

    func cancelAll() {
        tasks.forEach { $0.cancelFlag.cancel() }
    }

    fileprivate func update(_ id: UUID, progress: FileOperationProgress) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].progress = progress
    }

    private func registerUndo(_ report: FileOperationReport, plan: FileOperationPlan, undoManager: UndoManager?) {
        guard !report.mutations.isEmpty else { return }
        FileUndo.register(FileOperations.undoSteps(for: report.mutations), name: plan.kind == .copy ? L("Copy") : L("Move"),
                          undoManager: undoManager)
    }

    private func showProgressWindow() {
        if progressWindow == nil {
            // Like the original: a small standard window titled after the running operation.
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 150), styleMask: [.titled, .closable],
                                 backing: .buffered, defer: false)
            window.title = tasks.first.map { OperationProgressView.heading(for: $0.activity) } ?? L("Copying…")
            window.isFloatingPanel = false
            window.hidesOnDeactivate = false
            window.contentView = NSHostingView(rootView: OperationProgressView(center: self))
            window.center()
            progressWindow = window
        }
        if let first = tasks.first { progressWindow?.title = OperationProgressView.heading(for: first.activity) }
        progressWindow?.orderFront(nil)
    }
}

private extension OperationCenter.Task {
    nonisolated static func updateOnMain(_ center: OperationCenter?, id: UUID, progress: FileOperationProgress) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { center?.update(id, progress: progress) }
        }
    }
}

/// Progress of the running copy and move operations, laid out like the original's window: transfer icon,
/// "Copying…", the current top-level item with its position, a progress bar, a status line and Cancel.
struct OperationProgressView: View {
    @ObservedObject var center: OperationCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(center.tasks) { task in
                block(task)
            }
            if center.tasks.count > 1 {
                HStack {
                    Spacer()
                    Button(L("Stop All Tasks")) { center.cancelAll() }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 540)
    }

    private func block(_ task: OperationCenter.Task) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: Self.symbol(for: task.activity))
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading(task)).font(.system(size: 15, weight: .semibold))
                    Text(itemLine(task)).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let progress = task.progress, let total = progress.totalBytes, total > 0, progress.phase != .preparing {
                        ProgressView(value: Double(progress.completedBytes), total: Double(total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            HStack {
                Text(status(task)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !task.finished {
                    Button(L("Cancel")) { center.cancel(task.id) }
                }
            }
        }
    }

    private func heading(_ task: OperationCenter.Task) -> String {
        if task.finished, let report = task.report, !report.failures.isEmpty { return L("Completed with Issues") }
        return Self.heading(for: task.activity)
    }

    static func heading(for activity: OperationCenter.Activity) -> String {
        switch activity {
        case .copy: L("Copying…")
        case .move: L("Moving…")
        case .extract: L("Extracting…")
        case .compress: L("Compressing…")
        }
    }

    static func symbol(for activity: OperationCenter.Activity) -> String {
        switch activity {
        case .copy: "arrow.left.arrow.right"
        case .move: "arrow.right"
        case .extract: "arrow.up.bin"
        case .compress: "archivebox"
        }
    }

    /// Current top-level item and its position, e.g. "Photos   2/5".
    private func itemLine(_ task: OperationCenter.Task) -> String {
        let total = max(task.plan.sources.count, 1)
        let index = min((task.progress?.processedItemCount ?? 0) + 1, total)
        let name = task.progress?.currentSource?.lastPathComponent ?? task.plan.sources.first?.lastPathComponent ?? ""
        return "\(name)   \(index)/\(total)"
    }

    private func status(_ task: OperationCenter.Task) -> String {
        if let report = task.report, !report.failures.isEmpty {
            return LF("Completed %lld items; %lld failed", Int64(report.mutations.count), Int64(report.failures.count))
        }
        guard let progress = task.progress, progress.phase != .preparing, let total = progress.totalBytes, total > 0 else {
            return L("Calculating…")
        }
        let unit = AppModel.shared.preferences.fileSizeUnit
        return LF("%@ of %@", FileSizeFormatter.string(progress.completedBytes, unit: unit), FileSizeFormatter.string(total, unit: unit))
    }
}

/// Name conflict at the destination, as in the original: the item's name and the destination folder, an
/// "Apply to all conflicts" checkbox, and Keep Both (default) / Replace / Cancel, where Cancel stops the whole
/// operation.
@MainActor
enum ConflictPrompt {
    static func ask(source: URL, existing: URL) -> (FileConflictResolution, applyToAll: Bool) {
        let alert = makeAlert(existing: existing)
        let response = alert.runModal()
        let all = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.keepBoth, all)
        case .alertSecondButtonReturn: return (.replace, all)
        default: return (.stop, false)
        }
    }

    static func makeAlert(existing: URL) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("An item with the same name already exists at the destination.")
        alert.informativeText = existing.lastPathComponent + "\n" + existing.deletingLastPathComponent().path
        alert.addButton(withTitle: L("Keep Both"))
        alert.addButton(withTitle: L("Replace"))
        alert.addButton(withTitle: L("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = L("Apply to all conflicts")
        return alert
    }
}

extension Notification.Name {
    static let dirDeskFilesChanged = Notification.Name("DirDesk.FilesChanged")
}
