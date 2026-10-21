import AppKit
import DirDeskCore
import SwiftUI

/// What a pane shows instead of items: empty folder, empty Recent or tag view, a tag still being checked, the Trash
/// without Full Disk Access, a disconnected device, or another load failure. Drawn over the view mode's own view;
/// empty space stays transparent so clicks, menus and drops still reach the list or grid underneath.
struct PaneStateView: View {
    @ObservedObject var pane: PaneRuntime
    @ObservedObject private var volumes = VolumeMonitor.shared
    let controller: WorkspaceController

    var body: some View {
        Group {
            switch state {
            case .none:
                EmptyView()
            case .emptyFolder:
                ContentUnavailableView {
                    Label(L("Empty Folder"), systemImage: "folder")
                } description: {
                    Text(L("This folder has no items to show."))
                } actions: {
                    Button(L("New Folder")) {
                        controller.activate(pane: pane)
                        controller.newFolder()
                    }
                }
                .accessibilityIdentifier("BrowserPane.Empty")
            case .noResults:
                ContentUnavailableView(L("No Results"), systemImage: "magnifyingglass")
            case .emptyRecent:
                ContentUnavailableView(L("No Recent Items"), systemImage: "clock",
                                       description: Text(L("Nothing was opened in this time range.")))
                    .accessibilityIdentifier("BrowserPane.EmptyRecent")
            case .emptyTag:
                ContentUnavailableView(L("No Tagged Items"), systemImage: "tag",
                                       description: Text(L("No file you can open carries this tag right now.")))
                    .accessibilityIdentifier("BrowserPane.EmptyTag")
            case .checkingTag:
                ContentUnavailableView(L("Checking Tagged Items"), systemImage: "tag",
                                       description: Text(L("Items with this tag appear here once Spotlight has found them.")))
                    .accessibilityIdentifier("BrowserPane.TagSupplementing")
            case .trashNeedsFullDiskAccess:
                ContentUnavailableView {
                    Label(L("Trash Requires Full Disk Access"), systemImage: "trash")
                } description: {
                    Text(L("macOS shows the Trash to Wumi only after Full Disk Access is turned on."))
                } actions: {
                    privacyButtons
                }
                .accessibilityIdentifier("BrowserPane.TrashFullDiskAccess")
            case .accessDenied:
                ContentUnavailableView {
                    Label(L("Full Disk Access"), systemImage: "lock")
                } description: {
                    Text(L("macOS denied access to this folder. Turn on Full Disk Access for Wumi in Privacy & Security, then try again."))
                } actions: {
                    privacyButtons
                }
                .accessibilityIdentifier("BrowserPane.FullDiskAccessPending")
            case .deviceDisconnected(let name):
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(L("Device Disconnected")).font(.system(size: 17, weight: .semibold))
                    Text(LF("“%@” can't be reached. Connect it again to bring this pane back, or switch to a folder on this Mac.", name))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    HStack(spacing: 10) {
                        Button(L("Reconnect")) { reconnect(name) }
                            .buttonStyle(.borderedProminent)
                        Button(L("Go to Local Folder")) {
                            pane.navigate(to: .directory(FileManager.default.homeDirectoryForCurrentUser))
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("BrowserPane.DeviceDisconnected")
            case .failed(let message):
                ContentUnavailableView {
                    Label(message, systemImage: "exclamationmark.triangle")
                } actions: {
                    Button(L("Retry")) { pane.reload() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The volume came back: show its contents again.
        .onChange(of: volumes.volumes) { _, mounted in
            if case .deviceDisconnected(let name) = state, mounted.contains(where: { $0.url.lastPathComponent == name }) { pane.reload() }
        }
    }

    private var privacyButtons: some View {
        VStack(spacing: 14) {
            HStack {
                Button(L("Open Privacy Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(L("Retry")) { pane.reload() }
            }
            FullDiskAccessDragCard().frame(maxWidth: 380)
        }
    }

    private enum State: Equatable {
        case none, emptyFolder, noResults, emptyRecent, emptyTag, checkingTag, trashNeedsFullDiskAccess, accessDenied
        case deviceDisconnected(String)
        case failed(String)
    }

    private var state: State {
        switch pane.loadState {
        case .idle:
            return .none
        case .loading:
            if case .tag = pane.destination, pane.rows.isEmpty { return .checkingTag }
            return .none
        case .failed(let message):
            switch pane.loadFailure {
            case .accessDenied:
                return isTrash ? .trashNeedsFullDiskAccess : .accessDenied
            case .unavailable:
                if let name = disconnectedVolume { return .deviceDisconnected(name) }
                return .failed(message)
            case .notDirectory, .spotlight, nil:
                return .failed(message)
            }
        case .loaded:
            guard pane.rows.isEmpty else { return .none }
            if !pane.searchText.isEmpty { return .noResults }
            switch pane.destination {
            case .recent: return .emptyRecent
            case .tag: return .emptyTag
            case .directory, .allSubfiles, nil: return .emptyFolder
            }
        }
    }

    private var isTrash: Bool {
        guard let directory = pane.currentDirectory else { return false }
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        return directory.standardizedFileURL.path == trash.standardizedFileURL.path
    }

    /// Name of the volume under /Volumes that the pane's folder was on, when that volume is no longer mounted.
    private var disconnectedVolume: String? {
        guard let path = pane.currentDirectory?.standardizedFileURL.path, path.hasPrefix("/Volumes/") else { return nil }
        guard let name = path.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) else { return nil }
        return volumes.volumes.contains(where: { $0.url.lastPathComponent == name }) ? nil : name
    }

    /// Mounts a saved network location whose share has the volume's name again, otherwise just tries the folder again.
    private func reconnect(_ name: String) {
        let saved = NetworkLocationStore.shared.locations.first { location in
            (try? NetworkConnector.normalize(location.address))?.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame
        }
        guard let saved else {
            pane.reload()
            return
        }
        NetworkConnector.connect(address: saved.address) { _ in pane.reload() }
    }
}
