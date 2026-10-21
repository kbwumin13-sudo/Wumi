import AppKit
import DirDeskCore
import SwiftUI

// MARK: - Merge PDFs

@MainActor
final class MergePDFToolModel: ToolOrderedFilesModel {
    @Published private(set) var failures: [URL: String] = [:]
    private var loadStarted = false

    /// Opens each source once so an unreadable PDF is reported before merging.
    func checkSources() async {
        guard !loadStarted else { return }
        loadStarted = true
        for file in files {
            let url = file.url
            if case .failure(let message) = await ToolWork.run({ try PDFTransformationService().pageCount(of: url) }) {
                failures[url] = message
            }
        }
    }

    /// Why the first unreadable PDF in the current order cannot be merged (the message names the file).
    var problem: String? {
        guard let file = files.first(where: { failures[$0.url] != nil }), let message = failures[file.url] else { return nil }
        return message
    }

    /// "Merged.pdf" next to the first PDF in the chosen order.
    func job() -> ToolJob? {
        let urls = files.map(\.url)
        guard urls.count >= 2, let directory = urls.first?.deletingLastPathComponent() else { return nil }
        return ToolJob(name: urls.map(\.lastPathComponent).joined(separator: ", ")) { cancellation in
            let output = try PDFTransformationService().merge(sources: urls, outputDirectory: directory, outputBaseName: nil,
                                                              isCancelled: { cancellation.isCancelled })
            return ToolJobOutput(outputs: [output])
        }
    }
}

/// Reference layout: a note on the order, then one card per source PDF with its position and up / down arrows.
struct MergePDFToolSheet: View {
    @ObservedObject var model: MergePDFToolModel
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        ToolSheetScaffold(tool: .pdfMerge, subtitle: ToolSheetHeader.names(model.files.map(\.url)), problem: model.problem,
                          primaryTitle: L("Merge PDFs"), canRun: model.files.count >= 2 && model.problem == nil,
                          onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Check the order of the merged document. The arrows move all pages of a source PDF together."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(model.files.enumerated()), id: \.element.id) { index, file in
                            row(index: index, file: file)
                        }
                    }
                }
                .accessibilityIdentifier("BuiltInTool.Merge.Sources")
            }
        }
        .task { await model.checkSources() }
    }

    private func row(index: Int, file: ToolOrderedFile) -> some View {
        let failure = model.failures[file.url]
        return HStack(spacing: 0) {
            Text("\(index + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 17, alignment: .leading)
            Image(systemName: failure == nil ? "doc.richtext.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(failure == nil ? Color.secondary : Color.orange)
                .frame(width: 20)
                .help(failure ?? "")
            Text(file.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 10)
            Spacer(minLength: 12)
            arrow("arrow.up", title: L("Move Earlier"), enabled: model.canMove(index, by: -1)) { model.move(index, by: -1) }
            arrow("arrow.down", title: L("Move Later"), enabled: model.canMove(index, by: 1)) { model.move(index, by: 1) }
                .padding(.leading, 5)
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private func arrow(_ symbol: String, title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.45))
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Rotate PDF pages

@MainActor
final class RotatePDFPagesToolModel: PDFSourceModel {
    @Published var rotation: PDFRotation = .clockwise90
    @Published var pagesText = ""

    /// Pages to rotate, or the reason the field is invalid.
    var selection: Result<PDFPageSelection, ToolInputProblem> {
        let selection: PDFPageSelection
        do {
            selection = try PDFPageSelection.parse(pagesText)
        } catch {
            return .failure(ToolInputProblem(message: BuiltInToolErrorText.message(for: error)))
        }
        if case .pages(let pages) = selection, let pageCount, let high = pages.max(), high > pageCount {
            let low = pages.filter { $0 > pageCount }.min() ?? high
            return .failure(ToolInputProblem(message: BuiltInToolErrorText.message(
                for: PDFTransformationError.invalidPageRange(PDFPageRange(first: low, last: high), pageCount: pageCount))))
        }
        return .success(selection)
    }

    func job() -> ToolJob? {
        guard case .success(let selection) = selection else { return nil }
        let source = self.source, rotation = self.rotation
        return ToolJob(name: source.lastPathComponent) { _ in
            ToolJobOutput(outputs: [try PDFTransformationService().rotate(source: source, selection: selection, rotation: rotation,
                                                                           outputDirectory: source.deletingLastPathComponent())])
        }
    }
}

struct ToolInputProblem: Error {
    let message: String
}

/// Reference layout: the pages field (blank means every page) and the rotation pop-up.
struct RotatePDFPagesToolSheet: View {
    @ObservedObject var model: RotatePDFPagesToolModel
    let onCancel: () -> Void
    let onRun: () -> Void
    @FocusState private var pagesFocused: Bool

    private var problem: String? {
        if let failure = model.loadFailure { return failure }
        if case .failure(let problem) = model.selection { return problem.message }
        return nil
    }

    var body: some View {
        ToolSheetScaffold(tool: .pdfRotatePages, subtitle: model.source.lastPathComponent, problem: problem,
                          canRun: model.pageCount != nil && problem == nil, onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 12) {
                TextField(L("Pages (blank means all)"), text: $model.pagesText)
                    .textFieldStyle(.roundedBorder)
                    .focused($pagesFocused)
                    .accessibilityLabel(L("Pages (blank means all)"))
                    .accessibilityIdentifier("BuiltInTool.Rotate.Pages")
                ToolFormRow(L("Rotation")) {
                    Picker("", selection: $model.rotation) {
                        Text(L("90° Clockwise")).tag(PDFRotation.clockwise90)
                        Text(L("90° Counterclockwise")).tag(PDFRotation.counterclockwise90)
                        Text(L("180°")).tag(PDFRotation.halfTurn)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L("Rotation"))
                }
            }
        }
        .task { await model.loadPageCount() }
        .onAppear { DispatchQueue.main.async { pagesFocused = true } }
    }
}

// MARK: - Compress PDF

@MainActor
final class CompressPDFToolModel: ObservableObject {
    let sources: [URL]
    let sizeUnit: FileSizeUnit
    @Published var preset: PDFCompressionPreset = .screenOptimized
    @Published private(set) var totalBytes: Int64?

    init(sources: [URL], sizeUnit: FileSizeUnit) {
        self.sources = sources
        self.sizeUnit = sizeUnit
    }

    func loadSizes() async {
        let sources = self.sources
        if case .success(let total) = await ToolWork.run({
            sources.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }) {
            totalBytes = total
        }
    }

    func jobs() -> [ToolJob] {
        let preset = self.preset, unit = sizeUnit
        return sources.map { source in
            ToolJob(name: source.lastPathComponent) { _ in
                let result = try PDFTransformationService().compress(source: source, preset: preset, outputDirectory: source.deletingLastPathComponent())
                let (before, after) = ToolText.sizes(result.originalByteCount, result.outputByteCount, unit: unit)
                let detail: String
                if result.savedByteCount > 0, result.originalByteCount > 0 {
                    let percent = Int64((Double(result.savedByteCount) / Double(result.originalByteCount) * 100).rounded())
                    detail = LF("%@ → %@ (%lld%% smaller)", before, after, percent)
                } else if result.savedByteCount == 0 {
                    detail = LF("%@ → %@ (same size)", before, after)
                } else {
                    detail = LF("%@ → %@ (larger than the original)", before, after)
                }
                return ToolJobOutput(outputs: [result.output], detail: detail)
            }
        }
    }
}

/// Reference layout: the preset pop-up, the current size, and a note that the real size is known afterwards.
struct CompressPDFToolSheet: View {
    @ObservedObject var model: CompressPDFToolModel
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        ToolSheetScaffold(tool: .pdfCompress, subtitle: ToolSheetHeader.names(model.sources), primaryTitle: L("Compress PDF"),
                          onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 12) {
                ToolFormRow(L("Compression preset")) {
                    Picker("", selection: $model.preset) {
                        Text(L("Optimize images for screen")).tag(PDFCompressionPreset.screenOptimized)
                        Text(L("Optimize and convert images to JPEG")).tag(PDFCompressionPreset.screenOptimizedJPEG)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L("Compression preset"))
                }
                if let total = model.totalBytes {
                    Text(LF("Current size: %@", FileSizeFormatter.string(total, unit: model.sizeUnit)))
                        .font(.system(size: 12))
                }
                ToolCaption(L("The exact size is known only after compressing. An already optimized PDF can even grow; the original is always kept."))
            }
        }
        .task { await model.loadSizes() }
    }
}

// MARK: - Export PDF pages as images

@MainActor
final class ExportPDFImagesToolModel: PDFSourceModel {
    enum Resolution: Hashable {
        case screen, sharing, printing, custom
    }

    @Published var format: PDFImageExportFormat = .jpeg
    @Published var resolution: Resolution = .sharing
    @Published var customDPI = 200
    @Published var jpegQuality = 0.85
    @Published private(set) var firstPageSize: CGSize?

    func loadMetadata() async {
        await loadPageCount()
        let source = self.source
        if case .success(let size) = await ToolWork.run({ try PDFTransformationService().metadata(of: source).firstPageSize }) {
            firstPageSize = size
        }
    }

    var dpi: Int {
        switch resolution {
        case .screen: PDFImageExportOptions.screenReadingDPI
        case .sharing: PDFImageExportOptions.clearSharingDPI
        case .printing: PDFImageExportOptions.highQualityPrintingDPI
        case .custom: customDPI
        }
    }

    var firstPagePixels: (width: Int, height: Int)? {
        guard let size = firstPageSize, size.width > 0, size.height > 0 else { return nil }
        let scale = Double(dpi) / 72
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    var problem: String? {
        if let loadFailure { return loadFailure }
        guard PDFImageExportOptions.supportedDPI.contains(dpi) else {
            return BuiltInToolErrorText.message(for: PDFTransformationError.invalidImageExportOptions)
        }
        let limit = PDFTransformationService.Limits.default.maximumRenderedPixelsPerPage
        if let pixels = firstPagePixels {
            let product = pixels.width.multipliedReportingOverflow(by: pixels.height)
            let count = product.overflow ? Int.max : product.partialValue
            if count > limit {
                return BuiltInToolErrorText.message(for: PDFTransformationError.imagePixelLimitExceeded(page: 1, pixels: count, limit: limit))
            }
        }
        return nil
    }

    func job() -> ToolJob {
        let source = self.source
        let options = PDFImageExportOptions(format: format, dpi: dpi, jpegQuality: jpegQuality)
        return ToolJob(name: source.lastPathComponent) { cancellation in
            let result = try PDFTransformationService().exportImages(source: source, options: options, outputDirectory: source.deletingLastPathComponent(),
                                                                     isCancelled: { cancellation.isCancelled })
            return ToolJobOutput(outputs: [result.folder], detail: LF("Exported %@", ToolText.imageCount(result.images.count)))
        }
    }
}

/// Reference layout: JPEG / PNG, the resolution pop-up with a note, the JPEG quality slider, and where the images go.
struct ExportPDFImagesToolSheet: View {
    @ObservedObject var model: ExportPDFImagesToolModel
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        ToolSheetScaffold(tool: .pdfExportImages, subtitle: model.source.lastPathComponent, problem: model.problem,
                          primaryTitle: L("Export Images"), canRun: model.pageCount != nil && model.problem == nil,
                          onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 12) {
                ToolFormRow(L("Image format")) {
                    Picker("", selection: $model.format) {
                        Text("JPEG").tag(PDFImageExportFormat.jpeg)
                        Text("PNG").tag(PDFImageExportFormat.png)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L("Image format"))
                }
                ToolFormRow(L("Resolution")) {
                    Picker("", selection: $model.resolution) {
                        Text(L("Screen Reading (72 DPI)")).tag(ExportPDFImagesToolModel.Resolution.screen)
                        Text(L("Clear Sharing (150 DPI)")).tag(ExportPDFImagesToolModel.Resolution.sharing)
                        Text(L("High-Quality Printing (300 DPI)")).tag(ExportPDFImagesToolModel.Resolution.printing)
                        Text(L("Custom")).tag(ExportPDFImagesToolModel.Resolution.custom)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L("Resolution"))
                    .accessibilityIdentifier("BuiltInTool.PDF.ImageDPI")
                    if model.resolution == .custom {
                        ToolIntegerField(value: $model.customDPI, width: 70)
                        Text("DPI").foregroundStyle(.secondary)
                    }
                }
                ToolCaption(resolutionNote)
                ToolSliderRow(title: L("JPEG compression quality"), value: $model.jpegQuality, range: ToolQuality.range,
                              step: ToolQuality.step, valueText: ToolText.percent(model.jpegQuality))
                    .disabled(model.format != .jpeg)
                ToolCaption(L("Images are written in page order into a new folder next to the PDF. The folder appears when all pages are done."))
            }
        }
        .task { await model.loadMetadata() }
    }

    private var resolutionNote: String {
        var note = L("Higher resolutions make sharper, larger images, but cannot add detail that a scan does not contain.")
        if model.resolution == .custom {
            note += " " + LF("%lld–%lld", Int64(PDFImageExportOptions.supportedDPI.lowerBound), Int64(PDFImageExportOptions.supportedDPI.upperBound)) + " DPI"
        }
        return note
    }
}
