// Compare two PNGs of the same size: prints the mean absolute difference per channel (0–255)
// overall and per horizontal band, and writes a diff image where brighter = more different.
// usage: swift diff.swift a.png b.png out.png [bands]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func load(_ path: String) -> (CGImage, [UInt8], Int, Int) {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("cannot read \(path)") }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (img, buf, w, h)
}

let args = CommandLine.arguments
let (_, aFull, wa, ha) = load(args[1])
let (_, b, w, h) = load(args[2])
guard wa >= w, ha >= h else { print("A smaller than B: \(wa)x\(ha) vs \(w)x\(h)"); exit(1) }
var a = [UInt8](repeating: 0, count: w * h * 4)
for y in 0..<h { for x in 0..<w { for c in 0..<4 { a[(y * w + x) * 4 + c] = aFull[(y * wa + x) * 4 + c] } } }
let bands = args.count > 4 ? Int(args[4])! : 10
var out = [UInt8](repeating: 255, count: w * h * 4)
var total = 0.0
var bandSum = [Double](repeating: 0, count: bands)
var bandCount = [Double](repeating: 0, count: bands)
for y in 0..<h {
    let band = min(bands - 1, y * bands / h)
    for x in 0..<w {
        let i = (y * w + x) * 4
        var d = 0
        for c in 0..<3 { d += abs(Int(a[i + c]) - Int(b[i + c])) }
        let m = Double(d) / 3
        total += m; bandSum[band] += m; bandCount[band] += 1
        let v = UInt8(min(255, d * 2))
        out[i] = v; out[i + 1] = v; out[i + 2] = v; out[i + 3] = 255
    }
}
print(String(format: "mean abs diff %.2f / 255", total / Double(w * h)))
for i in 0..<bands {
    let y0 = i * h / bands, y1 = (i + 1) * h / bands
    print(String(format: "  rows %4d-%4d  %.2f", y0, y1, bandSum[i] / max(1, bandCount[i])))
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
