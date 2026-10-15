import AppKit

// Breeze app icon options, in the Arika Labs language: one slab of stone, one carved mark, two colours.
// usage: swift scripts/icon-options.swift <outdir>  (the monogram wants fonts/EBGaramond.ttf beside this script: fetch it from github.com/google/fonts, ofl/ebgaramond)
let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func color(_ hex: String, _ alpha: CGFloat = 1) -> NSColor {
    let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}
let beige = color("#e6d9c5"), ink = color("#1c1916")
let fontURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fonts/EBGaramond.ttf")
var fontError: Unmanaged<CFError>?
if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &fontError) { print("font registration:", fontURL.path, fontError?.takeRetainedValue().localizedDescription ?? "failed") }

/// The slab: macOS icon proportions, lit from the top left. Basalt or Travertine.
func slab(_ size: CGFloat, light: Bool) -> (NSRect, CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.085, radius = size * 0.21
    let slabRect = rect.insetBy(dx: inset, dy: inset)
    let path = NSBezierPath(roundedRect: slabRect, xRadius: radius, yRadius: radius)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(light ? 0.22 : 0.35); shadow.shadowBlurRadius = size * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01); shadow.set()
    if light { NSGradient(colors: [color("#f4eee5"), color("#e7ded4"), color("#d9cfc3")])!.draw(in: path, angle: -55) }
    else { NSGradient(colors: [color("#2a2219"), color("#1a1410"), color("#130f0a")])!.draw(in: path, angle: -55) }
    NSShadow().set()
    let w = max(1, size * 0.008)
    let edge = NSBezierPath(roundedRect: slabRect.insetBy(dx: w / 2, dy: w / 2), xRadius: radius - w / 2, yRadius: radius - w / 2)
    edge.lineWidth = w
    (light ? color("#ffffff", 0.7) : color("#fff0dc", 0.12)).setStroke(); edge.stroke()
    let top = NSBezierPath(roundedRect: slabRect.insetBy(dx: w, dy: w), xRadius: radius - w, yRadius: radius - w)
    NSGradient(colors: [light ? color("#ffffff", 0.35) : color("#fff0dc", 0.10), color("#fff0dc", 0.0)])!.draw(in: top, angle: -90)
    return (slabRect, radius)
}

/// A mark pressed into the stone: a dark line under, a light line over, the fill a shade off the ground.
func carve(_ path: NSBezierPath, size: CGFloat, light: Bool, fill: NSColor) {
    let d = size * 0.012
    path.transform(using: AffineTransform(translationByX: 0, byY: light ? d : -d))
    (light ? color("#ffffff", 0.75) : color("#000000", 0.55)).setFill(); path.fill()
    path.transform(using: AffineTransform(translationByX: 0, byY: light ? -d : d))
    fill.setFill(); path.fill()
}

// Option A — the unit, on Travertine: the current mark with the colours swapped.
func unit(_ size: CGFloat, light: Bool) {
    let streak = light ? ink : beige
    let unitW = size * 0.58, unitH = size * 0.15
    let unitRect = NSRect(x: (size - unitW) / 2, y: size * 0.56, width: unitW, height: unitH)
    for i in 0..<3 {
        let p = NSBezierPath(); p.lineWidth = size * 0.038; p.lineCapStyle = .round
        let x = unitRect.minX + unitW * (0.22 + 0.28 * CGFloat(i)), top = unitRect.minY - size * 0.05, bottom = size * 0.21
        p.move(to: NSPoint(x: x, y: top))
        p.curve(to: NSPoint(x: x, y: bottom), controlPoint1: NSPoint(x: x + size * 0.07, y: top - (top - bottom) * 0.33), controlPoint2: NSPoint(x: x - size * 0.07, y: top - (top - bottom) * 0.66))
        streak.withAlphaComponent(0.88 - 0.2 * CGFloat(i)).setStroke(); p.stroke()
    }
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(light ? 0.28 : 0.45); shadow.shadowBlurRadius = size * 0.03; shadow.shadowOffset = NSSize(width: 0, height: -size * 0.015); shadow.set()
    let u = NSBezierPath(roundedRect: unitRect, xRadius: unitH * 0.28, yRadius: unitH * 0.28)
    if light { NSGradient(colors: [color("#2a2420"), ink])!.draw(in: u, angle: -90) } else { NSGradient(colors: [color("#f1e6d2"), beige])!.draw(in: u, angle: -90) }
    NSShadow().set()
    let vent = NSBezierPath(roundedRect: NSRect(x: unitRect.minX + unitW * 0.08, y: unitRect.minY + unitH * 0.2, width: unitW * 0.84, height: unitH * 0.13), xRadius: size * 0.01, yRadius: size * 0.01)
    (light ? color("#e7ded4") : color("#130f0a")).setFill(); vent.fill()
}

// Option B — the breeze itself: three strokes of moving air, the longest in the middle, each ending in a curl.
func breeze(_ size: CGFloat, light: Bool) {
    let stroke = light ? ink : beige
    func line(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat, curl: CGFloat, up: Bool) {
        let p = NSBezierPath(); p.lineWidth = size * 0.052; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: NSPoint(x: size * x0, y: size * y)); p.line(to: NSPoint(x: size * x1, y: size * y))
        if curl > 0 {
            let c = size * curl
            if up { p.appendArc(withCenter: NSPoint(x: size * x1, y: size * y + c), radius: c, startAngle: -90, endAngle: 135, clockwise: false) }
            else { p.appendArc(withCenter: NSPoint(x: size * x1, y: size * y - c), radius: c, startAngle: 90, endAngle: -135, clockwise: true) }
        }
        stroke.setStroke(); p.stroke()
    }
    line(0.62, 0.26, 0.50, curl: 0, up: true)
    line(0.47, 0.20, 0.66, curl: 0.105, up: true)
    line(0.32, 0.30, 0.56, curl: 0.085, up: false)
}

// Option C — the grille: the unit's face, three slats pressed into a raised key of the same stone.
func grille(_ size: CGFloat, light: Bool) {
    let keyW = size * 0.56, keyH = size * 0.42
    let keyRect = NSRect(x: (size - keyW) / 2, y: (size - keyH) / 2, width: keyW, height: keyH)
    let key = NSBezierPath(roundedRect: keyRect, xRadius: size * 0.09, yRadius: size * 0.09)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(light ? 0.22 : 0.55); shadow.shadowBlurRadius = size * 0.035; shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018); shadow.set()
    if light { NSGradient(colors: [color("#f6f1e9"), color("#ece4d8")])!.draw(in: key, angle: -90) } else { NSGradient(colors: [color("#2a221a"), color("#1f1812")])!.draw(in: key, angle: -90) }
    NSShadow().set()
    let w = max(1, size * 0.006)
    let edge = NSBezierPath(roundedRect: keyRect.insetBy(dx: w / 2, dy: w / 2), xRadius: size * 0.09 - w / 2, yRadius: size * 0.09 - w / 2); edge.lineWidth = w
    (light ? color("#ffffff", 0.8) : color("#fff0dc", 0.14)).setStroke(); edge.stroke()
    for i in 0..<3 {
        let slatH = size * 0.045, slatW = keyW * 0.66
        let y = keyRect.midY + CGFloat(1 - i) * size * 0.105 - slatH / 2
        let slat = NSBezierPath(roundedRect: NSRect(x: (size - slatW) / 2, y: y, width: slatW, height: slatH), xRadius: slatH / 2, yRadius: slatH / 2)
        carve(slat, size: size, light: light, fill: light ? ink : beige)
    }
}

// Option D — one stroke: a single sweep of air, the mark at its simplest.
func sweep(_ size: CGFloat, light: Bool) {
    let stroke = light ? ink : beige
    let p = NSBezierPath(); p.lineWidth = size * 0.085; p.lineCapStyle = .round; p.lineJoinStyle = .round
    p.move(to: NSPoint(x: size * 0.22, y: size * 0.46))
    p.curve(to: NSPoint(x: size * 0.70, y: size * 0.46), controlPoint1: NSPoint(x: size * 0.36, y: size * 0.56), controlPoint2: NSPoint(x: size * 0.56, y: size * 0.36))
    p.appendArc(withCenter: NSPoint(x: size * 0.70, y: size * 0.56), radius: size * 0.10, startAngle: -90, endAngle: 160, clockwise: false)
    stroke.setStroke(); p.stroke()
}

// Option G — falling air: the three streaks from under the unit, on their own, bolder.
func falling(_ size: CGFloat, light: Bool) {
    let stroke = light ? ink : beige
    let lens: [CGFloat] = [0.46, 0.56, 0.40]
    for i in 0..<3 {
        let p = NSBezierPath(); p.lineWidth = size * 0.07; p.lineCapStyle = .round
        let x = size * (0.33 + 0.17 * CGFloat(i)), top = size * 0.50 + size * lens[i] / 2, bottom = top - size * lens[i]
        p.move(to: NSPoint(x: x, y: top))
        p.curve(to: NSPoint(x: x, y: bottom), controlPoint1: NSPoint(x: x + size * 0.11, y: top - (top - bottom) * 0.33), controlPoint2: NSPoint(x: x - size * 0.11, y: top - (top - bottom) * 0.66))
        stroke.setStroke(); p.stroke()
    }
}

// Option H — the monogram: a serif B carved into the slab, the house wordmark's letter.
func monogram(_ size: CGFloat, light: Bool) {
    let names = ["EBGaramond-Medium", "EBGaramond-Regular", "EBGaramond", "EB Garamond", "Iowan Old Style", "Georgia"]
    var font: NSFont? = nil
    for n in names { if let f = NSFont(name: n, size: size * 0.70) { font = f; break } }
    let f = font ?? NSFont.systemFont(ofSize: size * 0.7)
    if size == 256 { print("monogram font:", f.fontName) }
    let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: light ? ink : beige]
    let str = NSAttributedString(string: "B", attributes: attrs)
    let bounds = str.boundingRect(with: NSSize(width: size, height: size), options: [.usesLineFragmentOrigin])
    let origin = NSPoint(x: (size - bounds.width) / 2 - bounds.minX, y: (size - bounds.height) / 2 - bounds.minY + size * 0.01)
    // the carve: a shadow line below, light line above
    let d = size * 0.012
    let under = NSAttributedString(string: "B", attributes: [.font: f, .foregroundColor: light ? color("#ffffff", 0.75) : color("#000000", 0.6)])
    under.draw(at: NSPoint(x: origin.x, y: origin.y + (light ? d : -d)))
    str.draw(at: origin)
}

// Option E — the unit, taller: a body with real height and a vent you can see at sixteen pixels, three short bold streaks under it.
func tallUnit(_ size: CGFloat, light: Bool) {
    let unitW = size * 0.60, unitH = size * 0.29
    let unitRect = NSRect(x: (size - unitW) / 2, y: size * 0.49, width: unitW, height: unitH)
    let streak = light ? ink : beige
    for i in 0..<3 {
        let p = NSBezierPath(); p.lineWidth = size * 0.042; p.lineCapStyle = .round
        let x = unitRect.minX + unitW * (0.2 + 0.3 * CGFloat(i)), top = unitRect.minY - size * 0.05, bottom = size * 0.185
        p.move(to: NSPoint(x: x, y: top))
        p.curve(to: NSPoint(x: x, y: bottom), controlPoint1: NSPoint(x: x + size * 0.06, y: top - (top - bottom) * 0.33), controlPoint2: NSPoint(x: x - size * 0.06, y: top - (top - bottom) * 0.66))
        streak.withAlphaComponent(0.92 - 0.18 * CGFloat(i)).setStroke(); p.stroke()
    }
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(light ? 0.28 : 0.5); shadow.shadowBlurRadius = size * 0.035; shadow.shadowOffset = NSSize(width: 0, height: -size * 0.018); shadow.set()
    let u = NSBezierPath(roundedRect: unitRect, xRadius: size * 0.055, yRadius: size * 0.055)
    if light { NSGradient(colors: [color("#2a2420"), ink])!.draw(in: u, angle: -90) } else { NSGradient(colors: [color("#f3e9d8"), beige])!.draw(in: u, angle: -90) }
    NSShadow().set()
    let ventH = size * 0.05
    let vent = NSBezierPath(roundedRect: NSRect(x: unitRect.minX + unitW * 0.09, y: unitRect.minY + size * 0.05, width: unitW * 0.82, height: ventH), xRadius: ventH / 2, yRadius: ventH / 2)
    (light ? color("#e7ded4") : color("#130f0a")).setFill(); vent.fill()
}

let options: [(String, Bool, (CGFloat, Bool) -> Void)] = [
    ("a-unit-travertine", true, unit), ("b-breeze-basalt", false, breeze), ("e-breeze-travertine", true, breeze),
    ("g-falling-basalt", false, falling), ("j-falling-travertine", true, falling), ("k-unit-basalt", false, unit), ("l-unit-tall-basalt", false, tallUnit), ("m-unit-tall-travertine", true, tallUnit), ("h-monogram-travertine", true, monogram), ("i-monogram-basalt", false, monogram),
]
for (name, light, draw) in options {
    for px in [1024, 256, 128, 64, 32, 16] {
        let size = CGFloat(px)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        _ = slab(size, light: light); draw(size, light)
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)-\(px).png"))
    }
    print(name)
}
