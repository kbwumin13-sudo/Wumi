import AppKit
import DirDeskCore
import ImageIO
import PDFKit
import SwiftUI

/// Right-hand inspector: preview, summary, information, tags and quick actions for the selection.
/// In multi-pane layouts the inspector is narrower (260 pt in the original) and its labels sit above their values.
struct InspectorStacksLabelsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var inspectorStacksLabels: Bool {
        get { self[InspectorStacksLabelsKey.self] }
        set { self[InspectorStacksLabelsKey.self] = newValue }
    }
}

/// One title/value line of the inspector: side by side, or stacked when the inspector is narrow.
struct InspectorInfoLine: View {
    let title: String
    let value: String
    @Environment(\.inspectorStacksLabels) private var stacked

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.secondary).font(.system(size: 11))
                    Text(value).textSelection(.enabled).font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // A 27 pt row over a hairline, as in the original; long values (paths) wrap, right-aligned.
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 12)
                        Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 5.5)
                    .frame(minHeight: 26)
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                }
            }
        }
    }
}

struct InspectorView: View {
    @ObservedObject var model: WorkspaceModel
    let controller: WorkspaceController

    var body: some View {
        InspectorContent(pane: model.activePane, controller: controller)
            .id(model.activePane.id)
    }
}

private struct InspectorContent: View {
    @ObservedObject var pane: PaneRuntime
    let controller: WorkspaceController
    @Environment(\.inspectorStacksLabels) private var stacksLabels
    @AppStorage("dirdesk-inspector-preview-height-v1") private var previewHeight: Double = 324
    @State private var thumbnail: NSImage?
    @State private var folderSize: FolderSizeState?
    @State private var repositoryPath: String?

    private struct RepositoryRequest: Equatable {
        let url: URL?
        let revision: Int
    }

    private var subject: FileItem? {
        let selected = pane.selectedItems
        return selected.count == 1 ? selected[0] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if pane.selectedItems.count > 1 {
                multiple
            } else if let item = subject {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // The original shows a repository's Git summary above the folder preview.
                        if item.isBrowsableFolder, AppModel.shared.preferences.showsGitStatus, repositoryPath == item.url.path {
                            GitRepositorySection(url: item.url)
                        }
                        InteractivePreview(item: item, height: previewHeight, enlarge: { controller.showSuperPreview(item) },
                                           openLocation: { url in
                                               controller.navigateActivePane(to: url.deletingLastPathComponent())
                                               controller.activePane.select(urls: [url])
                                           })
                        // Only folder and archive trees get the handle, as in the original.
                        if isTree(item) { resizeHandle }
                        summary(item)
                        information(item)
                        tags(item)
                    }
                    .padding(12)
                }
                Divider()
                actions(item)
            } else {
                Spacer()
                VStack(spacing: 9) {
                    Image(systemName: "sidebar.right").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        .padding(.bottom, 2)
                    Text(L("No Selection")).font(.system(size: 13, weight: .semibold))
                    Text(L("Select a file to preview it.")).foregroundStyle(.secondary).font(.system(size: 11))
                }
                .accessibilityIdentifier("Inspector.Empty")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chrome)
        .task(id: RepositoryRequest(url: subject?.url, revision: pane.directoryContentRevision)) {
            repositoryPath = nil
            guard let item = subject, item.isBrowsableFolder else { return }
            GitRepositoryProbe.invalidate(item.url)
            let isRepository = await GitRepositoryProbe.isRepository(item.url)
            guard !Task.isCancelled else { return }
            repositoryPath = isRepository ? item.url.path : nil
        }
    }

    private var multiple: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "square.stack.3d.up").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(LF("%lld items selected", Int64(pane.selectedItems.count))).font(.system(size: 13, weight: .medium))
            let total = pane.selectedItems.compactMap(\.size).reduce(0, +)
            if total > 0 {
                Text(FileSizeFormatter.string(total, unit: AppModel.shared.preferences.fileSizeUnit)).foregroundStyle(.secondary).font(.system(size: 12))
            }
            Spacer()
        }
    }

    private func isTree(_ item: FileItem) -> Bool {
        let preferences = AppModel.shared.preferences
        switch PreviewKind.kind(for: item) {
        case .folder: return preferences.previewsFolders
        case .archive: return preferences.previewsArchives
        default: return false
        }
    }

    private var resizeHandle: some View {
        Capsule().fill(Color.primary.opacity(0.18)).frame(width: 38, height: 3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(DragGesture().onChanged { value in
                previewHeight = min(max(previewHeight + value.translation.height / 8, 120), 640)
            })
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .padding(.top, 4.5)
            .padding(.bottom, 5)
            .help(L("Drag to resize the preview. File information moves below it."))
            .accessibilityIdentifier("Inspector.Preview.ResizeHeight")
            .accessibilityLabel(L("Preview Height"))
    }

    private func summary(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).font(.system(size: 14, weight: .bold)).textSelection(.enabled).lineLimit(3)
            Text(summaryLine(item)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task(id: RepositoryRequest(url: item.url, revision: pane.directoryContentRevision)) {
            folderSize = nil
            guard FolderSizes.needsMeasurement(item) else { return }
            for await state in FolderSizes.shared.updates(for: item) {
                guard !Task.isCancelled else { return }
                folderSize = state
            }
        }
    }

    private func summaryLine(_ item: FileItem) -> String {
        let kind = pane.kindText(item)
        let unit = AppModel.shared.preferences.fileSizeUnit
        return kind + " · " + FolderSizes.text(item, state: folderSize, unit: unit)
    }

    private func information(_ item: FileItem) -> some View {
        let formatter = FileDateFormatter(locale: Localizer.shared.locale, absolute: true)
        return VStack(alignment: .leading, spacing: 0) {
            // Same rows and order as the original's inspector: created, modified, path, size on disk, then type details.
            Text(L("Information")).font(.system(size: 13, weight: .bold)).padding(.bottom, 12)
            infoRow(L("Created"), formatter.absoluteString(item.creationDate))
            infoRow(L("Modified"), formatter.absoluteString(item.modificationDate))
            infoRow(L("Path"), item.url.path)
            if !item.isBrowsableFolder, let allocated = item.allocatedSize {
                infoRow(L("On Disk"), FileSizeFormatter.string(allocated, unit: AppModel.shared.preferences.fileSizeUnit))
            }
            if !item.isWritable { infoRow(L("Permissions"), L("Read Only")) }
            ItemDetailRows(item: item)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        InspectorInfoLine(title: title, value: value)
    }

    private func tags(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Tags")).font(.system(size: 13, weight: .bold))
            HStack(spacing: 4) {
                ForEach(item.tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Circle().fill(Color(nsColor: TagColors.color(forTag: tag) ?? .tertiaryLabelColor)).frame(width: 8, height: 8)
                        Text(tag).font(.system(size: 11))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Button(L("Add Tags…")) { controller.editTags(for: [item]) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, item.tags.isEmpty ? 6 : 0)
                    .accessibilityIdentifier("Inspector.Tags.Edit")
            }
        }
    }

    /// Rename, Copy, Delete and More as four uniform rounded buttons (28 pt tall, 8 pt apart), as in the original.
    private func actions(_ item: FileItem) -> some View {
        HStack(spacing: 8) {
            actionButton(L("Rename"), "pencil", "Inspector.Rename") {
                pane.selectedIDs = [item.id]
                pane.renamingID = item.id
            }
            actionButton(L("Copy"), "doc.on.doc", "Inspector.Copy") { controller.copyToClipboard([item]) }
            actionButton(L("Delete"), "trash", "Inspector.Trash") { controller.moveToTrash([item], in: pane) }
            Menu {
                ForEach(controller.builtInToolMenuItems(for: [item]), id: \.title) { entry in
                    Button(entry.title, action: entry.action)
                }
            } label: {
                InspectorActionLabel(title: L("More"), symbol: "ellipsis", compact: stacksLabels)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("More"))
            .accessibilityIdentifier("Inspector.BuiltInTools")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 13)
    }

    /// Icon and title; the narrow multi-pane inspector keeps only the icon (the title stays as tooltip and label).
    private func actionButton(_ title: String, _ symbol: String, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            InspectorActionLabel(title: title, symbol: symbol, compact: stacksLabels)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// Label of an inspector action button: glyph and title on a soft rounded fill.
struct InspectorActionLabel: View {
    let title: String
    let symbol: String
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            if !compact {
                Text(title).font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(.leading, compact ? 10 : 12.5)
        .padding(.trailing, compact ? 10 : 13)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.075)))
        .contentShape(Rectangle())
    }
}

/// Static preview: a Quick Look thumbnail, or the icon while it loads.
private struct PreviewBox: View {
    let item: FileItem
    let height: Double
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(8)
            } else {
                Image(nsImage: FileIcons.shared.icon(for: item)).resizable().scaledToFit().frame(width: 96, height: 96)
            }
        }
        .frame(height: height)
        .task(id: item.url) {
            image = nil
            guard !item.isBrowsableFolder else { return }
            FileIcons.shared.thumbnail(for: item, size: 520) { image = $0 }
        }
        .accessibilityIdentifier("Inspector.StaticPreview")
    }
}

/// Repository summary for a folder that contains `.git`.
private struct GitRepositorySection: View {
    let url: URL
    @State private var status: GitRepositoryStatus?
    @State private var error: String?
    @State private var loading = false

    /// Like the original: the branch with a purple branch icon and a refresh button, then one line of colored
    /// counts (staged, unstaged, untracked, conflicts).
    var body: some View {
        // Metrics from the original: 12 pt monospaced branch, 10 pt counts, 21 pt from the inspector's edge.
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.purple)
                if let status {
                    Text(status.isDetached ? L("Detached HEAD") : (status.branch ?? "—"))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    if !status.hasCommits { Text(L("No commits yet")).font(.system(size: 11)).foregroundStyle(.secondary) }
                } else {
                    Text(L("Git Repository")).font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { load() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                        .buttonStyle(.borderless)
                        .help(L("Local status · submodule contents not scanned"))
                        .accessibilityLabel(L("Refresh Git Status"))
                }
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(L("Install Git or retry. Large repositories may exceed the preview time limit.")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let status {
                if status.isClean {
                    Label(L("Clean"), systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                } else {
                    let counts = Dictionary(grouping: status.states.values.flatMap { $0 }, by: { $0 }).mapValues(\.count)
                    HStack(spacing: 11) {
                        ForEach([GitFileState.staged, .unstaged, .untracked, .conflict], id: \.self) { state in
                            if let count = counts[state] {
                                HStack(spacing: 4) {
                                    Image(systemName: Self.symbol(state))
                                    Text(GitBadgeView.title(state))
                                    Text("\(count)")
                                }
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color(nsColor: GitBadgeView.color(state)))
                            }
                        }
                    }
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 7)
        .padding(.top, 8)
        .padding(.bottom, 9.5)
        .task(id: url) { load() }
    }

    private static func symbol(_ state: GitFileState) -> String {
        switch state {
        case .staged: "plus.circle.fill"
        case .unstaged: "pencil.circle.fill"
        case .untracked: "questionmark.circle.fill"
        case .conflict: "exclamationmark.triangle.fill"
        }
    }

    private func load() {
        loading = true
        let url = url
        Task.detached(priority: .utility) {
            let result = Result { try GitStatusService.status(of: url) }
            await MainActor.run {
                loading = false
                switch result {
                case .success(let value):
                    status = value
                    error = nil
                case .failure:
                    status = nil
                    error = L("Git status unavailable")
                }
            }
        }
    }
}

/// Type-specific metadata rows (image size and camera, PDF pages, text encoding, app version, archive items).
private struct ItemDetailRows: View {
    let item: FileItem
    @State private var rows: [(String, String)] = []

    var body: some View {
        // A container, so the task runs even while there are no rows (on a bare ForEach it never would).
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                InspectorInfoLine(title: row.0, value: row.1)
            }
        }
        .task(id: item.url) {
            let item = item
            rows = await Task.detached { Self.details(for: item) }.value
        }
    }

    nonisolated static func details(for item: FileItem) -> [(String, String)] {
        var result: [(String, String)] = []
        let url = item.url
        if let type = item.contentType {
            if type.conforms(to: .image), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                if let w = properties[kCGImagePropertyPixelWidth as String] as? Int, let h = properties[kCGImagePropertyPixelHeight as String] as? Int {
                    result.append((L("Dimensions"), "\(w) × \(h)"))
                }
                let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
                if let camera = (tiff?[kCGImagePropertyTIFFModel as String] as? String) ?? (tiff?[kCGImagePropertyTIFFMake as String] as? String),
                   !camera.isEmpty {
                    result.append((L("Camera"), camera))
                }
            }
            if type.conforms(to: .pdf), let document = PDFDocument(url: url) {
                result.append((L("Pages"), "\(document.pageCount)"))
                if let page = document.page(at: 0) {
                    let size = page.bounds(for: .mediaBox).size
                    result.append((L("Page Size"), "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt"))
                }
            }
            // Encoding and line count for plain text and code, not for web pages or rich text (as in the original).
            let rendered = type.conforms(to: .html) || type.conforms(to: .rtf) || type.conforms(to: .rtfd)
            if !rendered, type.conforms(to: .text) || type.conforms(to: .sourceCode), let decoded = TextPreviewDecoder.decode(url: url, limit: 1 << 20) {
                result.append((L("Encoding"), decoded.encodingName))
                result.append((L("Lines"), decoded.truncated ? "≥ \(decoded.lineCount)" : "\(decoded.lineCount)"))
            }
            if type.conforms(to: .application) || type.conforms(to: .applicationBundle), let bundle = Bundle(url: url) {
                if let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String { result.append((L("Version"), version)) }
                if let identifier = bundle.bundleIdentifier { result.append(("Bundle ID", identifier)) }
            }
        }
        if ArchiveService.isArchive(url), !item.isBrowsableFolder, let index = try? ArchiveService.index(of: url) {
            // The original lists the item count only; encrypted entries show greyed out in the preview instead.
            result.append((L("Archive Items"), "\(index.entries.count)"))
        }
        return result
    }
}
