import CoreGraphics
import Foundation

/// One-based, inclusive page range: "1-3" or "5".
public struct PDFPageRange: Hashable, Codable, Sendable, CustomStringConvertible {
    public var first: Int
    public var last: Int

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    public init(page: Int) {
        self.init(first: page, last: page)
    }

    public init(_ range: ClosedRange<Int>) {
        self.init(first: range.lowerBound, last: range.upperBound)
    }

    public var pageCount: Int {
        guard last >= first else { return 0 }
        let (difference, overflow) = last.subtractingReportingOverflow(first)
        return overflow || difference == .max ? .max : difference + 1
    }
    public var description: String { first == last ? "\(first)" : "\(first)-\(last)" }

    public func overlaps(_ other: PDFPageRange) -> Bool {
        first <= other.last && other.first <= last
    }

    /// Parses one-based ranges such as "1-3, 5, 8-10". Commas, semicolons, enumeration commas and
    /// whitespace separate entries; hyphens, dashes and tildes join a range; full-width digits are accepted.
    /// Blank text gives an empty list.
    public static func parse(_ text: String) throws -> [PDFPageRange] {
        var normalized = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        for separator in ["、", "；", ";", "\n", "\t"] {
            normalized = normalized.replacingOccurrences(of: separator, with: ",")
        }
        for dash in ["–", "—", "−", "‐", "~", "～", "至"] {
            normalized = normalized.replacingOccurrences(of: dash, with: "-")
        }
        var ranges: [PDFPageRange] = []
        for part in normalized.split(separator: ",") {
            let compact = part.replacingOccurrences(of: "\\s*-\\s*", with: "-", options: .regularExpression)
            for token in compact.split(whereSeparator: { $0.isWhitespace }) {
                let pieces = token.split(separator: "-", omittingEmptySubsequences: false)
                guard pieces.count == 1 || pieces.count == 2,
                      let low = Int(pieces[0]), let high = pieces.count == 2 ? Int(pieces[1]) : low,
                      low >= 1, high >= low else {
                    throw PDFTransformationError.malformedPageRange(String(token))
                }
                ranges.append(PDFPageRange(first: low, last: high))
            }
        }
        return ranges
    }

    /// "1-3, 5, 8-10".
    public static func format(_ ranges: [PDFPageRange]) -> String {
        ranges.map(\.description).joined(separator: ", ")
    }

    /// Ascending ranges covering exactly `pages` (values below 1 are ignored): {1, 2, 3, 5} gives 1-3, 5.
    public static func ranges(covering pages: Set<Int>) -> [PDFPageRange] {
        var ranges: [PDFPageRange] = []
        for page in pages.filter({ $0 >= 1 }).sorted() {
            if let last = ranges.last, last.last + 1 == page {
                ranges[ranges.count - 1].last = page
            } else {
                ranges.append(PDFPageRange(page: page))
            }
        }
        return ranges
    }
}

public enum PDFSplitStrategy: Hashable, Sendable {
    /// One output per range, in the given order.
    case pageRanges([PDFPageRange])
    /// Consecutive chunks of N pages; the last chunk may be shorter.
    case everyPages(Int)
    /// Exactly N outputs with page counts as even as possible (earlier files get the extra pages).
    case targetFileCount(Int)
}

public enum PDFExtractionMode: String, Codable, CaseIterable, Sendable {
    case combined, oneFilePerRange
}

public enum PDFRotation: String, Codable, CaseIterable, Sendable {
    case clockwise90, counterclockwise90, halfTurn

    /// Clockwise degrees added to each page's rotation.
    public var degrees: Int {
        switch self {
        case .clockwise90: 90
        case .counterclockwise90: 270
        case .halfTurn: 180
        }
    }
}

public enum PDFPageSelection: Hashable, Sendable {
    case all
    /// One-based page numbers.
    case pages(Set<Int>)

    /// The rotate tool's "Pages (blank means all)" field: blank selects every page.
    public static func parse(_ text: String) throws -> PDFPageSelection {
        let ranges = try PDFPageRange.parse(text)
        guard !ranges.isEmpty else { return .all }
        // A typo such as "1-99999999" must not expand into an enormous set.
        var total = 0
        for range in ranges {
            total += range.pageCount
            guard total <= 1_000_000 else {
                throw PDFTransformationError.malformedPageRange(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return .pages(Set(ranges.flatMap { Array($0.first...$0.last) }))
    }
}

public enum PDFCompressionPreset: String, Codable, CaseIterable, Sendable {
    /// PDFKit's "optimize images for screen".
    case screenOptimized
    /// Optimize for screen and save the images as JPEG.
    case screenOptimizedJPEG
}

public enum PDFImageExportFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg

    public var fileExtension: String { rawValue }

    var typeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        }
    }
}

public struct PDFImageExportOptions: Hashable, Codable, Sendable {
    /// "Screen Reading (72 DPI)".
    public static let screenReadingDPI = 72
    /// "Clear Sharing (150 DPI)".
    public static let clearSharingDPI = 150
    /// "High-Quality Printing (300 DPI)".
    public static let highQualityPrintingDPI = 300
    public static let supportedDPI = 1...2400

    public var format: PDFImageExportFormat
    public var dpi: Int
    /// 0…1, used for JPEG only.
    public var jpegQuality: Double

    public init(format: PDFImageExportFormat = .png, dpi: Int = PDFImageExportOptions.clearSharingDPI, jpegQuality: Double = 0.85) {
        self.format = format
        self.dpi = dpi
        self.jpegQuality = jpegQuality
    }
}

public struct PDFImageExportResult: Hashable, Sendable {
    public var source: URL
    /// The published "<base> Images" folder.
    public var folder: URL
    /// Page images in document order.
    public var images: [URL]
}

public struct PDFCompressionResult: Hashable, Sendable {
    public var source: URL
    public var output: URL
    public var originalByteCount: Int64
    public var outputByteCount: Int64

    /// Bytes saved; negative when the output is larger (already optimized PDFs).
    public var savedByteCount: Int64 { originalByteCount - outputByteCount }
}

public struct PDFMetadata: Hashable, Sendable {
    public var pageCount: Int
    public var isEncrypted: Bool
    public var isLocked: Bool
    public var allowsCopying: Bool
    public var allowsPrinting: Bool
    public var allowsDocumentAssembly: Bool
    public var allowsDocumentChanges: Bool
    public var majorVersion: Int
    public var minorVersion: Int
    public var title: String?
    public var author: String?
    public var creator: String?
    public var producer: String?
    public var creationDate: Date?
    public var modificationDate: Date?
    public var byteCount: Int64
    /// Crop-box size of the first page in points, after its rotation.
    public var firstPageSize: CGSize?
}

/// A rendered page for the extract-pages picker.
public struct PDFPageThumbnailPreview {
    /// One-based.
    public var pageNumber: Int
    public var image: CGImage
    /// Crop-box size in points, after the page's rotation.
    public var pageSize: CGSize
}

public struct PDFPlannedOutput: Hashable, Sendable {
    /// Exact output URL, keep-both resolved against existing items and the other planned outputs.
    public var url: URL
    /// Source pages written to this output, in order.
    public var ranges: [PDFPageRange]

    public var pageCount: Int { ranges.reduce(0) { $0 + $1.pageCount } }
}

public struct PDFSplitPlan: Hashable, Sendable {
    public var source: URL
    public var sourcePageCount: Int
    public var outputs: [PDFPlannedOutput]
}

public enum PDFTransformationError: Error, Equatable, Sendable, LocalizedError {
    case sourceUnavailable(String)
    case invalidPDF(String)
    case emptyPDF(String)
    case lockedPDF(String)
    case protectedPDF(String)
    case invalidPageRange(PDFPageRange, pageCount: Int)
    case malformedPageRange(String)
    case noPagesSelected
    case sourceCountOutOfRange(minimum: Int, maximum: Int, received: Int)
    case pageLimitExceeded(pageCount: Int, limit: Int)
    case imagePixelLimitExceeded(page: Int, pixels: Int, limit: Int)
    case invalidImageExportOptions
    case destinationUnavailable(String)
    case insufficientSpace(available: Int64, needed: Int64)
    case outputWriteFailed(String)
    case outputValidationFailed(String)
    case outputPublicationFailed(String)
    case overlappingPageRanges
    case invalidSplitParameter
    case invalidRotationSelection
    case cancelled

    public var message: String {
        switch self {
        case .sourceUnavailable(let name): "The source PDF is missing or unreadable: \(name)"
        case .invalidPDF(let name): "The file is not a valid PDF: \(name)"
        case .emptyPDF(let name): "The PDF has no pages: \(name)"
        case .lockedPDF(let name): "The PDF is locked: \(name)"
        case .protectedPDF(let name): "The PDF permissions do not allow this operation: \(name)"
        case .invalidPageRange(let range, let pageCount):
            range.first == range.last
                ? "Page \(range.first) is outside this \(pageCount)-page PDF."
                : "Pages \(range.first)-\(range.last) are outside this \(pageCount)-page PDF."
        case .malformedPageRange(let text):
            "“\(text)” is not a valid page range. Use one-based ranges such as 1-3, 5, 8-10."
        case .noPagesSelected: "Select at least one page."
        case .sourceCountOutOfRange(let minimum, let maximum, let received):
            received < minimum
                ? "This operation requires at least \(minimum) PDFs; received \(received)."
                : "This operation accepts at most \(maximum) PDFs; received \(received)."
        case .pageLimitExceeded(let pageCount, let limit):
            "The operation contains \(pageCount) pages, exceeding the \(limit)-page limit."
        case .imagePixelLimitExceeded(let page, let pixels, let limit):
            "A rendered page would contain \(pixels) pixels, exceeding the \(limit)-pixel limit (page \(page)). Choose a lower resolution."
        case .invalidImageExportOptions:
            "Choose a resolution between \(PDFImageExportOptions.supportedDPI.lowerBound) and \(PDFImageExportOptions.supportedDPI.upperBound) DPI and a JPEG quality between 0 and 1."
        case .destinationUnavailable(let path): "The destination folder is unavailable or not writable: \(path)"
        case .insufficientSpace(let available, let needed):
            "The destination has \(available) bytes available but the operation needs about \(needed) bytes."
        case .outputWriteFailed(let name): "Could not write the PDF: \(name)"
        case .outputValidationFailed(let name): "The generated PDF failed validation: \(name)"
        case .outputPublicationFailed(let name): "Could not publish the completed PDF: \(name)"
        case .overlappingPageRanges: "Page ranges must not overlap."
        case .invalidSplitParameter: "The split value must be greater than zero and produce at least one file."
        case .invalidRotationSelection: "At least one valid page must be selected for rotation."
        case .cancelled: "Tool operation cancelled"
        }
    }

    public var errorDescription: String? { message }
}
