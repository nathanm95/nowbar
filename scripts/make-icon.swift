// Draws the app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
// A dark tile holding a small now-playing bar: album square, progress line and a play triangle.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // Body: the standard macOS icon square, 824pt on a 1024 canvas, with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: srgb, colors: [
        NSColor(srgbRed: 0.42, green: 0.27, blue: 0.80, alpha: 1).cgColor,
        NSColor(srgbRed: 0.97, green: 0.47, blue: 0.29, alpha: 1).cgColor
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    ctx.restoreGState()

    // The bar: a dark translucent pill across the middle.
    let bar = CGRect(x: 170, y: 392, width: 684, height: 240)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 56, cornerHeight: 56, transform: nil))
    ctx.setFillColor(NSColor(white: 0.1, alpha: 0.88).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Album square with a few dots.
    let art = CGRect(x: 205, y: 427, width: 170, height: 170)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: art, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.clip()
    ctx.setFillColor(NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1).cgColor)
    ctx.fill(art)
    let dots: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow, .systemPurple, .systemOrange, .systemTeal, .systemPink, .black]
    for row in 0..<3 {
        for col in 0..<3 {
            ctx.setFillColor(dots[(row * 3 + col * 2) % dots.count].cgColor)
            ctx.fillEllipse(in: CGRect(x: art.minX + 22 + CGFloat(col) * 48, y: art.minY + 22 + CGFloat(row) * 48, width: 30, height: 30))
        }
    }
    ctx.restoreGState()

    // Title line, progress track and fill.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 410, y: 540, width: 210, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 410, y: 462, width: 290, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 410, y: 462, width: 120, height: 16), cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.fillPath()

    // Play triangle.
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.move(to: CGPoint(x: 748, y: 560))
    ctx.addLine(to: CGPoint(x: 748, y: 464))
    ctx.addLine(to: CGPoint(x: 826, y: 512))
    ctx.closePath()
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (pixels, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                       (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try! drawIcon(pixels: pixels).write(to: output.appendingPathComponent("icon_\(name).png"))
}
