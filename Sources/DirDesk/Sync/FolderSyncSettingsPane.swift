import AppKit
import DirDeskCore
import SwiftUI

/// Settings > Folder Sync, as in the original: a note, the saved tasks (or an empty state) in one box, and
/// Run / Edit / New / Delete below it. New and Edit open the task editor and Run opens the run, each as a sheet
/// over the Settings window.
struct FolderSyncSettingsPane: View {
    /// The sheet over the Settings window.
    private enum Sheet: Identifiable {
        case editor(FolderSyncEditorRequest)
        case run(UUID)

        var id: String {
            switch self {
            case .editor(let request): "editor-" + request.id
            case .run(let id): "run-" + id.uuidString
            }
        }
    }

    @ObservedObject private var store = FolderSyncStore.shared
    @State private var selection: UUID?
    @State private var pendingDeletion: FolderSyncPreset?
    @State private var sheet: Sheet?

    private var selected: FolderSyncPreset? { selection.flatMap { store.preset($0) } }
    private var selectedIsRunning: Bool { selection.map { store.runningPresetIDs.contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Save folder sync tasks, then run them yourself or let them keep folders up to date automatically."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            taskBox
                .frame(height: 360)
            HStack(spacing: 8) {
                Button(L("Run")) { if let selected { run(selected) } }
                    .disabled(selected == nil || selectedIsRunning)
                    .accessibilityIdentifier("FolderSync.Run")
                Button(L("Edit")) { if let selected { sheet = .editor(.edit(selected)) } }
                    .disabled(selected == nil || selectedIsRunning)
                    .accessibilityIdentifier("FolderSync.Edit")
                Button(L("New")) { sheet = .editor(.new) }
                    .accessibilityIdentifier("FolderSync.New")
                Button(L("Delete")) { pendingDeletion = selected }
                    .disabled(selected == nil || selectedIsRunning)
                    .accessibilityIdentifier("FolderSync.Delete")
            }
                if let error = store.saveError, sheet == nil {
                Text(error).font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .onAppear { if selected == nil { selection = store.presets.first?.id } }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .editor(let request):
                FolderSyncEditorView(request: request, save: save) { self.sheet = nil }
            case .run(let id):
                FolderSyncRunView(presetID: id) { self.sheet = nil }
            }
        }
        .alert(L("Delete Task"), isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
               presenting: pendingDeletion) { preset in
            Button(L("Delete Task"), role: .destructive) {
                store.delete(preset.id)
                pendingDeletion = nil
                selection = store.presets.first?.id
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { preset in
            Text(LF("“%@” and its run history will be removed. The files in its folders are not changed.", preset.name))
        }
    }

    @ViewBuilder private var taskBox: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Group {
            if store.presets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 6)
                    Text(L("No Sync Tasks")).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    Text(L("Create a task to keep changes in step between two folders."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(store.presets) { preset in
                        FolderSyncTaskRow(preset: preset).tag(preset.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first, let preset = store.preset(id), !store.runningPresetIDs.contains(id) {
                        sheet = .editor(.edit(preset))
                    }
                }
                .accessibilityIdentifier("FolderSync.Tasks")
            }
        }
        .background(shape.fill(Color.primary.opacity(0.015)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    }

    /// Runs a task in a sheet: its preview first, or straight to the confirmation when the task skips the preview.
    private func run(_ preset: FolderSyncPreset) {
        store.run(for: preset.id).start(preset)
        sheet = .run(preset.id)
    }

    /// The editor's Save and Sync Now. A failed save keeps the editor open with the error.
    private func save(_ preset: FolderSyncPreset, runNow: Bool) {
        guard store.save(preset) else { return }
        selection = preset.id
        if runNow {
            run(preset)
        } else {
            sheet = nil
        }
    }
}

/// One saved task: direction, name, both folders, the schedule and the last run (or that it is running).
struct FolderSyncTaskRow: View {
    let preset: FolderSyncPreset
    @ObservedObject private var store = FolderSyncStore.shared

    var body: some View {
        let running = store.runningPresetIDs.contains(preset.id)
        let lastRun = store.lastRun(for: preset.id)
        let status = running ? L("Running…") : FolderSyncMessages.lastRun(lastRun)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: FolderSyncMessages.directionSymbol(preset.direction))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.green)
                .frame(width: 22)
                .accessibilityLabel(FolderSyncMessages.direction(preset.direction))
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name).font(.system(size: 13, weight: .medium))
                HStack(spacing: 6) {
                    Text(FolderSyncMessages.displayPath(preset.leftURL))
                        .truncationMode(.middle)
                        .help(preset.leftURL.path)
                    Text(verbatim: FolderSyncMessages.directionArrow(preset.direction))
                        .layoutPriority(1)
                    Text(FolderSyncMessages.displayPath(preset.rightURL))
                        .truncationMode(.middle)
                        .help(preset.rightURL.path)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(FolderSyncMessages.schedule(preset.schedule) + " · " + status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(lastRun.map(FolderSyncMessages.details) ?? status)
            }
            Spacer(minLength: 8)
            if running {
                ProgressView().controlSize(.small)
            } else if let lastRun, lastRun.result != .completed, lastRun.result != .cancelled {
                Image(systemName: FolderSyncMessages.resultSymbol(lastRun.result))
                    .foregroundStyle(FolderSyncMessages.resultColor(lastRun.result))
                    .help(FolderSyncMessages.result(lastRun.result))
            }
        }
        .padding(.vertical, 6)
    }
}
