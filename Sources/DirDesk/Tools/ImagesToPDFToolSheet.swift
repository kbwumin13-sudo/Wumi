import AppKit
import DirDeskCore
import SwiftUI

/// Rows of an ordered file list ("Create PDF" pages, "Merge PDFs" sources).
struct ToolOrderedFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
class ToolOrderedFilesModel: ObservableObject {
    @Published var files: [ToolOrderedFile]

    init(urls: [URL]) {
        files = urls.map(ToolOrderedFile.init)
    }

    func canMove(_ index: Int, by offset: Int) -> Bool {
        files.indices.contains(index) && files.indices.contains(index + offset)
    }

    /// Swaps the file at `index` with its neighbour `offset` rows away.
    func move(_ index: Int, by offset: Int) {
        guard canMove(index, by: offset) else { return }
        files.swapAt(index, index + offset)
    }
}

/// One page per image in selection order, written as "<first image>-created.pdf" next to the first image.
@MainActor
final class ImagesToPDFToolModel: ToolOrderedFilesModel {
    @Published var paperSize: ImagePDFPaperSize = .original
    @Published var fitToPage = true
    @Published var allowUpscaling = false

    var options: ImagePDFOptions {
        ImagePDFOptions(paperSize: paperSize, fitToPage: fitToPage, allowUpscaling: allowUpscaling)
    }

    func job() -> ToolJob? {
        let urls = files.map(\.url)
        guard let first = urls.first else { return nil }
        let options = self.options
        let directory = first.deletingLastPathComponent()
        return ToolJob(name: urls.map(\.lastPathComponent).joined(separator: ", ")) { cancellation in
            let output = try ImageTransformationService().createPDF(sources: urls, options: options, outputDirectory: directory,
                                                                    isCancelled: { cancellation.isCancelled })
            return ToolJobOutput(outputs: [output])
        }
    }
}

/// Reference layout: paper size, the two fit options, then the page order as a numbered list.
struct ImagesToPDFToolSheet: View {
    @ObservedObject var model: ImagesToPDFToolModel
    let onCancel: () -> Void
    let onRun: () -> Void

    var body: some View {
        ToolSheetScaffold(tool: .imagesCreatePDF, subtitle: ToolSheetHeader.names(model.files.map(\.url)), primaryTitle: L("Create PDF"),
                          canRun: !model.files.isEmpty, onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 12) {
                ToolFormRow(L("Paper size")) {
                    Picker("", selection: $model.paperSize) {
                        Text(L("Original image size")).tag(ImagePDFPaperSize.original)
                        Text(L("A4 Portrait")).tag(ImagePDFPaperSize.a4Portrait)
                        Text(L("A4 Landscape")).tag(ImagePDFPaperSize.a4Landscape)
                        Text(L("US Letter Portrait")).tag(ImagePDFPaperSize.letterPortrait)
                        Text(L("US Letter Landscape")).tag(ImagePDFPaperSize.letterLandscape)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L("Paper size"))
                }
                Toggle(L("Fit images to the page"), isOn: $model.fitToPage)
                    .toggleStyle(.checkbox)
                    .disabled(model.paperSize == .original)
                Toggle(L("Allow enlarging smaller images"), isOn: $model.allowUpscaling)
                    .toggleStyle(.checkbox)
                    .disabled(model.paperSize == .original || !model.fitToPage)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Page order")).font(.system(size: 12, weight: .bold))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.files.enumerated()), id: \.element.id) { index, file in
                                Text(LF("%lld. %@", Int64(index + 1), file.name))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("BuiltInTool.CreatePDF.Pages")
                }
            }
        }
    }
}
