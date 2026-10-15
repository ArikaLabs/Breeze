import AppKit

// Renders the Breeze app icon into an .iconset directory. Usage: swift make-icon.swift <iconset dir>
// Arika Labs house style: a Basalt slab (warm black stone, lit from the top left) with the air
// conditioner and its airflow carved in beige. Two colours, no illustration. The body is tall on purpose:
// a short one lost its face below 32 px (owner, 2026-10-14).
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func color(_ hex: String, _ alpha: CGFloat = 1) -> NSColor {
    let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}
let beige = color("#e6d9c5")

func render(px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.085
    let slabRect = rect.insetBy(dx: inset, dy: inset)
    let radius = size * 0.21

    // Basalt slab, lit from the top left.
    let slab = NSBezierPath(roundedRect: slabRect, xRadius: radius, yRadius: radius)
    NSGradient(colors: [color("#2a2219"), color("#1a1410"), color("#130f0a")])!.draw(in: slab, angle: -55)
    // The light catching the edge.
    let edgeWidth = max(1, size * 0.008)
    let edge = NSBezierPath(roundedRect: slabRect.insetBy(dx: edgeWidth / 2, dy: edgeWidth / 2), xRadius: radius - edgeWidth / 2, yRadius: radius - edgeWidth / 2)
    edge.lineWidth = edgeWidth
    color("#fff0dc", 0.12).setStroke()
    edge.stroke()
    let topLight = NSBezierPath(roundedRect: slabRect.insetBy(dx: edgeWidth, dy: edgeWidth), xRadius: radius - edgeWidth, yRadius: radius - edgeWidth)
    NSGradient(colors: [color("#fff0dc", 0.10), color("#fff0dc", 0.0)])!.draw(in: topLight, angle: -90)

    // The unit: a tall beige body with a dark vent, sitting proud of the stone. Tall enough to keep its face at 16 px.
    let unitW = size * 0.60, unitH = size * 0.29
    let unitRect = NSRect(x: (size - unitW) / 2, y: size * 0.49, width: unitW, height: unitH)

    // Airflow, carved in beige: three streaks falling from the unit, fading to the right.
    for i in 0..<3 {
        let path = NSBezierPath()
        path.lineWidth = size * 0.042
        path.lineCapStyle = .round
        let x = unitRect.minX + unitW * (0.2 + 0.3 * CGFloat(i))
        let top = unitRect.minY - size * 0.05
        let bottom = size * 0.185
        path.move(to: NSPoint(x: x, y: top))
        path.curve(to: NSPoint(x: x, y: bottom),
                   controlPoint1: NSPoint(x: x + size * 0.06, y: top - (top - bottom) * 0.33),
                   controlPoint2: NSPoint(x: x - size * 0.06, y: top - (top - bottom) * 0.66))
        beige.withAlphaComponent(0.92 - 0.18 * CGFloat(i)).setStroke()
        path.stroke()
    }

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
    shadow.shadowBlurRadius = size * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    shadow.set()
    let unit = NSBezierPath(roundedRect: unitRect, xRadius: size * 0.055, yRadius: size * 0.055)
    NSGradient(colors: [color("#f3e9d8"), beige])!.draw(in: unit, angle: -90)
    NSShadow().set()
    let ventH = size * 0.05
    let vent = NSBezierPath(roundedRect: NSRect(x: unitRect.minX + unitW * 0.09, y: unitRect.minY + size * 0.05,
                                                width: unitW * 0.82, height: ventH), xRadius: ventH / 2, yRadius: ventH / 2)
    color("#130f0a").setFill()
    vent.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(px: base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! render(px: base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
print("icons written to \(outDir)")
