import AppKit
import DirDeskCore
import SwiftUI

/// Entry point of the image and PDF built-in tools: checks the selection, then either runs the tool
/// right away (rotate, remove location metadata) or opens its options sheet on the workspace window.
@MainActor
enum BuiltInToolPresenter {
    static func present(_ tool: BuiltInToolID, items: [FileItem], controller: WorkspaceController) {
        if tool.category == .folders {
            controller.runBuiltInTool(tool, items: items)
            return
        }
        if let running = BuiltInToolSession.current(for: controller) {
            running.showBusyAlert()
            return
        }
        if let problem = selectionProblem(for: tool, items: items) {
            controller.presentError(problem)
            return
        }
        let urls = items.map(\.url)
        switch tool {
        case .imageRotateLeft, .imageRotateRight:
            let direction: ImageRotationDirection = tool == .imageRotateLeft ? .left : .right
            runWithoutOptions(tool, urls: urls, controller: controller) { source in
                ToolJobOutput(outputs: [try ImageTransformationService().rotate(source: source, direction: direction).output])
            }
        case .imageRemoveLocationMetadata:
            runWithoutOptions(tool, urls: urls, controller: controller) { source in
                ToolJobOutput(outputs: [try ImageTransformationService().removeLocationMetadata(source: source).output])
            }
        default:
            presentSheet(tool, urls: urls, session: BuiltInToolSession(tool: tool, controller: controller))
        }
    }

    /// Why `tool` cannot run on `items`, or nil when it can.
    static func selectionProblem(for tool: BuiltInToolID, items: [FileItem]) -> String? {
        guard !items.isEmpty else { return L("Select at least one item.") }
        guard items.count <= BuiltInToolLimits.maximumItemCount else {
            return LF("Built-in Tools can process at most %lld items at once.", Int64(BuiltInToolLimits.maximumItemCount))
        }
        if let input = BuiltInToolInput(tool) {
            let unsupported = items.filter { !input.accepts($0) }
            if !unsupported.isEmpty {
                var names = unsupported.prefix(3).map(\.name).joined(separator: ", ")
                if unsupported.count > 3 { names += ", …" }
                let kind = input == .image ? L("This tool works with image files only.") : L("This tool works with PDF files only.")
                return [L("This tool does not support the current selection."), kind, LF("Not supported: %@", names)].joined(separator: "\n")
            }
        }
        guard tool.selectionRule.accepts(count: items.count) else {
            switch tool.selectionRule {
            case .exactlyOne:
                return L("This tool does not support the current selection.") + "\n" + L("Select exactly one file.")
            case .twoOrMore:
                return LF("This operation requires at least %lld PDFs; received %lld.", Int64(2), Int64(items.count))
            case .oneOrMore:
                return L("Select at least one item.")
            }
        }
        return nil
    }

    // MARK: Tools without options

    /// Runs one job per file; large batches are confirmed first. Quick runs show no sheet at all.
    private static func runWithoutOptions(_ tool: BuiltInToolID, urls: [URL], controller: WorkspaceController,
                                          work: @escaping @Sendable (URL) throws -> ToolJobOutput) {
        let jobs = urls.map { url in ToolJob(name: url.lastPathComponent) { _ in try work(url) } }
        let start = {
            guard BuiltInToolSession.current(for: controller) == nil else { return }
            let session = BuiltInToolSession(tool: tool, controller: controller)
            BuiltInToolRun.start(jobs, in: session, showsProgressImmediately: false)
        }
        guard urls.count > BuiltInToolLimits.confirmationThreshold, let window = controller.window else {
            start()
            return
        }
        let alert = NSAlert()
        alert.messageText = LF("Process %lld items?", Int64(urls.count))
        alert.informativeText = L("A new copy is created for each item and the originals stay unchanged. You can cancel while the items are processed.")
        alert.addButton(withTitle: BuiltInToolSupport.title(tool))
        alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { start() }
            }
        }
    }

    // MARK: Tools with options

    /// Every options sheet has the reference's fixed size (760 × 680 pt), shrunk to fit a small window.
    private static func presentSheet(_ tool: BuiltInToolID, urls: [URL], session: BuiltInToolSession) {
        let unit = AppModel.shared.preferences.fileSizeUnit
        let cancel = { session.end() }
        let first = urls[0]
        let size = ToolSheetMetrics.size
        switch tool {
        case .imageCrop:
            let model = CropToolModel(source: first)
            session.show(CropToolSheet(model: model, onCancel: cancel, onRun: { rect in
                BuiltInToolRun.start([ToolJob(name: first.lastPathComponent) { _ in
                    ToolJobOutput(outputs: [try ImageTransformationService().crop(source: first, rect: rect).output])
                }], in: session)
            }), size: size)

        case .imageConvert:
            let model = ConvertImageToolModel(sources: urls)
            session.show(ConvertImageToolSheet(model: model, onCancel: cancel, onRun: {
                BuiltInToolRun.start(model.jobs(), in: session)
            }), size: size)

        case .imageCompress:
            let model = CompressImageToolModel(sources: urls, sizeUnit: unit)
            session.show(CompressImageToolSheet(model: model, onCancel: cancel, onRun: {
                BuiltInToolRun.start(model.jobs(), in: session, report: .always)
            }), size: size)

        case .imageWatermark:
            let model = WatermarkToolModel(sources: urls)
            session.show(WatermarkToolSheet(model: model, onCancel: cancel, onRun: {
                BuiltInToolRun.start(model.jobs(), in: session)
            }), size: size)

        case .imageRemoveBackground:
            let model = RemoveBackgroundToolModel(source: first)
            session.onEnd { model.discard() }
            session.show(RemoveBackgroundToolSheet(model: model, onCancel: cancel, onSave: {
                guard let job = model.saveJob() else { return }
                BuiltInToolRun.start([job], in: session)
            }), size: size)

        case .imagesCreatePDF:
            let model = ImagesToPDFToolModel(urls: urls)
            session.show(ImagesToPDFToolSheet(model: model, onCancel: cancel, onRun: {
                guard let job = model.job() else { return }
                BuiltInToolRun.start([job], in: session)
            }), size: size)

        case .imageViewLocation:
            let model = PhotoLocationToolModel(source: first)
            session.show(PhotoLocationToolSheet(model: model, onDone: cancel), size: size)

        case .pdfSplit:
            let model = SplitPDFToolModel(source: first)
            session.show(SplitPDFToolSheet(model: model, onCancel: cancel, onRun: {
                guard let job = model.job() else { return }
                BuiltInToolRun.start([job], in: session)
            }), size: size)

        case .pdfExtractPages:
            let model = ExtractPagesToolModel(source: first)
            session.show(ExtractPagesToolSheet(model: model, onCancel: cancel, onRun: {
                guard let job = model.job() else { return }
                BuiltInToolRun.start([job], in: session)
            }), size: size)

        case .pdfMerge:
            let model = MergePDFToolModel(urls: urls)
            session.show(MergePDFToolSheet(model: model, onCancel: cancel, onRun: {
                guard let job = model.job() else { return }
                BuiltInToolRun.start([job], in: session)
            }), size: size)

        case .pdfRotatePages:
            let model = RotatePDFPagesToolModel(source: first)
            session.show(RotatePDFPagesToolSheet(model: model, onCancel: cancel, onRun: {
                guard let job = model.job() else { return }
                BuiltInToolRun.start([job], in: session)
            }), size: size)

        case .pdfCompress:
            let model = CompressPDFToolModel(sources: urls, sizeUnit: unit)
            session.show(CompressPDFToolSheet(model: model, onCancel: cancel, onRun: {
                BuiltInToolRun.start(model.jobs(), in: session, report: .always)
            }), size: size)

        case .pdfExportImages:
            let model = ExportPDFImagesToolModel(source: first)
            session.show(ExportPDFImagesToolSheet(model: model, onCancel: cancel, onRun: {
                BuiltInToolRun.start([model.job()], in: session)
            }), size: size)

        case .imageRotateLeft, .imageRotateRight, .imageRemoveLocationMetadata, .collectIntoFolder, .dissolveFolder:
            session.end()
        }
    }
}
