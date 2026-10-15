// Renders SF Symbols to 3x black PNG masks with the exact point size and weight SwiftUI uses, and prints their point sizes.
import AppKit
let out = CommandLine.arguments[1]
let specs: [(String, String, CGFloat, NSFont.Weight)] = [
    ("thermometer", "thermometer.medium", 16, .regular), ("drop", "drop.fill", 11, .regular), ("power", "power", 18, .semibold),
    ("minus", "minus", 16, .semibold), ("plus", "plus", 16, .semibold), ("leaf", "leaf", 17, .regular),
    ("snowflake", "snowflake", 20, .regular), ("sun", "sun.max", 20, .regular), ("dry", "drop", 20, .regular),
    ("fan", "fan", 20, .regular), ("auto", "arrow.triangle.2.circlepath", 20, .regular), ("bolt", "bolt", 20, .regular),
    ("wind", "wind", 20, .regular), ("chevron", "chevron.down", 11, .semibold), ("shield", "checkmark.shield", 13, .regular),
    ("sliders", "slider.horizontal.3", 16, .regular), ("ac", "air.conditioner.horizontal", 13, .regular),
    ("wifi", "wifi", 13, .regular), ("battery", "battery.100percent", 13, .regular), ("check", "checkmark", 12, .semibold),
]
var json: [String] = []
for (name, symbol, size, weight) in specs {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { print("missing", symbol); continue }
    let pt = base.size
    let scale: CGFloat = 2
    let px = NSSize(width: ceil(pt.width * scale), height: ceil(pt.height * scale))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = pt
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.black.set()
    let tinted = base.copy() as! NSImage
    tinted.lockFocus(); NSColor.black.set(); NSRect(origin: .zero, size: pt).fill(using: .sourceAtop); tinted.unlockFocus()
    tinted.draw(in: NSRect(origin: .zero, size: pt), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    json.append("\"\(name)\":[\(pt.width),\(pt.height)]")
    print(name, symbol, pt.width, pt.height)
}
try! ("{" + json.joined(separator: ",") + "}").write(toFile: "\(out)/sizes.json", atomically: true, encoding: .utf8)
