import AppKit
import DirDeskCore
import SwiftUI
import UniformTypeIdentifiers

/// Quality slider range shared by the image encoding tools: 10 %–100 % in 5 % steps.
enum ToolQuality {
    static let range: ClosedRange<Double> = 0.1...1
    static let step = 0.05
}

/// "Output format [JPEG ⌃⌄]" and "Quality: 80 %" over a full-width stepped slider, as in the reference.
struct ImageEncodingOptions: View {
    @Binding var format: ImageOutputFormat
    @Binding var quality: Double

    var body: some View {
        ToolFormRow(L("Output format")) {
            Picker("", selection: $format) {
                ForEach(ImageOutputFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(L("Output format"))
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(LF("Quality: %@", ToolText.percent(quality)))
            Slider(value: $quality, in: ToolQuality.range, step: ToolQuality.step)
                .labelsHidden()
                .accessibilityLabel(L("Quality"))
        }
        .disabled(!format.usesLossyQuality)
    }
}

// MARK: - Convert

@MainActor
final class ConvertImageToolModel: ObservableObject {
    let sources: [URL]
    @Published var format: ImageOutputFormat = .jpeg
    @Published var quality = 0.8

    init(sources: [URL]) {
        self.sources = sources
    }

    func jobs() -> [ToolJob] {
        let format = self.format, quality = format.usesLossyQuality ? self.quality : nil
        return sources.map { source in
            ToolJob(name: source.lastPathComponent) { _ in
                let result = try ImageTransformationService().convert(source: source, format: format, quality: quality)
                return ToolJobOutput(outputs: [result.output])
            }
        }
    }
}

struct ConvertImageToolSheet: View {
    @ObservedObject var model: ConvertImageToolModel
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        ToolSheetScaffold(tool: .imageConvert, subtitle: ToolSheetHeader.names(model.sources), onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 12) {
                ImageEncodingOptions(format: $model.format, quality: $model.quality)
                ToolCaption(L("The result is saved as a new file beside the source. The source file stays as it is."))
            }
        }
    }
}

// MARK: - Compress

/// Facts about the first readable selected image, for the size estimate.
struct ToolFirstImageInfo: Sendable {
    var byteCount: Int64

    static func load(_ source: URL) throws -> ToolFirstImageInfo {
        let metadata = try ImageTransformationService().metadata(source: source)
        if metadata.frameCount > 1 { throw ImageTransformationError.unsupportedFrameCount(metadata.frameCount) }
        return ToolFirstImageInfo(byteCount: metadata.byteCount)
    }
}

/// Live size estimate for the first readable selected image, recomputed shortly after the options stop
/// changing: "Estimated output: 64.3 KB (85 %)", the percentage relative to the original file.
@MainActor
final class CompressImageToolModel: ObservableObject {
    let sources: [URL]
    let sizeUnit: FileSizeUnit
    @Published var format: ImageOutputFormat = .jpeg {
        didSet { if format != oldValue { scheduleEstimate() } }
    }
    @Published var quality = 0.8 {
        didSet { if quality != oldValue { scheduleEstimate() } }
    }
    @Published var limitsDimensions = false {
        didSet { if limitsDimensions != oldValue { scheduleEstimate() } }
    }
    @Published var maximumDimension = 2048 {
        didSet { if maximumDimension != oldValue { scheduleEstimate() } }
    }
    @Published private(set) var estimateSource: URL?
    @Published private(set) var loadFailure: String?
    @Published private(set) var estimate: ToolEstimate = .idle
    private var info: ToolFirstImageInfo?
    private var estimateTask: Task<Void, Never>?
    private var loaded = false

    init(sources: [URL], sizeUnit: FileSizeUnit) {
        self.sources = sources
        self.sizeUnit = sizeUnit
    }

    static let dimensionRange = 16...100_000

    var isMaximumValid: Bool { !limitsDimensions || Self.dimensionRange.contains(maximumDimension) }

    /// A failure to read blocks the tool only when it was the one selected image.
    var blockingProblem: String? { sources.count == 1 ? loadFailure : nil }

    var options: ImageCompressionOptions {
        let bound = limitsDimensions ? maximumDimension : nil
        return ImageCompressionOptions(format: format, quality: quality, maximumPixelWidth: bound, maximumPixelHeight: bound)
    }

    /// Reads the first image that can be read (looking at a few), so one unsupported file does not hide the estimate of a batch.
    func load() async {
        guard !loaded, !sources.isEmpty else { return }
        loaded = true
        let candidates = Array(sources.prefix(8))
        let outcome = await ToolWork.run { () -> (URL, ToolFirstImageInfo) in
            var firstError: Error?
            for source in candidates {
                do {
                    return (source, try ToolFirstImageInfo.load(source))
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            throw firstError ?? ImageTransformationError.emptySelection
        }
        switch outcome {
        case .success(let (source, info)):
            estimateSource = source
            self.info = info
            scheduleEstimate(immediately: true)
        case .failure(let message):
            loadFailure = message
        }
    }

    func scheduleEstimate(immediately: Bool = false) {
        estimateTask?.cancel()
        guard let source = estimateSource, let info, isMaximumValid else {
            estimate = .idle
            return
        }
        estimate = .estimating
        let options = self.options, unit = sizeUnit
        estimateTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(300)) }
            if Task.isCancelled { return }
            let outcome = await ToolWork.run { try ImageTransformationService().estimateOutputSize(source: source, options: options) }
            if Task.isCancelled { return }
            switch outcome {
            case .success(let result):
                let size = FileSizeFormatter.string(result.byteCount, unit: unit)
                let share = info.byteCount > 0 ? Double(result.byteCount) / Double(info.byteCount) : 1
                self?.estimate = .ready(LF("Estimated output: %@ (%@)", size, ToolText.percent(share)))
            case .failure(let message):
                self?.estimate = .unavailable(message)
            }
        }
    }

    func cancelEstimate() {
        estimateTask?.cancel()
    }

    func jobs() -> [ToolJob] {
        let options = self.options, unit = sizeUnit
        return sources.map { source in
            ToolJob(name: source.lastPathComponent) { _ in
                let result = try ImageTransformationService().compress(source: source, options: options)
                let (before, after) = ToolText.sizes(result.originalByteCount, result.outputByteCount, unit: unit)
                var detail = LF("Compressed from %@ to %@", before, after)
                if result.outputByteCount >= result.originalByteCount {
                    detail += " · " + L("not smaller than the original")
                }
                if result.outputPixelWidth != result.originalPixelWidth || result.outputPixelHeight != result.originalPixelHeight {
                    detail += " · " + ToolText.pixels(result.outputPixelWidth, result.outputPixelHeight)
                }
                return ToolJobOutput(outputs: [result.output], detail: detail)
            }
        }
    }
}

struct CompressImageToolSheet: View {
    @ObservedObject var model: CompressImageToolModel
    let onCancel: () -> Void
    let onRun: () -> Void

    private var problem: String? {
        model.blockingProblem ?? (model.isMaximumValid ? nil : L("Maximum image dimensions must be positive."))
    }

    var body: some View {
        ToolSheetScaffold(tool: .imageCompress, subtitle: ToolSheetHeader.names(model.sources), problem: problem,
                          canRun: problem == nil, onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 12) {
                ImageEncodingOptions(format: $model.format, quality: $model.quality)
                Toggle(L("Limit maximum dimensions"), isOn: $model.limitsDimensions)
                    .toggleStyle(.checkbox)
                if model.limitsDimensions {
                    HStack(spacing: 6) {
                        ToolIntegerField(value: $model.maximumDimension, width: 90)
                        Text(L("px")).foregroundStyle(.secondary)
                        Stepper("", value: $model.maximumDimension, in: CompressImageToolModel.dimensionRange, step: 128).labelsHidden()
                    }
                }
                ToolCaption(dimensionNote)
                ToolCaption(L("The result is saved as a new file beside the source. The source file stays as it is."))
                if model.sources.count > 1, let source = model.estimateSource, model.estimate != .idle {
                    ToolEstimateLabel(estimate: model.estimate)
                    ToolCaption(LF("The estimate covers %@ only.", source.lastPathComponent))
                } else {
                    ToolEstimateLabel(estimate: model.estimate)
                }
            }
        }
        .task { await model.load() }
        .onDisappear { model.cancelEstimate() }
    }

    private var dimensionNote: String {
        guard model.limitsDimensions else { return L("Dimensions are preserved.") }
        return LF("Maximum width and height: %lld px", Int64(model.maximumDimension)) + " · " + L("Smaller images are never enlarged.")
    }
}
