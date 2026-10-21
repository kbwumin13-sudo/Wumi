// Draws DirDesk's original app icon (a stack of offset folder cards) and writes an .iconset.
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let background = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.42, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.10, green: 0.22, blue: 0.62, alpha: 1)])!
        .draw(in: background, angle: -90)
    // Three folder cards fanned upward, like a deck.
    let colors = [NSColor(srgbRed: 0.55, green: 0.80, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.75, green: 0.90, blue: 1.0, alpha: 1), NSColor.white]
    for (index, color) in colors.enumerated() {
        let offset = CGFloat(index) * s * 0.07
        let w = body.width * 0.62, h = body.height * 0.40
        let x = body.midX - w / 2 + offset * 0.35 - s * 0.03
        let y = body.minY + body.height * 0.18 + offset
        let tab = NSBezierPath()
        let tr = s * 0.03
        tab.appendRoundedRect(NSRect(x: x, y: y + h - s * 0.02, width: w * 0.38, height: s * 0.07), xRadius: tr, yRadius: tr)
        color.withAlphaComponent(0.95).setFill()
        tab.fill()
        let card = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: s * 0.04, yRadius: s * 0.04)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = s * 0.02
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        color.setFill()
        card.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
    // Two-pane divider hint on the front card.
    let w = body.width * 0.62
    let x = body.midX - w / 2 + 2 * s * 0.07 * 0.35 - s * 0.03
    let y = body.minY + body.height * 0.18 + 2 * s * 0.07
    NSColor(srgbRed: 0.16, green: 0.42, blue: 0.95, alpha: 0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: x + w / 2 - s * 0.006, y: y + s * 0.05, width: s * 0.012, height: body.height * 0.40 - s * 0.10),
                 xRadius: s * 0.006, yRadius: s * 0.006).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: output.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: output.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("iconset written to \(output.path)")
