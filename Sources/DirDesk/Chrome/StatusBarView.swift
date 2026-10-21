import AppKit
import DirDeskCore
import SwiftUI

/// Window status bar for the active pane: counts, transient operation tip, free space, path, thumbnail size.
struct StatusBarView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var app = AppModel.shared
    @State private var freeSpace: String = ""

    var body: some View {
        StatusBarContent(pane: model.activePane, preferences: app.preferences)
    }
}

private struct StatusBarContent: View {
    /// Where a virtual destination is shown in place of a path: "tag:Name" for a tag view, as in the original.
    static func virtualLocation(_ destination: PaneDestination?) -> String? {
        if case .tag(let name)? = destination { return "tag:" + name }
        return nil
    }

    @ObservedObject var pane: PaneRuntime
    let preferences: WorkspacePreferences
    @State private var freeSpace = ""

    var body: some View {
        HStack(spacing: 10) {
            Text(itemCountText).accessibilityIdentifier("Status.ItemCount")
            if !pane.selectedIDs.isEmpty {
                Text(LF("%@ selected", pane.selectedIDs.count.formatted(.number.locale(Localizer.shared.locale))))
            }
            if preferences.showsOperationTips, let message = pane.operationMessage {
                Text(message).foregroundStyle(.secondary).accessibilityIdentifier("Status.OperationTip")
            }
            if let result = pane.operationResult {
                OperationResultChip(result: result) { pane.operationResult = nil }
            }
            if pane.truncated {
                Text(L("Truncated for performance")).foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            if preferences.showsDiskFreeSpace, !freeSpace.isEmpty {
                Text(LF("%@ available", freeSpace)).accessibilityIdentifier("Status.DiskFreeSpace")
            }
            if let path = pane.currentDirectory?.path ?? Self.virtualLocation(pane.destination) {
                Text(path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.tertiary)
                    .layoutPriority(-1)
                    .accessibilityIdentifier("Status.DirectoryPath")
            }
            // The original shows the thumbnail slider in list and icon views only.
            if pane.viewConfiguration.mode == .list || pane.viewConfiguration.mode == .icons {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1, height: 12).padding(.horizontal, -1)
                Image(systemName: "photo.on.rectangle").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Slider(value: thumbnailBinding, in: thumbnailRange)
                    .controlSize(.mini)
                    .frame(width: 110)
                    .accessibilityIdentifier("Status.ThumbnailSize")
                    .accessibilityLabel(pane.viewConfiguration.mode == .list ? L("List Thumbnail Size") : L("Grid Thumbnail Size"))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 23)
        .task(id: pane.currentDirectory) { updateFreeSpace() }
        .onChange(of: pane.items.count) { _, _ in updateFreeSpace() }
    }

    /// "5,000 个项目": counts use grouping separators like the original.
    private var itemCountText: String {
        let count = pane.rows.filter { $0.item != nil }.count
        let number = count.formatted(.number.locale(Localizer.shared.locale))
        return count == 1 ? LF("%@ item", number) : LF("%@ items", number)
    }

    private var thumbnailRange: ClosedRange<Double> {
        pane.viewConfiguration.mode == .list ? 16...64 : 0.5...2.5
    }

    private var thumbnailBinding: Binding<Double> {
        Binding(get: {
            pane.viewConfiguration.mode == .list ? pane.viewConfiguration.listThumbnailSize : pane.viewConfiguration.gridThumbnailScale
        }, set: { value in
            if pane.viewConfiguration.mode == .list {
                pane.viewConfiguration.listThumbnailSize = value.rounded()
            } else {
                pane.viewConfiguration.gridThumbnailScale = value
            }
        })
    }

    private func updateFreeSpace() {
        guard let url = pane.currentDirectory else {
            freeSpace = ""
            return
        }
        let unit = preferences.fileSizeUnit
        Task.detached(priority: .utility) {
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            let bytes = values?.volumeAvailableCapacityForImportantUsage ?? values?.volumeAvailableCapacity.map(Int64.init) ?? 0
            let text = bytes > 0 ? FileSizeFormatter.string(bytes, unit: unit, style: .capacity) : ""
            await MainActor.run { freeSpace = text }
        }
    }
}

/// "ⓘ Processed 0 items, 1 failed… ×" after a finished operation; the text opens the details.
private struct OperationResultChip: View {
    let result: PaneRuntime.OperationResult
    let dismiss: () -> Void
    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 6) {
            Divider().frame(height: 12)
            Button { showingDetails = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                    Text(result.showsEllipsis ? result.summary + "…" : result.summary).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Status.OperationResult")
            .popover(isPresented: $showingDetails, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.summary).font(.system(size: 12, weight: .semibold))
                    ForEach(Array(result.details.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: 360, alignment: .leading)
            }
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Close"))
        }
    }
}
