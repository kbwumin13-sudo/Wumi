import AppKit
import DirDeskCore
import SwiftUI

/// Page count of a PDF, read off the main thread.
@MainActor
class PDFSourceModel: ObservableObject {
    let source: URL
    @Published private(set) var pageCount: Int?
    @Published private(set) var loadFailure: String?
    private var loadStarted = false

    init(source: URL) {
        self.source = source
    }

    func loadPageCount() async {
        guard !loadStarted else { return }
        loadStarted = true
        let source = self.source
        switch await ToolWork.run({ try PDFTransformationService().pageCount(of: source) }) {
        case .success(let count):
            pageCount = count
            didLoad(pageCount: count)
        case .failure(let message):
            loadFailure = message
        }
    }

    func didLoad(pageCount: Int) {}
}

// MARK: - Split PDF

@MainActor
final class SplitPDFToolModel: PDFSourceModel {
    enum Method: String, CaseIterable, Identifiable {
        case everyPages, ranges, fileCount
        var id: String { rawValue }

        var title: String {
            switch self {
            case .everyPages: L("Every N pages")
            case .ranges: L("Page ranges")
            case .fileCount: L("Target file count")
            }
        }
    }

    /// Reference default: ten pages per file.
    static let defaultPagesPerFile = 10
    static let maximumPagesPerFile = 10_000

    @Published var method: Method = .everyPages { didSet { if method != oldValue { schedulePlan() } } }
    @Published var rangesText = "" { didSet { if rangesText != oldValue { schedulePlan() } } }
    @Published var pagesPerFile = SplitPDFToolModel.defaultPagesPerFile { didSet { if pagesPerFile != oldValue { schedulePlan() } } }
    @Published var fileCount = 2 { didSet { if fileCount != oldValue { schedulePlan() } } }
    @Published private(set) var plan: PDFSplitPlan?
    @Published private(set) var planProblem: String?
    @Published private(set) var isPlanning = false
    private var planTask: Task<Void, Never>?

    override func didLoad(pageCount: Int) {
        fileCount = min(2, pageCount)
        schedulePlan(immediately: true)
    }

    private func strategy() throws -> PDFSplitStrategy {
        switch method {
        case .ranges:
            let ranges = try PDFPageRange.parse(rangesText)
            guard !ranges.isEmpty else { throw SplitInputError.emptyRanges }
            return .pageRanges(ranges)
        case .everyPages:
            return .everyPages(pagesPerFile)
        case .fileCount:
            return .targetFileCount(fileCount)
        }
    }

    private enum SplitInputError: Error {
        case emptyRanges
    }

    func schedulePlan(immediately: Bool = false) {
        guard pageCount != nil else { return }
        planTask?.cancel()
        let strategy: PDFSplitStrategy
        do {
            strategy = try self.strategy()
        } catch SplitInputError.emptyRanges {
            plan = nil
            planProblem = L("Enter page ranges, such as 1-3, 5, 8-10.")
            isPlanning = false
            return
        } catch {
            plan = nil
            planProblem = BuiltInToolErrorText.message(for: error)
            isPlanning = false
            return
        }
        isPlanning = true
        let source = self.source
        planTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            if Task.isCancelled { return }
            let outcome = await ToolWork.run { try PDFTransformationService().planSplit(source: source, strategy: strategy) }
            if Task.isCancelled { return }
            guard let self else { return }
            self.isPlanning = false
            switch outcome {
            case .success(let plan):
                self.plan = plan
                self.planProblem = nil
            case .failure(let message):
                self.plan = nil
                self.planProblem = message
            }
        }
    }

    func cancelPlanning() {
        planTask?.cancel()
    }

    func job() -> ToolJob? {
        guard plan != nil, let strategy = try? strategy() else { return nil }
        let source = self.source
        return ToolJob(name: source.lastPathComponent) { cancellation in
            let outputs = try PDFTransformationService().split(source: source, strategy: strategy, outputDirectory: source.deletingLastPathComponent(),
                                                               isCancelled: { cancellation.isCancelled })
            return ToolJobOutput(outputs: outputs)
        }
    }
}

/// Reference layout: the method as a segmented control, its value, then "N pages → M files" and the exact
/// output list ("Pages 1–10   sample-split-001-pages-1-10.pdf").
struct SplitPDFToolSheet: View {
    @ObservedObject var model: SplitPDFToolModel
    let onCancel: () -> Void
    let onRun: () -> Void

    private var problem: String? { model.loadFailure ?? model.planProblem }

    var body: some View {
        ToolSheetScaffold(tool: .pdfSplit, subtitle: model.source.lastPathComponent, problem: problem,
                          canRun: model.plan != nil && !model.isPlanning && problem == nil, onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 12) {
                ToolFormRow(L("Split method")) {
                    Picker("", selection: $model.method) {
                        ForEach(SplitPDFToolModel.Method.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel(L("Split method"))
                }
                methodControls
                    .disabled(model.pageCount == nil)
                planPreview
            }
        }
        .task { await model.loadPageCount() }
        .onDisappear { model.cancelPlanning() }
    }

    @ViewBuilder private var methodControls: some View {
        switch model.method {
        case .everyPages:
            Stepper(value: $model.pagesPerFile, in: 1...SplitPDFToolModel.maximumPagesPerFile) {
                Text(LF("Pages per file: %lld", Int64(model.pagesPerFile)))
            }
            .fixedSize()
        case .ranges:
            VStack(alignment: .leading, spacing: 4) {
                TextField(L("For example: 1-3, 5, 8-10"), text: $model.rangesText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("BuiltInTool.Split.Ranges")
                ToolCaption(L("Page numbers start at 1 and ranges are separated by commas. Each range becomes its own PDF."))
            }
        case .fileCount:
            Stepper(value: $model.fileCount, in: 1...max(1, model.pageCount ?? 1)) {
                Text(LF("Target files: %lld", Int64(model.fileCount)))
            }
            .fixedSize()
        }
    }

    private var planPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let plan = model.plan {
                    Text(ToolText.pageCount(plan.sourcePageCount) + " → " + ToolText.fileCount(plan.outputs.count))
                        .font(.system(size: 12, weight: .semibold))
                }
                if model.isPlanning {
                    ProgressView().controlSize(.mini)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array((model.plan?.outputs ?? []).enumerated()), id: \.offset) { _, output in
                        HStack(spacing: 0) {
                            Text(ToolText.pageSpans(output.ranges))
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 113, alignment: .leading)
                            Text(output.url.lastPathComponent)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("BuiltInTool.Split.Plan")
        }
    }
}

// MARK: - Extract PDF pages

struct ToolPageThumbnail: Identifiable, @unchecked Sendable {
    let page: Int
    let image: CGImage
    var id: Int { page }
}

@MainActor
final class ExtractPagesToolModel: PDFSourceModel {
    nonisolated static let thumbnailLimit = 120

    @Published private(set) var thumbnails: [ToolPageThumbnail] = []
    @Published private(set) var isRendering = false
    @Published private(set) var selection = Set<Int>()
    @Published var rangesText = "" {
        didSet { if !isSyncingText && rangesText != oldValue { rangesTextChanged() } }
    }
    @Published var onePerRange = false
    @Published private(set) var rangesProblem: String?
    private var anchor: Int?
    private var isSyncingText = false

    override func didLoad(pageCount: Int) {
        if rangesText.isEmpty {
            // Reference default: the first page is selected and the field reads "1".
            selection = [1]
            anchor = 1
            syncTextFromSelection()
        } else {
            rangesTextChanged()
        }
        Task { await renderThumbnails() }
    }

    private func renderThumbnails() async {
        isRendering = true
        let source = self.source
        let outcome = await ToolWork.run { () -> [ToolPageThumbnail] in
            try PDFTransformationService().pageThumbnails(source: source, maximumCount: ExtractPagesToolModel.thumbnailLimit,
                                                          size: CGSize(width: 128, height: 168))
                .map { ToolPageThumbnail(page: $0.pageNumber, image: $0.image) }
        }
        isRendering = false
        if case .success(let thumbnails) = outcome { self.thumbnails = thumbnails }
    }

    /// The ranges to extract, in the order typed; nil while the field is invalid or empty.
    var ranges: [PDFPageRange]? {
        guard rangesProblem == nil, let ranges = try? PDFPageRange.parse(rangesText), !ranges.isEmpty else { return nil }
        return ranges
    }

    func toggle(_ page: Int, extendingFromAnchor: Bool) {
        if extendingFromAnchor, let anchor {
            for number in min(anchor, page)...max(anchor, page) { selection.insert(number) }
        } else if selection.contains(page) {
            selection.remove(page)
        } else {
            selection.insert(page)
        }
        anchor = page
        syncTextFromSelection()
    }

    private func syncTextFromSelection() {
        isSyncingText = true
        rangesText = PDFPageRange.format(PDFPageRange.ranges(covering: selection))
        isSyncingText = false
        rangesProblem = nil
    }

    private func rangesTextChanged() {
        do {
            let ranges = try PDFPageRange.parse(rangesText)
            guard let pageCount else {
                rangesProblem = nil
                return
            }
            if let outside = ranges.first(where: { $0.last > pageCount }) {
                rangesProblem = BuiltInToolErrorText.message(for: PDFTransformationError.invalidPageRange(outside, pageCount: pageCount))
                return
            }
            let sorted = ranges.sorted { $0.first < $1.first }
            if zip(sorted, sorted.dropFirst()).contains(where: { $0.overlaps($1) }) {
                rangesProblem = L("Page ranges must not overlap.")
                return
            }
            rangesProblem = nil
            selection = Set(ranges.flatMap { Array($0.first...$0.last) })
        } catch {
            rangesProblem = BuiltInToolErrorText.message(for: error)
        }
    }

    func job() -> ToolJob? {
        guard let ranges else { return nil }
        let source = self.source, mode: PDFExtractionMode = onePerRange ? .oneFilePerRange : .combined
        return ToolJob(name: source.lastPathComponent) { cancellation in
            let outputs = try PDFTransformationService().extractPages(source: source, ranges: ranges, mode: mode,
                                                                      outputDirectory: source.deletingLastPathComponent(),
                                                                      isCancelled: { cancellation.isCancelled })
            return ToolJobOutput(outputs: outputs)
        }
    }
}

/// Reference layout: page cards to click, the ranges field (focused, "1" by default), one PDF per range,
/// and a note about what extracted pages may lose.
struct ExtractPagesToolSheet: View {
    @ObservedObject var model: ExtractPagesToolModel
    let onCancel: () -> Void
    let onRun: () -> Void
    @FocusState private var rangesFocused: Bool

    private static let cellWidth: CGFloat = 74
    private static let cellHeight: CGFloat = 112
    private static let cellSpacing: CGFloat = 10

    private var problem: String? { model.loadFailure ?? model.rangesProblem }

    var body: some View {
        ToolSheetScaffold(tool: .pdfExtractPages, subtitle: model.source.lastPathComponent, problem: problem,
                          canRun: model.ranges != nil && problem == nil, onCancel: onCancel, onRun: onRun) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(L("Select pages")).font(.system(size: 12, weight: .bold))
                    if model.isRendering { ProgressView().controlSize(.mini) }
                }
                thumbnailGrid
                if let count = model.pageCount, count > ExtractPagesToolModel.thumbnailLimit {
                    ToolCaption(LF("Only the first %lld pages are shown. Type ranges to pick later pages.", Int64(ExtractPagesToolModel.thumbnailLimit)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L("For example: 1-3, 5, 8-10"), text: $model.rangesText)
                        .textFieldStyle(.roundedBorder)
                        .focused($rangesFocused)
                        .accessibilityLabel(L("Page ranges"))
                        .accessibilityIdentifier("BuiltInTool.Extract.Ranges")
                    ToolCaption(L("Page numbers start at 1 and ranges are separated by commas, e.g. 1-3, 5, 8-10."))
                }
                Toggle(L("Create one PDF per range"), isOn: $model.onePerRange)
                    .toggleStyle(.checkbox)
                Label(L("Extracted pages can lose signatures, form fields, links, tags and bookmarks. The original PDF stays unchanged."),
                      systemImage: "doc.badge.ellipsis")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .task { await model.loadPageCount() }
        .onAppear { DispatchQueue.main.async { rangesFocused = true } }
    }

    /// One row of cards for short documents, two rows (scrolling) for longer ones, plus the reference's
    /// bottom margin before the ranges field.
    private var gridHeight: CGFloat {
        let columns = 8
        let rows = max(1, min(2, ((model.pageCount ?? 1) + columns - 1) / columns))
        return CGFloat(rows) * Self.cellHeight + CGFloat(rows - 1) * Self.cellSpacing + 7
    }

    private var thumbnailGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cellWidth, maximum: Self.cellWidth), spacing: Self.cellSpacing, alignment: .leading)],
                      alignment: .leading, spacing: Self.cellSpacing) {
                ForEach(model.thumbnails) { thumbnail in
                    PageThumbnailCell(thumbnail: thumbnail, isSelected: model.selection.contains(thumbnail.page)) {
                        model.toggle(thumbnail.page, extendingFromAnchor: NSEvent.modifierFlags.contains(.shift))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: gridHeight)
        .overlay {
            if model.thumbnails.isEmpty, !model.isRendering, model.loadFailure == nil, model.pageCount != nil {
                Text(L("Page previews are unavailable. Type the pages to extract below."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("BuiltInTool.Extract.Pages")
    }
}

/// A page card: the rendered page over "Page N", tinted and outlined in the accent color when selected.
private struct PageThumbnailCell: View {
    let thumbnail: ToolPageThumbnail
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(decorative: thumbnail.image, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 84)
                .background(Color.white)
            Text(LF("Page %lld", Int64(thumbnail.page)))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.top, 5)
        .padding(.bottom, 6)
        .frame(width: 74, height: 112, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.11), lineWidth: isSelected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LF("Page %lld", Int64(thumbnail.page)))
        .accessibilityValue(isSelected ? L("Selected") : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("BuiltInTool.PDF.Page.\(thumbnail.page)")
        .accessibilityAction(.default, action)
    }
}
