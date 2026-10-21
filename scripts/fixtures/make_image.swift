// Renders a test image with ImageIO; optionally embeds GPS metadata.
// Usage: swift make_image.swift <out> <width> <height> <utType> [lat lon alt]
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 5, let width = Int(args[2]), let height = Int(args[3]) else {
    FileHandle.standardError.write("usage: make_image <out> <w> <h> <uttype> [lat lon alt]\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[1])
let type = args[4] as CFString
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Background gradient plus a solid foreground subject for background-removal tests.
let colors = [CGColor(red: 0.92, green: 0.95, blue: 1, alpha: 1), CGColor(red: 0.75, green: 0.85, blue: 0.95, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
ctx.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1))
let side = CGFloat(min(width, height)) * 0.45
ctx.fillEllipse(in: CGRect(x: (CGFloat(width) - side) / 2, y: (CGFloat(height) - side) / 2, width: side, height: side))
ctx.setFillColor(CGColor(red: 0.2, green: 0.55, blue: 0.2, alpha: 1))
ctx.fill(CGRect(x: CGFloat(width) / 2 - side * 0.04, y: (CGFloat(height) + side) / 2 - side * 0.05, width: side * 0.08, height: side * 0.2))
let image = ctx.makeImage()!
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else {
    FileHandle.standardError.write("cannot create destination for \(type)\n".data(using: .utf8)!)
    exit(1)
}
var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
if args.count >= 8, let lat = Double(args[5]), let lon = Double(args[6]), let alt = Double(args[7]) {
    props[kCGImagePropertyGPSDictionary] = [
        kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
        kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
        kCGImagePropertyGPSAltitude: alt, kCGImagePropertyGPSAltitudeRef: 0,
        kCGImagePropertyGPSTimeStamp: "08:30:00", kCGImagePropertyGPSDateStamp: "2026:10:01",
    ]
    props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:10:01 16:30:00"]
    props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "DirDesk", kCGImagePropertyTIFFModel: "Fixture Camera"]
}
CGImageDestinationAddImage(dest, image, props as CFDictionary)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
