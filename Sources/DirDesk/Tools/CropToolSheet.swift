import AppKit
import DirDeskCore
import SwiftUI

enum CropAspectPreset: String, CaseIterable, Identifiable {
    case free, square, standard, widescreen

    var id: String { rawValue }

    /// Width / height.
    var ratio: Double? {
        switch self {
        case .free: nil
        case .square: 1
        case .standard: 4.0 / 3.0
        case .widescreen: 16.0 / 9.0
        }
    }

    var title: String {
        switch self {
        case .free: L("Free")
        case .square: L("Square (1:1)")
        case .standard: L("Standard (4:3)")
        case .widescreen: L("Widescreen (16:9)")
        }
    }
}

/// State of the crop sheet: the source's displayed pixel size, a preview, and the frame in source pixels.
@MainActor
final class CropToolModel: ObservableObject {
    enum Phase: Equatable {
        case loading, ready, failed(String)
    }

    let source: URL
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var preview: CGImage?
    @Published private(set) var imageSize = CGSize.zero
    @Published private(set) var rect = CGRect.zero
    @Published var aspect: CropAspectPreset = .free {
        didSet { if aspect != oldValue { applyRatio() } }
    }

    init(source: URL) {
        self.source = source
    }

    var ratio: Double? { aspect.ratio }

    var cropRect: ImageCropRect {
        ImageCropRect(x: Int(rect.minX), y: Int(rect.minY), width: Int(rect.width), height: Int(rect.height))
    }

    /// The part of the preview bitmap inside the crop frame, for the live result.
    var croppedPreview: CGImage? {
        guard let preview, imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else { return nil }
        let scaleX = CGFloat(preview.width) / imageSize.width, scaleY = CGFloat(preview.height) / imageSize.height
        let area = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: preview.width, height: preview.height))
        guard area.width >= 1, area.height >= 1 else { return nil }
        return preview.cropping(to: area)
    }

    func load() async {
        guard phase == .loading, preview == nil else { return }
        let source = self.source
        let outcome = await ToolWork.run { () -> (width: Int, height: Int, preview: ToolBitmap) in
            let metadata = try ImageTransformationService().metadata(source: source)
            if metadata.frameCount > 1 { throw ImageTransformationError.unsupportedFrameCount(metadata.frameCount) }
            guard let thumbnail = ToolImageLoader.thumbnail(of: source, maximumPixelSize: 2048) else {
                throw ImageTransformationError.unsupportedOrDamaged(source.lastPathComponent)
            }
            return (metadata.orientedPixelWidth, metadata.orientedPixelHeight, ToolBitmap(cgImage: thumbnail))
        }
        switch outcome {
        case .success(let info):
            imageSize = CGSize(width: info.width, height: info.height)
            preview = info.preview.cgImage
            rect = CropGeometry.initialRect(ratio: ratio, imageSize: imageSize)
            phase = .ready
        case .failure(let message):
            phase = .failed(message)
        }
    }

    func update(_ newRect: CGRect) {
        guard phase == .ready else { return }
        let next = CropGeometry.integral(newRect, imageSize: imageSize)
        if next != rect { rect = next }
    }

    func set(_ field: CropGeometry.Field, _ value: Int) {
        guard phase == .ready else { return }
        update(CropGeometry.setting(field, to: value, in: rect, ratio: ratio, imageSize: imageSize))
    }

    func binding(_ field: CropGeometry.Field) -> Binding<Int> {
        Binding(get: { [unowned self] in
            switch field {
            case .x: Int(self.rect.minX)
            case .y: Int(self.rect.minY)
            case .width: Int(self.rect.width)
            case .height: Int(self.rect.height)
            }
        }, set: { [unowned self] value in self.set(field, value) })
    }

    func reset() {
        aspect = .free
        rect = CropGeometry.initialRect(ratio: nil, imageSize: imageSize)
    }

    private func applyRatio() {
        guard phase == .ready else { return }
        update(CropGeometry.applying(ratio: ratio, to: rect, imageSize: imageSize))
    }
}

/// Reference layout: the source with the crop frame and the live result side by side, then the source size,
/// the aspect ratio, X / Y / Width / Height with Reset Crop, and a one-line hint.
struct CropToolSheet: View {
    @ObservedObject var model: CropToolModel
    let onCancel: () -> Void
    let onRun: (ImageCropRect) -> Void

    var body: some View {
        ToolSheetScaffold(tool: .imageCrop, subtitle: model.source.lastPathComponent, problem: problem,
                          canRun: model.phase == .ready, onCancel: onCancel, onRun: { onRun(model.cropRect) }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        ToolSectionTitle(L("Source — drag the crop frame"))
                        ToolPreviewBox(.native) { canvas }
                            .frame(maxWidth: ToolSheetMetrics.previewWidth, minHeight: 230, maxHeight: 230)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ToolSectionTitle(L("Live result"))
                        ToolPreviewBox(.result) {
                            ToolImagePreview(image: model.croppedPreview, isLoading: model.phase == .loading,
                                             accessibilityLabel: L("Transformation result preview"))
                        }
                        .frame(maxWidth: ToolSheetMetrics.previewWidth, minHeight: 230, maxHeight: 230)
                    }
                }
                if model.phase == .ready {
                    Text(LF("Source size: %@ × %@ pixels", ToolIntegerField.format(Int(model.imageSize.width)),
                            ToolIntegerField.format(Int(model.imageSize.height))))
                }
                ToolFormRow(L("Aspect ratio")) {
                    Picker("", selection: $model.aspect) {
                        ForEach(CropAspectPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L("Aspect ratio"))
                }
                HStack(spacing: 12) {
                    field("X", .x)
                    field("Y", .y)
                    field(L("Width"), .width)
                    field(L("Height"), .height)
                    Button(L("Reset Crop")) { model.reset() }
                        .accessibilityIdentifier("BuiltInTool.Crop.Reset")
                }
                .disabled(model.phase != .ready)
                ToolCaption(L("Drag the frame or move it with the arrow keys, one pixel per press (Shift: 10). X and Y count from the top-left corner of the upright image."))
            }
        }
        .task { await model.load() }
    }

    private var problem: String? {
        if case .failed(let message) = model.phase { return message }
        return nil
    }

    private func field(_ title: String, _ field: CropGeometry.Field) -> some View {
        HStack(spacing: 8) {
            Text(title).fixedSize()
            ToolIntegerField(value: model.binding(field), width: 91)
                .accessibilityLabel(title)
        }
    }

    @ViewBuilder private var canvas: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Reading image dimensions…")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            CropCanvasRepresentable(model: model)
        }
    }
}

/// Hosts the AppKit crop canvas and keeps it in sync with the model.
private struct CropCanvasRepresentable: NSViewRepresentable {
    @ObservedObject var model: CropToolModel

    func makeNSView(context: Context) -> CropCanvasView {
        let view = CropCanvasView()
        view.onChange = { [weak model] rect in model?.update(rect) }
        return view
    }

    func updateNSView(_ view: CropCanvasView, context: Context) {
        view.configure(image: model.preview, imageSize: model.imageSize, cropRect: model.rect, ratio: model.ratio)
    }
}

/// The source image fitted to the box, a dimmed outside, a white crop frame and four round corner
/// handles. Coordinates passed in and out are source pixels with a top-left origin.
final class CropCanvasView: NSView {
    var onChange: ((CGRect) -> Void)?

    private var image: CGImage?
    private var drawnImage: NSImage?
    private var imageSize = CGSize.zero
    private var cropRect = CGRect.zero
    private var ratio: Double?
    private var drag: Drag?
    private var trackingArea: NSTrackingArea?

    private enum Drag {
        case move(start: CGRect, origin: CGPoint)
        case resize(start: CGRect, corner: CropCorner)
        case select(anchor: CGPoint, viewStart: CGPoint, active: Bool)
    }

    private static let handleSize: CGFloat = 12
    private static let handleHitSize: CGFloat = 20

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Interactive crop frame"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(image: CGImage?, imageSize: CGSize, cropRect: CGRect, ratio: Double?) {
        if image !== self.image {
            self.image = image
            drawnImage = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            needsDisplay = true
        }
        if imageSize != self.imageSize {
            self.imageSize = imageSize
            needsDisplay = true
        }
        if cropRect != self.cropRect {
            self.cropRect = cropRect
            needsDisplay = true
            setAccessibilityValue(LF("X %lld, Y %lld, width %lld, height %lld", Int64(cropRect.minX), Int64(cropRect.minY),
                                     Int64(cropRect.width), Int64(cropRect.height)))
        }
        self.ratio = ratio
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            if !(window.firstResponder is NSText) { window.makeFirstResponder(self) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Geometry

    /// The image fitted to the whole view, like the reference (the corner handles may be clipped by the box).
    private var imageFrame: CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    private var scale: CGFloat {
        let frame = imageFrame
        return imageSize.width > 0 ? frame.width / imageSize.width : 1
    }

    private func viewRect(for pixels: CGRect) -> CGRect {
        let frame = imageFrame, scale = self.scale
        return CGRect(x: frame.minX + pixels.minX * scale, y: frame.minY + pixels.minY * scale,
                      width: pixels.width * scale, height: pixels.height * scale)
    }

    private func pixelPoint(for point: CGPoint) -> CGPoint {
        let frame = imageFrame, scale = max(self.scale, 0.0001)
        return CGPoint(x: (point.x - frame.minX) / scale, y: (point.y - frame.minY) / scale)
    }

    private func handleRect(_ corner: CropCorner, size: CGFloat) -> CGRect {
        let point = corner.point(of: viewRect(for: cropRect))
        return CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    private func corner(at point: CGPoint) -> CropCorner? {
        CropCorner.allCases.first { handleRect($0, size: Self.handleHitSize).contains(point) }
    }

    /// Smallest frame a drag produces: about 12 points on screen.
    private var minimumSide: CGFloat {
        max(1, min(12 / max(scale, 0.0001), imageSize.width, imageSize.height))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let drawnImage, imageSize.width > 0 else { return }
        let frame = imageFrame
        drawnImage.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                        hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        let crop = viewRect(for: cropRect)
        let shade = NSBezierPath(rect: frame)
        shade.append(NSBezierPath(rect: crop))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        shade.fill()

        let border = NSBezierPath(rect: crop.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()

        for corner in CropCorner.allCases {
            let handle = NSBezierPath(ovalIn: handleRect(corner, size: Self.handleSize))
            NSColor.white.setFill()
            handle.fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            handle.lineWidth = 1
            handle.stroke()
        }
    }

    // MARK: Mouse

    private func cursor(at point: CGPoint) -> NSCursor {
        if let corner = corner(at: point) {
            let position: NSCursor.FrameResizePosition = switch corner {
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if viewRect(for: cropRect).contains(point) { return .openHand }
        if imageFrame.contains(point) { return .crosshair }
        return .arrow
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        if drag == nil { cursor(at: convert(event.locationInWindow, from: nil)).set() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard imageSize.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pixel = pixelPoint(for: point)
        if let corner = corner(at: point) {
            drag = .resize(start: cropRect, corner: corner)
        } else if viewRect(for: cropRect).contains(point) {
            drag = .move(start: cropRect, origin: pixel)
            NSCursor.closedHand.set()
        } else if imageFrame.insetBy(dx: -10, dy: -10).contains(point) {
            drag = .select(anchor: pixel, viewStart: point, active: false)
        } else {
            drag = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pixel = pixelPoint(for: point)
        switch drag {
        case .move(let start, let origin):
            onChange?(CropGeometry.moved(start, by: CGSize(width: pixel.x - origin.x, height: pixel.y - origin.y), imageSize: imageSize))
        case .resize(let start, let corner):
            onChange?(CropGeometry.resized(start, corner: corner, to: pixel, ratio: ratio, imageSize: imageSize, minimumSide: minimumSide))
        case .select(let anchor, let viewStart, let active):
            guard active || hypot(point.x - viewStart.x, point.y - viewStart.y) > 4 else { return }
            self.drag = .select(anchor: anchor, viewStart: viewStart, active: true)
            onChange?(CropGeometry.selection(from: anchor, to: pixel, ratio: ratio, imageSize: imageSize, minimumSide: minimumSide))
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard imageSize.width > 0, let key = event.specialKey else {
            super.keyDown(with: event)
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch key {
        case .leftArrow: dx = -step
        case .rightArrow: dx = step
        case .upArrow: dy = -step
        case .downArrow: dy = step
        default:
            super.keyDown(with: event)
            return
        }
        if event.modifierFlags.contains(.option) {
            onChange?(CropGeometry.resizedByKeyboard(cropRect, dx: dx, dy: dy, ratio: ratio, imageSize: imageSize))
        } else {
            onChange?(CropGeometry.moved(cropRect, by: CGSize(width: dx, height: dy), imageSize: imageSize))
        }
    }
}
