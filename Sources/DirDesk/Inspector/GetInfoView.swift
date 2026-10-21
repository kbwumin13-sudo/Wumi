import AppKit
import DirDeskCore
import SwiftUI

/// DirDesk's own read-only "Info" window, laid out like the original's (430 × 544 pt, not resizable): large icon,
/// name and kind, then a two-column table with right-aligned labels — Kind, Size, Where, Modified (full date with
/// seconds), Tags, Open With, Permissions, Full Path.
struct GetInfoView: View {
    let item: FileItem
    @State private var folderSize: FolderSizeState?
    @State private var application: String?

    var body: some View {
        let unit = AppModel.shared.preferences.fileSizeUnit
        let kind = FileKindDescriber.describe(item, folderTitle: L("Folder"), aliasTitle: L("Alias"), fileTitle: L("File"))
        // Measured from the original: a 48 × 62 pt document symbol, 16 pt bold name, a divider, then 12 pt rows every
        // 27 pt with right-aligned labels.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24.5) {
                Image(systemName: item.isBrowsableFolder ? "folder.fill" : "doc.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
                    .frame(width: 50, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 16, weight: .bold)).lineLimit(2).textSelection(.enabled)
                    Text(kind).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 6.5)
            .padding(.top, 23)
            Divider().padding(.top, 19)
            Grid(alignment: .topLeading, horizontalSpacing: 19, verticalSpacing: 12) {
                row(L("Kind"), kind)
                row(L("Size"), sizeText(unit))
                row(L("Where"), item.url.deletingLastPathComponent().path)
                row(L("Modified"), item.modificationDate.map(Self.fullDate) ?? "--")
                row(L("Tags"), item.tags.isEmpty ? L("None") : item.tags.joined(separator: ", "))
                row(L("Open With"), application ?? "--")
                row(L("Permissions"), permissions)
                row(L("Full Path"), item.url.path)
            }
            .padding(.top, 18.5)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .frame(width: 430, height: 520, alignment: .topLeading)
        .task {
            let url = item.url
            let isFolder = item.isBrowsableFolder
            async let app = Task.detached { () -> String? in
                // The application's file name ("Preview"), as the original shows it.
                guard !isFolder, let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
                return appURL.deletingPathExtension().lastPathComponent
            }.value
            application = await app
        }
        .task(id: item.url) {
            folderSize = nil
            guard FolderSizes.needsMeasurement(item) else { return }
            for await state in FolderSizes.shared.updates(for: item) {
                guard !Task.isCancelled else { return }
                folderSize = state
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).fontWeight(.semibold).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sizeText(_ unit: FileSizeUnit) -> String {
        FolderSizes.text(item, state: folderSize, unit: unit)
    }

    private var permissions: String {
        switch (item.isReadable, item.isWritable) {
        case (true, true): L("Read & Write")
        case (true, false): L("Read Only")
        case (false, true): L("Write Only")
        case (false, false): L("No Access")
        }
    }

    /// "2026年10月19日 22:55:41" in Chinese; the same long date with seconds in other languages.
    static func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Localizer.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMMd HH:mm:ss")
        return formatter.string(from: date)
    }
}
