import AppKit
import PDFKit
import ImageIO
import DirDeskCore
import SwiftUI

/// Super Preview: a large preview panel over the workspace window. Folders and archives show their tree with
/// a detail preview of the clicked file or archive entry; other items show their full-size preview.
/// Esc, Space or a click outside closes it; Return opens the item.
@MainActor
final class SuperPreviewController: NSObject, NSWindowDelegate {
    static let shared = SuperPreviewController()
    private var panel: SuperPreviewPanel?
    private var monitors: [Any] = []
    private weak var controller: WorkspaceController?
    private var item: FileItem?

    var isVisible: Bool { panel?.isVisible == true }

    /// Space in a browser: folders and archives (when enabled in Settings) use Super Preview, everything else Quick Look.
    /// Space opens this window for every file the app previews itself (images, PDF, text, Markdown, media), as
    /// the original does; folders and archives follow their Settings › Preview switches. Other types (Office
    /// documents and the like) go to the system's Quick Look.
    static func handlesSpace(for items: [FileItem]) -> Bool {
        guard items.count == 1, let item = items.first else { return false }
        let preferences = AppModel.shared.preferences
        switch PreviewKind.kind(for: item) {
        case .folder: return preferences.previewsFolders
        case .archive: return preferences.previewsArchives
        case .image, .pdf, .video, .audio, .text, .markdown: return true
        case .quickLook, .icon: return false
        }
    }

    func toggle(_ item: FileItem, controller: WorkspaceController) {
        if isVisible, self.item?.url == item.url { close() } else { show(item, controller: controller) }
    }

    /// `archiveEntry` (an archive tree node's path) opens the preview with that entry already shown.
    func show(_ item: FileItem, controller: WorkspaceController, archiveEntry: String? = nil) {
        close()
        guard let parent = controller.window else { return }
        self.item = item
        self.controller = controller
        // 980 × 680 pt centred on the main window, as in the original (smaller only when the window is).
        let size = NSSize(width: min(980, max(640, parent.frame.width - 40)), height: min(680, max(460, parent.frame.height - 40)))
        let frame = NSRect(x: parent.frame.midX - size.width / 2, y: parent.frame.midY - size.height / 2, width: size.width, height: size.height)
        let panel = SuperPreviewPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityIdentifier("SuperPreview.Window")
        // Only the close button, as in the original.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: SuperPreviewView(item: item, controller: controller, initialEntry: archiveEntry) { [weak self] in
            self?.close()
        })
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        panel.onCancel = { [weak self] in self?.close() }
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        // A click in any other window of the app closes the preview.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let panel = self?.panel, event.window !== panel { self?.close() }
            return event
        } as Any)
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        controller?.window?.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel = nil
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard flags.isEmpty else { return false }
        switch event.keyCode {
        case 53, 49: // Esc, Space
            close()
            return true
        case 36, 76: // Return
            if let item, let controller {
                close()
                controller.open([item], in: controller.activePane, newTab: false)
            }
            return true
        default:
            return false
        }
    }
}

final class SuperPreviewPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct SuperPreviewView: View {
    let item: FileItem
    let controller: WorkspaceController
    var initialEntry: String? = nil
    let close: () -> Void
    @State private var detail: FileItem?
    @State private var detailState: DetailState = .empty
    @State private var thumbnail: NSImage?
    @State private var entryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DirDesk-SuperPreview-\(UUID().uuidString)", isDirectory: true)

    enum DetailState: Equatable { case empty, loading, failed(String) }

    private var kind: PreviewKind { PreviewKind.kind(for: item) }
    private var isTree: Bool {
        (kind == .folder && AppModel.shared.preferences.previewsFolders) || (kind == .archive && AppModel.shared.preferences.previewsArchives)
    }

    /// Laid out like the original's 980 × 680 window: a 56 pt header (icon, name, the folder's full path in a
    /// monospaced font, four buttons) under the window's close button, then the preview. Folders and archives
    /// split into the tree and, on the right half, the clicked item.
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            if isTree {
                HStack(spacing: 0) {
                    PreviewContent(item: item, openLocation: { openLocation($0) }, selectFile: { selectFile($0) },
                                   selectArchiveEntry: { previewEntry(path: $0.id) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
                    detailPane.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                PreviewContent(item: item, showsImageRotation: true, openLocation: { openLocation($0) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Pictures, PDFs and media sit on a lighter field; rendered Markdown does not.
                    .background(Color.primary.opacity(kind == .markdown ? 0 : 0.05))
            }
        }
        .background(Theme.chrome)
        .ignoresSafeArea()
        .frame(minWidth: 600, minHeight: 420)
        .task { if let initialEntry { previewEntry(path: initialEntry) } }
        .onDisappear { try? FileManager.default.removeItem(at: entryDirectory) }
    }

    private var header: some View {
        HStack(spacing: 0) {
            // Pictures and PDFs show a thumbnail here, other items their icon, as in the original.
            Image(nsImage: thumbnail ?? FileIcons.shared.icon(forPath: item.url.path)).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .padding(.leading, 52)
                .task(id: item.url) {
                    guard kind == .image || kind == .pdf else { return }
                    let url = item.url, isPDF = kind == .pdf
                    thumbnail = await Task.detached { isPDF ? Self.pdfThumbnail(url) : Self.thumbnail(url) }.value
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                // The containing folder's full path, monospaced, as in the original.
                Text(item.url.deletingLastPathComponent().path)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, 8)
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                headerButton(L("Open Location"), "folder", id: "EnhancedPreview.OpenLocation") { openLocation(item.url) }
                headerButton(L("Copy"), "doc.on.doc", id: "EnhancedPreview.Copy") { controller.copyToClipboard([item]) }
                headerButton(L("Share…"), "square.and.arrow.up", id: "EnhancedPreview.Share") { controller.share([item]) }
                if kind == .archive {
                    // Archives get "Extract Archive" in place of "Open File".
                    headerButton(L("Extract Archive"), "archivebox", id: "EnhancedPreview.ExtractArchive") {
                        close()
                        controller.extract(item, to: nil)
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    headerButton(L("Open File"), "arrow.up.forward.square", id: "EnhancedPreview.OpenFile") {
                        close()
                        controller.open([item], in: controller.activePane, newTab: false)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.trailing, 17)
        }
        .frame(height: 56)
        .background(Color.primary.opacity(0.04))
    }

    nonisolated private static func pdfThumbnail(_ url: URL) -> NSImage? {
        PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: NSSize(width: 64, height: 64), for: .mediaBox)
    }

    nonisolated private static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 96]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func headerButton(_ title: String, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.leading, 12.5)
            .padding(.trailing, 11.5)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.18)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let detail {
            PreviewContent(item: detail).id(detail.url)
        } else {
            switch detailState {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let message):
                unavailable("exclamationmark.triangle", L("Cannot Preview"), message)
            case .empty:
                unavailable("cursorarrow", L("Select a File or Folder"), nil)
            }
        }
    }

    private func unavailable(_ symbol: String, _ title: String, _ message: String?) -> some View {
        VStack(spacing: 0) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
                .padding(.bottom, 24)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.top, 3)
            }
        }
        .padding()
        .padding(.bottom, 5)
    }

    private func selectFile(_ url: URL) {
        Task {
            let loaded = await Task.detached { DirectoryLoader.item(at: url) }.value
            detail = loaded
            detailState = loaded == nil ? .failed(L("The preview item is no longer available.")) : .empty
        }
    }

    /// Encrypted entries are not decrypted here: like the original, the pane says the entry cannot be previewed
    /// (the password is asked for when the archive is extracted).
    private func previewEntry(path: String) {
        detail = nil
        detailState = .loading
        let archive = item.url, directory = entryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        Task {
            let result = await Task.detached { Result { try ArchiveService.extractEntry(path, from: archive, to: directory) } }.value
            switch result {
            case .success(let url):
                detail = await Task.detached { DirectoryLoader.item(at: url) }.value
                detailState = detail == nil ? .failed(L("Archive entry preview unavailable")) : .empty
            case .failure(ArchiveError.tooLarge):
                detailState = .failed(L("This archive entry is larger than the Super Preview limit."))
            case .failure:
                detailState = .failed(L("Archive entry preview unavailable"))
            }
        }
    }

    private func openLocation(_ url: URL) {
        close()
        let parent = url.deletingLastPathComponent()
        controller.navigateActivePane(to: parent)
        controller.activePane.select(urls: [url])
    }
}
