import CoreGraphics
import Foundation
import ImageIO

extension ImageTransformationService {
    /// Largest page edge written (the PDF implementation limit of 200 inches).
    static let maximumPageEdge: CGFloat = 14_400

    /// "Create a PDF using the visible selection order": one page per image, in the order of `sources`,
    /// written to "<first image's base name>-created.pdf" (keep-both). With `.original` paper each page has the
    /// image's own size at its stored resolution (72 DPI when none); other paper sizes center the image,
    /// scaling it down to fit (and up when `allowUpscaling`) with `fitToPage`, or clipping its natural size without.
    @discardableResult
    public func createPDF(sources: [URL], options: ImagePDFOptions = ImagePDFOptions(), outputDirectory: URL,
                          isCancelled: () -> Bool = { false }) throws -> URL {
        guard let first = sources.first else { throw ImageTransformationError.emptySelection }
        guard ToolOutputSupport.isWritableDirectory(outputDirectory) else {
            throw ImageTransformationError.destinationNotWritable(outputDirectory.path)
        }
        let images = try sources.map { try load($0, purpose: .pdfPage) }
        let desired = outputDirectory.appendingPathComponent(
            ToolOutputSupport.fileName(base: first.deletingPathExtension().lastPathComponent, suffix: "-created", extension: "pdf"))
        let staged = Self.stagingURL(next: desired)
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(staged as CFURL, mediaBox: &defaultBox, [kCGPDFContextCreator: "Wumi"] as CFDictionary) else {
            throw ImageTransformationError.pdfCreationFailed(desired.lastPathComponent)
        }
        do {
            for image in images {
                if isCancelled() { throw ImageTransformationError.cancelled }
                try autoreleasepool { () throws -> Void in
                    let decoded = try decode(image)
                    let display = ImageToolRendering.swapsDimensions(image.orientation)
                        ? CGSize(width: decoded.height, height: decoded.width) : CGSize(width: decoded.width, height: decoded.height)
                    let layout = Self.pageLayout(naturalSize: Self.naturalSize(of: image), options: options)
                    var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
                    let boxData = withUnsafeBytes(of: &mediaBox) { Data($0) }
                    context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                    context.saveGState()
                    context.clip(to: mediaBox)
                    context.interpolationQuality = .high
                    context.translateBy(x: layout.imageRect.minX, y: layout.imageRect.minY)
                    context.scaleBy(x: layout.imageRect.width / display.width, y: layout.imageRect.height / display.height)
                    context.concatenate(ImageToolRendering.transform(for: image.orientation, displaySize: display))
                    context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
                    context.restoreGState()
                    context.endPDFPage()
                }
            }
            context.closePDF()
        } catch {
            context.closePDF()
            ToolOutputSupport.removeIfPresent(staged)
            throw error
        }
        guard let written = CGPDFDocument(staged as CFURL), written.numberOfPages == images.count else {
            ToolOutputSupport.removeIfPresent(staged)
            throw ImageTransformationError.pdfCreationFailed(desired.lastPathComponent)
        }
        do {
            return try ToolOutputSupport.publish(staged, as: desired)
        } catch {
            ToolOutputSupport.removeIfPresent(staged)
            throw ImageTransformationError.pdfCreationFailed(desired.lastPathComponent)
        }
    }

    /// Displayed size in points at the image's stored resolution (72 DPI when absent), at most `maximumPageEdge`.
    static func naturalSize(of image: LoadedImage) -> CGSize {
        func dpi(_ key: CFString) -> CGFloat {
            guard let value = (image.properties[key] as? NSNumber)?.doubleValue, value.isFinite, value >= 1, value <= 10_000 else { return 72 }
            return CGFloat(value)
        }
        let swapped = ImageToolRendering.swapsDimensions(image.orientation)
        let horizontal = dpi(swapped ? kCGImagePropertyDPIHeight : kCGImagePropertyDPIWidth)
        let vertical = dpi(swapped ? kCGImagePropertyDPIWidth : kCGImagePropertyDPIHeight)
        var size = CGSize(width: CGFloat(image.displayWidth) * 72 / horizontal, height: CGFloat(image.displayHeight) * 72 / vertical)
        let longest = max(size.width, size.height)
        if longest > maximumPageEdge {
            size = CGSize(width: size.width * maximumPageEdge / longest, height: size.height * maximumPageEdge / longest)
        }
        return size
    }

    /// Page size and the image's rectangle on it.
    static func pageLayout(naturalSize natural: CGSize, options: ImagePDFOptions) -> (pageSize: CGSize, imageRect: CGRect) {
        guard let paper = options.paperSize.pointSize else { return (natural, CGRect(origin: .zero, size: natural)) }
        var scale: CGFloat = 1
        if options.fitToPage {
            scale = min(paper.width / natural.width, paper.height / natural.height)
            if !options.allowUpscaling { scale = min(scale, 1) }
        }
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        return (paper, CGRect(x: (paper.width - size.width) / 2, y: (paper.height - size.height) / 2, width: size.width, height: size.height))
    }
}
