import CoreGraphics
import Foundation
import ImageIO

extension ImageTransformationService {
    // MARK: - Reading

    public func metadata(source: URL) throws -> ImageMetadata {
        let image = try load(source, purpose: .inspect)
        let properties = image.properties
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        return ImageMetadata(
            pixelWidth: image.pixelWidth,
            pixelHeight: image.pixelHeight,
            colorModel: properties[kCGImagePropertyColorModel] as? String,
            orientation: (properties[kCGImagePropertyOrientation] as? NSNumber).flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) },
            cameraMake: Self.text(tiff?[kCGImagePropertyTIFFMake]),
            cameraModel: Self.text(tiff?[kCGImagePropertyTIFFModel]),
            capturedAt: Self.captureDate(exif: exif, tiff: tiff),
            containsGPS: !(gps?.isEmpty ?? true),
            typeIdentifier: image.typeIdentifier,
            frameCount: image.frameCount,
            hasAlpha: (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false,
            byteCount: image.byteCount)
    }

    /// The embedded GPS position, or nil when the image has none. Read-only; nothing is looked up online.
    public func photoLocation(source: URL) throws -> PhotoLocationMetadata? {
        Self.location(from: try load(source, purpose: .inspect).properties)
    }

    static func location(from properties: [CFString: Any]) -> PhotoLocationMetadata? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              var latitude = number(gps[kCGImagePropertyGPSLatitude]),
              var longitude = number(gps[kCGImagePropertyGPSLongitude]) else { return nil }
        if text(gps[kCGImagePropertyGPSLatitudeRef])?.uppercased().hasPrefix("S") == true { latitude = -abs(latitude) }
        if text(gps[kCGImagePropertyGPSLongitudeRef])?.uppercased().hasPrefix("W") == true { longitude = -abs(longitude) }
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        var altitude = number(gps[kCGImagePropertyGPSAltitude])
        if let value = altitude, number(gps[kCGImagePropertyGPSAltitudeRef]) == 1 { altitude = -abs(value) }
        var speed = number(gps[kCGImagePropertyGPSSpeed])
        if let value = speed {
            switch text(gps[kCGImagePropertyGPSSpeedRef])?.uppercased() {
            case "M": speed = value * 1.609344
            case "N": speed = value * 1.852
            default: break
            }
        }
        return PhotoLocationMetadata(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            timestamp: gpsDate(dateStamp: text(gps[kCGImagePropertyGPSDateStamp]), timeStamp: gps[kCGImagePropertyGPSTimeStamp]),
            horizontalPositioningError: number(gps[kCGImagePropertyGPSHPositioningError]),
            imageDirection: number(gps[kCGImagePropertyGPSImgDirection]),
            speed: speed)
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// GPS DateStamp "yyyy:MM:dd" plus TimeStamp "HH:mm:ss(.SS)", both UTC.
    static func gpsDate(dateStamp: String?, timeStamp: Any?) -> Date? {
        guard let dateStamp else { return nil }
        let day = dateStamp.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { Int($0) }
        guard day.count == 3 else { return nil }
        var components = DateComponents(year: day[0], month: day[1], day: day[2], hour: 0, minute: 0, second: 0)
        if let time = timeStamp as? String {
            let parts = time.split(separator: ":").compactMap { Double($0) }
            if parts.count == 3 {
                components.hour = Int(parts[0])
                components.minute = Int(parts[1])
                components.second = Int(parts[2])
                components.nanosecond = Int((parts[2] - parts[2].rounded(.down)) * 1_000_000_000)
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)
    }

    /// EXIF DateTimeOriginal (with OffsetTimeOriginal when present, else the local time zone), then TIFF DateTime.
    static func captureDate(exif: [CFString: Any]?, tiff: [CFString: Any]?) -> Date? {
        let candidates: [(String?, String?)] = [
            (text(exif?[kCGImagePropertyExifDateTimeOriginal]), text(exif?[kCGImagePropertyExifOffsetTimeOriginal])),
            (text(exif?[kCGImagePropertyExifDateTimeDigitized]), text(exif?[kCGImagePropertyExifOffsetTimeDigitized])),
            (text(tiff?[kCGImagePropertyTIFFDateTime]), text(exif?[kCGImagePropertyExifOffsetTime])),
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        for (stamp, offset) in candidates {
            guard let stamp else { continue }
            if let offset {
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
                if let date = formatter.date(from: stamp + offset) { return date }
            }
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.timeZone = .current
            if let date = formatter.date(from: stamp) { return date }
        }
        return nil
    }

    // MARK: - Removing location metadata

    /// "Create copies with embedded location metadata removed" into "<base>-location-removed.<ext>": drops
    /// GPS, the XMP packet, IPTC, ExifAux and maker notes while keeping the EXIF and TIFF fields. The encoded
    /// image data is copied unchanged when ImageIO supports that for the format (JPEG, HEIC, TIFF); otherwise
    /// the pixels are re-encoded, losslessly for PNG and TIFF. ImageIO mirrors some kept EXIF values (dates,
    /// artist, copyright, description) into a fresh IPTC block; every other IPTC field is gone.
    @discardableResult
    public func removeLocationMetadata(source: URL, outputDirectory: URL? = nil) throws -> ImageTransformationResult {
        let image = try load(source, purpose: .copy)
        let target = try sameFormatTarget(for: image)
        let desired = try desiredURL(for: source, suffix: "-location-removed", fileExtension: target.fileExtension, outputDirectory: outputDirectory)
        let staged = Self.stagingURL(next: desired)
        if !(Self.copyWithoutPrivateMetadata(image, to: staged) && Self.isFreeOfPrivateMetadata(staged)) {
            ToolOutputSupport.removeIfPresent(staged)
            guard image.frameCount == 1 else { throw ImageTransformationError.unsupportedFrameCount(image.frameCount) }
            let auxiliary = Self.auxiliaryDataKinds(in: image.source)
            guard auxiliary.isEmpty else { throw ImageTransformationError.unsupportedAuxiliaryData(auxiliary) }
            var properties = Self.privacyCleanedProperties(image.properties)
            if target.usesLossyQuality { properties[kCGImageDestinationLossyCompressionQuality] = 1.0 }
            guard let destination = CGImageDestinationCreateWithURL(staged as CFURL, target.typeIdentifier as CFString, 1, nil) else {
                throw ImageTransformationError.unsupportedDestinationFormat(target.typeIdentifier)
            }
            CGImageDestinationAddImage(destination, try decode(image), properties as CFDictionary)
            guard CGImageDestinationFinalize(destination), Self.isFreeOfPrivateMetadata(staged) else {
                ToolOutputSupport.removeIfPresent(staged)
                throw ImageTransformationError.outputWriteFailed(desired.lastPathComponent)
            }
        }
        return try publish(staged, desired: desired, source: image, typeIdentifier: target.typeIdentifier,
                           expectedPixelWidth: image.pixelWidth, expectedPixelHeight: image.pixelHeight)
    }

    /// Tags kept when the metadata is replaced: everything ImageIO maps to EXIF and TIFF fields (it keeps
    /// DateTimeOriginal as photoshop:DateCreated, DateTimeDigitized and DateTime as xmp:CreateDate and
    /// xmp:ModifyDate, Software as xmp:CreatorTool, Artist, Copyright and ImageDescription in dc:), minus GPS.
    private static func isRetainedTag(namespace: String, name: String) -> Bool {
        if name.hasPrefix("GPS") || name == "MakerNote" { return false }
        let retained: [CFString: Set<String>?] = [
            kCGImageMetadataNamespaceExif: nil,
            kCGImageMetadataNamespaceTIFF: nil,
            kCGImageMetadataNamespaceExifEX: nil,
            kCGImageMetadataNamespacePhotoshop: ["DateCreated"],
            kCGImageMetadataNamespaceXMPBasic: ["CreateDate", "ModifyDate", "CreatorTool"],
            kCGImageMetadataNamespaceDublinCore: ["creator", "rights", "description"],
        ]
        guard let names = retained[namespace as CFString] else { return false }
        return names?.contains(name) ?? true
    }

    /// IPTC fields ImageIO regenerates from the retained EXIF and TIFF values. Any other IPTC field (city,
    /// keywords, contact details…) means private data survived.
    private static var mirroredIPTCKeys: Set<String> {
        Set([kCGImagePropertyIPTCDateCreated, kCGImagePropertyIPTCTimeCreated, kCGImagePropertyIPTCDigitalCreationDate,
             kCGImagePropertyIPTCDigitalCreationTime, kCGImagePropertyIPTCByline, kCGImagePropertyIPTCCopyrightNotice,
             kCGImagePropertyIPTCCaptionAbstract, kCGImagePropertyIPTCOriginatingProgram, kCGImagePropertyIPTCProgramVersion].map { $0 as String })
    }

    /// XMP tags that place or identify where a photo was taken: GPS fields in any namespace, maker notes,
    /// IPTC Core and Extension (locations, contact addresses), ExifAux, and Photoshop's City/State/Country.
    /// Other XMP, such as `photoshop:DateCreated` that ImageIO derives from EXIF in PNG files, is allowed.
    private static func isPrivateTag(namespace: String, name: String) -> Bool {
        if name.hasPrefix("GPS") || name == "MakerNote" { return true }
        let privateNamespaces = [kCGImageMetadataNamespaceIPTCCore as String, kCGImageMetadataNamespaceIPTCExtension as String,
                                 kCGImageMetadataNamespaceExifAux as String]
        if privateNamespaces.contains(namespace) { return true }
        return namespace == kCGImageMetadataNamespacePhotoshop as String && ["City", "State", "Country"].contains(name)
    }

    private static var privateDictionaries: [CFString] {
        [kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary,
         kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
         kCGImagePropertyMakerMinoltaDictionary, kCGImagePropertyMakerFujiDictionary, kCGImagePropertyMakerOlympusDictionary,
         kCGImagePropertyMakerPentaxDictionary]
    }

    /// Copies every frame's encoded data and replaces the metadata with its EXIF and TIFF tags (no GPS,
    /// maker notes, IPTC or ExifAux), writing no XMP packet.
    static func copyWithoutPrivateMetadata(_ image: LoadedImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, image.typeIdentifier as CFString, image.frameCount, nil) else {
            return false
        }
        let metadata: CGImageMetadata = CGImageSourceCopyMetadataAtIndex(image.source, 0, nil).flatMap(privacyCleanedMetadata)
            ?? CGImageMetadataCreateMutable()
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        return CGImageDestinationCopyImageSource(destination, image.source, options as CFDictionary, nil)
    }

    static func privacyCleanedMetadata(_ metadata: CGImageMetadata) -> CGImageMetadata? {
        guard let cleaned = CGImageMetadataCreateMutableCopy(metadata) else { return nil }
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let namespace = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            if !isRetainedTag(namespace: namespace, name: name) {
                CGImageMetadataRemoveTagWithPath(cleaned, nil, path)
            }
            return true
        }
        return cleaned
    }

    /// Properties for the re-encoding fallback: EXIF, TIFF, orientation and resolution only.
    static func privacyCleanedProperties(_ properties: [CFString: Any]) -> [CFString: Any] {
        var cleaned: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyOrientation,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = properties[key] { cleaned[key] = value }
        }
        return cleaned
    }

    /// True when the written file has no GPS, ExifAux or maker-note data, no IPTC beyond the mirrored EXIF
    /// fields, and no private XMP tags.
    /// Checked after every write because `CGImageDestinationCopyImageSource` can leave GPS tags in some
    /// formats (PNG keeps them as XMP).
    static func isFreeOfPrivateMetadata(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        for key in privateDictionaries {
            if let dictionary = properties[key] as? [CFString: Any], !dictionary.isEmpty { return false }
        }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           !Set(iptc.keys.map { $0 as String }).isSubset(of: mirroredIPTCKeys) {
            return false
        }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return true }
        var clean = true
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            let namespace = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            if isPrivateTag(namespace: namespace, name: name) { clean = false }
            return clean
        }
        return clean
    }
}
