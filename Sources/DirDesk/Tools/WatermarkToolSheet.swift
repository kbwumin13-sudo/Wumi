import AppKit
import DirDeskCore
import SwiftUI

@MainActor
final class WatermarkToolModel: ObservableObject {
    /// Slider ranges and steps measured from the reference sheet.
    static let angleRange: ClosedRange<Double> = -90...90
    static let opacityRange: ClosedRange<Double> = 0.05...1
    static let textSizeRange: ClosedRange<Double> = 0.01...0.2
    static let spacingRange: ClosedRange<Double> = 0.02...0.5
    /// Default watermark text: the app's name, as the reference prefills its own.
    static let defaultText = "Wumi"

    let sources: [URL]
    @Published var text: String
    @Published var layout: ImageWatermarkLayout
    @Published var angle: Double
    @Published var opacity: Double
    @Published var textSize: Double
    @Published var spacing: Double
    @Published var color: ImageWatermarkColor
    @Published private(set) var previewSource: URL?
    @Published private(set) var base: ToolBitmap?
    @Published private(set) var rendered: ToolBitmap?
    @Published private(set) var loadFailure: String?
    @Published private(set) var isRendering = false
    private var renderTask: Task<Void, Never>?
    private var loaded = false

    init(sources: [URL]) {
        self.sources = sources
        let defaults = ImageWatermarkOptions(text: Self.defaultText)
        text = defaults.text
        layout = defaults.layout
        angle = defaults.angleDegrees
        opacity = defaults.opacity
        textSize = defaults.relativeFontSize
        spacing = defaults.relativeSpacing
        color = defaults.color
    }

    var options: ImageWatermarkOptions {
        ImageWatermarkOptions(text: text, layout: layout, angleDegrees: angle.rounded(), opacity: opacity, relativeFontSize: textSize,
                              relativeSpacing: spacing, color: color)
    }

    /// A failure to preview blocks the tool only when it was the one selected image.
    var blockingProblem: String? { sources.count == 1 ? loadFailure : nil }

    var swiftUIColor: Binding<Color> {
        Binding(get: { [unowned self] in
            Color(.sRGB, red: self.color.red, green: self.color.green, blue: self.color.blue, opacity: 1)
        }, set: { [unowned self] newValue in
            let srgb = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
            self.color = ImageWatermarkColor(red: Self.unit(srgb.redComponent), green: Self.unit(srgb.greenComponent),
                                             blue: Self.unit(srgb.blueComponent))
        })
    }

    private static func unit(_ value: CGFloat) -> Double { min(1, max(0, Double(value))) }

    /// Previews the first selected image that can be read (looking at a few), so one unsupported file
    /// does not hide the preview of a batch.
    func load() async {
        guard !loaded, !sources.isEmpty else { return }
        loaded = true
        let candidates = Array(sources.prefix(8))
        let outcome = await ToolWork.run { () -> (URL, ToolBitmap) in
            var firstError: Error?
            for source in candidates {
                do {
                    let metadata = try ImageTransformationService().metadata(source: source)
                    if metadata.frameCount > 1 { throw ImageTransformationError.unsupportedFrameCount(metadata.frameCount) }
                    guard let thumbnail = ToolImageLoader.thumbnail(of: source, maximumPixelSize: 1200) else {
                        throw ImageTransformationError.unsupportedOrDamaged(source.lastPathComponent)
                    }
                    return (source, ToolBitmap(cgImage: thumbnail))
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            throw firstError ?? ImageTransformationError.emptySelection
        }
        switch outcome {
        case .success(let (source, bitmap)):
            previewSource = source
            base = bitmap
            render(delay: false)
        case .failure(let message):
            loadFailure = message
        }
    }

    /// Redraws the preview shortly after the options stop changing.
    func render(delay: Bool = true) {
        guard let base else { return }
        renderTask?.cancel()
        let options = self.options
        guard options.isValid else {
            rendered = nil
            isRendering = false
            return
        }
        isRendering = true
        renderTask = Task { [weak self] in
            if delay { try? await Task.sleep(for: .milliseconds(60)) }
            if Task.isCancelled { return }
            let outcome = await ToolWork.run { () -> ToolBitmap? in
                ImageTransformationService.renderWatermark(options, on: base.cgImage).map(ToolBitmap.init)
            }
            if Task.isCancelled { return }
            if case .success(let image) = outcome { self?.rendered = image }
            self?.isRendering = false
        }
    }

    func cancelRendering() {
        renderTask?.cancel()
    }

    func jobs() -> [ToolJob] {
        let options = self.options
        return sources.map { source in
            ToolJob(name: source.lastPathComponent) { _ in
                ToolJobOutput(outputs: [try ImageTransformationService().watermark(source: source, options: options).output])
            }
        }
    }
}

/// Reference layout: options on the left (text, layout, four sliders, color), a square live preview on the right.
struct WatermarkToolSheet: View {
    @ObservedObject var model: WatermarkToolModel
    let onCancel: () -> Void
    let onRun: () -> Void
    @FocusState private var textFocused: Bool

    private var problem: String? {
        if let failure = model.blockingProblem { return failure }
        if model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L("Enter the watermark text.") }
        return nil
    }

    var body: some View {
        ToolSheetScaffold(tool: .imageWatermark, subtitle: ToolSheetHeader.names(model.sources), problem: problem,
                          primaryTitle: L("Add Watermark"), canRun: problem == nil && model.options.isValid, onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    controls.frame(width: 320)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            ToolSectionTitle(L("Live Preview"))
                            if model.isRendering { ProgressView().controlSize(.mini) }
                        }
                        ToolPreviewBox(.result) {
                            ToolImagePreview(image: model.rendered?.cgImage ?? model.base?.cgImage,
                                             isLoading: model.base == nil && model.loadFailure == nil,
                                             message: model.loadFailure, accessibilityLabel: L("Transformation result preview"))
                        }
                        .frame(maxWidth: ToolSheetMetrics.previewWidth, minHeight: ToolSheetMetrics.previewWidth, maxHeight: ToolSheetMetrics.previewWidth)
                    }
                }
                ToolCaption(L("Every image gets a watermarked copy saved beside it. The originals are left untouched."))
            }
        }
        .task { await model.load() }
        .onAppear { DispatchQueue.main.async { textFocused = true } }
        .onChange(of: model.options) { _, _ in model.render() }
        .onDisappear { model.cancelRendering() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(L("Watermark Text"), text: $model.text)
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .accessibilityLabel(L("Watermark Text"))
                .accessibilityIdentifier("BuiltInTool.Watermark.Text")
            ToolFormRow(L("Layout")) {
                Picker("", selection: $model.layout) {
                    Text(L("Centered")).tag(ImageWatermarkLayout.centered)
                    Text(L("Tiled")).tag(ImageWatermarkLayout.tiled)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(L("Layout"))
            }
            VStack(alignment: .leading, spacing: 8) {
                ToolSliderRow(title: L("Angle"), value: $model.angle, range: WatermarkToolModel.angleRange, step: 1,
                              valueText: ToolText.degrees(model.angle))
                ToolSliderRow(title: L("Opacity"), value: $model.opacity, range: WatermarkToolModel.opacityRange, step: 0.05,
                              valueText: ToolText.percent(model.opacity))
                ToolSliderRow(title: L("Text Size"), value: $model.textSize, range: WatermarkToolModel.textSizeRange, step: 0.005,
                              valueText: ToolText.percent(model.textSize, fractionDigits: 1))
                ToolSliderRow(title: L("Spacing"), value: $model.spacing, range: WatermarkToolModel.spacingRange, step: 0.01,
                              valueText: ToolText.percent(model.spacing))
                    .disabled(model.layout != .tiled)
            }
            HStack(spacing: 8) {
                Text(L("Text Color"))
                ColorPicker("", selection: model.swiftUIColor, supportsOpacity: false)
                    .labelsHidden()
                    .accessibilityLabel(L("Text Color"))
            }
            ToolCaption(L("Text size and spacing follow each image's shorter edge, so the watermark looks alike on large and small images."))
        }
    }
}
