import AppKit
import DirDeskCore
import SwiftUI

/// One task's run in a sheet: the analysis, the preview with its conflicts, the confirmation, the progress and the
/// result. Closing the sheet while the folders are being analyzed cancels the analysis; a sync that has started keeps
/// going and shows in the task list.
struct FolderSyncRunView: View {
    static let size = CGSize(width: 640, height: 520)

    let presetID: UUID
    @ObservedObject var run: FolderSyncRun
    let close: () -> Void
    @ObservedObject private var store = FolderSyncStore.shared
    @State private var confirming = false
    /// The confirmation came straight from the run (no preview), so cancelling it ends the run.
    @State private var confirmationEndsRun = false

    init(presetID: UUID, close: @escaping () -> Void) {
        self.presetID = presetID
        run = FolderSyncStore.shared.run(for: presetID)
        self.close = close
    }

    private var preset: FolderSyncPreset? { store.preset(presetID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear(perform: showRequestedConfirmation)
        .onChange(of: run.confirmationRequested) { _, _ in showRequestedConfirmation() }
        .alert(L("Are You Sure You Want to Sync?"), isPresented: $confirming) {
            Button(L("Sync")) { run.sync() }
            Button(L("Cancel"), role: .cancel) {
                if confirmationEndsRun { finish() }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: Header and content

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(preset?.name ?? L("Folder Sync"))
                .font(.system(size: 18, weight: .bold))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let preset {
                HStack(spacing: 6) {
                    Text(FolderSyncMessages.displayPath(preset.leftURL))
                        .truncationMode(.middle)
                        .help(preset.leftURL.path)
                    Image(systemName: FolderSyncMessages.directionSymbol(preset.direction))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(FolderSyncMessages.direction(preset.direction))
                    Text(FolderSyncMessages.displayPath(preset.rightURL))
                        .truncationMode(.middle)
                        .help(preset.rightURL.path)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if preset == nil, !run.isBusy {
            FolderSyncMessagePanel(symbol: "questionmark.folder", tint: .secondary, text: L("This sync task no longer exists."))
        } else {
            switch run.phase {
            case .idle:
                FolderSyncIdlePanel(notice: run.notice, lastRun: store.lastRun(for: presetID))
            case .analyzing:
                FolderSyncBusyPanel(title: L("Analyzing folder changes…"))
            case .analyzed(let analysis, let presentation):
                FolderSyncAnalysisPanel(analysis: analysis, presentation: presentation, run: run)
            case .syncing:
                FolderSyncProgressPanel(run: run)
            case .finished(let summary):
                FolderSyncResultPanel(summary: summary)
            case .failed(let message):
                FolderSyncMessagePanel(symbol: "exclamationmark.triangle.fill", tint: .orange, text: message)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if case .analyzed(_, let presentation) = run.phase, undecidedCount(presentation) > 0 {
                let count = undecidedCount(presentation)
                Label(count == 1 ? L("1 conflict still needs a decision.") : LF("%lld conflicts still need a decision.", Int64(count)),
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            switch run.phase {
            case .idle:
                Button(L("Close"), action: finish)
                    .keyboardShortcut(.cancelAction)
                Button(L("Run"), action: restart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preset == nil)
            case .analyzing:
                Button(L("Cancel")) {
                    run.cancel()
                    close()
                }
                .keyboardShortcut(.cancelAction)
            case .analyzed(let analysis, let presentation):
                Button(L("Close"), action: finish)
                    .keyboardShortcut(.cancelAction)
                Button(L("Preview Again"), action: reanalyze)
                    .disabled(preset == nil)
                Button(L("Sync")) {
                    confirmationEndsRun = false
                    confirming = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!analysis.hasChanges || undecidedCount(presentation) > 0)
                .accessibilityIdentifier("FolderSync.Sync")
            case .syncing:
                Button(L("Stop")) { run.cancel() }
                Button(L("Close"), action: close)
                    .keyboardShortcut(.cancelAction)
                    .help(L("The sync keeps running after you close this."))
            case .finished:
                Button(L("Preview Again"), action: reanalyze)
                    .disabled(preset == nil)
                Button(L("Done"), action: finish)
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button(L("Close"), action: finish)
                    .keyboardShortcut(.cancelAction)
                Button(L("Try Again"), action: restart)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preset == nil)
            }
        }
    }

    private func undecidedCount(_ presentation: FolderSyncPresentation) -> Int {
        presentation.conflicts.reduce(0) { $0 + (run.decisions[$1.relativePath] == nil ? 1 : 0) }
    }

    private var confirmationMessage: String {
        guard let analysis = run.analysis else { return "" }
        var lines = [LF("Copy Left: %lld", Int64(analysis.copyLeftCount)), LF("Copy Right: %lld", Int64(analysis.copyRightCount)),
                     LF("Updates: %lld", Int64(analysis.updateCount))]
        if analysis.conflictCount > 0 { lines.append(LF("Conflicts: %lld", Int64(analysis.conflictCount))) }
        lines.append("")
        lines.append(L("Updated files replace their older copies. Nothing is deleted."))
        return lines.joined(separator: "\n")
    }

    // MARK: Actions

    private func showRequestedConfirmation() {
        guard run.confirmationRequested else { return }
        run.confirmationRequested = false
        confirmationEndsRun = true
        confirming = true
    }

    /// Runs the task again the way it is set up: with or without the preview.
    private func restart() {
        if let preset { run.start(preset) }
    }

    private func reanalyze() {
        if let preset { run.analyze(preset, then: .review) }
    }

    /// Closes the sheet and forgets a preview or result it was showing.
    private func finish() {
        run.reset()
        close()
    }
}

/// Toolbar › More › Run Folder Sync…: the original's sheet on the browser window, listing the saved tasks with
/// Cancel / Continue. Continue runs the chosen task in the same sheet.
struct FolderSyncRunChooser: View {
    static let size = CGSize(width: 520, height: 420)

    let close: () -> Void
    /// Fits the sheet window to the list or to the run.
    let resize: (CGSize) -> Void
    @ObservedObject private var store = FolderSyncStore.shared
    @State private var selection: UUID?
    @State private var running: UUID?

    init(initialSelection: UUID?, close: @escaping () -> Void, resize: @escaping (CGSize) -> Void) {
        _selection = State(initialValue: initialSelection)
        self.close = close
        self.resize = resize
    }

    var body: some View {
        if let running {
            FolderSyncRunView(presetID: running, close: close)
        } else {
            chooser
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Run Folder Sync"))
                .font(.system(size: 18, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            List(selection: $selection) {
                ForEach(store.presets) { preset in
                    FolderSyncTaskRow(preset: preset).tag(preset.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                if let id = ids.first { proceed(id) }
            }
            .accessibilityIdentifier("FolderSync.Run.Tasks")
            .padding(.top, 12)
            HStack(spacing: 8) {
                Spacer()
                Button(L("Cancel"), action: close)
                    .keyboardShortcut(.cancelAction)
                Button(L("Continue")) {
                    if let selection { proceed(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.flatMap { store.preset($0) } == nil)
                .accessibilityIdentifier("FolderSync.Run.Continue")
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private func proceed(_ id: UUID) {
        guard let preset = store.preset(id) else { return }
        store.run(for: id).start(preset)
        resize(FolderSyncRunView.size)
        running = id
    }
}

extension WorkspaceController {
    /// Toolbar › More › Run Folder Sync…: a sheet on this window. The task syncing this window's folder is selected.
    func showFolderSync() {
        guard let window else { return }
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: FolderSyncRunChooser.size), styleMask: [.titled],
                             backing: .buffered, defer: false)
        let close: () -> Void = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        let resize: (CGSize) -> Void = { [weak sheet] size in
            sheet?.setContentSize(size)
        }
        let presets = FolderSyncStore.shared.presets
        let folder = activePane.currentDirectory?.standardizedFileURL.path
        let match = presets.first { $0.leftURL.standardizedFileURL.path == folder || $0.rightURL.standardizedFileURL.path == folder }
        sheet.contentViewController = NSHostingController(rootView: FolderSyncRunChooser(initialSelection: (match ?? presets.first)?.id,
                                                                                          close: close, resize: resize))
        window.beginSheet(sheet)
    }
}

// MARK: - Panels

/// A short note in orange, such as why a sync did not start.
private struct FolderSyncNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Nothing to show yet: why the run stopped, if it did, and the task's last run.
private struct FolderSyncIdlePanel: View {
    let notice: String?
    let lastRun: FolderSyncHistoryEntry?

    var body: some View {
        VStack(spacing: 10) {
            if let notice { FolderSyncNotice(text: notice) }
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(FolderSyncMessages.lastRun(lastRun))
                .font(.system(size: 13, weight: .medium))
            if let lastRun {
                Text(FolderSyncMessages.details(lastRun))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FolderSyncBusyPanel: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A symbol over a message, such as why a run failed.
private struct FolderSyncMessagePanel: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(tint)
            Text(text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The preview: counts, conflicts with a decision for each, and the items each action will touch.
private struct FolderSyncAnalysisPanel: View {
    let analysis: FolderSyncAnalysis
    let presentation: FolderSyncPresentation
    @ObservedObject var run: FolderSyncRun

    static let conflictRowLimit = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                counts
                if let notice = run.notice { FolderSyncNotice(text: notice) }
                if !analysis.unreadableFolders.isEmpty { unreadableFolders }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            if analysis.hasChanges {
                list
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                    Text(L("The folders are already in sync.")).font(.system(size: 13, weight: .medium))
                    Text(L("Nothing needs to be copied.")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: Counts

    private var counts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                transferChips
                stateChips
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { transferChips }
                HStack(spacing: 6) { stateChips }
            }
        }
    }

    @ViewBuilder private var transferChips: some View {
        chip(LF("Copy Left: %lld", Int64(analysis.copyLeftCount)), symbol: "arrow.left", tint: .primary)
        chip(LF("Copy Right: %lld", Int64(analysis.copyRightCount)), symbol: "arrow.right", tint: .primary)
        chip(LF("Updates: %lld", Int64(analysis.updateCount)), symbol: "arrow.triangle.2.circlepath", tint: .primary)
    }

    @ViewBuilder private var stateChips: some View {
        chip(LF("Conflicts: %lld", Int64(analysis.conflictCount)), symbol: "exclamationmark.triangle",
             tint: analysis.conflictCount > 0 ? .orange : .secondary)
        chip(LF("Unchanged: %lld", Int64(presentation.unchangedCount)), symbol: "checkmark", tint: .secondary)
        if presentation.skippedCount > 0 {
            chip(LF("Skipped: %lld", Int64(presentation.skippedCount)), symbol: "forward", tint: .secondary)
        }
    }

    private func chip(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .fixedSize()
    }

    private var unreadableFolders: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(analysis.unreadableFolders.prefix(50), id: \.self) { url in
                    Text(FolderSyncMessages.displayPath(url))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                }
            }
        } label: {
            Label(unreadableTitle, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        }
    }

    private var unreadableTitle: String {
        let count = analysis.unreadableFolders.count
        return count == 1 ? L("1 folder could not be read. Its contents are not included.")
            : LF("%lld folders could not be read. Their contents are not included.", Int64(count))
    }

    // MARK: Items

    private var list: some View {
        List {
            if !presentation.conflicts.isEmpty {
                Section {
                    ForEach(presentation.conflicts.prefix(Self.conflictRowLimit), id: \.relativePath) { item in
                        FolderSyncConflictRow(item: item, decision: decision(for: item.relativePath))
                    }
                    if presentation.conflicts.count > Self.conflictRowLimit {
                        Text(LF("%lld more conflicts are not listed. Use Apply to All to decide them.",
                                Int64(presentation.conflicts.count - Self.conflictRowLimit)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(L("Conflicts"))
                        Text(verbatim: "\(presentation.conflicts.count)").foregroundStyle(.secondary)
                        Spacer()
                        Menu(L("Apply to All")) {
                            ForEach(FolderSyncMessages.decisions, id: \.self) { decision in
                                Button(FolderSyncMessages.decision(decision)) { run.applyToAllConflicts(decision) }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.borderless)
                        .fixedSize()
                    }
                }
            }
            ForEach(presentation.groups) { group in
                Section {
                    ForEach(group.items, id: \.relativePath) { item in
                        FolderSyncItemRow(item: item, kind: group.kind, direction: analysis.preset.direction)
                    }
                    if group.totalCount > group.items.count {
                        Text(LF("and %lld more", Int64(group.totalCount - group.items.count)))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(Self.title(group.kind))
                        Text(verbatim: "\(group.totalCount)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func decision(for path: String) -> Binding<FolderSyncConflictDecision?> {
        Binding(get: { run.decisions[path] }, set: { run.decisions[path] = $0 })
    }

    static func title(_ kind: FolderSyncPresentation.GroupKind) -> String {
        switch kind {
        case .copyToRight: L("Copy to Right")
        case .copyToLeft: L("Copy to Left")
        case .updateRight: L("Update in Right Folder")
        case .updateLeft: L("Update in Left Folder")
        case .skipped: L("Skipped")
        }
    }
}

private struct FolderSyncConflictRow: View {
    let item: FolderSyncAnalysisItem
    @Binding var decision: FolderSyncConflictDecision?

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: FolderSyncItemRow.symbol(for: item))
                .foregroundStyle(.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.relativePath)
                if let reason = item.conflictReason {
                    Text(FolderSyncMessages.reason(reason))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(FolderSyncMessages.reason(reason))
                }
                Text(LF("Left: %@", Self.describe(item.left)) + "    " + LF("Right: %@", Self.describe(item.right)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Picker("", selection: $decision) {
                Text(L("Choose…")).tag(FolderSyncConflictDecision?.none)
                ForEach(FolderSyncMessages.decisions, id: \.self) { decision in
                    Text(FolderSyncMessages.decision(decision)).tag(FolderSyncConflictDecision?.some(decision))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    static func describe(_ entry: FolderSyncEntry?) -> String {
        guard let entry else { return L("Not present") }
        let modified = FolderSyncMessages.dateText(entry.fingerprint.modificationDate)
        switch entry.kind {
        case .directory: return L("Folder")
        case .symbolicLink: return L("Symbolic link") + ", " + modified
        case .file: return FolderSyncMessages.size(entry.fingerprint.size) + ", " + modified
        }
    }
}

private struct FolderSyncItemRow: View {
    let item: FolderSyncAnalysisItem
    let kind: FolderSyncPresentation.GroupKind
    let direction: FolderSyncDirection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(for: item))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(item.relativePath)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.relativePath)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var detail: String {
        switch kind {
        case .skipped: Self.skipReason(item, direction: direction)
        case .copyToRight, .updateRight: Self.size(of: item.left)
        case .copyToLeft, .updateLeft: Self.size(of: item.right)
        }
    }

    private static func size(of entry: FolderSyncEntry?) -> String {
        guard let entry else { return "" }
        switch entry.kind {
        case .file: return FolderSyncMessages.size(entry.fingerprint.size)
        case .directory: return L("Folder")
        case .symbolicLink: return L("Symbolic link")
        }
    }

    static func symbol(for item: FolderSyncAnalysisItem) -> String {
        switch (item.left ?? item.right)?.kind {
        case .directory: "folder"
        case .symbolicLink: "link"
        case .file, nil: "doc"
        }
    }

    static func skipReason(_ item: FolderSyncAnalysisItem, direction: FolderSyncDirection) -> String {
        if let reason = item.conflictReason { return FolderSyncMessages.reason(reason) }
        switch (item.left, item.right) {
        case (.some, nil): return L("Only in the left folder")
        case (nil, .some): return L("Only in the right folder")
        case (.some, .some):
            switch direction {
            case .updateRight: return L("The right folder has the newer copy")
            case .updateLeft: return L("The left folder has the newer copy")
            case .updateBoth: return L("Not changed since the last sync")
            }
        case (nil, nil): return ""
        }
    }
}

private struct FolderSyncProgressPanel: View {
    @ObservedObject var run: FolderSyncRun

    var body: some View {
        VStack(spacing: 10) {
            Text(L("Syncing…")).font(.system(size: 13, weight: .medium))
            if let progress = run.progress, progress.totalItemCount > 0 {
                ProgressView(value: Double(progress.processedItemCount), total: Double(progress.totalItemCount))
                HStack {
                    Text(LF("%lld of %lld items", Int64(progress.processedItemCount), Int64(progress.totalItemCount)))
                    Spacer()
                    if progress.totalBytes > 0 {
                        Text(LF("%@ of %@", FolderSyncMessages.size(progress.completedBytes), FolderSyncMessages.size(progress.totalBytes)))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                Text(progress.currentRelativePath ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .frame(maxWidth: 440)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FolderSyncResultPanel: View {
    let summary: FolderSyncRunSummary

    private var result: FolderSyncHistoryEntry.Result { FolderSyncHistoryEntry.Result(summary.outcome) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: FolderSyncMessages.resultSymbol(result))
                    .font(.system(size: 28))
                    .foregroundStyle(FolderSyncMessages.resultColor(result))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(LF("Copied to left: %lld", Int64(summary.copiedToLeftCount)) + " · "
                         + LF("Copied to right: %lld", Int64(summary.copiedToRightCount)))
                        .foregroundStyle(.secondary)
                    Text(FolderSyncMessages.dateText(summary.finishedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            if summary.failures.isEmpty {
                Spacer(minLength: 0)
            } else {
                Text(summary.failures.count == 1 ? L("1 item could not be synced:")
                     : LF("%lld items could not be synced:", Int64(summary.failures.count)))
                    .font(.system(size: 12, weight: .semibold))
                List(Array(summary.failures.enumerated()), id: \.offset) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.element.relativePath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.element.message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        switch summary.outcome {
        case .completed: L("Sync completed")
        case .completedWithIssues: L("Sync completed with issues")
        case .cancelled: L("Sync cancelled")
        case .failed: L("Sync failed")
        }
    }
}
