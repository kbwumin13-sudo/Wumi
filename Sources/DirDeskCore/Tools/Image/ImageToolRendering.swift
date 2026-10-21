import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Pixel work shared by the image tools: EXIF orientation math, bitmap formats that keep the source's
/// color space and depth, and the CoreText watermark.
enum ImageToolRendering {
    static func swapsDimensions(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: true
        default: false
        }
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// An orientation as "mirror horizontally (optional), then rotate clockwise by quarter turns".
    private static func components(_ orientation: CGImagePropertyOrientation) -> (mirrored: Bool, quarterTurns: Int) {
        switch orientation {
        case .up: (false, 0)
        case .right: (false, 1)
        case .down: (false, 2)
        case .left: (false, 3)
        case .upMirrored: (true, 0)
        case .rightMirrored: (true, 1)
        case .downMirrored: (true, 2)
        case .leftMirrored: (true, 3)
        @unknown default: (false, 0)
        }
    }

    private static func orientation(mirrored: Bool, quarterTurns: Int) -> CGImagePropertyOrientation {
        switch (mirrored, ((quarterTurns % 4) + 4) % 4) {
        case (false, 0): .up
        case (false, 1): .right
        case (false, 2): .down
        case (false, 3): .left
        case (true, 0): .upMirrored
        case (true, 1): .rightMirrored
        case (true, 2): .downMirrored
        default: .leftMirrored
        }
    }

    /// The single orientation equal to displaying with `first` and then applying `second` to the result.
    static func compose(_ first: CGImagePropertyOrientation, then second: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
        let a = components(first), b = components(second)
        // rot^b · mir^mb · rot^a · mir^ma = rot^(b ± a) · mir^(ma ⊕ mb), because mir · rot = rot⁻¹ · mir.
        return orientation(mirrored: a.mirrored != b.mirrored, quarterTurns: b.quarterTurns + (b.mirrored ? -a.quarterTurns : a.quarterTurns))
    }

    /// Maps the stored image, drawn in (0, 0, storedWidth, storedHeight), onto an upright canvas of
    /// `size` (the displayed size). Built from exact quarter-turn matrices so pixels map one to one.
    static func transform(for orientation: CGImagePropertyOrientation, displaySize size: CGSize) -> CGAffineTransform {
        let quarterTurnCounterclockwise = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        let quarterTurnClockwise = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        let halfTurn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        var t = CGAffineTransform.identity
        switch orientation {
        case .down, .downMirrored: t = halfTurn.concatenating(t.translatedBy(x: size.width, y: size.height))
        case .left, .leftMirrored: t = quarterTurnCounterclockwise.concatenating(t.translatedBy(x: size.width, y: 0))
        case .right, .rightMirrored: t = quarterTurnClockwise.concatenating(t.translatedBy(x: 0, y: size.height))
        default: break
        }
        switch orientation {
        case .upMirrored, .downMirrored: t = t.translatedBy(x: size.width, y: 0).scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored: t = t.translatedBy(x: size.height, y: 0).scaledBy(x: -1, y: 1)
        default: break
        }
        return t
    }

    /// A bitmap context in the image's own color space and bit depth when Quartz supports it, else sRGB.
    /// `opaque` drops the alpha channel.
    static func makeContext(width: Int, height: Int, like image: CGImage, opaque: Bool) -> CGContext? {
        let alpha = !opaque && hasAlpha(image)
        let deep = image.bitsPerComponent > 8
        let rgbInfo = (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        var candidates: [(space: CGColorSpace, bitsPerComponent: Int, bitmapInfo: UInt32)] = []
        if let space = image.colorSpace {
            switch space.model {
            case .rgb: candidates.append((space, deep ? 16 : 8, rgbInfo))
            case .monochrome where !alpha: candidates.append((space, deep ? 16 : 8, CGImageAlphaInfo.none.rawValue))
            case .cmyk where !alpha: candidates.append((space, 8, CGImageAlphaInfo.none.rawValue))
            default: break
            }
        }
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB) {
            if deep { candidates.append((sRGB, 16, rgbInfo)) }
            candidates.append((sRGB, 8, rgbInfo))
        }
        for candidate in candidates {
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: candidate.bitsPerComponent,
                                       bytesPerRow: 0, space: candidate.space, bitmapInfo: candidate.bitmapInfo) {
                return context
            }
        }
        return nil
    }

    /// Draws `image` upright (applying `orientation`), optionally cropped to `crop` in displayed pixels with
    /// a top-left origin. `flattenOnto` fills an opaque background first (for formats without alpha).
    /// `decorate` then draws on top in the output's coordinate space (origin bottom-left).
    static func render(_ image: CGImage, orientation: CGImagePropertyOrientation, crop: CGRect? = nil, flattenOnto background: CGColor? = nil,
                       decorate: ((CGContext, CGSize) -> Void)? = nil) -> CGImage? {
        let stored = CGSize(width: image.width, height: image.height)
        let display = swapsDimensions(orientation) ? CGSize(width: stored.height, height: stored.width) : stored
        let area = crop ?? CGRect(origin: .zero, size: display)
        let width = Int(area.width), height = Int(area.height)
        guard width > 0, height > 0, let context = makeContext(width: width, height: height, like: image, opaque: background != nil) else {
            return nil
        }
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .none
        context.saveGState()
        context.translateBy(x: -area.minX, y: -(display.height - area.maxY))
        context.concatenate(transform(for: orientation, displaySize: display))
        context.draw(image, in: CGRect(origin: .zero, size: stored))
        context.restoreGState()
        decorate?(context, CGSize(width: width, height: height))
        return context.makeImage()
    }

    /// Most watermark tiles drawn on one image; denser layouts are spread out to stay under it.
    static let maximumWatermarkTiles = 20_000

    /// Draws the watermark text in "Helvetica Neue" (CoreText falls back for missing glyphs), each copy rotated
    /// counterclockwise by `angleDegrees` around its own center: once in the middle of the image, or tiled like
    /// the reference, in horizontal rows where every other row is shifted by half a step. Tile steps are the
    /// rotated text's bounding box plus the spacing; copies cut by the image edges are drawn too.
    static func drawWatermark(_ options: ImageWatermarkOptions, in context: CGContext, size: CGSize) {
        let shorterEdge = min(size.width, size.height)
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, max(1, CGFloat(options.relativeFontSize) * shorterEdge), nil)
        let color = CGColor(srgbRed: CGFloat(options.color.red), green: CGFloat(options.color.green), blue: CGFloat(options.color.blue),
                            alpha: CGFloat(options.opacity))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: options.text, attributes: attributes) as CFAttributedString)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let lineHeight = ascent + descent
        guard lineWidth > 0, lineHeight > 0 else { return }
        let angle = CGFloat(options.angleDegrees * .pi / 180)

        context.saveGState()
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.textMatrix = .identity
        /// One copy centered on (x, y) in the context's bottom-left-origin space.
        func draw(centeredAt x: CGFloat, _ y: CGFloat) {
            context.saveGState()
            context.translateBy(x: x, y: y)
            context.rotate(by: angle)
            context.textPosition = CGPoint(x: -lineWidth / 2, y: -(ascent - descent) / 2)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        switch options.layout {
        case .centered:
            draw(centeredAt: size.width / 2, size.height / 2)
        case .tiled:
            let spacing = CGFloat(options.relativeSpacing) * shorterEdge
            let boxWidth = abs(lineWidth * cos(angle)) + abs(lineHeight * sin(angle))
            let boxHeight = abs(lineWidth * sin(angle)) + abs(lineHeight * cos(angle))
            var stepX = max(1, boxWidth + spacing), stepY = max(1, boxHeight + spacing)
            let tiles = (size.width / stepX + 2) * (size.height / stepY + 2)
            if tiles > CGFloat(maximumWatermarkTiles) {
                let spread = (tiles / CGFloat(maximumWatermarkTiles)).squareRoot()
                stepX *= spread
                stepY *= spread
            }
            // The first copy sits a quarter of the spacing in from the top-left corner.
            let originX = boxWidth / 2 + spacing / 4
            var top = boxHeight / 2 + spacing / 4
            var row = 0
            while top - boxHeight / 2 < size.height {
                var x = originX + (row.isMultiple(of: 2) ? 0 : stepX / 2)
                while x - stepX > -boxWidth / 2 { x -= stepX }
                while x - boxWidth / 2 < size.width {
                    draw(centeredAt: x, size.height - top)
                    x += stepX
                }
                top += stepY
                row += 1
            }
        }
        context.restoreGState()
    }
}
