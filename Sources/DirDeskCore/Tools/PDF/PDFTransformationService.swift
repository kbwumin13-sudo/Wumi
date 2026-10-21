import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Built-in PDF tools: split, extract pages, merge, rotate pages, compress and export pages as images.
///
/// Sources are never modified. Every PDF is written to a hidden ".dirdesk-pdf-<id>.partial.pdf" in the
/// output folder, re-opened and checked, and only then published under a keep-both sibling name. Tools
/// that create several files stage all of them before publishing any. Locked PDFs are refused (unlocking
/// is never attempted); PDFs that open without a password must permit the operation.
public struct PDFTransformationService: Sendable {
    public struct Limits: Hashable, Sendable {
        /// Most pages one operation reads or writes.
        public var maximumPageCount: Int
        /// Most PDFs one merge combines.
        public var maximumSourceCount: Int
        /// Most pixels in one rendered page image (export and thumbnails); 32 million like the original's
        /// `PDFTransformationService.maximumImageExportPixelsPerPage`.
        public var maximumRenderedPixelsPerPage: Int

        public init(maximumPageCount: Int = 10_000, maximumSourceCount: Int = 500, maximumRenderedPixelsPerPage: Int = 32_000_000) {
            self.maximumPageCount = maximumPageCount
            self.maximumSourceCount = maximumSourceCount
            self.maximumRenderedPixelsPerPage = maximumRenderedPixelsPerPage
        }

        public static let `default` = Limits()
    }

    /// Base name of a merged PDF when the user gives none.
    public static let defaultMergedBaseName = "Merged"

    public var limits: Limits

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    // MARK: - Inspection

    public func metadata(of source: URL) throws -> PDFMetadata {
        let name = source.lastPathComponent
        guard ToolOutputSupport.isReadableFile(source) else { throw PDFTransformationError.sourceUnavailable(name) }
        guard let document = PDFDocument(url: source) else { throw PDFTransformationError.invalidPDF(name) }
        let attributes = document.documentAttributes ?? [:]
        func attribute<T>(_ key: PDFDocumentAttribute) -> T? { attributes[key.rawValue] as? T }
        return PDFMetadata(
            pageCount: document.pageCount,
            isEncrypted: document.isEncrypted,
            isLocked: document.isLocked,
            allowsCopying: document.allowsCopying,
            allowsPrinting: document.allowsPrinting,
            allowsDocumentAssembly: document.allowsDocumentAssembly,
            allowsDocumentChanges: document.allowsDocumentChanges,
            majorVersion: document.majorVersion,
            minorVersion: document.minorVersion,
            title: attribute(.titleAttribute),
            author: attribute(.authorAttribute),
            creator: attribute(.creatorAttribute),
            producer: attribute(.producerAttribute),
            creationDate: attribute(.creationDateAttribute),
            modificationDate: attribute(.modificationDateAttribute),
            byteCount: ToolOutputSupport.byteCount(of: source),
            firstPageSize: document.isLocked ? nil : document.page(at: 0)?.pageRef.map(Self.displaySize(of:)))
    }

    /// Page count of an unlocked, non-empty PDF.
    public func pageCount(of source: URL) throws -> Int {
        try open(source, enforcesPageLimit: false).pageCount
    }

    /// Renders the first `maximumCount` pages to fit within `size` pixels (pass a Retina-scaled size when needed).
    public func pageThumbnails(source: URL, maximumCount: Int = 120, size: CGSize) throws -> [PDFPageThumbnailPreview] {
        let document = try open(source, enforcesPageLimit: false)
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return [] }
        var previews: [PDFPageThumbnailPreview] = []
        for index in 0..<min(document.pageCount, max(0, maximumCount)) {
            guard let page = document.page(at: index)?.pageRef else { continue }
            let pageSize = Self.displaySize(of: page)
            guard pageSize.width > 0, pageSize.height > 0 else { continue }
            let scale = min(size.width / pageSize.width, size.height / pageSize.height)
            guard let width = Self.pixelDimension(pageSize.width, scale: scale), let height = Self.pixelDimension(pageSize.height, scale: scale),
                  width * height <= limits.maximumRenderedPixelsPerPage else { continue }
            if let image = autoreleasepool(invoking: { Self.render(page, width: width, height: height) }) {
                previews.append(PDFPageThumbnailPreview(pageNumber: index + 1, image: image, pageSize: pageSize))
            }
        }
        return previews
    }

    // MARK: - Merge

    /// Combines `sources` in the given order into "<outputBaseName or Merged>.pdf".
    @discardableResult
    public func merge(sources: [URL], outputDirectory: URL, outputBaseName: String? = nil, isCancelled: () -> Bool = { false }) throws -> URL {
        guard sources.count >= 2, sources.count <= limits.maximumSourceCount else {
            throw PDFTransformationError.sourceCountOutOfRange(minimum: 2, maximum: limits.maximumSourceCount, received: sources.count)
        }
        try requireDestination(outputDirectory)
        var documents: [(document: PDFDocument, name: String)] = []
        var pageCount = 0
        for source in sources {
            if isCancelled() { throw PDFTransformationError.cancelled }
            let document = try open(source, requiring: [.assembly, .copying])
            pageCount += document.pageCount
            guard pageCount <= limits.maximumPageCount else {
                throw PDFTransformationError.pageLimitExceeded(pageCount: pageCount, limit: limits.maximumPageCount)
            }
            documents.append((document, source.lastPathComponent))
        }
        try requireSpace(in: outputDirectory, needed: Self.estimatedSize(of: sources))
        let desired = outputDirectory.appendingPathComponent(
            ToolOutputSupport.fileName(base: Self.mergedOutputBaseName(outputBaseName), extension: "pdf"))
        let merged = PDFDocument()
        for (document, name) in documents {
            if isCancelled() { throw PDFTransformationError.cancelled }
            for index in 0..<document.pageCount {
                merged.insert(try Self.pageCopy(document, index, sourceName: name), at: merged.pageCount)
            }
        }
        let partial = try stage(merged, in: outputDirectory, displayName: desired.lastPathComponent, expectedPageCount: pageCount)
        return try publish([(partial, desired)])[0]
    }

    /// The user's name without a ".pdf" suffix, path separators or leading dots; "Merged" when blank.
    static func mergedOutputBaseName(_ name: String?) -> String {
        var base = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".pdf") { base = String(base.dropLast(4)).trimmingCharacters(in: .whitespaces) }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        return base.isEmpty ? defaultMergedBaseName : base
    }

    // MARK: - Split and extract

    /// The exact files `split` would create, without writing anything.
    public func planSplit(source: URL, strategy: PDFSplitStrategy, outputDirectory: URL? = nil) throws -> PDFSplitPlan {
        let document = try open(source, requiring: [.assembly, .copying])
        return try splitPlan(source: source, pageCount: document.pageCount, strategy: strategy,
                             outputDirectory: outputDirectory ?? source.deletingLastPathComponent())
    }

    /// "<base>-split-001-pages-1-10.pdf", "<base>-split-002-pages-11-20.pdf"…: the output number and its page span, for every strategy.
    @discardableResult
    public func split(source: URL, strategy: PDFSplitStrategy, outputDirectory: URL, isCancelled: () -> Bool = { false }) throws -> [URL] {
        try requireDestination(outputDirectory)
        let document = try open(source, requiring: [.assembly, .copying])
        let plan = try splitPlan(source: source, pageCount: document.pageCount, strategy: strategy, outputDirectory: outputDirectory)
        try requireSpace(in: outputDirectory, needed: Self.estimatedSize(of: [source]))
        return try produce(plan.outputs, from: document, sourceName: source.lastPathComponent, in: outputDirectory, isCancelled: isCancelled)
    }

    /// "<base>-extracted.pdf" with every range in order, or "<base>-extracted-pages-<a>-<b>.pdf" per range.
    @discardableResult
    public func extractPages(source: URL, ranges: [PDFPageRange], mode: PDFExtractionMode, outputDirectory: URL,
                             isCancelled: () -> Bool = { false }) throws -> [URL] {
        try requireDestination(outputDirectory)
        let document = try open(source, requiring: [.assembly, .copying])
        guard !ranges.isEmpty else { throw PDFTransformationError.noPagesSelected }
        try Self.validate(ranges, pageCount: document.pageCount)
        let groups: [(suffix: String, ranges: [PDFPageRange])] = switch mode {
        case .combined: [("-extracted", ranges)]
        case .oneFilePerRange: ranges.map { ("-extracted-pages-\($0.first)-\($0.last)", [$0]) }
        }
        let outputs = Self.plannedOutputs(groups, source: source, in: outputDirectory)
        try requireSpace(in: outputDirectory, needed: Self.estimatedSize(of: [source]))
        return try produce(outputs, from: document, sourceName: source.lastPathComponent, in: outputDirectory, isCancelled: isCancelled)
    }

    private func splitPlan(source: URL, pageCount: Int, strategy: PDFSplitStrategy, outputDirectory: URL) throws -> PDFSplitPlan {
        var spans: [PDFPageRange] = []
        switch strategy {
        case .pageRanges(let ranges):
            guard !ranges.isEmpty else { throw PDFTransformationError.invalidSplitParameter }
            try Self.validate(ranges, pageCount: pageCount)
            spans = ranges
        case .everyPages(let size):
            guard size > 0 else { throw PDFTransformationError.invalidSplitParameter }
            var start = 1
            while start <= pageCount {
                let end = start + min(size, pageCount - start + 1) - 1
                spans.append(PDFPageRange(first: start, last: end))
                start = end + 1
            }
        case .targetFileCount(let count):
            guard count > 0, count <= pageCount else { throw PDFTransformationError.invalidSplitParameter }
            let size = pageCount / count, extra = pageCount % count
            var start = 1
            for index in 0..<count {
                let length = size + (index < extra ? 1 : 0)
                spans.append(PDFPageRange(first: start, last: start + length - 1))
                start += length
            }
        }
        let groups = spans.enumerated().map { index, span in (suffix: Self.splitSuffix(number: index + 1, span: span), ranges: [span]) }
        return PDFSplitPlan(source: source, sourcePageCount: pageCount, outputs: Self.plannedOutputs(groups, source: source, in: outputDirectory))
    }

    /// "-split-001-pages-1-10": the reference's split output names carry the output number and the page span.
    static func splitSuffix(number: Int, span: PDFPageRange) -> String {
        String(format: "-split-%03ld", number) + "-pages-\(span.first)-\(span.last)"
    }

    /// Resolves keep-both names against existing items and against each other.
    private static func plannedOutputs(_ groups: [(suffix: String, ranges: [PDFPageRange])], source: URL, in directory: URL) -> [PDFPlannedOutput] {
        let base = source.deletingPathExtension().lastPathComponent
        var reserved = Set<String>()
        return groups.map { group in
            let desired = directory.appendingPathComponent(ToolOutputSupport.fileName(base: base, suffix: group.suffix, extension: "pdf"))
            let url = ToolOutputSupport.availableURL(for: desired, reserved: reserved)
            reserved.insert(url.path)
            return PDFPlannedOutput(url: url, ranges: group.ranges)
        }
    }

    /// Ranges must be well formed, inside the document and disjoint.
    static func validate(_ ranges: [PDFPageRange], pageCount: Int) throws {
        for range in ranges {
            guard range.first >= 1, range.last >= range.first else { throw PDFTransformationError.malformedPageRange(range.description) }
            guard range.last <= pageCount else { throw PDFTransformationError.invalidPageRange(range, pageCount: pageCount) }
        }
        let sorted = ranges.sorted { $0.first < $1.first }
        for (current, next) in zip(sorted, sorted.dropFirst()) where current.overlaps(next) {
            throw PDFTransformationError.overlappingPageRanges
        }
    }

    /// Builds one PDF per planned output, staging all of them before publishing any.
    private func produce(_ outputs: [PDFPlannedOutput], from document: PDFDocument, sourceName: String, in directory: URL,
                         isCancelled: () -> Bool) throws -> [URL] {
        var staged: [(partial: URL, desired: URL)] = []
        do {
            for output in outputs {
                if isCancelled() { throw PDFTransformationError.cancelled }
                let partial = try autoreleasepool { () throws -> URL in
                    let part = PDFDocument()
                    for range in output.ranges {
                        for number in range.first...range.last {
                            part.insert(try Self.pageCopy(document, number - 1, sourceName: sourceName), at: part.pageCount)
                        }
                    }
                    return try stage(part, in: directory, displayName: output.url.lastPathComponent, expectedPageCount: output.pageCount)
                }
                staged.append((partial, output.url))
            }
        } catch {
            staged.forEach { ToolOutputSupport.removeIfPresent($0.partial) }
            throw error
        }
        return try publish(staged)
    }

    // MARK: - Rotate and compress

    /// Adds `rotation` to the selected one-based pages and writes "<base>-rotated.pdf".
    @discardableResult
    public func rotate(source: URL, selection: PDFPageSelection, rotation: PDFRotation, outputDirectory: URL) throws -> URL {
        try requireDestination(outputDirectory)
        let document = try open(source, requiring: [.assembly])
        let pageCount = document.pageCount
        let selected: [Int]
        switch selection {
        case .all:
            selected = Array(1...pageCount)
        case .pages(let pages):
            guard !pages.isEmpty else { throw PDFTransformationError.invalidRotationSelection }
            let outside = pages.filter { $0 < 1 || $0 > pageCount }
            if let low = outside.min(), let high = outside.max() {
                throw PDFTransformationError.invalidPageRange(PDFPageRange(first: low, last: high), pageCount: pageCount)
            }
            selected = pages.sorted()
        }
        var expected = (0..<pageCount).map { Self.normalizedRotation(document.page(at: $0)?.rotation ?? 0) }
        for number in selected {
            guard let page = document.page(at: number - 1) else { throw PDFTransformationError.invalidPDF(source.lastPathComponent) }
            let rotated = Self.normalizedRotation(page.rotation + rotation.degrees)
            page.rotation = rotated
            expected[number - 1] = rotated
        }
        try requireSpace(in: outputDirectory, needed: Self.estimatedSize(of: [source]))
        let desired = outputDirectory.appendingPathComponent(
            ToolOutputSupport.fileName(base: source.deletingPathExtension().lastPathComponent, suffix: "-rotated", extension: "pdf"))
        let partial = try stage(document, in: outputDirectory, displayName: desired.lastPathComponent, expectedPageCount: pageCount) { reopened in
            (0..<pageCount).allSatisfy { Self.normalizedRotation(reopened.page(at: $0)?.rotation ?? -1) == expected[$0] }
        }
        return try publish([(partial, desired)])[0]
    }

    /// Re-saves with PDFKit's screen image optimization (plus JPEG images for `.screenOptimizedJPEG`)
    /// into "<base>-compressed.pdf". The output can be larger than an already optimized source.
    public func compress(source: URL, preset: PDFCompressionPreset, outputDirectory: URL) throws -> PDFCompressionResult {
        try requireDestination(outputDirectory)
        let document = try open(source, requiring: [.copying])
        try requireSpace(in: outputDirectory, needed: Self.estimatedSize(of: [source]))
        var options: [PDFDocumentWriteOption: Any] = [.optimizeImagesForScreenOption: true]
        if preset == .screenOptimizedJPEG { options[.saveImagesAsJPEGOption] = true }
        let desired = outputDirectory.appendingPathComponent(
            ToolOutputSupport.fileName(base: source.deletingPathExtension().lastPathComponent, suffix: "-compressed", extension: "pdf"))
        let partial = try stage(document, in: outputDirectory, displayName: desired.lastPathComponent,
                                expectedPageCount: document.pageCount, options: options)
        let outputByteCount = ToolOutputSupport.byteCount(of: partial)
        let output = try publish([(partial, desired)])[0]
        return PDFCompressionResult(source: source, output: output, originalByteCount: ToolOutputSupport.byteCount(of: source),
                                    outputByteCount: outputByteCount)
    }

    static func normalizedRotation(_ degrees: Int) -> Int {
        ((degrees % 360) + 360) % 360
    }

    // MARK: - Export pages as images

    /// Renders every page in order into a new sibling folder "<base> Images" holding "page-1.png"…
    /// (zero-padded to the digits of the page count). The folder appears only after every image
    /// has been written and re-read.
    public func exportImages(source: URL, options: PDFImageExportOptions, outputDirectory: URL,
                             isCancelled: () -> Bool = { false }) throws -> PDFImageExportResult {
        guard PDFImageExportOptions.supportedDPI.contains(options.dpi), (0...1).contains(options.jpegQuality) else {
            throw PDFTransformationError.invalidImageExportOptions
        }
        try requireDestination(outputDirectory)
        let name = source.lastPathComponent
        let document = try open(source, requiring: [.copying])
        let scale = CGFloat(options.dpi) / 72
        // Size every page first so an oversized page fails before anything is written.
        var pages: [(page: CGPDFPage, width: Int, height: Int)] = []
        var totalPixels = 0.0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.pageRef else { throw PDFTransformationError.invalidPDF(name) }
            let size = Self.displaySize(of: page)
            let width = Self.pixelDimension(size.width, scale: scale), height = Self.pixelDimension(size.height, scale: scale)
            let product = (width ?? .max).multipliedReportingOverflow(by: height ?? .max)
            guard let width, let height, !product.overflow, product.partialValue <= limits.maximumRenderedPixelsPerPage else {
                throw PDFTransformationError.imagePixelLimitExceeded(page: index + 1, pixels: product.overflow ? .max : product.partialValue,
                                                                     limit: limits.maximumRenderedPixelsPerPage)
            }
            pages.append((page, width, height))
            totalPixels += Double(product.partialValue)
        }
        try requireSpace(in: outputDirectory, needed: Int64(totalPixels * (options.format == .png ? 1.5 : 0.4)) + (1 << 20))

        let staging = outputDirectory.appendingPathComponent(".dirdesk-pdf-images-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw PDFTransformationError.destinationUnavailable(outputDirectory.path)
        }
        var published = false
        defer { if !published { ToolOutputSupport.removeIfPresent(staging) } }
        let digits = String(pages.count).count
        var names: [String] = []
        for (index, item) in pages.enumerated() {
            if isCancelled() { throw PDFTransformationError.cancelled }
            let fileName = "page-" + String(format: "%0\(digits)ld", index + 1) + "." + options.format.fileExtension
            try autoreleasepool { () throws -> Void in
                guard let image = Self.render(item.page, width: item.width, height: item.height),
                      Self.writeImage(image, to: staging.appendingPathComponent(fileName), options: options) else {
                    throw PDFTransformationError.outputWriteFailed(fileName)
                }
                guard let written = Self.pixelSize(ofImageAt: staging.appendingPathComponent(fileName)),
                      written.width == item.width, written.height == item.height else {
                    throw PDFTransformationError.outputValidationFailed(fileName)
                }
            }
            names.append(fileName)
        }
        let base = source.deletingPathExtension().lastPathComponent
        let desired = outputDirectory.appendingPathComponent(ToolOutputSupport.fileName(base: base, suffix: " Images", extension: ""), isDirectory: true)
        let folder: URL
        do {
            folder = try ToolOutputSupport.publish(staging, as: desired)
        } catch {
            throw PDFTransformationError.outputPublicationFailed(desired.lastPathComponent)
        }
        published = true
        return PDFImageExportResult(source: source, folder: folder, images: names.map { folder.appendingPathComponent($0) })
    }

    // MARK: - Rendering

    /// Crop-box size in points after the page's /Rotate.
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox).standardized
        let rotation = normalizedRotation(Int(page.rotationAngle))
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Pixel count along one edge; nil for sizes no bitmap could hold.
    static func pixelDimension(_ points: CGFloat, scale: CGFloat) -> Int? {
        let pixels = (points * scale).rounded()
        guard pixels.isFinite, pixels < 1_000_000_000 else { return nil }
        return max(1, Int(pixels))
    }

    /// Draws the crop box (with its rotation) over white into an sRGB bitmap of exactly `width` × `height`.
    static func render(_ page: CGPDFPage, width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return context.makeImage() }
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func writeImage(_ image: CGImage, to url: URL, options: PDFImageExportOptions) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, options.format.typeIdentifier as CFString, 1, nil) else { return false }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: options.dpi, kCGImagePropertyDPIHeight: options.dpi]
        if options.format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = options.jpegQuality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func pixelSize(ofImageAt url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return (width, height)
    }

    // MARK: - Shared guards and staging

    private enum Permission {
        case assembly, copying
    }

    /// Opens an unlocked, non-empty PDF whose permissions allow `permissions`.
    private func open(_ url: URL, requiring permissions: [Permission] = [], enforcesPageLimit: Bool = true) throws -> PDFDocument {
        let name = url.lastPathComponent
        guard ToolOutputSupport.isReadableFile(url) else { throw PDFTransformationError.sourceUnavailable(name) }
        guard let document = PDFDocument(url: url) else { throw PDFTransformationError.invalidPDF(name) }
        guard !document.isLocked else { throw PDFTransformationError.lockedPDF(name) }
        guard document.pageCount > 0 else { throw PDFTransformationError.emptyPDF(name) }
        for permission in permissions {
            let allowed = switch permission {
            case .assembly: document.allowsDocumentAssembly
            case .copying: document.allowsCopying
            }
            guard allowed else { throw PDFTransformationError.protectedPDF(name) }
        }
        if enforcesPageLimit && document.pageCount > limits.maximumPageCount {
            throw PDFTransformationError.pageLimitExceeded(pageCount: document.pageCount, limit: limits.maximumPageCount)
        }
        return document
    }

    private func requireDestination(_ directory: URL) throws {
        guard ToolOutputSupport.isWritableDirectory(directory) else { throw PDFTransformationError.destinationUnavailable(directory.path) }
    }

    private func requireSpace(in directory: URL, needed: Int64) throws {
        guard needed > 0, let available = ToolOutputSupport.availableCapacity(of: directory), available < needed else { return }
        throw PDFTransformationError.insufficientSpace(available: available, needed: needed)
    }

    /// Outputs assembled from the pages of `sources` take about as much space as the sources.
    private static func estimatedSize(of sources: [URL]) -> Int64 {
        sources.reduce(Int64(1 << 20)) { $0 + ToolOutputSupport.byteCount(of: $1) }
    }

    private static func pageCopy(_ document: PDFDocument, _ index: Int, sourceName: String) throws -> PDFPage {
        guard let page = document.page(at: index) else { throw PDFTransformationError.invalidPDF(sourceName) }
        return (page.copy() as? PDFPage) ?? page
    }

    /// Writes `document` to a hidden partial file in `directory`, then re-opens and checks it.
    private func stage(_ document: PDFDocument, in directory: URL, displayName: String, expectedPageCount: Int,
                       options: [PDFDocumentWriteOption: Any]? = nil, check: ((PDFDocument) -> Bool)? = nil) throws -> URL {
        let partial = directory.appendingPathComponent(".dirdesk-pdf-\(UUID().uuidString).partial.pdf")
        let written = options.map { document.write(to: partial, withOptions: $0) } ?? document.write(to: partial)
        guard written, ToolOutputSupport.isReadableFile(partial) else {
            ToolOutputSupport.removeIfPresent(partial)
            throw PDFTransformationError.outputWriteFailed(displayName)
        }
        guard let reopened = PDFDocument(url: partial), !reopened.isLocked, reopened.pageCount == expectedPageCount,
              check?(reopened) ?? true else {
            ToolOutputSupport.removeIfPresent(partial)
            throw PDFTransformationError.outputValidationFailed(displayName)
        }
        return partial
    }

    /// Publishes staged files under their planned names. If one cannot be published, everything this
    /// call created is removed again.
    private func publish(_ staged: [(partial: URL, desired: URL)]) throws -> [URL] {
        var published: [URL] = []
        for (index, item) in staged.enumerated() {
            do {
                published.append(try ToolOutputSupport.publish(item.partial, as: item.desired))
            } catch {
                published.forEach(ToolOutputSupport.removeIfPresent)
                staged[index...].forEach { ToolOutputSupport.removeIfPresent($0.partial) }
                throw PDFTransformationError.outputPublicationFailed(item.desired.lastPathComponent)
            }
        }
        return published
    }
}
