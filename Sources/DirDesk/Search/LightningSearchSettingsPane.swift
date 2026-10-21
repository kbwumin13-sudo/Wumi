import AppKit
import DirDeskCore
import SwiftUI

/// Settings › Lightning Search, laid out like the original: one card with the shortcut note, the watched and
/// ignored folder lists, and Save / Restore Default Settings. The index state only shows when it needs attention.
struct LightningSearchSettingsPane: View {
    @ObservedObject private var service = LightningSearchService.shared
    @State private var watchedText = ""
    @State private var ignoredText = ""
    @State private var error: String?
    @State private var notice: String?
    @State private var loaded = false

    /// Laid out like the original's page: a filled card whose rows sit on an inner dark panel.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Lightning Search"))
                .font(.system(size: 13, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            RowStack(rowPadding: 12) {
                Text(L("Open Lightning Search with Command-F or by pressing D twice. Conditions picked from the menus and queries you type run on the same search engine."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("With Full Disk Access, Wumi prepares the index in the background after launch; otherwise it starts the first time Lightning Search opens."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = statusLine {
                    status
                }
                Text(L("Watched folders")).font(.system(size: 13, weight: .semibold))
                folderEditor(L("Watched folders"), text: $watchedText, height: 75, identifier: "LightningSearch.Settings.Paths")
                Text(L("Ignored folders")).font(.system(size: 13, weight: .semibold))
                folderEditor(L("Ignored folders"), text: $ignoredText, height: 145, identifier: "LightningSearch.Settings.Ignored")
                Text(L("One folder per line as an absolute path; ~ stands for your home folder. Saving different folders rebuilds the index. Folders macOS does not let Wumi read are skipped."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L("Save")) { save() }
                        .disabled(!hasChanges)
                    Button(L("Restore Default Settings")) {
                        watchedText = LightningSearchService.defaultWatchedFolders.joined(separator: "\n")
                        ignoredText = LightningSearchService.defaultIgnoredFolders.joined(separator: "\n")
                        error = nil
                        save()
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(.system(size: 10)).foregroundStyle(.red)
                    } else if let notice {
                        Text(notice).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 29.5)
            .padding(.top, 15)
            .padding(.bottom, 16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.03)))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20.5)
        .padding(.bottom, 21)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The original's outer card here is a plain rectangle.
        .background(Rectangle().fill(Color.primary.opacity(0.04)))
        .onAppear {
            if !loaded {
                revert()
                loaded = true
            }
            service.refreshFullDiskAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service.refreshFullDiskAccess()
        }
    }

    // MARK: Status

    /// Building, partly built, failed or unreadable folders; nothing while the index is simply ready or idle.
    private var statusLine: AnyView? {
        guard service.isStarted else { return nil }
        var lines: [(String, Color)] = []
        switch service.status.stage {
        case .loadingSnapshot: lines.append((L("Loading Search Index…"), .secondary))
        case .indexing: lines.append((LF("Building Search Index… %lld items", Int64(service.status.indexedCount)), .secondary))
        case .limited: lines.append((L("Index resource limit reached. Choose fewer watched folders."), .orange))
        case .failed: lines.append((L("Search index unavailable"), .red))
        case .ready where service.status.isUpdating: lines.append((L("Updating Search Index…"), .secondary))
        case .ready, .idle: break
        }
        if service.status.unreadableFolderCount > 0 {
            lines.append((LF("Folders that could not be read: %lld", Int64(service.status.unreadableFolderCount)), .secondary))
        }
        if let lastError = service.status.lastError {
            lines.append((LightningStatusText.errorText(lastError), .red))
        }
        guard !lines.isEmpty else { return nil }
        return AnyView(VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.0).font(.system(size: 11)).foregroundStyle(line.1)
            }
        })
    }

    // MARK: Folders

    private func folderEditor(_ title: String, text: Binding<String>, height: CGFloat, identifier: String) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4)
            .frame(height: height)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
    }

    private var hasChanges: Bool {
        normalized(watchedText) != service.watchedFolders || normalized(ignoredText) != service.ignoredFolders
    }

    /// The folder list a text would save, for change detection; invalid text counts as changed.
    private func normalized(_ text: String) -> [String]? {
        try? LightningSearchService.parseFolderList(text, allowsEmpty: true).get()
    }

    private func revert() {
        watchedText = service.watchedFolders.joined(separator: "\n")
        ignoredText = service.ignoredFolders.joined(separator: "\n")
        error = nil
    }

    private func save() {
        let watched = LightningSearchService.parseFolderList(watchedText, allowsEmpty: false)
        let ignored = LightningSearchService.parseFolderList(ignoredText, allowsEmpty: true)
        switch (watched, ignored) {
        case let (.success(watchedFolders), .success(ignoredFolders)):
            error = nil
            service.updateFolders(watched: watchedFolders, ignored: ignoredFolders)
            watchedText = watchedFolders.joined(separator: "\n")
            ignoredText = ignoredFolders.joined(separator: "\n")
            notice = service.isStarted ? L("Saved. The index is being rebuilt.") : L("Saved. The new folders are used when the index starts.")
        case (.failure(.empty), _):
            notice = nil
            error = L("Use + to add folders.")
        default:
            notice = nil
            error = L("Enter valid absolute folder paths, one per line.")
        }
    }
}
