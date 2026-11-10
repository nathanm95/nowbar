import AppKit
import SwiftUI

/// Colours taken from the album art: two for the bar's see-through tint (a left-to-right gradient)
/// and a bright accent for the scrubber and the shuffle and repeat lights.
struct ArtworkPalette: Equatable {
    let primary: Color
    let secondary: Color
    /// Nil for grey or black-and-white art, which keeps the system accent colour.
    let accent: Color?
}

enum PaletteExtractor {
    private static let side = 32
    private static let binCount = 24 // 15° of hue each

    /// Shrinks the art to 32×32 and finds its most prominent vivid hues. Colourful pixels count
    /// for more than dull ones, so a bright detail on a grey cover still sets the colour.
    static func palette(from image: NSImage) -> ArtworkPalette? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        struct Bin { var weight = 0.0, red = 0.0, green = 0.0, blue = 0.0 }
        var bins = [Bin](repeating: Bin(), count: binCount)
        var average = (red: 0.0, green: 0.0, blue: 0.0)
        let count = Double(side * side)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255, green = Double(pixels[index + 1]) / 255, blue = Double(pixels[index + 2]) / 255
            average.red += red / count
            average.green += green / count
            average.blue += blue / count
            let (hue, saturation, brightness) = hsb(red, green, blue)
            guard saturation > 0.2, brightness > 0.15 else { continue }
            let weight = saturation * saturation * brightness
            let bin = min(binCount - 1, Int(hue * Double(binCount)))
            bins[bin].weight += weight
            bins[bin].red += red * weight
            bins[bin].green += green * weight
            bins[bin].blue += blue * weight
        }

        // Score each hue with its neighbours so a colour split across two bins still wins.
        func window(_ center: Int) -> Bin {
            var total = Bin()
            for offset in -1...1 {
                let bin = bins[(center + offset + binCount) % binCount]
                total.weight += bin.weight
                total.red += bin.red
                total.green += bin.green
                total.blue += bin.blue
            }
            return total
        }
        let ranked = (0..<binCount).map { ($0, window($0)) }.sorted { $0.1.weight > $1.1.weight }
        let totalVivid = bins.reduce(0) { $0 + $1.weight }

        guard let (topIndex, top) = ranked.first, totalVivid / count > 0.02, top.weight > 0 else {
            // Grey or black-and-white art: a neutral tint from its average shade.
            let grey = NSColor(srgbRed: average.red, green: average.green, blue: average.blue, alpha: 1)
            let tint = adjusted(grey, saturation: 0...0.12, brightness: 0.3...0.45)
            return ArtworkPalette(primary: Color(nsColor: tint), secondary: Color(nsColor: darker(tint)), accent: nil)
        }
        let base = NSColor(srgbRed: top.red / top.weight, green: top.green / top.weight, blue: top.blue / top.weight, alpha: 1)

        // A second colour for the gradient: the next strongest hue at least 45° away, if it's
        // reasonably present. Otherwise a darker shade of the first.
        let second = ranked.first { index, bin in
            let distance = min(abs(index - topIndex), binCount - abs(index - topIndex))
            return distance >= 3 && bin.weight >= top.weight * 0.25
        }.map { _, bin in
            NSColor(srgbRed: bin.red / bin.weight, green: bin.green / bin.weight, blue: bin.blue / bin.weight, alpha: 1)
        }

        let primary = adjusted(base, saturation: 0.35...0.75, brightness: 0.38...0.55)
        let secondary = second.map { adjusted($0, saturation: 0.35...0.75, brightness: 0.3...0.5) } ?? darker(primary)
        let accent = adjusted(base, saturation: 0.45...0.8, brightness: 0.9...1)
        return ArtworkPalette(primary: Color(nsColor: primary), secondary: Color(nsColor: secondary),
                              accent: Color(nsColor: accent))
    }

    private static func hsb(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
        let maximum = max(red, green, blue), minimum = min(red, green, blue), delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == red { hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == green { hue = (blue - red) / delta + 2 }
            else { hue = (red - green) / delta + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maximum == 0 ? 0 : delta / maximum, maximum)
    }

    private static func adjusted(_ color: NSColor, saturation: ClosedRange<CGFloat>, brightness: ClosedRange<CGFloat>) -> NSColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bright: CGFloat = 0, alpha: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&hue, saturation: &sat, brightness: &bright, alpha: &alpha)
        return NSColor(hue: hue, saturation: min(max(sat, saturation.lowerBound), saturation.upperBound),
                       brightness: min(max(bright, brightness.lowerBound), brightness.upperBound), alpha: 1)
    }

    private static func darker(_ color: NSColor) -> NSColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bright: CGFloat = 0, alpha: CGFloat = 0
        (color.usingColorSpace(.sRGB) ?? color).getHue(&hue, saturation: &sat, brightness: &bright, alpha: &alpha)
        return NSColor(hue: hue, saturation: sat, brightness: bright * 0.6, alpha: 1)
    }
}

// MARK: - Accent in the environment

private struct BarAccentKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    /// The bar's highlight colour: from the album art when tinting is on, else the system accent.
    var barAccent: Color {
        get { self[BarAccentKey.self] }
        set { self[BarAccentKey.self] = newValue }
    }
}
