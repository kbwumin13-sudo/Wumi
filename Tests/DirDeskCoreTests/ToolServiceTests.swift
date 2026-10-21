import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import DirDeskCore

final class ToolServiceTests: XCTestCase {
    private var root: URL!
    private let pdfService = PDFTransformationService()
    private let imageService = ImageTransformationService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dirdesk-tool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Page ranges

    func testPageRangeParsing() throws {
        XCTAssertEqual(try PDFPageRange.parse("1-3, 5, 8-10"),
                       [PDFPageRange(first: 1, last: 3), PDFPageRange(page: 5), PDFPageRange(first: 8, last: 10)])
        XCTAssertEqual(try PDFPageRange.parse("１－３，５；7 ~ 8"),
                       [PDFPageRange(first: 1, last: 3), PDFPageRange(page: 5), PDFPageRange(first: 7, last: 8)])
        XCTAssertEqual(try PDFPageRange.parse("  "), [])
        for bad in ["3-1", "0", "a-b", "2-", "-2", "1-2-3"] {
            XCTAssertThrowsError(try PDFPageRange.parse(bad), bad) { error in
                XCTAssertEqual(error as? PDFTransformationError, .malformedPageRange(bad))
            }
        }
        XCTAssertEqual(PDFPageRange.ranges(covering: [1, 2, 3, 5, 7, 8]),
                       [PDFPageRange(first: 1, last: 3), PDFPageRange(page: 5), PDFPageRange(first: 7, last: 8)])
        XCTAssertEqual(PDFPageRange.format(PDFPageRange.ranges(covering: [1, 2, 3, 5])), "1-3, 5")
        XCTAssertEqual(try PDFPageSelection.parse(" "), .all)
        XCTAssertEqual(try PDFPageSelection.parse("1, 3-4"), .pages([1, 3, 4]))
    }

    // MARK: - PDF tools

    func testMergeKeepsSelectionOrderAndKeepsBothNames() throws {
        let a = try makePDF("a.pdf", pageCount: 2)
        let b = try makePDF("b.pdf", pageCount: 3) { CGSize(width: 300 + 10 * $0, height: 200) }
        let merged = try pdfService.merge(sources: [b, a], outputDirectory: root, outputBaseName: nil)
        XCTAssertEqual(merged.lastPathComponent, "Merged.pdf")
        XCTAssertEqual(try pageWidths(merged), [310, 320, 330, 110, 120])

        let second = try pdfService.merge(sources: [a, b], outputDirectory: root, outputBaseName: "  ")
        XCTAssertEqual(second.lastPathComponent, "Merged 2.pdf")
        XCTAssertEqual(try pageWidths(second), [110, 120, 310, 320, 330])

        let named = try pdfService.merge(sources: [a, a], outputDirectory: root, outputBaseName: "Quarterly Report.pdf")
        XCTAssertEqual(named.lastPathComponent, "Quarterly Report.pdf")
        XCTAssertEqual(try pageWidths(named), [110, 120, 110, 120])
        XCTAssertEqual(stagingLeftovers(in: root), [])
    }

    func testMergeRequiresTwoPDFs() throws {
        let a = try makePDF("a.pdf", pageCount: 1)
        XCTAssertThrowsError(try pdfService.merge(sources: [a], outputDirectory: root, outputBaseName: nil)) { error in
            XCTAssertEqual(error as? PDFTransformationError, .sourceCountOutOfRange(minimum: 2, maximum: 500, received: 1))
            XCTAssertEqual((error as? PDFTransformationError)?.message, "This operation requires at least 2 PDFs; received 1.")
        }
    }

    func testSplitStrategiesAndNames() throws {
        let source = try makePDF("doc.pdf", pageCount: 5)
        let every = try folder("every")
        let chunks = try pdfService.split(source: source, strategy: .everyPages(2), outputDirectory: every)
        XCTAssertEqual(chunks.map(\.lastPathComponent), ["doc-split-001-pages-1-2.pdf", "doc-split-002-pages-3-4.pdf", "doc-split-003-pages-5-5.pdf"])
        XCTAssertEqual(try chunks.map { try pageWidths($0) }, [[110, 120], [130, 140], [150]])

        let again = try pdfService.split(source: source, strategy: .everyPages(2), outputDirectory: every)
        XCTAssertEqual(again.map(\.lastPathComponent),
                       ["doc-split-001-pages-1-2 2.pdf", "doc-split-002-pages-3-4 2.pdf", "doc-split-003-pages-5-5 2.pdf"])

        let target = try pdfService.split(source: source, strategy: .targetFileCount(2), outputDirectory: try folder("target"))
        XCTAssertEqual(target.map(\.lastPathComponent), ["doc-split-001-pages-1-3.pdf", "doc-split-002-pages-4-5.pdf"])
        XCTAssertEqual(try target.map { try pageWidths($0) }, [[110, 120, 130], [140, 150]])

        let ranges = try pdfService.split(source: source, strategy: .pageRanges(try PDFPageRange.parse("4-5, 1-2")),
                                          outputDirectory: try folder("ranges"))
        XCTAssertEqual(ranges.map(\.lastPathComponent), ["doc-split-001-pages-4-5.pdf", "doc-split-002-pages-1-2.pdf"])
        XCTAssertEqual(try ranges.map { try pageWidths($0) }, [[140, 150], [110, 120]])
        XCTAssertEqual(stagingLeftovers(in: every), [])
    }

    func testSplitRejectsOverlapsOutOfRangeAndBadParameters() throws {
        let source = try makePDF("doc.pdf", pageCount: 5)
        let output = try folder("out")
        assertPDFError(.overlappingPageRanges) {
            try pdfService.split(source: source, strategy: .pageRanges(try PDFPageRange.parse("1-3, 3-4")), outputDirectory: output)
        }
        XCTAssertThrowsError(try pdfService.split(source: source, strategy: .pageRanges([PDFPageRange(first: 3, last: 9)]), outputDirectory: output)) {
            XCTAssertEqual(($0 as? PDFTransformationError)?.message, "Pages 3-9 are outside this 5-page PDF.")
        }
        XCTAssertEqual(PDFTransformationError.overlappingPageRanges.message, "Page ranges must not overlap.")
        for strategy in [PDFSplitStrategy.everyPages(0), .targetFileCount(0), .targetFileCount(6), .pageRanges([])] {
            assertPDFError(.invalidSplitParameter) { try pdfService.split(source: source, strategy: strategy, outputDirectory: output) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testPlanSplitResolvesConflictsWithoutWriting() throws {
        let source = try makePDF("doc.pdf", pageCount: 5)
        try Data("taken".utf8).write(to: root.appendingPathComponent("doc-split-001-pages-1-2.pdf"))
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let plan = try pdfService.planSplit(source: source, strategy: .everyPages(2))
        XCTAssertEqual(plan.sourcePageCount, 5)
        XCTAssertEqual(plan.outputs.map(\.url.lastPathComponent),
                       ["doc-split-001-pages-1-2 2.pdf", "doc-split-002-pages-3-4.pdf", "doc-split-003-pages-5-5.pdf"])
        XCTAssertEqual(plan.outputs.map(\.pageCount), [2, 2, 1])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)

        let created = try pdfService.split(source: source, strategy: .everyPages(2), outputDirectory: root)
        XCTAssertEqual(created, plan.outputs.map(\.url))
    }

    func testSplitNameOfSinglePagePDFMatchesReference() throws {
        // Reference capture: a one-page "sample.pdf" split every 10 pages plans "sample-split-001-pages-1-1.pdf".
        let sample = try makePDF("sample.pdf", pageCount: 1)
        let plan = try pdfService.planSplit(source: sample, strategy: .everyPages(10))
        XCTAssertEqual(plan.outputs.map(\.url.lastPathComponent), ["sample-split-001-pages-1-1.pdf"])
        XCTAssertEqual(plan.outputs.map(\.ranges), [[PDFPageRange(first: 1, last: 1)]])
    }

    func testExtractPagesCombinedAndPerRange() throws {
        let source = try makePDF("doc.pdf", pageCount: 5)
        let ranges = try PDFPageRange.parse("4-5, 2")
        let combined = try pdfService.extractPages(source: source, ranges: ranges, mode: .combined, outputDirectory: root)
        XCTAssertEqual(combined.map(\.lastPathComponent), ["doc-extracted.pdf"])
        XCTAssertEqual(try pageWidths(combined[0]), [140, 150, 120])

        let separate = try pdfService.extractPages(source: source, ranges: ranges, mode: .oneFilePerRange, outputDirectory: root)
        XCTAssertEqual(separate.map(\.lastPathComponent), ["doc-extracted-pages-4-5.pdf", "doc-extracted-pages-2-2.pdf"])
        XCTAssertEqual(try separate.map { try pageWidths($0) }, [[140, 150], [120]])

        assertPDFError(.noPagesSelected) { try pdfService.extractPages(source: source, ranges: [], mode: .combined, outputDirectory: root) }
        assertPDFError(.overlappingPageRanges) {
            try pdfService.extractPages(source: source, ranges: try PDFPageRange.parse("1-2, 2"), mode: .combined, outputDirectory: root)
        }
    }

    func testRotateSelectedPages() throws {
        let source = try makePDF("doc.pdf", pageCount: 5)
        let rotated = try pdfService.rotate(source: source, selection: .pages([1, 3]), rotation: .clockwise90, outputDirectory: root)
        XCTAssertEqual(rotated.lastPathComponent, "doc-rotated.pdf")
        XCTAssertEqual(try rotations(rotated), [90, 0, 90, 0, 0])
        XCTAssertEqual(try rotations(source), [0, 0, 0, 0, 0])

        let back = try pdfService.rotate(source: rotated, selection: .all, rotation: .counterclockwise90, outputDirectory: root)
        XCTAssertEqual(back.lastPathComponent, "doc-rotated-rotated.pdf")
        XCTAssertEqual(try rotations(back), [0, 270, 0, 270, 270])

        let half = try pdfService.rotate(source: source, selection: try PDFPageSelection.parse("2"), rotation: .halfTurn, outputDirectory: root)
        XCTAssertEqual(half.lastPathComponent, "doc-rotated 2.pdf")
        XCTAssertEqual(try rotations(half), [0, 180, 0, 0, 0])

        assertPDFError(.invalidRotationSelection) {
            try pdfService.rotate(source: source, selection: .pages([]), rotation: .clockwise90, outputDirectory: root)
        }
        assertPDFError(.invalidPageRange(PDFPageRange(page: 9), pageCount: 5)) {
            try pdfService.rotate(source: source, selection: .pages([2, 9]), rotation: .clockwise90, outputDirectory: root)
        }
    }

    func testCompressReportsByteSizes() throws {
        let source = try makePDF("scan.pdf", pageCount: 2, image: noiseImage(width: 600, height: 600))
        let result = try pdfService.compress(source: source, preset: .screenOptimized, outputDirectory: root)
        XCTAssertEqual(result.output.lastPathComponent, "scan-compressed.pdf")
        XCTAssertEqual(result.originalByteCount, try byteCount(source))
        XCTAssertEqual(result.outputByteCount, try byteCount(result.output))
        XCTAssertGreaterThan(result.outputByteCount, 0)
        XCTAssertEqual(PDFDocument(url: result.output)?.pageCount, 2)

        let jpeg = try pdfService.compress(source: source, preset: .screenOptimizedJPEG, outputDirectory: root)
        XCTAssertEqual(jpeg.output.lastPathComponent, "scan-compressed 2.pdf")
        XCTAssertEqual(PDFDocument(url: jpeg.output)?.pageCount, 2)
        XCTAssertEqual(stagingLeftovers(in: root), [])
    }

    func testExportImagesAt150DPI() throws {
        let source = try makePDF("doc.pdf", pageCount: 5) { _ in CGSize(width: 200, height: 100) }
        let result = try pdfService.exportImages(source: source, options: PDFImageExportOptions(format: .png, dpi: 150), outputDirectory: root)
        XCTAssertEqual(result.folder.lastPathComponent, "doc Images")
        XCTAssertEqual(result.images.map(\.lastPathComponent), ["page-1.png", "page-2.png", "page-3.png", "page-4.png", "page-5.png"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.folder.path).sorted(), result.images.map(\.lastPathComponent))
        for image in result.images {
            let bitmap = try decodedBitmap(at: image)
            XCTAssertEqual(bitmap.width, 417)
            XCTAssertEqual(bitmap.height, 208)
            assertColor(bitmap.rgba(2, 2), (255, 255, 255), tolerance: 2)       // white page background
            assertColor(bitmap.rgba(208, 104), (51, 102, 204), tolerance: 20)  // the filled rectangle
        }

        let jpeg = try pdfService.exportImages(source: source, options: PDFImageExportOptions(format: .jpeg, dpi: 72, jpegQuality: 0.7),
                                               outputDirectory: root)
        XCTAssertEqual(jpeg.folder.lastPathComponent, "doc Images 2")
        XCTAssertEqual(jpeg.images.first?.lastPathComponent, "page-1.jpeg")
        XCTAssertEqual(try decodedBitmap(at: jpeg.images[0]).width, 200)

        // A page carrying /Rotate 90 renders with its displayed (swapped) size.
        let turned = try pdfService.rotate(source: source, selection: .pages([1]), rotation: .clockwise90, outputDirectory: root)
        let turnedImages = try pdfService.exportImages(source: turned, options: PDFImageExportOptions(dpi: 72), outputDirectory: root)
        XCTAssertEqual(turnedImages.folder.lastPathComponent, "doc-rotated Images")
        XCTAssertEqual([try decodedBitmap(at: turnedImages.images[0]).width, try decodedBitmap(at: turnedImages.images[0]).height], [100, 200])
        XCTAssertEqual(try decodedBitmap(at: turnedImages.images[1]).width, 200)

        let long = try makePDF("long.pdf", pageCount: 12) { _ in CGSize(width: 72, height: 72) }
        let padded = try pdfService.exportImages(source: long, options: PDFImageExportOptions(format: .png, dpi: 10), outputDirectory: root)
        XCTAssertEqual(padded.images.first?.lastPathComponent, "page-01.png")
        XCTAssertEqual(padded.images.last?.lastPathComponent, "page-12.png")
        XCTAssertEqual(stagingLeftovers(in: root), [])
    }

    func testExportImagesRespectsPixelLimitWithoutLeavingFiles() throws {
        let source = try makePDF("doc.pdf", pageCount: 2) { _ in CGSize(width: 200, height: 100) }
        let limited = PDFTransformationService(limits: .init(maximumRenderedPixelsPerPage: 10_000))
        let output = try folder("out")
        XCTAssertThrowsError(try limited.exportImages(source: source, options: PDFImageExportOptions(dpi: 150), outputDirectory: output)) { error in
            XCTAssertEqual(error as? PDFTransformationError, .imagePixelLimitExceeded(page: 1, pixels: 417 * 208, limit: 10_000))
        }
        assertPDFError(.invalidImageExportOptions) {
            try pdfService.exportImages(source: source, options: PDFImageExportOptions(dpi: 0), outputDirectory: output)
        }
        assertPDFError(.invalidImageExportOptions) {
            try pdfService.exportImages(source: source, options: PDFImageExportOptions(format: .jpeg, jpegQuality: 1.5), outputDirectory: output)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testLockedProtectedInvalidAndMissingPDFsAreRejected() throws {
        let locked = try makePDF("locked.pdf", pageCount: 1,
                                 auxiliaryInfo: [kCGPDFContextUserPassword: "user", kCGPDFContextOwnerPassword: "owner"])
        assertPDFError(.lockedPDF("locked.pdf")) {
            try pdfService.rotate(source: locked, selection: .all, rotation: .clockwise90, outputDirectory: root)
        }
        let lockedInfo = try pdfService.metadata(of: locked)
        XCTAssertTrue(lockedInfo.isLocked)
        XCTAssertTrue(lockedInfo.isEncrypted)

        let protected = try makePDF("protected.pdf", pageCount: 1,
                                    auxiliaryInfo: [kCGPDFContextOwnerPassword: "owner", kCGPDFContextAllowsCopying: false])
        XCTAssertFalse(try pdfService.metadata(of: protected).allowsCopying)
        assertPDFError(.protectedPDF("protected.pdf")) {
            try pdfService.exportImages(source: protected, options: PDFImageExportOptions(), outputDirectory: root)
        }

        let fake = root.appendingPathComponent("fake.pdf")
        try Data("not a pdf".utf8).write(to: fake)
        assertPDFError(.invalidPDF("fake.pdf")) { try pdfService.pageCount(of: fake) }
        assertPDFError(.sourceUnavailable("missing.pdf")) { try pdfService.pageCount(of: root.appendingPathComponent("missing.pdf")) }

        let empty = root.appendingPathComponent("empty.pdf")
        if PDFDocument().write(to: empty), PDFDocument(url: empty) != nil {
            assertPDFError(.emptyPDF("empty.pdf")) { try pdfService.pageCount(of: empty) }
        }
        let source = try makePDF("doc.pdf", pageCount: 1)
        assertPDFError(.destinationUnavailable(root.appendingPathComponent("nowhere").path)) {
            try pdfService.rotate(source: source, selection: .all, rotation: .clockwise90, outputDirectory: root.appendingPathComponent("nowhere"))
        }
    }

    func testThumbnailsMetadataAndPageLimit() throws {
        let source = try makePDF("doc.pdf", pageCount: 5)
        let thumbnails = try pdfService.pageThumbnails(source: source, maximumCount: 3, size: CGSize(width: 64, height: 64))
        XCTAssertEqual(thumbnails.map(\.pageNumber), [1, 2, 3])
        XCTAssertEqual(thumbnails.first?.image.height, 64)
        XCTAssertEqual(thumbnails.first?.image.width, 35)
        XCTAssertEqual(thumbnails.first?.pageSize, CGSize(width: 110, height: 200))

        let metadata = try pdfService.metadata(of: source)
        XCTAssertEqual(metadata.pageCount, 5)
        XCTAssertFalse(metadata.isLocked)
        XCTAssertEqual(metadata.firstPageSize, CGSize(width: 110, height: 200))
        XCTAssertEqual(try pdfService.pageCount(of: source), 5)

        let limited = PDFTransformationService(limits: .init(maximumPageCount: 4))
        assertPDFError(.pageLimitExceeded(pageCount: 5, limit: 4)) {
            try limited.split(source: source, strategy: .everyPages(1), outputDirectory: root)
        }
        let small = try makePDF("small.pdf", pageCount: 3)
        assertPDFError(.pageLimitExceeded(pageCount: 6, limit: 4)) {
            try limited.merge(sources: [small, small], outputDirectory: root, outputBaseName: nil)
        }
    }

    // MARK: - Image tools

    func testRotatePreservesMetadataAndRotatesPixels() throws {
        let source = try writeImage(splitImage(width: 400, height: 200), name: "photo.jpg", type: .jpeg, properties: photoProperties)
        let original = try Data(contentsOf: source)

        let right = try imageService.rotate(source: source, direction: .right)
        XCTAssertEqual(right.output.lastPathComponent, "photo-rotated.jpg")
        XCTAssertEqual([right.outputPixelWidth, right.outputPixelHeight], [200, 400])
        XCTAssertEqual([right.originalPixelWidth, right.originalPixelHeight], [400, 200])
        let rightBitmap = try decodedBitmap(at: right.output)
        assertColor(rightBitmap.rgba(100, 50), (255, 0, 0))   // the left (red) half is now on top
        assertColor(rightBitmap.rgba(100, 350), (0, 0, 255))
        let properties = try imageProperties(right.output)
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual((gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue ?? 0, 30.6586, accuracy: 0.0001)
        XCTAssertEqual((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, "DirDesk")

        let left = try imageService.rotate(source: source, direction: .left)
        XCTAssertEqual(left.output.lastPathComponent, "photo-rotated 2.jpg")
        let leftBitmap = try decodedBitmap(at: left.output)
        assertColor(leftBitmap.rgba(100, 350), (255, 0, 0))   // the left half is now at the bottom
        assertColor(leftBitmap.rgba(100, 50), (0, 0, 255))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(stagingLeftovers(in: root), [])
    }

    func testRotateComposesWithExistingOrientation() throws {
        // Stored 400×200 (red left, blue right) tagged "rotate 90° clockwise to display": displayed 200×400, red on top.
        let source = try writeImage(splitImage(width: 400, height: 200), name: "tagged.tiff", type: .tiff,
                                    properties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue])
        XCTAssertEqual(try imageService.metadata(source: source).orientedPixelWidth, 200)
        let result = try imageService.rotate(source: source, direction: .left)
        XCTAssertEqual(result.output.lastPathComponent, "tagged-rotated.tiff")
        XCTAssertEqual([result.outputPixelWidth, result.outputPixelHeight], [400, 200])
        let bitmap = try decodedBitmap(at: result.output)
        XCTAssertEqual(bitmap.rgba(50, 100).r, 255)
        XCTAssertEqual(bitmap.rgba(350, 100).b, 255)

        let flipped = try imageService.rotate(source: source, direction: .right)
        let flippedBitmap = try decodedBitmap(at: flipped.output)
        XCTAssertEqual([flippedBitmap.width, flippedBitmap.height], [400, 200])
        XCTAssertEqual(flippedBitmap.rgba(50, 100).b, 255)   // 180° from the stored pixels: blue now on the left
        XCTAssertEqual(flippedBitmap.rgba(350, 100).r, 255)
    }

    func testCropUsesOrientedCoordinates() throws {
        let source = try writeImage(splitImage(width: 400, height: 200), name: "tagged.tiff", type: .tiff,
                                    properties: [kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue])
        // Displayed 200×400 with red in rows 0–199 and blue in rows 200–399.
        let result = try imageService.crop(source: source, rect: ImageCropRect(x: 0, y: 150, width: 200, height: 100))
        XCTAssertEqual(result.output.lastPathComponent, "tagged-cropped.tiff")
        let bitmap = try decodedBitmap(at: result.output)
        XCTAssertEqual([bitmap.width, bitmap.height], [200, 100])
        XCTAssertEqual(bitmap.rgba(100, 10).r, 255)
        XCTAssertEqual(bitmap.rgba(100, 90).b, 255)

        for rect in [ImageCropRect(x: 150, y: 0, width: 100, height: 10), ImageCropRect(x: 0, y: 0, width: 0, height: 10),
                     ImageCropRect(x: -1, y: 0, width: 10, height: 10), ImageCropRect(x: 0, y: 399, width: 10, height: 2)] {
            XCTAssertThrowsError(try imageService.crop(source: source, rect: rect)) { error in
                XCTAssertEqual(error as? ImageTransformationError, .invalidCrop)
                XCTAssertEqual((error as? ImageTransformationError)?.message, "The crop rectangle is outside the image.")
            }
        }
    }

    func testConvertFormats() throws {
        let logo = makeImage(width: 120, height: 80, alpha: true) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0.8, blue: 0, alpha: 1))
            context.fill(CGRect(x: 40, y: 20, width: 40, height: 40))
        }
        let source = try writeImage(logo, name: "logo.png", type: .png)
        let jpeg = try imageService.convert(source: source, format: .jpeg, quality: 0.8)
        XCTAssertEqual(jpeg.output.lastPathComponent, "logo-converted.jpg")
        XCTAssertEqual(jpeg.typeIdentifier, "public.jpeg")
        let bitmap = try decodedBitmap(at: jpeg.output)
        assertColor(bitmap.rgba(2, 2), (255, 255, 255), tolerance: 8)   // transparency flattened onto white
        assertColor(bitmap.rgba(60, 40), (0, 204, 0))

        let tiff = try imageService.convert(source: source, format: .tiff)
        XCTAssertEqual(tiff.output.lastPathComponent, "logo-converted.tiff")
        XCTAssertEqual(try decodedBitmap(at: tiff.output).rgba(2, 2).a, 0)    // TIFF keeps the alpha channel

        if ImageTransformationService.writableTypeIdentifiers.contains(UTType.heic.identifier) {
            let heic = try imageService.convert(source: source, format: .heic, quality: 0.6)
            XCTAssertEqual(heic.output.lastPathComponent, "logo-converted.heic")
            XCTAssertEqual([heic.outputPixelWidth, heic.outputPixelHeight], [120, 80])
        }
        XCTAssertThrowsError(try imageService.convert(source: source, format: .jpeg, quality: 2)) {
            XCTAssertEqual($0 as? ImageTransformationError, .invalidQuality)
        }
    }

    func testCompressValidatesOptionsAndResizes() throws {
        let source = try writeImage(splitImage(width: 400, height: 200), name: "photo.jpg", type: .jpeg, properties: photoProperties)
        XCTAssertThrowsError(try imageService.compress(source: source, options: ImageCompressionOptions(quality: 1.5))) { error in
            XCTAssertEqual(error as? ImageTransformationError, .invalidQuality)
            XCTAssertEqual(error.localizedDescription, "Image quality must be between 0 and 1.")
        }
        XCTAssertThrowsError(try imageService.compress(source: source, options: ImageCompressionOptions(maximumPixelWidth: 0))) {
            XCTAssertEqual($0 as? ImageTransformationError, .invalidMaximumDimensions)
        }

        let options = ImageCompressionOptions(quality: 0.5, maximumPixelWidth: 100)
        let estimate = try imageService.estimateOutputSize(source: source, options: options)
        let result = try imageService.compress(source: source, options: options)
        XCTAssertEqual(result.output.lastPathComponent, "photo-compressed.jpg")
        XCTAssertEqual([result.outputPixelWidth, result.outputPixelHeight], [100, 50])
        XCTAssertEqual([estimate.pixelWidth, estimate.pixelHeight], [100, 50])
        XCTAssertEqual(result.originalByteCount, try byteCount(source))
        XCTAssertEqual(result.outputByteCount, try byteCount(result.output))
        XCTAssertLessThan(result.outputByteCount, result.originalByteCount)
        XCTAssertEqual(Double(estimate.byteCount), Double(result.outputByteCount), accuracy: Double(result.outputByteCount) * 0.05)

        let png = try imageService.compress(source: source, options: ImageCompressionOptions(format: .png, maximumPixelHeight: 20))
        XCTAssertEqual(png.output.lastPathComponent, "photo-compressed.png")
        XCTAssertEqual([png.outputPixelWidth, png.outputPixelHeight], [40, 20])

        let unchanged = try imageService.compress(source: source, options: ImageCompressionOptions(quality: 0.3, maximumPixelWidth: 4000))
        XCTAssertEqual([unchanged.outputPixelWidth, unchanged.outputPixelHeight], [400, 200])
        let converted = try imageService.estimateOutputSize(source: source, format: .png)
        XCTAssertEqual(converted.typeIdentifier, "public.png")
        XCTAssertGreaterThan(converted.byteCount, 0)
    }

    func testWatermarkDefaultsMatchReference() {
        let defaults = ImageWatermarkOptions(text: "DirDesk")
        XCTAssertEqual(defaults.layout, .tiled)
        XCTAssertEqual(defaults.angleDegrees, -30)
        XCTAssertEqual(defaults.opacity, 0.28, accuracy: 0.0001)
        XCTAssertEqual(defaults.relativeFontSize, 0.05, accuracy: 0.0001)
        XCTAssertEqual(defaults.relativeSpacing, 0.12, accuracy: 0.0001)
        XCTAssertEqual(defaults.color, .white)
        XCTAssertTrue(defaults.isValid)
    }

    func testWatermarkChangesPixels() throws {
        let white = makeImage(width: 300, height: 200) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        }
        let source = try writeImage(white, name: "white.png", type: .png)
        var options = ImageWatermarkOptions(text: "DirDesk", layout: .centered, angleDegrees: 0, opacity: 0.9,
                                            relativeFontSize: 0.2, relativeSpacing: 0.1, color: .black)
        let centered = try imageService.watermark(source: source, options: options)
        XCTAssertEqual(centered.output.lastPathComponent, "white-watermarked.png")
        let centeredBitmap = try decodedBitmap(at: centered.output)
        let centeredInk = centeredBitmap.countPixels { $0.r < 128 }
        XCTAssertGreaterThan(centeredInk, 100)
        XCTAssertEqual(centeredBitmap.rgba(2, 2).r, 255)   // corners stay clean

        options.layout = .tiled
        options.angleDegrees = 30
        let tiled = try imageService.watermark(source: source, options: options)
        XCTAssertEqual(tiled.output.lastPathComponent, "white-watermarked 2.png")
        XCTAssertGreaterThan(try decodedBitmap(at: tiled.output).countPixels { $0.r < 128 }, centeredInk)

        XCTAssertNotNil(ImageTransformationService.renderWatermark(options, on: white))
        for invalid in [ImageWatermarkOptions(text: "  "), ImageWatermarkOptions(text: "x", opacity: 0), ImageWatermarkOptions(text: "x", relativeFontSize: 0)] {
            XCTAssertThrowsError(try imageService.watermark(source: source, options: invalid)) {
                XCTAssertEqual($0 as? ImageTransformationError, .invalidWatermark)
            }
        }
    }

    func testRemoveBackgroundWithInjectedMask() throws {
        let source = try writeImage(splitImage(width: 200, height: 100), name: "subject.jpg", type: .jpeg)
        let service = ImageTransformationService(foregroundMaskGenerator: FixedMaskGenerator(keepsLeftHalf: true))
        let result = try service.removeBackground(source: source)
        XCTAssertEqual(result.output.lastPathComponent, "subject-background-removed.png")
        XCTAssertEqual(result.typeIdentifier, "public.png")
        let bitmap = try decodedBitmap(at: result.output)
        XCTAssertEqual(bitmap.rgba(50, 50).a, 255)
        assertColor(bitmap.rgba(50, 50), (255, 0, 0))
        XCTAssertEqual(bitmap.rgba(150, 50).a, 0)

        let empty = ImageTransformationService(foregroundMaskGenerator: FixedMaskGenerator(keepsLeftHalf: nil))
        XCTAssertThrowsError(try empty.removeBackground(source: source)) {
            XCTAssertEqual($0 as? ImageTransformationError, .noForegroundSubject)
        }
    }

    func testRemoveBackgroundWithVision() throws {
        let photo = makeImage(width: 512, height: 512) { context in
            context.setFillColor(CGColor(srgbRed: 0.92, green: 0.92, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.2, blue: 0.1, alpha: 1))
            context.fillEllipse(in: CGRect(x: 136, y: 136, width: 240, height: 240))
        }
        let source = try writeImage(photo, name: "ball.jpg", type: .jpeg)
        let result: ImageTransformationResult
        do {
            result = try imageService.removeBackground(source: source)
        } catch ImageTransformationError.noForegroundSubject {
            throw XCTSkip("Vision found no subject in the synthetic image.")
        } catch ImageTransformationError.foregroundDetectionFailed(let detail) {
            throw XCTSkip("Vision subject lifting is unavailable here: \(detail)")
        }
        XCTAssertEqual(result.output.lastPathComponent, "ball-background-removed.png")
        let bitmap = try decodedBitmap(at: result.output)
        XCTAssertGreaterThan(bitmap.countPixels { $0.a == 0 }, 0)
        XCTAssertGreaterThan(bitmap.countPixels { $0.a == 255 }, 0)
    }

    func testCreatePDFPageSizes() throws {
        let a = try writeImage(splitImage(width: 300, height: 200), name: "a.png", type: .png)
        let b = try writeImage(splitImage(width: 100, height: 400), name: "b.jpg", type: .jpeg)
        let c = try writeImage(splitImage(width: 50, height: 50), name: "c.png", type: .png)

        let original = try imageService.createPDF(sources: [a, b, c], options: ImagePDFOptions(paperSize: .original), outputDirectory: root)
        XCTAssertEqual(original.lastPathComponent, "a-created.pdf")
        XCTAssertEqual(try pageSizes(original), [CGSize(width: 300, height: 200), CGSize(width: 100, height: 400), CGSize(width: 50, height: 50)])

        let fitted = try imageService.createPDF(sources: [c, a], options: ImagePDFOptions(paperSize: .a4Portrait, fitToPage: true),
                                                outputDirectory: root)
        XCTAssertEqual(fitted.lastPathComponent, "c-created.pdf")
        let a4 = try XCTUnwrap(ImagePDFPaperSize.a4Portrait.pointSize)
        XCTAssertEqual(try pageSizes(fitted).map { [$0.width.rounded(), $0.height.rounded()] }, [[595, 842], [595, 842]])
        // Without upscaling the 50×50 image stays small and centered on white paper.
        let small = try renderedPage(fitted, page: 0)
        assertColor(small.rgba(small.width / 2 - 10, small.height / 2), (255, 0, 0))
        assertColor(small.rgba(20, small.height / 2), (255, 255, 255), tolerance: 2)

        let enlarged = try imageService.createPDF(sources: [c], options: ImagePDFOptions(paperSize: .a4Portrait, fitToPage: true, allowUpscaling: true),
                                                  outputDirectory: root)
        XCTAssertEqual(enlarged.lastPathComponent, "c-created 2.pdf")
        let large = try renderedPage(enlarged, page: 0)
        assertColor(large.rgba(20, large.height / 2), (255, 0, 0))   // now spans the paper width
        XCTAssertEqual(a4.width, 595.2756, accuracy: 0.001)

        let big = try writeImage(splitImage(width: 1000, height: 1000), name: "big.png", type: .png)
        let clipped = try imageService.createPDF(sources: [big], options: ImagePDFOptions(paperSize: .letterLandscape, fitToPage: false),
                                                 outputDirectory: root)
        XCTAssertEqual(try pageSizes(clipped), [CGSize(width: 792, height: 612)])
        let clippedPage = try renderedPage(clipped, page: 0)
        assertColor(clippedPage.rgba(2, 2), (255, 0, 0))   // natural size overflows the paper and is clipped
        assertColor(clippedPage.rgba(clippedPage.width - 3, 2), (0, 0, 255))

        XCTAssertThrowsError(try imageService.createPDF(sources: [], outputDirectory: root)) {
            XCTAssertEqual($0 as? ImageTransformationError, .emptySelection)
        }
        XCTAssertEqual(stagingLeftovers(in: root), [])
    }

    func testPhotoLocation() throws {
        let north = try writeImage(splitImage(width: 40, height: 20), name: "north.jpg", type: .jpeg, properties: photoProperties)
        let location = try XCTUnwrap(try imageService.photoLocation(source: north))
        XCTAssertEqual(location.latitude, 30.6586, accuracy: 0.0001)
        XCTAssertEqual(location.longitude, 104.0648, accuracy: 0.0001)
        XCTAssertEqual(location.altitude ?? 0, 512.3, accuracy: 0.01)
        XCTAssertEqual(location.timestamp, ISO8601DateFormatter().date(from: "2026-10-01T08:30:00Z"))
        XCTAssertEqual(location.coordinateText, "30.658600, 104.064800")
        XCTAssertEqual(location.mapsURL.absoluteString, "https://maps.apple.com/?ll=30.658600,104.064800")

        let southWest: [CFString: Any] = [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 33.8688, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 70.6693, kCGImagePropertyGPSLongitudeRef: "W",
            kCGImagePropertyGPSAltitude: 12.0, kCGImagePropertyGPSAltitudeRef: 1,
        ]]
        let south = try writeImage(splitImage(width: 40, height: 20), name: "south.jpg", type: .jpeg, properties: southWest)
        let southLocation = try XCTUnwrap(try imageService.photoLocation(source: south))
        XCTAssertEqual(southLocation.latitude, -33.8688, accuracy: 0.0001)
        XCTAssertEqual(southLocation.longitude, -70.6693, accuracy: 0.0001)
        XCTAssertEqual(southLocation.altitude ?? 0, -12, accuracy: 0.01)

        let plain = try writeImage(splitImage(width: 40, height: 20), name: "plain.jpg", type: .jpeg)
        XCTAssertNil(try imageService.photoLocation(source: plain))

        let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("DirDeskFixtures/03-图片/photo-gps.jpg")
        if FileManager.default.isReadableFile(atPath: fixture.path) {
            let fixtureLocation = try XCTUnwrap(try imageService.photoLocation(source: fixture))
            XCTAssertEqual(fixtureLocation.latitude, 30.6586, accuracy: 0.0001)
            XCTAssertEqual(fixtureLocation.longitude, 104.0648, accuracy: 0.0001)
            XCTAssertEqual(fixtureLocation.altitude ?? 0, 512.3, accuracy: 0.01)
        }
    }

    func testRemoveLocationMetadataKeepsPixels() throws {
        let source = try writeImage(noiseImage(width: 160, height: 120), name: "photo.jpg", type: .jpeg, properties: photoProperties)
        let result = try imageService.removeLocationMetadata(source: source)
        XCTAssertEqual(result.output.lastPathComponent, "photo-location-removed.jpg")
        let cleaned = try imageProperties(result.output)
        XCTAssertNil(cleaned[kCGImagePropertyGPSDictionary])
        let iptc = cleaned[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(iptc[kCGImagePropertyIPTCCity])
        XCTAssertNil(iptc[kCGImagePropertyIPTCKeywords])
        XCTAssertEqual((cleaned[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String,
                       "2026:10:01 16:30:00")
        XCTAssertEqual((cleaned[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, "DirDesk")
        XCTAssertNil(try imageService.photoLocation(source: result.output))
        XCTAssertFalse(try imageService.metadata(source: result.output).containsGPS)
        XCTAssertEqual(try decodedBitmap(at: result.output).bytes, try decodedBitmap(at: source).bytes)
        XCTAssertNotNil(try imageService.photoLocation(source: source))   // the source keeps its location

        let png = try writeImage(splitImage(width: 64, height: 32), name: "shot.png", type: .png, properties: photoProperties)
        let pngResult = try imageService.removeLocationMetadata(source: png)
        XCTAssertEqual(pngResult.output.lastPathComponent, "shot-location-removed.png")
        XCTAssertNil(try imageService.photoLocation(source: pngResult.output))
        XCTAssertEqual(try decodedBitmap(at: pngResult.output).bytes, try decodedBitmap(at: png).bytes)
        XCTAssertEqual(stagingLeftovers(in: root), [])
    }

    func testImageMetadata() throws {
        var properties = photoProperties
        properties[kCGImagePropertyOrientation] = CGImagePropertyOrientation.right.rawValue
        let source = try writeImage(splitImage(width: 400, height: 200), name: "photo.jpg", type: .jpeg, properties: properties)
        let metadata = try imageService.metadata(source: source)
        XCTAssertEqual([metadata.pixelWidth, metadata.pixelHeight], [400, 200])
        XCTAssertEqual([metadata.orientedPixelWidth, metadata.orientedPixelHeight], [200, 400])
        XCTAssertEqual(metadata.orientation, .right)
        XCTAssertEqual(metadata.cameraMake, "DirDesk")
        XCTAssertEqual(metadata.cameraModel, "Test Camera")
        XCTAssertEqual(metadata.colorModel, "RGB")
        XCTAssertTrue(metadata.containsGPS)
        XCTAssertEqual(metadata.typeIdentifier, "public.jpeg")
        XCTAssertEqual(metadata.frameCount, 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        XCTAssertEqual(metadata.capturedAt, formatter.date(from: "2026:10:01 16:30:00"))
    }

    func testImageGuards() throws {
        let gif = root.appendingPathComponent("anim.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil))
        for color in [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)] {
            let frame = makeImage(width: 20, height: 20) { $0.setFillColor(color); $0.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try imageService.rotate(source: gif, direction: .left)) { error in
            XCTAssertEqual(error as? ImageTransformationError, .unsupportedFrameCount(2))
            XCTAssertEqual(error.localizedDescription, "This operation does not support images with 2 frames.")
        }

        let photo = try writeImage(splitImage(width: 400, height: 200), name: "photo.png", type: .png)
        let tight = ImageTransformationService(limits: .init(maximumPixelCount: 1_000))
        XCTAssertThrowsError(try tight.rotate(source: photo, direction: .left)) {
            XCTAssertEqual($0 as? ImageTransformationError, .pixelBudgetExceeded(pixels: 80_000, limit: 1_000))
        }
        XCTAssertThrowsError(try imageService.rotate(source: root.appendingPathComponent("missing.png"), direction: .left)) {
            XCTAssertEqual($0 as? ImageTransformationError, .sourceUnavailable("missing.png"))
        }
        let text = root.appendingPathComponent("note.jpg")
        try Data("not an image".utf8).write(to: text)
        XCTAssertThrowsError(try imageService.rotate(source: text, direction: .left)) { error in
            switch error as? ImageTransformationError {
            case .unsupportedOrDamaged, .unsupportedSourceFormat: break
            default: XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try imageService.rotate(source: photo, direction: .left, outputDirectory: root.appendingPathComponent("nowhere"))) {
            XCTAssertEqual($0 as? ImageTransformationError, .destinationNotWritable(root.appendingPathComponent("nowhere").path))
        }
        XCTAssertEqual(stagingLeftovers(in: root), [])
    }

    func testAuxiliaryDataIsRefused() throws {
        let url = root.appendingPathComponent("depth.heic")
        guard ImageTransformationService.writableTypeIdentifiers.contains(UTType.heic.identifier),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("HEIC encoding is unavailable.")
        }
        CGImageDestinationAddImage(destination, splitImage(width: 64, height: 64), nil)
        let width = 32, height = 32
        let disparity = Data(count: width * height * 2)
        let description: [CFString: Any] = [kCGImagePropertyWidth: width, kCGImagePropertyHeight: height,
                                            kCGImagePropertyBytesPerRow: width * 2, kCGImagePropertyPixelFormat: kCVPixelFormatType_DisparityFloat16]
        let info: [CFString: Any] = [kCGImageAuxiliaryDataInfoData: disparity, kCGImageAuxiliaryDataInfoDataDescription: description,
                                     kCGImageAuxiliaryDataInfoMetadata: CGImageMetadataCreateMutable()]
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeDisparity, info as CFDictionary)
        guard CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              !ImageTransformationService.auxiliaryDataKinds(in: source).isEmpty else {
            throw XCTSkip("ImageIO did not store the synthetic disparity map.")
        }
        XCTAssertThrowsError(try imageService.rotate(source: url, direction: .left)) {
            XCTAssertEqual($0 as? ImageTransformationError, .unsupportedAuxiliaryData(["disparity"]))
        }
    }

    // MARK: - Fixtures and helpers

    private struct FixedMaskGenerator: ImageForegroundMaskGenerating {
        /// nil reports no subject.
        var keepsLeftHalf: Bool?

        func foregroundMask(for image: CGImage) throws -> CIImage? {
            guard let keepsLeftHalf else { return nil }
            let space = CGColorSpaceCreateDeviceGray()
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.setFillColor(gray: 1, alpha: 1)
            let half = CGFloat(image.width) / 2
            context.fill(CGRect(x: keepsLeftHalf ? 0 : half, y: 0, width: half, height: CGFloat(image.height)))
            return CIImage(cgImage: context.makeImage()!)
        }
    }

    private struct Bitmap {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        /// Top-left origin, premultiplied sRGB.
        func rgba(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let index = (y * width + x) * 4
            return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]), Int(bytes[index + 3]))
        }

        func countPixels(where predicate: ((r: Int, g: Int, b: Int, a: Int)) -> Bool) -> Int {
            var count = 0
            for y in 0..<height {
                for x in 0..<width where predicate(rgba(x, y)) { count += 1 }
            }
            return count
        }
    }

    private var photoProperties: [CFString: Any] {
        [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 30.6586, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 104.0648, kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 512.3, kCGImagePropertyGPSAltitudeRef: 0,
                kCGImagePropertyGPSDateStamp: "2026:10:01", kCGImagePropertyGPSTimeStamp: "08:30:00",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "DirDesk", kCGImagePropertyTIFFModel: "Test Camera"] as [CFString: Any],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:01 16:30:00"] as [CFString: Any],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Chengdu", kCGImagePropertyIPTCKeywords: ["fixture"]] as [CFString: Any],
        ]
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Page `n` (one-based) defaults to (100 + 10n) × 200 points with an inset blue rectangle.
    private func makePDF(_ name: String, pageCount: Int, auxiliaryInfo: [CFString: Any] = [:], image: CGImage? = nil,
                         pageSize: ((Int) -> CGSize)? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        var defaultBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &defaultBox, auxiliaryInfo as CFDictionary))
        for page in 1...pageCount {
            var box = CGRect(origin: .zero, size: pageSize?(page) ?? CGSize(width: 100 + 10 * page, height: 200))
            context.beginPDFPage([kCGPDFContextMediaBox: withUnsafeBytes(of: &box) { Data($0) }] as CFDictionary)
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(box.insetBy(dx: 10, dy: 10))
            if let image { context.draw(image, in: box.insetBy(dx: 5, dy: 5)) }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func pageWidths(_ url: URL) throws -> [Int] {
        let document = try XCTUnwrap(PDFDocument(url: url))
        return (0..<document.pageCount).map { Int(document.page(at: $0)?.bounds(for: .mediaBox).width ?? 0) }
    }

    private func pageSizes(_ url: URL) throws -> [CGSize] {
        let document = try XCTUnwrap(PDFDocument(url: url))
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).size }
    }

    private func rotations(_ url: URL) throws -> [Int] {
        let document = try XCTUnwrap(PDFDocument(url: url))
        return (0..<document.pageCount).map { document.page(at: $0)?.rotation ?? -1 }
    }

    private func renderedPage(_ url: URL, page index: Int) throws -> Bitmap {
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: index)?.pageRef)
        let size = PDFTransformationService.displaySize(of: page)
        let image = try XCTUnwrap(PDFTransformationService.render(page, width: Int(size.width.rounded()), height: Int(size.height.rounded())))
        return rasterize(image)
    }

    private func byteCount(_ url: URL) throws -> Int64 {
        Int64(try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize))
    }

    private func stagingLeftovers(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".dirdesk") }
    }

    private func makeImage(width: Int, height: Int, alpha: Bool = false, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        draw(context)
        return context.makeImage()!
    }

    /// Left half red, right half blue.
    private func splitImage(width: Int, height: Int) -> CGImage {
        makeImage(width: width, height: height) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
    }

    private func noiseImage(width: Int, height: Int) -> CGImage {
        var state: UInt32 = 0x2545_F491
        let bytes = (0..<(width * height * 4)).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func writeImage(_ image: CGImage, name: String, type: UTType, properties: [CFString: Any] = [:]) throws -> URL {
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func imageProperties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func rasterize(_ image: CGImage) -> Bitmap {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return Bitmap(width: image.width, height: image.height, bytes: bytes)
    }

    private func decodedBitmap(at url: URL) throws -> Bitmap {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return rasterize(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    private func assertColor(_ pixel: (r: Int, g: Int, b: Int, a: Int), _ expected: (Int, Int, Int), tolerance: Int = 40,
                             file: StaticString = #filePath, line: UInt = #line) {
        let matches = abs(pixel.r - expected.0) <= tolerance && abs(pixel.g - expected.1) <= tolerance && abs(pixel.b - expected.2) <= tolerance
        XCTAssertTrue(matches, "pixel \(pixel) is not close to \(expected)", file: file, line: line)
    }

    private func assertPDFError<T>(_ expected: PDFTransformationError, file: StaticString = #filePath, line: UInt = #line,
                                   _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? PDFTransformationError, expected, file: file, line: line)
        }
    }
}
