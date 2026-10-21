import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageOutputFormat: String, Codable, CaseIterable, Sendable {
    case jpeg, png, heic, tiff

    public var typeIdentifier: String {
        switch self {
        case .jpeg: UTType.jpeg.identifier
        case .png: UTType.png.identifier
        case .heic: UTType.heic.identifier
        case .tiff: UTType.tiff.identifier
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }

    /// "JPEG", "PNG", "HEIC", "TIFF".
    public var displayName: String { rawValue.uppercased() }

    /// JPEG and HEIC take a 0…1 quality; PNG and TIFF are lossless.
    public var usesLossyQuality: Bool { self == .jpeg || self == .heic }

    public init?(typeIdentifier: String) {
        guard let format = Self.allCases.first(where: { $0.typeIdentifier == typeIdentifier }) else { return nil }
        self = format
    }
}

public enum ImageRotationDirection: String, Codable, CaseIterable, Sendable {
    /// 90° counterclockwise.
    case left
    /// 90° clockwise.
    case right
}

/// Crop rectangle in orientation-normalized pixels: the origin is the top-left corner of the image as displayed.
public struct ImageCropRect: Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct ImageCompressionOptions: Hashable, Codable, Sendable {
    /// nil keeps the source format.
    public var format: ImageOutputFormat?
    /// 0…1; ignored by lossless formats.
    public var quality: Double
    /// Optional bounds in displayed pixels; the aspect ratio is kept and images are never enlarged.
    public var maximumPixelWidth: Int?
    public var maximumPixelHeight: Int?

    public init(format: ImageOutputFormat? = nil, quality: Double = 0.8, maximumPixelWidth: Int? = nil, maximumPixelHeight: Int? = nil) {
        self.format = format
        self.quality = quality
        self.maximumPixelWidth = maximumPixelWidth
        self.maximumPixelHeight = maximumPixelHeight
    }
}

public enum ImageWatermarkLayout: String, Codable, CaseIterable, Sendable {
    case centered, tiled
}

/// sRGB components, 0…1.
public struct ImageWatermarkColor: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = ImageWatermarkColor(red: 1, green: 1, blue: 1)
    public static let black = ImageWatermarkColor(red: 0, green: 0, blue: 0)
    public static let gray = ImageWatermarkColor(red: 0.5, green: 0.5, blue: 0.5)
}

public struct ImageWatermarkOptions: Hashable, Codable, Sendable {
    public var text: String
    public var layout: ImageWatermarkLayout
    /// Counterclockwise rotation of the text.
    public var angleDegrees: Double
    /// 0…1 (0 is invisible and therefore rejected).
    public var opacity: Double
    /// Text size as a fraction of the shorter image edge.
    public var relativeFontSize: Double
    /// Gap between tiles as a fraction of the shorter image edge (tiled layout).
    public var relativeSpacing: Double
    public var color: ImageWatermarkColor

    /// The defaults are the reference sheet's: tiled white text at -30°, 28 % opacity, 5 % size and 12 % spacing.
    public init(text: String, layout: ImageWatermarkLayout = .tiled, angleDegrees: Double = -30, opacity: Double = 0.28,
                relativeFontSize: Double = 0.05, relativeSpacing: Double = 0.12, color: ImageWatermarkColor = .white) {
        self.text = text
        self.layout = layout
        self.angleDegrees = angleDegrees
        self.opacity = opacity
        self.relativeFontSize = relativeFontSize
        self.relativeSpacing = relativeSpacing
        self.color = color
    }

    public var isValid: Bool {
        let components = [color.red, color.green, color.blue]
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && angleDegrees.isFinite
            && opacity > 0 && opacity <= 1
            && relativeFontSize >= 0.005 && relativeFontSize <= 1
            && relativeSpacing >= 0 && relativeSpacing <= 2
            && components.allSatisfy { $0 >= 0 && $0 <= 1 }
    }
}

public enum ImagePDFPaperSize: String, Codable, CaseIterable, Sendable {
    /// Each page matches its image.
    case original
    case a4Portrait, a4Landscape, letterPortrait, letterLandscape

    /// Page size in points; nil for `.original`.
    public var pointSize: CGSize? {
        let a4 = CGSize(width: 595.2756, height: 841.8898)
        let letter = CGSize(width: 612, height: 792)
        switch self {
        case .original: return nil
        case .a4Portrait: return a4
        case .a4Landscape: return CGSize(width: a4.height, height: a4.width)
        case .letterPortrait: return letter
        case .letterLandscape: return CGSize(width: letter.height, height: letter.width)
        }
    }
}

public struct ImagePDFOptions: Hashable, Codable, Sendable {
    public var paperSize: ImagePDFPaperSize
    /// Scale images down to fit the paper; without it images keep their natural size, centered and clipped.
    public var fitToPage: Bool
    /// With `fitToPage`, also enlarge images smaller than the paper.
    public var allowUpscaling: Bool

    public init(paperSize: ImagePDFPaperSize = .original, fitToPage: Bool = true, allowUpscaling: Bool = false) {
        self.paperSize = paperSize
        self.fitToPage = fitToPage
        self.allowUpscaling = allowUpscaling
    }
}

public struct PhotoLocationMetadata: Hashable, Codable, Sendable {
    /// Degrees, negative south of the equator.
    public var latitude: Double
    /// Degrees, negative west of Greenwich.
    public var longitude: Double
    /// Meters, negative below sea level.
    public var altitude: Double?
    /// GPS date and time (UTC).
    public var timestamp: Date?
    /// Meters.
    public var horizontalPositioningError: Double?
    /// Degrees.
    public var imageDirection: Double?
    /// Kilometers per hour (converted from the recorded unit).
    public var speed: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, timestamp: Date? = nil,
                horizontalPositioningError: Double? = nil, imageDirection: Double? = nil, speed: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
        self.horizontalPositioningError = horizontalPositioningError
        self.imageDirection = imageDirection
        self.speed = speed
    }

    /// "30.658600, 104.064800" for Copy Coordinates.
    public var coordinateText: String {
        String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
    }

    /// Opens Apple Maps at the coordinate; nothing is looked up over the network by DirDesk itself.
    public var mapsURL: URL {
        let ll = String(format: "%.6f,%.6f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
        return URL(string: "https://maps.apple.com/?ll=\(ll)")!
    }
}

public struct ImageMetadata: Hashable, Sendable {
    /// Stored pixel size (before EXIF orientation is applied).
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// "RGB", "Gray", "CMYK" or "Lab".
    public var colorModel: String?
    public var orientation: CGImagePropertyOrientation?
    public var cameraMake: String?
    public var cameraModel: String?
    public var capturedAt: Date?
    public var containsGPS: Bool
    public var typeIdentifier: String
    public var frameCount: Int
    public var hasAlpha: Bool
    public var byteCount: Int64

    /// Size as displayed, after the orientation; crop rectangles use this space.
    public var orientedPixelWidth: Int { swapsDimensions ? pixelHeight : pixelWidth }
    public var orientedPixelHeight: Int { swapsDimensions ? pixelWidth : pixelHeight }

    private var swapsDimensions: Bool {
        guard let orientation else { return false }
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: return true
        default: return false
        }
    }
}

public struct ImageTransformationResult: Hashable, Sendable {
    public var source: URL
    public var output: URL
    public var typeIdentifier: String
    public var originalByteCount: Int64
    public var outputByteCount: Int64
    /// Sizes as displayed (after orientation).
    public var originalPixelWidth: Int
    public var originalPixelHeight: Int
    public var outputPixelWidth: Int
    public var outputPixelHeight: Int
}

/// In-memory encoding result for the "Estimated output" label.
public struct ImageOutputEstimate: Hashable, Sendable {
    public var byteCount: Int64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var typeIdentifier: String
}

public enum ImageTransformationError: Error, Equatable, Sendable, LocalizedError {
    case sourceUnavailable(String)
    case unsupportedOrDamaged(String)
    case unsupportedFrameCount(Int)
    case unsupportedAuxiliaryData([String])
    case unsupportedSourceFormat(String)
    case unsupportedDestinationFormat(String)
    case invalidCrop
    case invalidQuality
    case pixelBudgetExceeded(pixels: Int, limit: Int)
    case destinationExists(String)
    case destinationNotWritable(String)
    case invalidMaximumDimensions
    case invalidWatermark
    case destinationMatchesSource
    case noForegroundSubject
    case foregroundDetectionFailed(String)
    case locationUnavailable
    case pdfCreationFailed(String)
    case emptySelection
    case outputWriteFailed(String)
    case cancelled

    public var message: String {
        switch self {
        case .sourceUnavailable(let name): "The source image is missing or unreadable: \(name)"
        case .unsupportedOrDamaged(let name): "The image is unsupported or damaged: \(name)"
        case .unsupportedFrameCount(let count): "This operation does not support images with \(count) frames."
        case .unsupportedAuxiliaryData(let kinds): "This operation would discard unsupported image data: \(kinds.joined(separator: ", "))."
        case .unsupportedSourceFormat: "The source image format is not supported."
        case .unsupportedDestinationFormat(let format): "The destination format is unavailable: \(format)"
        case .invalidCrop: "The crop rectangle is outside the image."
        case .invalidQuality: "Image quality must be between 0 and 1."
        case .pixelBudgetExceeded(let pixels, let limit): "The image has \(pixels) pixels, above the safe limit of \(limit)."
        case .destinationExists(let name): "An item named “\(name)” already exists."
        case .destinationNotWritable(let path): "The destination folder is not writable: \(path)"
        case .invalidMaximumDimensions: "Maximum image dimensions must be positive."
        case .invalidWatermark: "Watermark text and settings are invalid."
        case .destinationMatchesSource: "Image tools create a new file and cannot replace the source."
        case .noForegroundSubject: "No suitable foreground subject was detected."
        case .foregroundDetectionFailed(let detail): "Subject detection is unavailable: \(detail)"
        case .locationUnavailable: "The image does not contain readable location metadata."
        case .pdfCreationFailed: "The PDF could not be created."
        case .emptySelection: "Select at least one item."
        case .outputWriteFailed(let name): "Could not write the image: \(name)"
        case .cancelled: "Tool operation cancelled"
        }
    }

    public var errorDescription: String? { message }
}
