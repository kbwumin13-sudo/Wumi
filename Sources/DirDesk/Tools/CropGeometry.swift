import CoreGraphics
import Foundation

enum CropCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    /// +1 when the corner sits on the larger coordinate (right / bottom; top-left origin).
    var horizontalSign: CGFloat { self == .topRight || self == .bottomRight ? 1 : -1 }
    var verticalSign: CGFloat { self == .bottomLeft || self == .bottomRight ? 1 : -1 }

    func point(of rect: CGRect) -> CGPoint {
        CGPoint(x: horizontalSign > 0 ? rect.maxX : rect.minX, y: verticalSign > 0 ? rect.maxY : rect.minY)
    }

    /// The corner that stays fixed while this one is dragged.
    func anchor(of rect: CGRect) -> CGPoint {
        CGPoint(x: horizontalSign > 0 ? rect.minX : rect.maxX, y: verticalSign > 0 ? rect.minY : rect.maxY)
    }
}

/// Crop-frame math in image pixels with a top-left origin. Every result lies inside the image, and
/// with a ratio (width / height) the result keeps it. Results are whole pixels.
enum CropGeometry {
    /// The largest rectangle with `ratio` (nil: the whole area) centered in `bounds`.
    static func largest(ratio: Double?, in bounds: CGRect) -> CGRect {
        guard let ratio, ratio > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        var size = CGSize(width: bounds.width, height: bounds.width / ratio)
        if size.height > bounds.height { size = CGSize(width: bounds.height * ratio, height: bounds.height) }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The default frame: the whole image, or the largest centered rectangle with `ratio`.
    static func initialRect(ratio: Double?, imageSize: CGSize) -> CGRect {
        integral(largest(ratio: ratio, in: CGRect(origin: .zero, size: imageSize)), imageSize: imageSize)
    }

    /// After choosing another aspect ratio: the largest rectangle with that ratio, centered where the
    /// current frame is centered, moved back inside the image.
    static func applying(ratio: Double?, to rect: CGRect, imageSize: CGSize) -> CGRect {
        guard ratio != nil else { return integral(rect, imageSize: imageSize) }
        let bounds = CGRect(origin: .zero, size: imageSize)
        var target = largest(ratio: ratio, in: bounds)
        target.origin = CGPoint(x: rect.midX - target.width / 2, y: rect.midY - target.height / 2)
        return moved(target, by: .zero, imageSize: imageSize)
    }

    /// `rect` shifted by `delta` and stopped at the image edges; its size never changes.
    static func moved(_ rect: CGRect, by delta: CGSize, imageSize: CGSize) -> CGRect {
        let width = min(rect.width, imageSize.width), height = min(rect.height, imageSize.height)
        let x = min(max(0, rect.minX + delta.width), imageSize.width - width)
        let y = min(max(0, rect.minY + delta.height), imageSize.height - height)
        return integral(CGRect(x: x, y: y, width: width, height: height), imageSize: imageSize)
    }

    /// Dragging `corner` of `start` to `point`; the opposite corner stays put. The frame never flips.
    static func resized(_ start: CGRect, corner: CropCorner, to point: CGPoint, ratio: Double?, imageSize: CGSize,
                        minimumSide: CGFloat) -> CGRect {
        sized(from: corner.anchor(of: start), toward: point, horizontal: corner.horizontalSign, vertical: corner.verticalSign,
              ratio: ratio, imageSize: imageSize, minimumSide: minimumSide)
    }

    /// A new frame dragged out from `anchor` to `point`, in whichever direction the pointer went.
    static func selection(from anchor: CGPoint, to point: CGPoint, ratio: Double?, imageSize: CGSize, minimumSide: CGFloat) -> CGRect {
        let anchor = CGPoint(x: min(max(0, anchor.x), imageSize.width), y: min(max(0, anchor.y), imageSize.height))
        return sized(from: anchor, toward: point, horizontal: point.x >= anchor.x ? 1 : -1, vertical: point.y >= anchor.y ? 1 : -1,
                     ratio: ratio, imageSize: imageSize, minimumSide: minimumSide)
    }

    /// Keyboard resize: grows or shrinks the right and bottom edges by `dx` and `dy`.
    static func resizedByKeyboard(_ rect: CGRect, dx: CGFloat, dy: CGFloat, ratio: Double?, imageSize: CGSize) -> CGRect {
        var width = rect.width + dx, height = rect.height + dy
        if let ratio, ratio > 0 {
            if dx != 0 { height = width / ratio } else { width = height * ratio }
        }
        let corner = CGPoint(x: rect.minX + width, y: rect.minY + height)
        return sized(from: rect.origin, toward: corner, horizontal: 1, vertical: 1, ratio: ratio, imageSize: imageSize, minimumSide: 1)
    }

    /// Setting one field of the frame from the X / Y / Width / Height boxes.
    enum Field { case x, y, width, height }

    static func setting(_ field: Field, to value: Int, in rect: CGRect, ratio: Double?, imageSize: CGSize) -> CGRect {
        let value = CGFloat(value)
        switch field {
        case .x:
            return moved(rect, by: CGSize(width: value - rect.minX, height: 0), imageSize: imageSize)
        case .y:
            return moved(rect, by: CGSize(width: 0, height: value - rect.minY), imageSize: imageSize)
        case .width:
            let width = max(1, value)
            let height = ratio.map { width / CGFloat($0) } ?? rect.height
            return sized(from: rect.origin, toward: CGPoint(x: rect.minX + width, y: rect.minY + height), horizontal: 1, vertical: 1,
                         ratio: ratio, imageSize: imageSize, minimumSide: 1, prefersWidth: true)
        case .height:
            let height = max(1, value)
            let width = ratio.map { height * CGFloat($0) } ?? rect.width
            return sized(from: rect.origin, toward: CGPoint(x: rect.minX + width, y: rect.minY + height), horizontal: 1, vertical: 1,
                         ratio: ratio, imageSize: imageSize, minimumSide: 1, prefersWidth: false)
        }
    }

    /// Whole pixels inside the image, at least 1 × 1. Edges are rounded separately so a fixed edge stays put.
    static func integral(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        let imageWidth = max(1, imageSize.width.rounded()), imageHeight = max(1, imageSize.height.rounded())
        let minX = rect.minX.rounded(), minY = rect.minY.rounded()
        let width = min(max(1, rect.maxX.rounded() - minX), imageWidth)
        let height = min(max(1, rect.maxY.rounded() - minY), imageHeight)
        let x = min(max(0, minX), imageWidth - width)
        let y = min(max(0, minY), imageHeight - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The frame from `anchor` toward `point`, growing right/down for positive signs and left/up for
    /// negative ones, limited by the image and kept at `ratio`.
    private static func sized(from anchor: CGPoint, toward point: CGPoint, horizontal: CGFloat, vertical: CGFloat, ratio: Double?,
                              imageSize: CGSize, minimumSide: CGFloat, prefersWidth: Bool? = nil) -> CGRect {
        let maximumWidth = max(1, horizontal > 0 ? imageSize.width - anchor.x : anchor.x)
        let maximumHeight = max(1, vertical > 0 ? imageSize.height - anchor.y : anchor.y)
        let minimum = max(1, min(minimumSide, maximumWidth, maximumHeight))
        var width = min(max((point.x - anchor.x) * horizontal, minimum), maximumWidth)
        var height = min(max((point.y - anchor.y) * vertical, minimum), maximumHeight)
        if let ratio, ratio > 0 {
            let r = CGFloat(ratio)
            let followWidth = prefersWidth ?? (width / r >= height)
            if followWidth { height = width / r } else { width = height * r }
            if width > maximumWidth { width = maximumWidth; height = width / r }
            if height > maximumHeight { height = maximumHeight; width = height * r }
            if width < minimum || height < minimum {
                let scale = max(minimum / max(width, 0.001), minimum / max(height, 0.001))
                width = min(width * scale, maximumWidth)
                height = min(height * scale, maximumHeight)
            }
        }
        let x = horizontal > 0 ? anchor.x : anchor.x - width
        let y = vertical > 0 ? anchor.y : anchor.y - height
        return integral(CGRect(x: x, y: y, width: width, height: height), imageSize: imageSize)
    }
}
