import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Built-in image tools: rotate, crop, convert, compress, watermark, remove background, images to PDF,
/// and the location-metadata tools.
///
/// Every output is a new sibling copy ("<base>-rotated.jpg"…, keep-both on conflicts); the source is never
/// overwritten. Images are encoded to a hidden ".dirdesk-image-<UUID>.tmp" next to the output, re-read,
/// and only then published. Pixel transforms refuse multi-frame images, images above the pixel budget,
/// and images carrying auxiliary data (depth, mattes, HDR gain maps) that re-encoding would discard.
public struct ImageTransformationService: Sendable {
    public struct Limits: Hashable, Sendable {
        /// Largest stored pixel count accepted.
        public var maximumPixelCount: Int

        public init(maximumPixelCount: Int = 200_000_000) {
            self.maximumPixelCount = maximumPixelCount
        }

        public static let `default` = Limits()
    }

    /// Quality used when a lossy image is re-encoded without a user-chosen quality (rotate, crop, watermark, convert).
    public static let defaultLossyQuality = 0.92

    public var limits: Limits
    public var foregroundMaskGenerator: any ImageForegroundMaskGenerating

    public init(limits: Limits = .default, foregroundMaskGenerator: any ImageForegroundMaskGenerating = VisionForegroundMaskGenerator()) {
        self.limits = limits
        self.foregroundMaskGenerator = foregroundMaskGenerator
    }

    // MARK: - Tools

    /// "Create a rotated copy while preserving image metadata": pixels are rotated and the orientation reset to up.
    @discardableResult
    public func rotate(source: URL, direction: ImageRotationDirection, outputDirectory: URL? = nil) throws -> ImageTransformationResult {
        let image = try load(source, purpose: .transform)
        let target = try sameFormatTarget(for: image)
        let desired = try desiredURL(for: source, suffix: "-rotated", fileExtension: target.fileExtension, outputDirectory: outputDirectory)
        let orientation = ImageToolRendering.compose(image.orientation, then: direction == .right ? .right : .left)
        let pixels = try uprightPixels(decode(image), orientation: orientation, target: target, name: image.name)
        let properties = outputProperties(from: image, width: pixels.width, height: pixels.height, quality: Self.defaultLossyQuality, target: target)
        return try writeOutput(pixels, properties: properties, target: target, desired: desired, source: image)
    }

    /// Crops to `rect` in displayed (orientation-normalized) pixels.
    @discardableResult
    public func crop(source: URL, rect: ImageCropRect, outputDirectory: URL? = nil) throws -> ImageTransformationResult {
        let image = try load(source, purpose: .transform)
        guard rect.width > 0, rect.height > 0, rect.x >= 0, rect.y >= 0,
              rect.width <= image.displayWidth - rect.x, rect.height <= image.displayHeight - rect.y else {
            throw ImageTransformationError.invalidCrop
        }
        let target = try sameFormatTarget(for: image)
        let desired = try desiredURL(for: source, suffix: "-cropped", fileExtension: target.fileExtension, outputDirectory: outputDirectory)
        let area = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        let pixels = try uprightPixels(decode(image), orientation: image.orientation, target: target, name: image.name, crop: area)
        let properties = outputProperties(from: image, width: pixels.width, height: pixels.height, quality: Self.defaultLossyQuality, target: target)
        return try writeOutput(pixels, properties: properties, target: target, desired: desired, source: image)
    }

    /// Writes "<base>-converted.<ext>" in `format`. `quality` (0…1) applies to JPEG and HEIC.
    @discardableResult
    public func convert(source: URL, format: ImageOutputFormat, quality: Double? = nil, outputDirectory: URL? = nil) throws -> ImageTransformationResult {
        if let quality, !(0...1).contains(quality) { throw ImageTransformationError.invalidQuality }
        let image = try load(source, purpose: .transform)
        let prepared = try prepareEncoding(image, format: format, quality: quality ?? Self.defaultLossyQuality, maximumWidth: nil, maximumHeight: nil)
        let desired = try desiredURL(for: source, suffix: "-converted", fileExtension: prepared.target.fileExtension, outputDirectory: outputDirectory)
        return try writeOutput(prepared.image, properties: prepared.properties, target: prepared.target, desired: desired, source: image)
    }

    /// Re-encodes with `options.quality`, optionally bounded to the maximum dimensions, into "<base>-compressed.<ext>".
    @discardableResult
    public func compress(source: URL, options: ImageCompressionOptions, outputDirectory: URL? = nil) throws -> ImageTransformationResult {
        try Self.validate(options)
        let image = try load(source, purpose: .transform)
        let prepared = try prepareEncoding(image, format: options.format, quality: options.quality,
                                           maximumWidth: options.maximumPixelWidth, maximumHeight: options.maximumPixelHeight)
        let desired = try desiredURL(for: source, suffix: "-compressed", fileExtension: prepared.target.fileExtension, outputDirectory: outputDirectory)
        return try writeOutput(prepared.image, properties: prepared.properties, target: prepared.target, desired: desired, source: image)
    }

    /// Encodes in memory exactly as `compress` would, for the "Estimated output" label.
    public func estimateOutputSize(source: URL, options: ImageCompressionOptions) throws -> ImageOutputEstimate {
        try Self.validate(options)
        let image = try load(source, purpose: .transform)
        return try estimate(prepareEncoding(image, format: options.format, quality: options.quality,
                                            maximumWidth: options.maximumPixelWidth, maximumHeight: options.maximumPixelHeight))
    }

    /// Encodes in memory exactly as `convert` would.
    public func estimateOutputSize(source: URL, format: ImageOutputFormat, quality: Double? = nil) throws -> ImageOutputEstimate {
        if let quality, !(0...1).contains(quality) { throw ImageTransformationError.invalidQuality }
        let image = try load(source, purpose: .transform)
        return try estimate(prepareEncoding(image, format: format, quality: quality ?? Self.defaultLossyQuality, maximumWidth: nil, maximumHeight: nil))
    }

    /// Draws centered or tiled text into "<base>-watermarked.<ext>".
    @discardableResult
    public func watermark(source: URL, options: ImageWatermarkOptions, outputDirectory: URL? = nil) throws -> ImageTransformationResult {
        guard options.isValid else { throw ImageTransformationError.invalidWatermark }
        let image = try load(source, purpose: .transform)
        let target = try sameFormatTarget(for: image)
        let desired = try desiredURL(for: source, suffix: "-watermarked", fileExtension: target.fileExtension, outputDirectory: outputDirectory)
        let pixels = try uprightPixels(decode(image), orientation: image.orientation, target: target, name: image.name) { context, size in
            ImageToolRendering.drawWatermark(options, in: context, size: size)
        }
        let properties = outputProperties(from: image, width: pixels.width, height: pixels.height, quality: Self.defaultLossyQuality, target: target)
        return try writeOutput(pixels, properties: properties, target: target, desired: desired, source: image)
    }

    /// The watermark drawn on an upright `image`, for the live preview (pass a downscaled first image).
    public static func renderWatermark(_ options: ImageWatermarkOptions, on image: CGImage) -> CGImage? {
        guard options.isValid else { return nil }
        return ImageToolRendering.render(image, orientation: .up) { context, size in
            ImageToolRendering.drawWatermark(options, in: context, size: size)
        }
    }

    /// Lifts the detected subjects onto a transparent background: "<base>-background-removed.png".
    @discardableResult
    public func removeBackground(source: URL, outputDirectory: URL? = nil) throws -> ImageTransformationResult {
        let image = try load(source, purpose: .transform)
        let target = try outputTarget(for: .png, source: image)
        let desired = try desiredURL(for: source, suffix: "-background-removed", fileExtension: target.fileExtension, outputDirectory: outputDirectory)
        let upright = try uprightPixels(decode(image), orientation: image.orientation, target: target, name: image.name)
        guard let mask = try foregroundMaskGenerator.foregroundMask(for: upright) else { throw ImageTransformationError.noForegroundSubject }
        guard let cutout = Self.applyMask(mask, to: upright) else { throw ImageTransformationError.outputWriteFailed(desired.lastPathComponent) }
        let properties = outputProperties(from: image, width: cutout.width, height: cutout.height, quality: nil, target: target)
        return try writeOutput(cutout, properties: properties, target: target, desired: desired, source: image)
    }

    /// `CIBlendWithMask` of `image` over a clear background; the mask is stretched to the image if its size differs.
    static func applyMask(_ mask: CIImage, to image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        var scaledMask = mask
        if mask.extent.size != extent.size, mask.extent.width > 0, mask.extent.height > 0, !mask.extent.isInfinite {
            scaledMask = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY)
                .concatenating(CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height)))
        }
        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIImage(color: .clear).cropped(to: extent), forKey: kCIInputBackgroundImageKey)
        filter.setValue(scaledMask, forKey: kCIInputMaskImageKey)
        guard let output = filter.outputImage,
              let space = image.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // No working color space: pixel values pass through unchanged and are tagged with the source's RGB space.
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        return context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: space)
    }

    // MARK: - Loading and guards

    enum Purpose {
        /// Re-encodes pixels: one frame, pixel budget, no auxiliary images.
        case transform
        /// Draws into a PDF page: one frame, pixel budget.
        case pdfPage
        /// Copies the encoded data with new metadata: pixel budget only.
        case copy
        /// Reads properties only.
        case inspect
    }

    struct LoadedImage {
        var url: URL
        var source: CGImageSource
        var typeIdentifier: String
        var properties: [CFString: Any]
        var pixelWidth: Int
        var pixelHeight: Int
        var orientation: CGImagePropertyOrientation
        var frameCount: Int
        var byteCount: Int64

        var name: String { url.lastPathComponent }
        var displayWidth: Int { ImageToolRendering.swapsDimensions(orientation) ? pixelHeight : pixelWidth }
        var displayHeight: Int { ImageToolRendering.swapsDimensions(orientation) ? pixelWidth : pixelHeight }
    }

    func load(_ url: URL, purpose: Purpose) throws -> LoadedImage {
        let name = url.lastPathComponent
        guard ToolOutputSupport.isReadableFile(url) else { throw ImageTransformationError.sourceUnavailable(name) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String? else {
            throw ImageTransformationError.unsupportedOrDamaged(name)
        }
        guard let utType = UTType(type), utType.conforms(to: .image) else { throw ImageTransformationError.unsupportedSourceFormat(type) }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount >= 1, CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            throw ImageTransformationError.unsupportedOrDamaged(name)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        let image = LoadedImage(url: url, source: source, typeIdentifier: type, properties: properties, pixelWidth: width,
                                pixelHeight: height, orientation: orientation, frameCount: frameCount,
                                byteCount: ToolOutputSupport.byteCount(of: url))
        guard purpose != .inspect else { return image }
        if frameCount > 1 && purpose != .copy { throw ImageTransformationError.unsupportedFrameCount(frameCount) }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        if overflow || pixels > limits.maximumPixelCount {
            throw ImageTransformationError.pixelBudgetExceeded(pixels: overflow ? .max : pixels, limit: limits.maximumPixelCount)
        }
        if purpose == .transform {
            let auxiliary = Self.auxiliaryDataKinds(in: source)
            if !auxiliary.isEmpty { throw ImageTransformationError.unsupportedAuxiliaryData(auxiliary) }
        }
        return image
    }

    private static var auxiliaryDataTypes: [(type: CFString, name: String)] {
        [
            (kCGImageAuxiliaryDataTypeDepth, "depth"),
            (kCGImageAuxiliaryDataTypeDisparity, "disparity"),
            (kCGImageAuxiliaryDataTypePortraitEffectsMatte, "portrait effects matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, "skin matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte, "hair matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, "teeth matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte, "glasses matte"),
            (kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte, "sky matte"),
            (kCGImageAuxiliaryDataTypeHDRGainMap, "HDR gain map"),
            (kCGImageAuxiliaryDataTypeISOGainMap, "HDR gain map"),
        ]
    }

    /// Names of the auxiliary images stored with the first image (depth, mattes, gain maps).
    static func auxiliaryDataKinds(in source: CGImageSource) -> [String] {
        var kinds: [String] = []
        for entry in auxiliaryDataTypes where !kinds.contains(entry.name) {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, entry.type) != nil { kinds.append(entry.name) }
        }
        return kinds
    }

    func decode(_ image: LoadedImage) throws -> CGImage {
        guard let decoded = CGImageSourceCreateImageAtIndex(image.source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ImageTransformationError.unsupportedOrDamaged(image.name)
        }
        return decoded
    }

    static func validate(_ options: ImageCompressionOptions) throws {
        guard (0...1).contains(options.quality) else { throw ImageTransformationError.invalidQuality }
        if let width = options.maximumPixelWidth, width <= 0 { throw ImageTransformationError.invalidMaximumDimensions }
        if let height = options.maximumPixelHeight, height <= 0 { throw ImageTransformationError.invalidMaximumDimensions }
    }

    // MARK: - Output formats

    struct OutputTarget {
        var typeIdentifier: String
        var fileExtension: String

        var supportsAlpha: Bool { typeIdentifier != UTType.jpeg.identifier }
        var usesLossyQuality: Bool { ImageTransformationService.lossyTypeIdentifiers.contains(typeIdentifier) }
    }

    static let lossyTypeIdentifiers: Set<String> = [
        "public.jpeg", "public.heic", "public.heif", "public.jpeg-2000", "org.webmproject.webp", "public.avif", "public.avci",
    ]

    static var writableTypeIdentifiers: Set<String> {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }

    /// The source's own format, keeping its extension spelling, when ImageIO can write it.
    func sameFormatTarget(for image: LoadedImage) throws -> OutputTarget {
        guard Self.writableTypeIdentifiers.contains(image.typeIdentifier) else {
            throw ImageTransformationError.unsupportedDestinationFormat(UTType(image.typeIdentifier)?.localizedDescription ?? image.typeIdentifier)
        }
        let ext = image.url.pathExtension.isEmpty ? (UTType(image.typeIdentifier)?.preferredFilenameExtension ?? "") : image.url.pathExtension
        return OutputTarget(typeIdentifier: image.typeIdentifier, fileExtension: ext)
    }

    func outputTarget(for format: ImageOutputFormat, source: LoadedImage) throws -> OutputTarget {
        guard Self.writableTypeIdentifiers.contains(format.typeIdentifier) else {
            throw ImageTransformationError.unsupportedDestinationFormat(format.displayName)
        }
        let keepsSpelling = format.typeIdentifier == source.typeIdentifier && !source.url.pathExtension.isEmpty
        return OutputTarget(typeIdentifier: format.typeIdentifier, fileExtension: keepsSpelling ? source.url.pathExtension : format.fileExtension)
    }

    struct PreparedEncoding {
        var image: CGImage
        var target: OutputTarget
        var properties: [CFString: Any]
    }

    /// Upright pixels in the target format, downscaled with ImageIO's thumbnailer when maximum dimensions apply.
    func prepareEncoding(_ image: LoadedImage, format: ImageOutputFormat?, quality: Double, maximumWidth: Int?,
                         maximumHeight: Int?) throws -> PreparedEncoding {
        let target = try format.map { try outputTarget(for: $0, source: image) } ?? sameFormatTarget(for: image)
        var scale = 1.0
        if let maximumWidth { scale = min(scale, Double(maximumWidth) / Double(image.displayWidth)) }
        if let maximumHeight { scale = min(scale, Double(maximumHeight) / Double(image.displayHeight)) }
        let pixels: CGImage
        if scale < 1 {
            let longestEdge = Double(max(image.displayWidth, image.displayHeight)) * scale
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(longestEdge.rounded(.down))),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image.source, 0, options as CFDictionary) else {
                throw ImageTransformationError.unsupportedOrDamaged(image.name)
            }
            pixels = try uprightPixels(thumbnail, orientation: .up, target: target, name: image.name)
        } else {
            pixels = try uprightPixels(decode(image), orientation: image.orientation, target: target, name: image.name)
        }
        let properties = outputProperties(from: image, width: pixels.width, height: pixels.height, quality: quality, target: target)
        return PreparedEncoding(image: pixels, target: target, properties: properties)
    }

    private func estimate(_ prepared: PreparedEncoding) throws -> ImageOutputEstimate {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, prepared.target.typeIdentifier as CFString, 1, nil) else {
            throw ImageTransformationError.unsupportedDestinationFormat(prepared.target.typeIdentifier)
        }
        CGImageDestinationAddImage(destination, prepared.image, prepared.properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageTransformationError.outputWriteFailed(prepared.target.typeIdentifier) }
        return ImageOutputEstimate(byteCount: Int64(data.length), pixelWidth: prepared.image.width, pixelHeight: prepared.image.height,
                                   typeIdentifier: prepared.target.typeIdentifier)
    }

    private static var opaqueBackground: CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }

    /// `image` drawn upright (optionally cropped and decorated); flattened onto white for formats without alpha.
    func uprightPixels(_ image: CGImage, orientation: CGImagePropertyOrientation, target: OutputTarget, name: String,
                       crop: CGRect? = nil, decorate: ((CGContext, CGSize) -> Void)? = nil) throws -> CGImage {
        let flatten = !target.supportsAlpha && ImageToolRendering.hasAlpha(image)
        if orientation == .up && crop == nil && decorate == nil && !flatten { return image }
        guard let rendered = ImageToolRendering.render(image, orientation: orientation, crop: crop,
                                                       flattenOnto: flatten ? Self.opaqueBackground : nil, decorate: decorate) else {
            throw ImageTransformationError.unsupportedOrDamaged(name)
        }
        return rendered
    }

    /// Metadata carried into a re-encoded image: EXIF, TIFF, GPS, IPTC, ExifAux and resolution, with the
    /// orientation reset to up (pixels are written upright) and the EXIF pixel size updated.
    func outputProperties(from image: LoadedImage, width: Int, height: Int, quality: Double?, target: OutputTarget) -> [CFString: Any] {
        let carried = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyTIFFDictionary,
                       kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight]
        var properties: [CFString: Any] = [:]
        for key in carried {
            if let value = image.properties[key] { properties[key] = value }
        }
        properties[kCGImagePropertyOrientation] = 1
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
                    kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength] {
            tiff.removeValue(forKey: key)
        }
        tiff[kCGImagePropertyTIFFOrientation] = 1
        if target.typeIdentifier == UTType.tiff.identifier { tiff[kCGImagePropertyTIFFCompression] = 5 } // LZW
        properties[kCGImagePropertyTIFFDictionary] = tiff
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if target.usesLossyQuality, let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        return properties
    }

    // MARK: - Writing

    /// "<base><suffix>.<ext>" in `outputDirectory` (default: the source's folder), which must be writable.
    func desiredURL(for source: URL, suffix: String, fileExtension: String, outputDirectory: URL?) throws -> URL {
        let directory = outputDirectory ?? source.deletingLastPathComponent()
        guard ToolOutputSupport.isWritableDirectory(directory) else { throw ImageTransformationError.destinationNotWritable(directory.path) }
        let base = source.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(ToolOutputSupport.fileName(base: base, suffix: suffix, extension: fileExtension))
    }

    static func stagingURL(next desired: URL) -> URL {
        desired.deletingLastPathComponent().appendingPathComponent(".dirdesk-image-\(UUID().uuidString).tmp")
    }

    /// Encodes into the staging file, then validates and publishes it.
    func writeOutput(_ pixels: CGImage, properties: [CFString: Any], target: OutputTarget, desired: URL,
                     source: LoadedImage) throws -> ImageTransformationResult {
        let staged = Self.stagingURL(next: desired)
        guard let destination = CGImageDestinationCreateWithURL(staged as CFURL, target.typeIdentifier as CFString, 1, nil) else {
            throw ImageTransformationError.unsupportedDestinationFormat(target.typeIdentifier)
        }
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            ToolOutputSupport.removeIfPresent(staged)
            throw ImageTransformationError.outputWriteFailed(desired.lastPathComponent)
        }
        return try publish(staged, desired: desired, source: source, typeIdentifier: target.typeIdentifier,
                           expectedPixelWidth: pixels.width, expectedPixelHeight: pixels.height)
    }

    /// Re-reads the staged file (stored size must match), then moves it to the keep-both name of `desired`.
    func publish(_ staged: URL, desired: URL, source: LoadedImage, typeIdentifier: String, expectedPixelWidth: Int,
                 expectedPixelHeight: Int) throws -> ImageTransformationResult {
        guard let written = Self.storedSize(of: staged), written.width == expectedPixelWidth, written.height == expectedPixelHeight else {
            ToolOutputSupport.removeIfPresent(staged)
            throw ImageTransformationError.outputWriteFailed(desired.lastPathComponent)
        }
        guard desired.standardizedFileURL.path != source.url.standardizedFileURL.path else {
            ToolOutputSupport.removeIfPresent(staged)
            throw ImageTransformationError.destinationMatchesSource
        }
        let output: URL
        do {
            output = try ToolOutputSupport.publish(staged, as: desired)
        } catch {
            ToolOutputSupport.removeIfPresent(staged)
            throw ImageTransformationError.outputWriteFailed(desired.lastPathComponent)
        }
        let swaps = ImageToolRendering.swapsDimensions(written.orientation)
        return ImageTransformationResult(
            source: source.url, output: output, typeIdentifier: typeIdentifier,
            originalByteCount: source.byteCount, outputByteCount: ToolOutputSupport.byteCount(of: output),
            originalPixelWidth: source.displayWidth, originalPixelHeight: source.displayHeight,
            outputPixelWidth: swaps ? written.height : written.width, outputPixelHeight: swaps ? written.width : written.height)
    }

    static func storedSize(of url: URL) -> (width: Int, height: Int, orientation: CGImagePropertyOrientation)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        return (width, height, orientation)
    }
}
