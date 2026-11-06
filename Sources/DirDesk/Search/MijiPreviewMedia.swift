import AppKit
import AVKit
import PDFKit
import QuickLookUI
import QuickLookThumbnailing
import SwiftUI
import MijiCore

/// Shared by visible grid cells and the selected preview; never preloads the result set.
enum MijiPreviewThumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()
    private static let lock=NSLock()
    private static var generation=0
    static func clear() {lock.lock();generation &+= 1;cache.removeAllObjects();lock.unlock()}
    private static func currentGeneration()->Int {lock.lock();defer{lock.unlock()};return generation}
    private static func retain(_ image:NSImage,key:NSString,cost:Int,generation expected:Int) {
        lock.lock();defer{lock.unlock()}
        if generation==expected {cache.setObject(image,forKey:key,cost:cost)}
    }
    static func load(_ hit: SearchHit, pixels: Int) async -> NSImage? {
        let generation=currentGeneration()
        let key = "\(hit.path)|\(hit.file.inode)|\(hit.file.modified)|\(hit.file.size)|\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let url = await Task.detached(priority: .utility) { MijiPreviewResolver.localURL(for: hit) }.value
        guard !Task.isCancelled, let url else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixels, height: pixels),
                                                   scale: 1, representationTypes: .thumbnail)
        let image: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { result, _ in
                    continuation.resume(returning: result?.nsImage)
                }
            }
        } onCancel: { QLThumbnailGenerator.shared.cancel(request) }
        guard !Task.isCancelled, let image else { return nil }
        let cost = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        retain(image,key:key,cost:cost,generation:generation)
        return image
    }
}

struct MijiFileThumbnail: View {
    let hit: SearchHit
    var pixels = 400
    var showsStatus = false
    @State private var image: NSImage?
    @State private var loading = true
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if showsStatus {
                if loading { ProgressView("正在载入缩略图…").controlSize(.small).font(.caption) }
                else { Label("缩略图不可用 · 可使用快速查看", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
            } else { Image(systemName: hit.file.kind.mijiPreviewSymbol).font(.system(size: 38, weight: .light)).foregroundStyle(.secondary) }
        }
        .task(id: "\(hit.path)|\(hit.file.modified)|\(hit.file.size)|\(pixels)") {
            image = nil; loading = true
            let loaded = await MijiPreviewThumbnails.load(hit, pixels: pixels)
            guard !Task.isCancelled else { return }
            image = loaded; loading = false
        }
    }
}

struct MijiPDFDocumentPreview: NSViewRepresentable {
    let document: PDFDocument
    let page: Int?
    let terms: [String]
    final class Coordinator {
        var document: PDFDocument?
        var page: Int?
        var terms: [String] = []
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        let state = context.coordinator
        guard state.document !== document || state.page != page || state.terms != terms else { return }
        state.document = document; state.page = page; state.terms = terms
        if view.document !== document { view.document = document }
        guard let shown = document.page(at: max(0, min(document.pageCount - 1, (page ?? 1) - 1))) else { return }
        view.go(to: shown)
        var selections: [PDFSelection] = []
        let text = (shown.string ?? "") as NSString
        for term in terms where !term.isEmpty {
            var offset = 0
            for _ in 0..<40 {
                let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: offset, length: text.length - offset))
                guard range.location != NSNotFound, range.length > 0 else { break }
                if let selected = shown.selection(for: range) { selected.color = .systemYellow.withAlphaComponent(0.4); selections.append(selected) }
                offset = NSMaxRange(range)
                if offset >= text.length { break }
            }
        }
        view.highlightedSelections = selections
    }
    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { view.document = nil; coordinator.document = nil }
}

// SwiftUI's provider teardown invokes deactivate; keep Quick Look's own private
// activation lifecycle behind a plain container and close its child explicitly.
final class MijiQuickLookContainer: NSView {
    let preview=QLPreviewView(frame:.zero,style:.compact)!
    override init(frame:NSRect) {
        super.init(frame:frame)
        preview.autostarts=false;preview.shouldCloseWithWindow=false
        preview.translatesAutoresizingMaskIntoConstraints=false;addSubview(preview)
        NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo:leadingAnchor),preview.trailingAnchor.constraint(equalTo:trailingAnchor),preview.topAnchor.constraint(equalTo:topAnchor),preview.bottomAnchor.constraint(equalTo:bottomAnchor)])
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
}
struct MijiSystemFilePreview: NSViewRepresentable {
    let url:URL
    func makeNSView(context:Context)->MijiQuickLookContainer {MijiQuickLookContainer(frame:.zero)}
    func updateNSView(_ view:MijiQuickLookContainer,context:Context) {
        if (view.preview.previewItem as? NSURL) != url as NSURL {view.preview.previewItem=url as NSURL}
    }
    static func dismantleNSView(_ view:MijiQuickLookContainer,coordinator:()) {view.preview.previewItem=nil;view.preview.close()}
}

private final class MijiPreviewPlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var failed = false
    private var observation: NSKeyValueObservation?
    func play(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                DispatchQueue.main.async { if self?.player?.currentItem === item { self?.failed = true } }
            }
        }
        let next = AVPlayer(playerItem: item); player = next; next.play()
    }
    func stop() { observation = nil; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil; failed = false }
    deinit { player?.pause() }
}

struct MijiMediaFilePreview: View {
    let hit: SearchHit
    @StateObject private var playback = MijiPreviewPlayback()
    var body: some View {
        ZStack {
            if playback.failed { Label("无法播放此媒体 · 可打开原文件", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
            else if let player = playback.player { VideoPlayer(player: player) }
            else {
                if hit.file.kind == .video { MijiFileThumbnail(hit: hit, pixels: 800, showsStatus: true) }
                else { Image(systemName: "waveform").font(.system(size: 32)).foregroundStyle(.secondary).offset(y: -48) }
                Button {
                    if let url = MijiPreviewResolver.localURL(for: hit) { playback.play(url) }
                } label: { Image(systemName: "play.circle.fill").font(.system(size: 48)).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6)) }
                .buttonStyle(.plain).accessibilityLabel("播放预览")
                .disabled(!hit.root.isOnline)
            }
        }
        .onChange(of: hit.path) { playback.stop() }
        .onDisappear { playback.stop() }
    }
}

func mijiHighlightedPreview(_ text: String, query: String) -> AttributedString {
    var result = AttributedString(text)
    // A bounded preview may contain many occurrences. Search in the original string so
    // Unicode range conversion preserves emoji and decomposed characters.
    for term in MijiPreviewResolver.terms(in: query) {
        var start = text.startIndex
        for _ in 0..<100 {
            guard start < text.endIndex, let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex),
                  let mapped = Range(range, in: result) else { break }
            result[mapped].backgroundColor = .yellow.opacity(0.25)
            result[mapped].foregroundColor = .primary
            start = range.upperBound
        }
    }
    return result
}

/// Ask the selected default editor to open a real source line when its documented
/// URL scheme supports it. Other editors keep the normal macOS open behavior.
enum MijiCodeFileOpener {
    static func locationURL(file: URL, line: Int, bundleID: String) -> URL? {
        let schemes = ["com.microsoft.VSCode": "vscode", "com.microsoft.VSCodeInsiders": "vscode-insiders", "com.todesktop.230313mzl4w4u92": "cursor"]
        guard let scheme = schemes[bundleID] else { return nil }
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: ":?#%")
        guard let path = file.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://file\(path):\(max(1, line)):1")
    }
    @MainActor static func open(_ file: URL, line: Int) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: file), let bundleID = Bundle(url: app)?.bundleIdentifier,
              let url = locationURL(file: file, line: line, bundleID: bundleID) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

extension FileKind {
    var mijiPreviewSymbol:String {switch self {case .document:return "doc.text";case .image:return "photo";case .folder:return "folder";case .application:return "app";case .code:return "curlybraces";case .audio:return "waveform";case .video:return "film";case .archive:return "archivebox";case .other:return "doc"}}
}

@MainActor
final class MijiPDFReaderController: NSObject, NSWindowDelegate {
    static let shared = MijiPDFReaderController()
    private var window: NSWindow?
    func show(document: PDFDocument, page: Int, terms: [String], title: String) {
        window?.close()
        let next = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:700), styleMask:[.titled,.closable,.resizable,.miniaturizable], backing:.buffered,defer:false)
        next.title=title;next.isReleasedWhenClosed=false;next.delegate=self
        next.identifier=NSUserInterfaceItemIdentifier("Wumi.MijiPDFReader")
        next.contentView=NSHostingView(rootView:MijiPDFDocumentPreview(document:document,page:page,terms:terms))
        window=next;next.center();NSApp.unhide(nil);NSApp.activate(ignoringOtherApps:true);next.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification:Notification) {
        guard let closed=notification.object as? NSWindow,closed===window else{return}
        closed.contentView=nil;window=nil
    }
}
