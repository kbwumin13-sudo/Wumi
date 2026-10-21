import AppKit
import DirDeskCore
import SwiftUI

/// Stop flag shared with work running off the main thread.
final class ToolCancellation: @unchecked Sendable {
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

/// One unit of a tool run, usually one source file. `work` runs off the main thread.
struct ToolJob: Sendable {
    var name: String
    var work: @Sendable (ToolCancellation) throws -> ToolJobOutput
}

struct ToolJobOutput: Sendable {
    var outputs: [URL]
    /// Shown in the report, e.g. "Compressed from 3.2 MB to 840 KB".
    var detail: String?

    init(outputs: [URL], detail: String? = nil) {
        self.outputs = outputs
        self.detail = detail
    }
}

struct ToolJobResult: Identifiable, Sendable {
    /// Index of the job in its run.
    let id: Int
    let name: String
    var outputs: [URL] = []
    var detail: String?
    var failure: String?
    /// The job stopped because the run was cancelled; it is neither a success nor a failure.
    var wasCancelled = false
}

enum ToolReportPolicy {
    /// Report only failures, cancellations and outputs that the active pane does not show.
    case automatic
    /// Always end with the report (tools whose result sizes matter).
    case always
}

@MainActor
final class ToolRunProgress: ObservableObject {
    @Published var completed = 0
    @Published var total: Int
    @Published var currentName = ""
    @Published var isCancelling = false

    init(total: Int) {
        self.total = total
    }
}

/// Runs jobs one at a time with a progress sheet and Cancel, then refreshes the panes, selects the
/// outputs, registers one undo step that moves them to the Trash, and reports what happened.
@MainActor
final class BuiltInToolRun {
    private let session: BuiltInToolSession
    private let jobs: [ToolJob]
    private let policy: ToolReportPolicy
    private let progress: ToolRunProgress
    private let cancellation = ToolCancellation()
    private var finished = false

    /// Starts `jobs` in `session`. With `showsProgressImmediately` false, the progress sheet appears only
    /// when the work takes longer than a moment, so quick one-click tools do not flash a sheet.
    @discardableResult
    static func start(_ jobs: [ToolJob], in session: BuiltInToolSession, report policy: ToolReportPolicy = .automatic,
                      showsProgressImmediately: Bool = true) -> BuiltInToolRun {
        let run = BuiltInToolRun(session: session, jobs: jobs, policy: policy)
        run.begin(showsProgressImmediately: showsProgressImmediately)
        return run
    }

    private init(session: BuiltInToolSession, jobs: [ToolJob], policy: ToolReportPolicy) {
        self.session = session
        self.jobs = jobs
        self.policy = policy
        progress = ToolRunProgress(total: jobs.count)
    }

    private func begin(showsProgressImmediately: Bool) {
        let cancellation = self.cancellation
        session.onEnd { cancellation.cancel() }
        if showsProgressImmediately {
            showProgress()
        } else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !self.finished else { return }
                self.showProgress()
            }
        }
        let jobs = self.jobs
        let progress = self.progress
        Task { [self] in
            var results: [ToolJobResult] = []
            for (index, job) in jobs.enumerated() {
                if cancellation.isCancelled { break }
                progress.completed = index
                progress.currentName = job.name
                let result = await Self.perform(job, index: index, cancellation: cancellation)
                if !result.wasCancelled { results.append(result) }
            }
            progress.completed = results.count
            finished = true
            let outputs = results.filter { $0.failure == nil }.flatMap(\.outputs)
            let directories = session.controller?.model.allPanes.compactMap(\.currentDirectory) ?? []
            finish(results, locations: await ToolLocations.resolve(outputs: outputs, directories: directories))
        }
    }

    private nonisolated static func perform(_ job: ToolJob, index: Int, cancellation: ToolCancellation) async -> ToolJobResult {
        await Task.detached(priority: .userInitiated) { () -> ToolJobResult in
            var result = ToolJobResult(id: index, name: job.name)
            do {
                let output = try job.work(cancellation)
                result.outputs = output.outputs
                result.detail = output.detail
            } catch where BuiltInToolErrorText.isCancellation(error) {
                cancellation.cancel()
                result.wasCancelled = true
            } catch {
                result.failure = BuiltInToolErrorText.message(for: error)
            }
            return result
        }.value
    }

    private func showProgress() {
        let cancellation = self.cancellation
        let progress = self.progress
        session.show(ToolProgressView(title: session.title, progress: progress) {
            progress.isCancelling = true
            cancellation.cancel()
        }, size: NSSize(width: 460, height: 190), minimumSize: nil)
    }

    private func finish(_ results: [ToolJobResult], locations: ToolLocations) {
        finished = true
        let cancelled = cancellation.isCancelled
        let succeeded = results.filter { $0.failure == nil }
        let outputs = succeeded.flatMap(\.outputs)
        guard let controller = session.controller else {
            session.end()
            return
        }
        var outputsVisible = true
        if !outputs.isEmpty {
            controller.refreshPanes(showing: locations.foldersToRefresh(for: outputs))
            let pane = controller.activePane
            let current = pane.currentDirectory.map(locations.path(ofDirectory:))
            let visible = outputs.filter { locations.folderPath(of: $0) == current }
            outputsVisible = visible.count == outputs.count
            if !visible.isEmpty { pane.select(urls: locations.selectionURLs(for: visible)) }
            controller.registerTrashUndo(outputs, name: session.title)
        }
        guard !session.isEnded else { return }
        let failures = results.filter { $0.failure != nil }
        if cancelled && outputs.isEmpty {
            session.end()
            flash(L("Tool operation cancelled"), in: controller)
            return
        }
        if policy == .always || cancelled || !failures.isEmpty || !outputsVisible {
            showReport(results, cancelled: cancelled, locations: locations)
            return
        }
        session.end()
        // Like the reference: the new files stay selected and the status bar reads "ⓘ Created 1 file ×".
        let created = LF("Created %@", ToolText.fileCount(outputs.count))
        let summary = results.count == 1 ? (results[0].detail ?? created) : created
        controller.activePane.operationResult = PaneRuntime.OperationResult(summary: summary, details: outputs.map(\.lastPathComponent),
                                                                            showsEllipsis: false)
    }

    private func flash(_ message: String, in controller: WorkspaceController) {
        controller.activePane.operationMessage = message
        controller.clearOperationMessage(after: 4)
    }

    private func showReport(_ results: [ToolJobResult], cancelled: Bool, locations: ToolLocations) {
        let failed = results.filter { $0.failure != nil }.map(\.id)
        let retryJobs = cancelled ? [] : failed.map { jobs[$0] }
        let outputs = results.filter { $0.failure == nil }.flatMap(\.outputs)
        let session = self.session
        let view = ToolReportView(
            title: session.title, results: results, cancelled: cancelled, totalCount: jobs.count,
            onRetry: retryJobs.isEmpty ? nil : {
                BuiltInToolRun.start(retryJobs, in: session, report: .automatic)
            },
            onReveal: outputs.isEmpty ? nil : {
                session.end()
                BuiltInToolRun.reveal(outputs, locations: locations, in: session.controller)
            },
            onDone: { session.end() })
        let rows = min(results.count, 6)
        session.show(view, size: NSSize(width: 560, height: CGFloat(250 + rows * 44)), minimumSize: NSSize(width: 480, height: 300))
    }

    /// Opens the first output's folder in the active pane and selects the outputs in it.
    static func reveal(_ outputs: [URL], locations: ToolLocations, in controller: WorkspaceController?) {
        guard let controller, let first = outputs.first else { return }
        let folderPath = locations.folderPath(of: first)
        let targets = locations.selectionURLs(for: outputs.filter { locations.folderPath(of: $0) == folderPath })
        if let current = controller.activePane.currentDirectory, locations.path(ofDirectory: current) == folderPath {
            controller.refreshPanes(showing: [current])
        } else {
            controller.navigateActivePane(to: URL(fileURLWithPath: folderPath, isDirectory: true))
        }
        controller.activePane.select(urls: targets)
    }
}

/// Real paths (symlinks such as /tmp resolved) of tool outputs and pane folders, worked out off the main
/// thread. Folder listings report real paths, while a pane may show a folder through a symlinked path.
struct ToolLocations: Sendable {
    var outputs: [URL: URL] = [:]
    var directories: [URL: String] = [:]

    static func resolve(outputs: [URL], directories: [URL]) async -> ToolLocations {
        await Task.detached(priority: .userInitiated) {
            var locations = ToolLocations()
            for url in outputs { locations.outputs[url] = URL(fileURLWithPath: realPath(url)) }
            for url in directories { locations.directories[url] = realPath(url) }
            return locations
        }.value
    }

    /// `url`'s path with every symlink resolved, or its standardized path when that fails.
    nonisolated static func realPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func path(ofDirectory url: URL) -> String {
        directories[url] ?? url.standardizedFileURL.path
    }

    func folderPath(of output: URL) -> String {
        (outputs[output] ?? output.standardizedFileURL).deletingLastPathComponent().path
    }

    /// Both spellings of each output, so the pane matches whichever one its listing uses.
    func selectionURLs(for urls: [URL]) -> [URL] {
        urls + urls.compactMap { outputs[$0] }.filter { !urls.contains($0) }
    }

    /// Output folders plus every pane folder that is one of them under another path.
    func foldersToRefresh(for outputs: [URL]) -> [URL] {
        let paths = Set(outputs.map(folderPath(of:)))
        var folders = outputs.map { $0.deletingLastPathComponent().standardizedFileURL }
        folders += directories.filter { paths.contains($0.value) }.map(\.key)
        return folders
    }
}

// MARK: - Views

struct ToolProgressView: View {
    let title: String
    @ObservedObject var progress: ToolRunProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if progress.total > 1 {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                Text(LF("Processing %lld of %lld…", Int64(min(progress.completed + 1, progress.total)), Int64(progress.total)))
                    .font(.system(size: 12))
                    .monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
                Text(L("Processing…")).font(.system(size: 12))
            }
            Text(progress.currentName.isEmpty ? " " : progress.currentName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(alignment: .bottom) {
                Text(L("Files are processed one at a time. Cancelling never changes the originals."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(progress.isCancelling ? L("Cancelling…") : L("Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress.isCancelling)
                    .accessibilityIdentifier("BuiltInTool.Progress.Cancel")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BuiltInTool.Progress")
    }
}

struct ToolReportView: View {
    let title: String
    let results: [ToolJobResult]
    let cancelled: Bool
    let totalCount: Int
    let onRetry: (() -> Void)?
    let onReveal: (() -> Void)?
    let onDone: () -> Void

    private var failedCount: Int { results.filter { $0.failure != nil }.count }
    private var createdCount: Int { results.filter { $0.failure == nil }.reduce(0) { $0 + $1.outputs.count } }

    private var headline: String {
        if cancelled { return L("Tool operation cancelled") }
        if failedCount == 0 { return results.count == 1 ? L("1 item processed") : LF("%lld items processed", Int64(results.count)) }
        return totalCount == 1 ? L("The file could not be processed") : L("Some files could not be processed")
    }

    private var symbol: (name: String, color: Color) {
        if cancelled { return ("stop.circle.fill", .secondary) }
        return failedCount == 0 ? ("checkmark.circle.fill", .green) : ("exclamationmark.triangle.fill", .orange)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol.name)
                    .font(.system(size: 26))
                    .foregroundStyle(symbol.color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(headline).font(.headline)
                    Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        ToolReportRow(result: result)
                        Divider().opacity(0.5)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                if let onRetry {
                    Button(L("Retry Failed Items"), action: onRetry)
                }
                Spacer()
                if let onReveal {
                    Button(L("Reveal Outputs"), action: onReveal)
                        .accessibilityIdentifier("BuiltInTool.Report.Reveal")
                }
                Button(L("Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("BuiltInTool.Report.Done")
                Button("", action: onDone).keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("BuiltInTool.Report")
    }

    private var summary: String {
        var text = LF("%lld created · %lld failed", Int64(createdCount), Int64(failedCount))
        if cancelled, totalCount > results.count {
            text += " · " + LF("%lld not started", Int64(totalCount - results.count))
        }
        return text
    }
}

private struct ToolReportRow: View {
    let result: ToolJobResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.failure == nil ? "checkmark.circle" : "xmark.octagon")
                .foregroundStyle(result.failure == nil ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let failure = result.failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    if let detail = result.detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !result.outputs.isEmpty {
                        Text(result.outputs.map(\.lastPathComponent).joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }
}
