import AppKit
import AVKit
import DirDeskCore
import ImageIO
import PDFKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Which interactive preview an item gets in the inspector.
enum PreviewKind {
    case folder, image, pdf, video, audio, text, markdown, archive, quickLook, icon

    static func kind(for item: FileItem) -> PreviewKind {
        if item.isBrowsableFolder { return .folder }
        let ext = item.fileExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(ext) { return .markdown }
        guard let type = item.contentType else { return ArchiveService.isArchive(item.url) ? .archive : .quickLook }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) && !type.conforms(to: .pdf) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if ArchiveService.isArchive(item.url) && !item.isPackage { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .plainText) || type.conforms(to: .json) || type.conforms(to: .xml)
            || type.conforms(to: .commaSeparatedText) || type.conforms(to: .shellScript) || type.conforms(to: .propertyList) {
            return .text
        }
        // Office documents show their icon rather than a rendered page, as in the original.
        if type.identifier.hasPrefix("org.openxmlformats") || type.identifier.hasPrefix("com.microsoft.") || type.identifier.hasPrefix("com.apple.iwork") {
            return .icon
        }
        return .quickLook
    }
}

/// Interactive preview area of the inspector, with a button that opens the same item in Super Preview.
struct InteractivePreview: View {
    let item: FileItem
    let height: Double
    var enlarge: (() -> Void)? = nil
    var openLocation: ((URL) -> Void)? = nil
    @State private var hovering = false

    /// Files preview on a rounded card; a folder's contents, rendered Markdown, the audio player and document
    /// thumbnails sit directly on the inspector and an archive draws its own outlined card, as in the original.
    private var showsCard: Bool {
        switch PreviewKind.kind(for: item) {
        case .folder: !AppModel.shared.preferences.previewsFolders
        case .archive: !AppModel.shared.preferences.previewsArchives
        case .markdown, .audio, .quickLook, .icon: false
        default: true
        }
    }

    var body: some View {
        PreviewContent(item: item, compact: true, openLocation: openLocation)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(showsCard ? 0.04 : 0)))
            .overlay(alignment: .topTrailing) {
                if let enlarge, hovering {
                    Button(action: enlarge) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help(L("Enlarge Preview"))
                    .accessibilityIdentifier("Inspector.EnlargePreview")
                }
            }
            .onHover { hovering = $0 }
            .id(item.url)
    }
}

/// The preview that matches an item's kind; shared by the inspector and Super Preview.
struct PreviewContent: View {
    let item: FileItem
    /// The inspector's small preview: other document types show a still Quick Look thumbnail there, as in the original.
    var compact = false
    var showsImageRotation = false
    var openLocation: ((URL) -> Void)? = nil
    var selectFile: ((URL) -> Void)? = nil
    var selectArchiveEntry: ((ArchiveTreeNode) -> Void)? = nil
    @ObservedObject var app = AppModel.shared

    var body: some View {
        switch PreviewKind.kind(for: item) {
        case .folder where app.preferences.previewsFolders:
            FolderTreePreview(url: item.url, onSelectFile: selectFile, onOpenLocation: openLocation)
        case .image: ZoomableImagePreview(url: item.url, showsRotate: showsImageRotation)
        case .pdf: PDFPreview(url: item.url)
        case .video: MediaPreview(url: item.url, audioOnly: false)
        case .audio: MediaPreview(url: item.url, audioOnly: true)
        case .text: TextFilePreview(url: item.url)
        case .markdown: MarkdownFilePreview(url: item.url)
        case .archive where app.preferences.previewsArchives:
            if let selectArchiveEntry {
                ArchiveTreePreview(item: item, limitMB: app.preferences.archiveDirectBrowseSizeLimitMB, style: .superPreview,
                                   onSelectEntry: selectArchiveEntry)
            } else {
                // In the inspector, clicking an entry opens it in Super Preview.
                ArchiveTreePreview(item: item, limitMB: app.preferences.archiveDirectBrowseSizeLimitMB, style: .inspector) { node in
                    NotificationCenter.default.post(name: .dirDeskShowSuperPreview, object: item.url, userInfo: ["archiveEntry": node.id])
                }
            }
        case .icon:
            // Office documents are not rendered; the original shows a small generic document symbol.
            Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if compact { QuickLookThumbnailPreview(url: item.url) } else { QuickLookPreview(url: item.url) }
        }
    }
}

// MARK: Image

struct ZoomableImagePreview: View {
    let url: URL
    /// Super Preview and the gallery also offer rotation; the inspector shows fit, actual size and zoom only.
    var showsRotate = false
    @State private var image: NSImage?
    @State private var scale: CGFloat = 1
    @State private var fit = true
    @State private var rotation = 0.0

    private var isAnimated: Bool { ["gif", "apng"].contains(url.pathExtension.lowercased()) }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if isAnimated && fit && rotation == 0 {
                        AnimatedImageView(url: url).frame(width: geometry.size.width, height: geometry.size.height)
                    } else if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: fit ? geometry.size.width : image.size.width * scale,
                                   height: fit ? geometry.size.height : image.size.height * scale)
                            .rotationEffect(.degrees(rotation))
                    } else {
                        ProgressView().frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .gesture(MagnificationGesture().onChanged { value in
                    fit = false
                    scale = min(max(value, 0.05), 16)
                })
            }
            // Tools and identifiers as in the original: (rotate left,) fit, actual size, zoom out, zoom in.
            HStack(spacing: 14) {
                if showsRotate { button("rotate.left", L("Rotate Left"), id: "RotateLeft") { rotation -= 90 } }
                button("arrow.down.right.and.arrow.up.left", L("Fit to Window"), id: "Fit") { fit = true }
                button("viewfinder", L("Actual Size"), id: "ActualSize") { fit = false; scale = 1 }
                button("minus.magnifyingglass", L("Zoom Out"), id: "ZoomOut") { fit = false; scale = max(scale / 1.25, 0.05) }
                button("plus.magnifyingglass", L("Zoom In"), id: "ZoomIn") { fit = false; scale = min(scale * 1.25, 16) }
            }
            // The tools sit on a 32 pt band under the image card, one every 32 pt, as in the original.
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(Theme.chrome)
        }
        .task(id: url) {
            let url = url
            image = await Task.detached { Self.load(url) }.value
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Inspector.Image.InteractivePreview")
    }

    private func button(_ symbol: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 18) }.buttonStyle(.borderless).help(title).accessibilityLabel(title)
            .accessibilityIdentifier("InteractivePreview.Image." + id)
    }

    /// Decodes at most 4096 px on the long edge so huge images stay responsive.
    nonisolated static func load(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 4096]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

/// Plays animated GIFs (the inspector and gallery show the animation like the original).
struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        load(into: view)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.toolTip != url.path { load(into: view) }
    }

    private func load(into view: NSImageView) {
        view.toolTip = url.path
        let url = url
        Task.detached(priority: .userInitiated) {
            let data = try? Data(contentsOf: url, options: .mappedIfSafe)
            await MainActor.run {
                guard view.toolTip == url.path, let data else { return }
                view.image = NSImage(data: data)
            }
        }
    }
}

extension Notification.Name {
    /// Object: the file URL to open in Super Preview (the image preview's Full Screen button).
    static let dirDeskShowSuperPreview = Notification.Name("DirDeskShowSuperPreview")
}

// MARK: PDF

/// PDF preview: the page, a thumbnail strip, "‹ n / N ›" navigation and fit / zoom controls (as the original).
struct PDFPreview: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var page = 1
    @State private var zoom: PDFZoomRequest = .fit

    /// As in the original: in the inspector the page with a 74 pt band of page thumbnails under it; in a wide
    /// preview (Super Preview) the thumbnails run down a 104 pt column on the left. Page navigation and zoom sit on
    /// a 32 pt row at the bottom (tools every 32 pt).
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if let document, document.pageCount > 0, geometry.size.width >= 560 {
                    HStack(spacing: 0) {
                        PDFThumbnailStrip(document: document, page: $page, vertical: true).frame(width: 104.5)
                        PDFKitView(document: document, page: $page, zoom: $zoom)
                    }
                } else {
                    VStack(spacing: 0) {
                        PDFKitView(document: document, page: $page, zoom: $zoom)
                        if let document, document.pageCount > 0 { PDFThumbnailStrip(document: document, page: $page) }
                    }
                }
            }
            if let document {
                HStack(spacing: 14) {
                    Button { page = max(1, page - 1) } label: { Image(systemName: "chevron.left").font(.system(size: 14)).frame(width: 17) }
                        .disabled(page <= 1).help(L("Previous Page"))
                        .accessibilityLabel(L("Previous Page")).accessibilityIdentifier("InteractivePreview.PDF.PreviousPage")
                    Text("\(page) / \(document.pageCount)").font(.system(size: 11)).monospacedDigit().frame(minWidth: 35.5)
                    Button { page = min(document.pageCount, page + 1) } label: { Image(systemName: "chevron.right").font(.system(size: 14)).frame(width: 17) }
                        .disabled(page >= document.pageCount).help(L("Next Page"))
                        .accessibilityLabel(L("Next Page")).accessibilityIdentifier("InteractivePreview.PDF.NextPage")
                    Button { zoom = .fit } label: { Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 18) }.help(L("Fit to Window"))
                        .accessibilityLabel(L("Fit to Window")).accessibilityIdentifier("InteractivePreview.PDF.Fit")
                    Button { zoom = .out } label: { Image(systemName: "minus.magnifyingglass").frame(width: 18) }.help(L("Zoom Out"))
                        .accessibilityLabel(L("Zoom Out")).accessibilityIdentifier("InteractivePreview.PDF.ZoomOut")
                    Button { zoom = .in } label: { Image(systemName: "plus.magnifyingglass").frame(width: 18) }.help(L("Zoom In"))
                        .accessibilityLabel(L("Zoom In")).accessibilityIdentifier("InteractivePreview.PDF.ZoomIn")
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(Theme.chrome)
            }
        }
        .task(id: url) { document = PDFDocument(url: url) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Inspector.PDF.Preview")
    }
}

enum PDFZoomRequest: Equatable { case none, fit, `in`, out }

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument?
    @Binding var page: Int
    @Binding var zoom: PDFZoomRequest

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.pageShadowsEnabled = false
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let current = view.currentPage, let index = view.document?.index(for: current) { page = index + 1 }
            }
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        if let document, let target = document.page(at: page - 1), view.currentPage !== target { view.go(to: target) }
        switch zoom {
        case .none: break
        case .fit: view.autoScales = true
        case .in: view.autoScales = false; view.zoomIn(nil)
        case .out: view.autoScales = false; view.zoomOut(nil)
        }
        if zoom != .none { DispatchQueue.main.async { zoom = .none } }
    }
}

/// Page thumbnails, as PDFKit's thumbnail view draws them in the original: the current page on a grey tile with
/// its number on a grey label under it. In the inspector a 74 pt band of 36 × 32 tiles under the page; in Super
/// Preview a column of 60 × 64 tiles on the left.
private struct PDFThumbnailStrip: View {
    let document: PDFDocument
    @Binding var page: Int
    var vertical = false

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                    Group {
                        if vertical {
                            LazyVStack(spacing: 8) { tiles }
                                .padding(.top, 6)
                                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .top)
                        } else {
                            LazyHStack(alignment: .top, spacing: 8) { tiles }
                                .padding(.horizontal, 8)
                                .padding(.top, 6)
                                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .top)
                        }
                    }
                }
                .onChange(of: page) { _, value in withAnimation { proxy.scrollTo(value, anchor: .center) } }
            }
        }
        .frame(height: vertical ? nil : 74)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Inspector.PDF.Thumbnails")
    }

    private var tiles: some View {
        ForEach(0..<min(document.pageCount, 300), id: \.self) { index in
            let current = index + 1 == page
            VStack(spacing: 2) {
                PDFPageThumb(document: document, index: index)
                    .frame(width: vertical ? 38 : 18, height: vertical ? 52 : 24)
                    .frame(width: vertical ? 60 : 36, height: vertical ? 64 : 32)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(current ? 0.23 : 0)))
                Text("\(index + 1)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 4.5)
                    .frame(minWidth: 15, minHeight: 17)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(current ? 0.25 : 0)))
            }
            .contentShape(Rectangle())
            .onTapGesture { page = index + 1 }
            .help("\(index + 1)")
            .id(index + 1)
        }
    }
}

private struct PDFPageThumb: View {
    let document: PDFDocument
    let index: Int
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() } else { Color.white.opacity(0.1) }
        }
        .task(id: index) {
            image = document.page(at: index)?.thumbnail(of: NSSize(width: 76, height: 104), for: .mediaBox)
        }
    }
}

// MARK: Audio and video

struct MediaPreview: View {
    let url: URL
    let audioOnly: Bool
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var progress = 0.0
    @State private var duration = 0.0
    @State private var volume = 1.0
    @State private var observer: Any?

    /// The original's own player controls (no AVKit chrome): a round play button, the position slider, a volume
    /// icon and slider, and the time. Audio shows them under a waveform on the bare inspector; video shows the
    /// picture on black with a large play button and the controls on a bar near the bottom.
    var body: some View {
        // A container that always has content, so the task runs before there is a player.
        ZStack {
            if audioOnly { audioBody } else { videoBody }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            let item = AVPlayerItem(url: url)
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.volume = Float(volume)
            player = newPlayer
            playing = false
            progress = 0
            if let length = try? await item.asset.load(.duration) { duration = length.seconds.isFinite ? length.seconds : 0 }
            observer = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
                MainActor.assumeIsolated { progress = time.seconds }
            }
            // At the end, back to the start with the play button showing again.
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                playing = false
                await newPlayer.seek(to: .zero)
                progress = 0
            }
        }
        .onDisappear {
            player?.pause()
            if let observer { player?.removeTimeObserver(observer) }
        }
    }

    private var audioBody: some View {
        VStack(spacing: 0) {
            Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(.secondary)
            controls.padding(.top, 18)
            Text(timeText).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().padding(.top, 6.5)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 25)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Inspector.Audio.Player")
    }

    private var videoBody: some View {
        ZStack {
            Color.black
            if let player { VideoPlayerView(player: player) }
            if !playing {
                Button { toggle() } label: {
                    Image(systemName: "play.fill").font(.system(size: 26)).foregroundStyle(.white)
                        .frame(width: 65, height: 65)
                        .background(Circle().fill(Color.black.opacity(0.75)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Play Media"))
                .accessibilityIdentifier("InteractivePreview.Media.Video.Play")
                .padding(.bottom, 49)
            }
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                controls.background(Capsule().fill(Color(white: 39 / 255)))
                Text(timeText).font(.system(size: 10)).foregroundStyle(.white).monospacedDigit()
                    .padding(.horizontal, 4.5)
                    .frame(height: 13)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 39 / 255)))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Inspector.Media.Player")
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 15))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(audioOnly ? 0.075 : 0.18)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(playLabel)
            .accessibilityLabel(playLabel)
            .accessibilityIdentifier("InteractivePreview.Media.Audio.PlayPause")
            Slider(value: Binding(get: { progress }, set: { value in
                progress = value
                player?.seek(to: CMTime(seconds: value, preferredTimescale: 600))
            }), in: 0...max(duration, 0.1))
            .controlSize(.small)
            .accessibilityLabel(L("Playback Position"))
            .accessibilityIdentifier("InteractivePreview.Media.Audio.Progress")
            .padding(.leading, 10)
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.leading, 9)
            Slider(value: $volume, in: 0...1)
                .controlSize(.small)
                .frame(width: 40)
                .accessibilityLabel(L("Volume"))
                .accessibilityIdentifier("InteractivePreview.Media.Volume")
                .padding(.leading, 5)
                .onChange(of: volume) { _, value in player?.volume = Float(value) }
        }
    }

    private var playLabel: String {
        audioOnly ? (playing ? L("Pause Audio") : L("Play Audio")) : (playing ? L("Pause Media") : L("Play Media"))
    }

    private var timeText: String { Self.time(progress) + " / " + Self.time(duration) }

    private func toggle() {
        guard let player else { return }
        playing ? player.pause() : player.play()
        playing.toggle()
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // The preview draws its own controls, as the original does.
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

// MARK: Text and Markdown

struct TextFilePreview: View {
    let url: URL
    @State private var decoded: TextPreviewDecoder.Decoded?
    @State private var failed = false

    var body: some View {
        Group {
            if let decoded {
                PlainTextView(text: decoded.text)
            } else if failed {
                Text(L("This text file uses an unsupported encoding.")).foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let url = url
            decoded = await Task.detached { TextPreviewDecoder.decode(url: url, limit: 256 * 1024) }.value
            failed = decoded == nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Inspector.Text.Preview")
    }
}

/// Read-only, selectable text in an AppKit text view, as the original shows it: 10.5 pt monospaced on a fixed
/// 12 pt line pitch (CJK lines included), 13 pt in from the card's edge.
private struct PlainTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 12
        style.maximumLineHeight = 12
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: style,
        ]))
        textView.scroll(.zero)
    }
}

struct MarkdownFilePreview: View {
    let url: URL
    @State private var blocks: [MarkdownBlock] = []

    /// Rendered straight on the inspector (no card), 24 pt in, blocks 16 pt apart, as in the original.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in MarkdownBlockView(block: block) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: url) {
            let url = url
            blocks = await Task.detached { MarkdownBlockParser.parse(TextPreviewDecoder.decode(url: url)?.text ?? "") }.value
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Inspector.Markdown.Preview")
    }
}

/// One Markdown block, styled after the original's renderer (sizes and colours measured from its captures):
/// headings 28/22/18 pt bold, 14 pt text, list markers in a 13 pt column, a blue quote bar, a header-shaded table
/// with fixed 185 pt columns, code on an outlined card under its language, PlantUML as participant cards.
struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(.system(size: Self.headingSize(level), weight: .bold))
        case .paragraph(let text):
            inline(text).font(.system(size: 14))
        case .unorderedList(let items):
            list(items.map { _ in "•" }, items)
        case .orderedList(let items):
            list(items.indices.map { "\($0 + 1)." }, items)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10.5) {
                Rectangle().fill(Color.accentColor.opacity(0.65)).frame(width: 3)
                inline(text).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        case .code(let language, let text):
            VStack(alignment: .leading, spacing: 15) {
                if let language {
                    Text(language.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 11)
            .padding(.top, 7)
            .padding(.bottom, 11.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows)
        case .plantUML(let diagram):
            PlantUMLView(diagram: diagram)
        case .rule:
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
    }

    static func headingSize(_ level: Int) -> CGFloat { [28, 22, 18, 16, 14, 13][min(max(level, 1), 6) - 1] }

    private func list(_ markers: [String], _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(markers[index]).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 13, alignment: .trailing)
                    inline(item)
                }
            }
        }
        .font(.system(size: 14))
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) { return Text(attributed) }
        return Text(text)
    }
}

/// A Markdown table: header row shaded blue, fixed 185 pt columns (wider tables scroll sideways), dividers between
/// the header and the rows and between columns, all cells left-aligned as in the original.
private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    private let columnWidth: CGFloat = 185.5

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                row(header, bold: true)
                    .frame(height: 31)
                    .background(Color.accentColor.opacity(0.08))
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    row(cells, bold: false).frame(height: 31.5)
                }
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(1..<max(header.count, 1), id: \.self) { _ in
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1).padding(.leading, columnWidth - 1)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.5))
        }
    }

    private func row(_ cells: [String], bold: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<header.count, id: \.self) { index in
                Text(index < cells.count ? cells[index] : "")
                    .font(.system(size: 12, weight: bold ? .semibold : .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(width: columnWidth, alignment: .leading)
            }
        }
    }
}

/// The PlantUML subset drawn natively, as in the original: a titled card with one tile per participant and one
/// line per message or relation ("Alice → Bob  Request").
struct PlantUMLView: View {
    let diagram: PlantUMLDiagram

    var body: some View {
        VStack(alignment: .leading, spacing: 12.5) {
            HStack(spacing: 9) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 10))
                Text("PlantUML").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11.5) {
                    ForEach(diagram.participants, id: \.self) { name in
                        VStack(spacing: 4) {
                            Image(systemName: "person.crop.rectangle").font(.system(size: 14)).foregroundStyle(Color.accentColor)
                            Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .frame(width: 122.5, height: 73.5)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(diagram.edges.enumerated()), id: \.offset) { _, edge in
                    HStack(spacing: 8) {
                        Text(edge.from).font(.system(size: 11, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                        Text(edge.to).font(.system(size: 11, weight: .semibold))
                        if !edge.label.isEmpty { Text(edge.label).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.11)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Markdown.PlantUML")
    }
}

// MARK: Archive and folder trees

struct ArchiveTreePreview: View {
    /// The inspector shows the tree on an outlined card titled "Archive Contents" with a usage hint below it;
    /// Super Preview lists it under the archive format and entry count.
    enum Style { case inspector, superPreview }

    let item: FileItem
    let limitMB: Int
    var style: Style = .superPreview
    var onSelectEntry: ((ArchiveTreeNode) -> Void)? = nil
    @State private var index: ArchiveIndex?
    @State private var nodes: [ArchiveTreeNode] = []
    @State private var message: String?
    @State private var expanded: Set<String> = []
    @State private var selectedEntry: String?

    var body: some View {
        VStack(spacing: 0) {
            switch style {
            case .inspector: inspectorCard
            case .superPreview: list
            }
        }
        .task(id: item.url) {
            index = nil
            message = nil
            expanded = []
            let size = item.size ?? 0
            guard size <= Int64(limitMB) * 1_000_000 else {
                message = L("Larger archives must be extracted before you can browse their contents.")
                return
            }
            let url = item.url
            let result = await Task.detached { Result { try ArchiveService.index(of: url) } }.value
            switch result {
            case .success(let value):
                nodes = ArchiveTreeNode.build(value.entries)
                index = value
            case .failure(let error): message = WorkspaceController.archiveMessage(error)
            }
        }
    }

    // MARK: Inspector

    /// Measured from the original: a 31 pt title row and a divider, then rows straight below it (folders 22 pt,
    /// files 14 pt, 2 pt apart) with 11 pt names and sizes; the hint sits centred under the card.
    private var inspectorCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox").font(.system(size: 12))
                    Text(L("Archive Contents")).font(.system(size: 12, weight: .semibold))
                }
                .padding(.leading, 8.5)
                .frame(maxWidth: .infinity, minHeight: 31, maxHeight: 31, alignment: .leading)
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                Group {
                    if index != nil {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(visibleRows, id: \.node.id) { entry in
                                    inspectorRow(entry.node, depth: entry.depth)
                                }
                            }
                        }
                        .accessibilityIdentifier("Inspector.Archive.Tree")
                    } else if let message {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .padding()
                    } else {
                        ProgressView().controlSize(.small).accessibilityIdentifier("Inspector.Archive.Loading")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: index != nil ? .top : .center)
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.065), lineWidth: 0.5))
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9))
                Text(L("Click folders to expand, files to preview. Press Space to browse the contents.")).font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.top, 4)
        }
    }

    /// Rows in order, following the expanded folders.
    private var visibleRows: [(node: ArchiveTreeNode, depth: Int)] {
        var result: [(node: ArchiveTreeNode, depth: Int)] = []
        func walk(_ nodes: [ArchiveTreeNode], depth: Int) {
            for node in nodes {
                result.append((node, depth))
                if node.isDirectory, expanded.contains(node.id), let children = node.children { walk(children, depth: depth + 1) }
            }
        }
        walk(nodes, depth: 0)
        return result
    }

    private func inspectorRow(_ node: ArchiveTreeNode, depth: Int) -> some View {
        HStack(spacing: 0) {
            // The chevron column is kept on file rows too, so icons line up under the folders'.
            Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                .font(.system(size: 9))
                .opacity(node.isDirectory ? 1 : 0)
                .frame(width: 8)
                .padding(.trailing, 6)
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .font(.system(size: node.isDirectory ? 11.5 : 11))
                .foregroundStyle(node.isDirectory ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .padding(.trailing, 5)
            Text(node.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = node.size {
                Text(FileSizeFormatter.string(size, unit: AppModel.shared.preferences.fileSizeUnit))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 9.5 + CGFloat(depth) * 16)
        .padding(.trailing, 9)
        .frame(height: node.isDirectory ? 22 : 14)
        // Encrypted entries cannot be previewed without the password; the original greys them out.
        .opacity(node.encrypted && !node.isDirectory ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { activate(node) }
        .accessibilityElement(children: .combine)
        // After combining, so the hint is not repeated once per child.
        .help(node.isDirectory ? "" : L("Click to preview archive entry"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier((node.isDirectory ? "SuperPreview.ArchiveDirectory." : "SuperPreview.ArchiveEntry.") + node.name)
        .accessibilityAction { activate(node) }
    }

    private func activate(_ node: ArchiveTreeNode) {
        if node.isDirectory {
            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        } else {
            onSelectEntry?(node)
        }
    }

    // MARK: Super Preview

    /// The left half of Super Preview, measured from the original: a 38 pt header with the archive format and entry
    /// count, then 26 pt rows with every folder expanded, folders led by a chevron and files indented 6 pt more,
    /// 14 pt per level; the clicked entry stays highlighted.
    @ViewBuilder
    private var list: some View {
        if let index {
            VStack(spacing: 0) {
                HStack(spacing: 8.5) {
                    Image(systemName: "archivebox").font(.system(size: 12))
                    Text(index.formatName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(index.entries.count)").font(.system(size: 13)).monospacedDigit()
                }
                .padding(.leading, 8.5)
                .padding(.trailing, 9)
                .frame(height: 38)
                .accessibilityIdentifier("Inspector.Archive.Header")
                Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRows, id: \.node.id) { entry in
                            superPreviewRow(entry.node, depth: entry.depth)
                        }
                    }
                    .padding(.top, 6.5)
                }
                .accessibilityIdentifier("Inspector.Archive.Tree")
            }
            .onAppear { expanded = Set(Self.folderIDs(nodes)) }
            .onChange(of: index.entries.count) { _, _ in expanded = Set(Self.folderIDs(nodes)) }
        } else if let message {
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("Inspector.Archive.Loading")
        }
    }

    private static func folderIDs(_ nodes: [ArchiveTreeNode]) -> [String] {
        nodes.flatMap { node in node.isDirectory ? [node.id] + folderIDs(node.children ?? []) : [] }
    }

    private func superPreviewRow(_ node: ArchiveTreeNode, depth: Int) -> some View {
        let indent = CGFloat(depth) * 14
        return HStack(spacing: 0) {
            if node.isDirectory {
                Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .frame(width: 8)
                    .padding(.leading, 9 + indent)
                    .padding(.trailing, 6)
                Image(systemName: "folder.fill").font(.system(size: 11.5)).foregroundStyle(Color.accentColor)
                    .padding(.trailing, 4)
            } else {
                Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 29 + indent)
                    .padding(.trailing, 6.5)
            }
            Text(node.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = node.size {
                Text(FileSizeFormatter.string(size, unit: AppModel.shared.preferences.fileSizeUnit))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(.trailing, 14)
        .frame(height: node.isDirectory ? 25 : 26)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selectedEntry == node.id ? Color.accentColor.opacity(0.2) : .clear)
                .padding(.leading, 8)
                .padding(.trailing, 9)
                .padding(.vertical, 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { activateInSuperPreview(node) }
        .accessibilityElement(children: .combine)
        .help(node.isDirectory ? "" : L("Click to preview archive entry"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier((node.isDirectory ? "SuperPreview.ArchiveDirectory." : "EnhancedPreview.ArchiveEntry.")
                                 + node.id.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        .accessibilityAction { activateInSuperPreview(node) }
    }

    private func activateInSuperPreview(_ node: ArchiveTreeNode) {
        if node.isDirectory {
            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        } else {
            selectedEntry = node.id
            onSelectEntry?(node)
        }
    }
}

struct ArchiveTreeNode: Identifiable {
    let id: String
    let name: String
    var isDirectory: Bool
    var size: Int64?
    var encrypted: Bool
    var children: [ArchiveTreeNode]?

    static func build(_ entries: [ArchiveEntryMetadata]) -> [ArchiveTreeNode] {
        final class Box {
            var name: String
            var isDirectory = false
            var size: Int64?
            var encrypted = false
            var children: [String: Box] = [:]
            var order: [String] = []
            init(_ name: String) { self.name = name }
        }
        let root = Box("")
        for entry in entries {
            var node = root
            let components = entry.pathComponents
            for (offset, component) in components.enumerated() {
                if node.children[component] == nil {
                    node.children[component] = Box(component)
                    node.order.append(component)
                }
                node.isDirectory = true
                node = node.children[component]!
                if offset == components.count - 1 {
                    node.isDirectory = node.isDirectory || entry.kind == .directory
                    if entry.kind != .directory { node.size = entry.uncompressedSize }
                    node.encrypted = entry.isEncrypted
                }
            }
        }
        func convert(_ box: Box, path: String) -> [ArchiveTreeNode] {
            box.order.compactMap { box.children[$0] }.sorted { ($0.isDirectory ? 0 : 1, $0.name) < ($1.isDirectory ? 0 : 1, $1.name) }.map { child in
                let childPath = path + "/" + child.name
                let kids = child.isDirectory ? convert(child, path: childPath) : nil
                return ArchiveTreeNode(id: childPath, name: child.name, isDirectory: child.isDirectory, size: child.size,
                                       encrypted: child.encrypted, children: kids?.isEmpty == true ? nil : kids)
            }
        }
        return convert(root, path: "")
    }
}

/// Folder contents as an expandable tree: click folders to expand, double-click to open the location.
/// Laid out like the original: a large folder icon with the title, rows indented under it on a 26 pt pitch without
/// separators, and the usage hint with an icon at the bottom.
struct FolderTreePreview: View {
    let url: URL
    var onSelectFile: ((URL) -> Void)? = nil
    var onOpenLocation: ((URL) -> Void)? = nil
    @State private var root: [FolderNode] = []
    @State private var expanded: Set<String> = []
    @State private var loaded = false
    @State private var isRepository = false
    @State private var repositoryRevision = 0

    private func openLocation(_ url: URL) {
        if let onOpenLocation { onOpenLocation(url) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().frame(width: 30, height: 30)
                    .overlay(alignment: .bottomTrailing) {
                        if isRepository {
                            Image(nsImage: FileNameCellView.gitBadgeImage).resizable().frame(width: 15, height: 15).offset(x: 1, y: 2)
                        }
                    }
                Text(L("Folder Contents")).font(.system(size: 12, weight: .semibold))
            }
            .padding(.leading, 13)
            .padding(.top, 12)
            .padding(.bottom, 9)
            if loaded && root.isEmpty {
                Text(L("Empty Folder")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 49).padding(.top, 6)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(flattened, id: \.node.id) { entry in
                            row(entry.node, depth: entry.depth)
                        }
                    }
                }
                .accessibilityIdentifier("Inspector.Folder.Tree")
            }
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9))
                Text(L("Click folders to expand, files to preview. Double-click to open the location.")).font(.system(size: 10))
            }
            .foregroundStyle(.tertiary)
            .padding(.leading, 13)
            .padding(.top, 8)
            .padding(.bottom, 11.5)
        }
        .task(id: url) {
            let url = url
            expanded = []
            root = await Task.detached { FolderNode.children(of: url, depth: 0) }.value
            loaded = true
        }
        .task(id: "\(url.path)|\(repositoryRevision)") {
            isRepository = false
            GitRepositoryProbe.invalidate(url)
            let value = await GitRepositoryProbe.isRepository(url)
            guard !Task.isCancelled else { return }
            isRepository = value
        }
        .onReceive(NotificationCenter.default.publisher(for: .dirDeskFilesChanged)) { _ in
            repositoryRevision &+= 1
        }
    }

    /// Visible rows in order, following the expanded folders.
    private var flattened: [(node: FolderNode, depth: Int)] {
        var result: [(node: FolderNode, depth: Int)] = []
        func walk(_ nodes: [FolderNode], depth: Int) {
            for node in nodes {
                result.append((node, depth))
                if node.isFolder, expanded.contains(node.id), let children = node.children { walk(children, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return result
    }

    private func row(_ node: FolderNode, depth: Int) -> some View {
        HStack(spacing: 4) {
            Group {
                if node.isFolder {
                    Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 12)
            Image(nsImage: Self.icon(for: node)).resizable().frame(width: 14, height: 14)
            Text(node.url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.leading, 34.5 + CGFloat(depth) * 14)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openLocation(node.url) }
        .onTapGesture {
            if node.isFolder {
                if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
            } else {
                onSelectFile?(node.url)
            }
        }
        .accessibilityElement(children: .combine)
        .help(node.isFolder ? L("Click folders to expand, files to preview. Double-click to open the location.")
                            : L("Click to preview. Double-click or press Return to open."))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("Inspector.Folder.Child.\(node.url.lastPathComponent)")
        .accessibilityAction { if node.isFolder { openLocation(node.url) } else { onSelectFile?(node.url) } }
        .accessibilityAction(named: L("Open Location")) { openLocation(node.url) }
    }

    /// Type icons looked up by extension, so the preview never reads the listed files on the main thread.
    static func icon(for node: FolderNode) -> NSImage {
        if node.isFolder { return NSWorkspace.shared.icon(for: .folder) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: node.url.pathExtension) ?? .data)
    }
}

struct FolderNode: Identifiable, Sendable {
    let url: URL
    var isFolder: Bool
    var children: [FolderNode]?
    var id: String { url.path }

    /// Folders first, then files, each in natural order (as the original's mini tree lists them).
    static func children(of url: URL, depth: Int) -> [FolderNode] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let nodes = urls.prefix(200).map { child -> FolderNode in
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            return FolderNode(url: child, isFolder: isFolder, children: isFolder && depth < 2 ? children(of: child, depth: depth + 1) : nil)
        }
        return nodes.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }
}

// MARK: Quick Look fallback

/// A still Quick Look thumbnail fitted into the preview (a web page renders 4:3, a document as its first page),
/// with the generic document symbol while it loads or when there is none.
struct QuickLookThumbnailPreview: View {
    let url: URL
    @State private var image: NSImage?
    @State private var loaded = false

    private var isWebPage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .html) == true }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image, isWebPage {
                    // The top of the page in a 4:3 frame, as the original shows web pages.
                    Color.white
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .overlay(alignment: .topLeading) {
                            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        }
                        .clipped()
                } else if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else if loaded {
                    Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .task(id: url) {
                image = nil
                loaded = false
                let size = isWebPage ? CGSize(width: geometry.size.width, height: geometry.size.width * 0.75) : geometry.size
                let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
                image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
                loaded = true
            }
        }
        .accessibilityIdentifier("Inspector.QuickLook.Thumbnail")
    }
}

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
