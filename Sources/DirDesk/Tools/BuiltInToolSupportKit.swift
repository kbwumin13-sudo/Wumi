import AppKit
import DirDeskCore
import ImageIO
import UniformTypeIdentifiers

/// Limits shared by every built-in tool run.
enum BuiltInToolLimits {
    /// Most items one run accepts ("Built-in Tools can process at most %lld items at once.").
    static let maximumItemCount = 500
    /// Tools that run without an options sheet ask before processing more items than this.
    static let confirmationThreshold = 20
}

/// The kind of file a tool reads.
enum BuiltInToolInput {
    case image, pdf

    init?(_ tool: BuiltInToolID) {
        switch tool.category {
        case .images, .metadataPrivacy: self = .image
        case .pdf: self = .pdf
        case .folders: return nil
        }
    }

    /// Plain files whose type (or, when the type is unknown, extension) matches.
    func accepts(_ item: FileItem) -> Bool {
        guard !item.isDirectory else { return false }
        guard let type = item.contentType ?? UTType(filenameExtension: item.fileExtension) else { return false }
        switch self {
        case .image: return type.conforms(to: .image) && !type.conforms(to: .pdf)
        case .pdf: return type.conforms(to: .pdf)
        }
    }
}

/// Immutable bitmap handed from background work to the views.
struct ToolBitmap: @unchecked Sendable {
    let cgImage: CGImage
}

/// Result of work done off the main thread; failures carry a localized message.
enum ToolOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
}

enum ToolWork {
    /// Runs `work` on a background thread and returns its value or localized error message.
    static func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async -> ToolOutcome<Value> {
        await Task.detached(priority: .userInitiated) { () -> ToolOutcome<Value> in
            do {
                return .success(try work())
            } catch {
                return .failure(BuiltInToolErrorText.message(for: error))
            }
        }.value
    }
}

enum ToolImageLoader {
    /// Upright thumbnail (EXIF orientation applied) whose longer edge is at most `maximumPixelSize`; never enlarged.
    static func thumbnail(of url: URL, maximumPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, maximumPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Moves finished files from a private staging folder to their sibling destination.
enum ToolFilePublisher {
    /// A private folder on the same volume as `directory` when the system provides one.
    static func makeStagingDirectory(near directory: URL) throws -> URL {
        if let url = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true) {
            return url
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DirDesk-Tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Moves `file` to `desired`, or to its keep-both name ("name 2.ext"); an existing item is never replaced.
    static func publish(_ file: URL, as desired: URL) throws -> URL {
        var candidate = FileManager.default.fileExists(atPath: desired.path) ? FileOperationCoordinator.keepBothURL(for: desired) : desired
        for _ in 0..<16 {
            do {
                try FileManager.default.moveItem(at: file, to: candidate)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                candidate = FileOperationCoordinator.keepBothURL(for: desired)
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// A file name base from user input: no path separators, leading dots or `.pdf` suffix; `fallback` when blank.
    static func sanitizedBaseName(_ text: String, removingExtension ext: String, fallback: String) -> String {
        var base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix("." + ext) { base = String(base.dropLast(ext.count + 1)).trimmingCharacters(in: .whitespaces) }
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        while base.utf8.count > 200 { base.removeLast() }
        return base.isEmpty ? fallback : base
    }

    static func removeQuietly(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Localized text for the tool engines' errors.
enum BuiltInToolErrorText {
    static func message(for error: Error) -> String {
        if let error = error as? PDFTransformationError { return message(for: error) }
        if let error = error as? ImageTransformationError { return message(for: error) }
        return error.localizedDescription
    }

    static func isCancellation(_ error: Error) -> Bool {
        (error as? PDFTransformationError) == .cancelled || (error as? ImageTransformationError) == .cancelled || error is CancellationError
    }

    static func message(for error: PDFTransformationError) -> String {
        switch error {
        case .sourceUnavailable(let name): LF("The source PDF is missing or unreadable: %@", name)
        case .invalidPDF(let name): LF("The file is not a valid PDF: %@", name)
        case .emptyPDF(let name): LF("The PDF has no pages: %@", name)
        case .lockedPDF(let name): LF("The PDF is locked: %@", name)
        case .protectedPDF(let name): LF("The PDF permissions do not allow this operation: %@", name)
        case .invalidPageRange(let range, let pageCount):
            range.first == range.last
                ? LF("Page %lld is outside this %lld-page PDF.", Int64(range.first), Int64(pageCount))
                : LF("Pages %lld-%lld are outside this %lld-page PDF.", Int64(range.first), Int64(range.last), Int64(pageCount))
        case .malformedPageRange(let text): LF("“%@” is not a valid page range. Use one-based ranges such as 1-3, 5, 8-10.", text)
        case .noPagesSelected: L("Select at least one page.")
        case .sourceCountOutOfRange(let minimum, let maximum, let received):
            received < minimum
                ? LF("This operation requires at least %lld PDFs; received %lld.", Int64(minimum), Int64(received))
                : LF("This operation accepts at most %lld PDFs; received %lld.", Int64(maximum), Int64(received))
        case .pageLimitExceeded(let pageCount, let limit):
            LF("The operation contains %lld pages, exceeding the %lld-page limit.", Int64(pageCount), Int64(limit))
        case .imagePixelLimitExceeded(let page, let pixels, let limit):
            LF("Page %lld would render with %lld pixels, above the limit of %lld. Choose a lower resolution.", Int64(page), Int64(pixels), Int64(limit))
        case .invalidImageExportOptions:
            LF("Choose a resolution between %lld and %lld DPI.", Int64(PDFImageExportOptions.supportedDPI.lowerBound),
               Int64(PDFImageExportOptions.supportedDPI.upperBound))
        case .destinationUnavailable(let path): LF("The destination folder is unavailable or not writable: %@", path)
        case .insufficientSpace(let available, let needed):
            LF("Not enough free space: %@ available, about %@ needed.", byteText(available), byteText(needed))
        case .outputWriteFailed(let name): LF("Could not write the PDF: %@", name)
        case .outputValidationFailed(let name): LF("The generated PDF failed validation: %@", name)
        case .outputPublicationFailed(let name): LF("Could not publish the completed PDF: %@", name)
        case .overlappingPageRanges: L("Page ranges must not overlap.")
        case .invalidSplitParameter: L("The split value must be greater than zero and produce at least one file.")
        case .invalidRotationSelection: L("At least one valid page must be selected for rotation.")
        case .cancelled: L("Tool operation cancelled")
        }
    }

    static func message(for error: ImageTransformationError) -> String {
        switch error {
        case .sourceUnavailable(let name): LF("The source image is missing or unreadable: %@", name)
        case .unsupportedOrDamaged(let name): LF("The image is unsupported or damaged: %@", name)
        case .unsupportedFrameCount(let count): LF("This operation does not support images with %lld frames.", Int64(count))
        case .unsupportedAuxiliaryData(let kinds): LF("This operation would discard unsupported image data: %@.", kinds.joined(separator: ", "))
        case .unsupportedSourceFormat: L("The source image format is not supported.")
        case .unsupportedDestinationFormat(let format): LF("The destination format is unavailable: %@", format)
        case .invalidCrop: L("The crop rectangle is outside the image.")
        case .invalidQuality: L("Image quality must be between 0 and 1.")
        case .pixelBudgetExceeded(let pixels, let limit): LF("The image has %lld pixels, above the safe limit of %lld.", Int64(pixels), Int64(limit))
        case .destinationExists(let name): LF("An item named “%@” already exists.", name)
        case .destinationNotWritable(let path): LF("The destination folder is not writable: %@", path)
        case .invalidMaximumDimensions: L("Maximum image dimensions must be positive.")
        case .invalidWatermark: L("Watermark text and settings are invalid.")
        case .destinationMatchesSource: L("Image tools create a new file and cannot replace the source.")
        case .noForegroundSubject: L("No suitable foreground subject was detected.")
        case .foregroundDetectionFailed(let detail): LF("Subject detection is unavailable: %@", detail)
        case .locationUnavailable: L("The image does not contain readable location metadata.")
        case .pdfCreationFailed: L("The PDF could not be created.")
        case .emptySelection: L("Select at least one item.")
        case .outputWriteFailed(let name): LF("Could not write the image: %@", name)
        case .cancelled: L("Tool operation cancelled")
        }
    }

    private static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Small formatting helpers for tool labels.
enum ToolText {
    static func pixels(_ width: Int, _ height: Int) -> String {
        LF("%lld × %lld px", Int64(width), Int64(height))
    }

    static func percent(_ fraction: Double) -> String {
        LF("%lld%%", Int64((fraction * 100).rounded()))
    }

    /// "5.0%": a percentage with a fixed number of decimals in the interface language.
    static func percent(_ fraction: Double, fractionDigits: Int) -> String {
        fraction.formatted(.percent.precision(.fractionLength(fractionDigits)).locale(Localizer.shared.locale))
    }

    static func degrees(_ value: Double) -> String {
        LF("%lld°", Int64(value.rounded()))
    }

    static func pages(_ ranges: [PDFPageRange]) -> String {
        ranges.map { range in
            range.first == range.last ? LF("Page %lld", Int64(range.first)) : LF("Pages %lld–%lld", Int64(range.first), Int64(range.last))
        }.joined(separator: ", ")
    }

    /// "Pages 1–1": every range written as a span, as in the split preview of the reference.
    static func pageSpans(_ ranges: [PDFPageRange]) -> String {
        ranges.map { LF("Pages %lld–%lld", Int64($0.first), Int64($0.last)) }.joined(separator: ", ")
    }

    static func pageCount(_ count: Int) -> String {
        count == 1 ? L("1 page") : LF("%lld pages", Int64(count))
    }

    /// Two sizes for a before/after comparison, in bytes when the rounded sizes would read the same.
    static func sizes(_ before: Int64, _ after: Int64, unit: FileSizeUnit) -> (String, String) {
        let rounded = (FileSizeFormatter.string(before, unit: unit), FileSizeFormatter.string(after, unit: unit))
        guard rounded.0 == rounded.1, before != after else { return rounded }
        return (LF("%lld bytes", before), LF("%lld bytes", after))
    }

    static func fileCount(_ count: Int) -> String {
        count == 1 ? L("1 file") : LF("%lld files", Int64(count))
    }

    static func imageCount(_ count: Int) -> String {
        count == 1 ? L("1 image") : LF("%lld images", Int64(count))
    }
}
