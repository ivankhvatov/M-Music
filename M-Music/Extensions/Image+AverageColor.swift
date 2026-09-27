import SwiftUI

extension UIImage {
    /// The mean color of the whole image, sampled from a 32×32 downscale of it (drawn with high
    /// interpolation quality, which averages neighboring source pixels together as it shrinks)
    /// rather than by running a Core Image area-average over every pixel — the latter needs a
    /// fresh `CIContext` per call and touches the full-resolution bitmap, which is real CPU for
    /// something only used to tint a background.
    func averageColor() -> Color? {
        guard let cgImage else { return nil }

        let side = 32
        let bytesPerPixel = 4
        var pixelData = [UInt8](repeating: 0, count: side * side * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var red = 0, green = 0, blue = 0
        for pixelIndex in 0..<(side * side) {
            let offset = pixelIndex * bytesPerPixel
            red += Int(pixelData[offset])
            green += Int(pixelData[offset + 1])
            blue += Int(pixelData[offset + 2])
        }
        let total = Double(side * side) * 255

        return Color(red: Double(red) / total, green: Double(green) / total, blue: Double(blue) / total)
    }
}

extension UIImage {
    /// Extracts up to `count` visually distinct dominant colors, ordered by prevalence.
    ///
    /// Pixels are quantized onto a coarse RGB grid so near-duplicate shades collapse into a
    /// single bucket instead of splintering the histogram, and near-black/near-white/transparent
    /// pixels are excluded since they'd otherwise dominate album art borders and mattes without
    /// giving a useful background hue.
    func dominantColors(count: Int) -> [Color] {
        guard let cgImage = cgImage else { return [] }

        let side = 40
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: side * side * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        let bucketLevels = 8
        var buckets: [Int: (r: Int, g: Int, b: Int, count: Int)] = [:]

        for pixelIndex in 0..<(side * side) {
            let offset = pixelIndex * bytesPerPixel
            let r = pixelData[offset]
            let g = pixelData[offset + 1]
            let b = pixelData[offset + 2]
            let alpha = pixelData[offset + 3]
            guard alpha > 200 else { continue }

            let maxChannel = max(r, g, b)
            let minChannel = min(r, g, b)
            guard maxChannel > 20, minChannel < 235 else { continue }

            let rBucket = Int(r) * bucketLevels / 256
            let gBucket = Int(g) * bucketLevels / 256
            let bBucket = Int(b) * bucketLevels / 256
            let key = (rBucket << 8) | (gBucket << 4) | bBucket

            var bucket = buckets[key] ?? (r: 0, g: 0, b: 0, count: 0)
            bucket.r += Int(r)
            bucket.g += Int(g)
            bucket.b += Int(b)
            bucket.count += 1
            buckets[key] = bucket
        }

        let sortedBuckets = buckets.values.sorted { $0.count > $1.count }
        let minDistance: Double = 60

        var picked: [(color: Color, r: Double, g: Double, b: Double)] = []
        for bucket in sortedBuckets {
            let r = Double(bucket.r) / Double(bucket.count)
            let g = Double(bucket.g) / Double(bucket.count)
            let b = Double(bucket.b) / Double(bucket.count)

            let isDistinct = picked.allSatisfy { existing in
                let dr = existing.r - r, dg = existing.g - g, db = existing.b - b
                return (dr * dr + dg * dg + db * db).squareRoot() > minDistance
            }
            guard isDistinct else { continue }

            picked.append((Color(red: r / 255, green: g / 255, blue: b / 255), r, g, b))
            if picked.count == count { break }
        }

        return picked.map(\.color)
    }
}

extension Color {
    /// Caps brightness so the color stays legible as a backdrop behind light text, matching Apple Music's darkened artwork background.
    func darkened(maxBrightness: CGFloat = 0.35) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: saturation, brightness: min(brightness, maxBrightness))
    }

    /// Scales brightness down by `factor`, always yielding a color darker than the original —
    /// unlike `darkened(maxBrightness:)`, which only caps brightness and leaves already-dark
    /// colors untouched.
    func darkened(by factor: CGFloat) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: saturation, brightness: brightness * factor)
    }

    /// How light the color reads to the eye, 0 (black) to 1 (white) — a luma-weighted mix of the
    /// channels, so a saturated blue reads as darker than an equally "bright" yellow.
    var perceivedLightness: CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }

    /// The color's HSB saturation, 0 (gray) to 1 (fully saturated).
    var saturation: CGFloat {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return saturation
    }

    /// Scales saturation up by `factor`, clamped to fully saturated — makes a color more vivid
    /// without touching its hue or brightness.
    func saturated(by factor: CGFloat) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(saturation * factor, 1), brightness: brightness)
    }

    /// Linearly blends towards `other` in RGB space — `fraction` is clamped to 0...1, where 0 is
    /// this color and 1 is `other`.
    func interpolated(to other: Color, fraction: CGFloat) -> Color {
        let t = min(max(fraction, 0), 1)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        UIColor(self).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        UIColor(other).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            opacity: a1 + (a2 - a1) * t
        )
    }
}

extension [Color] {
    /// Pulls every color toward the group's average by `fraction` (0 = untouched, 1 = all
    /// collapse to the same average color) — softens how starkly different the picked colors
    /// look next to each other in the gradient, without losing the overall palette.
    func reducedContrast(by fraction: CGFloat) -> [Color] {
        guard count > 1 else { return self }
        var totalRed: CGFloat = 0, totalGreen: CGFloat = 0, totalBlue: CGFloat = 0
        for color in self {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            totalRed += red
            totalGreen += green
            totalBlue += blue
        }
        let n = CGFloat(count)
        let average = Color(red: totalRed / n, green: totalGreen / n, blue: totalBlue / n)
        return map { $0.interpolated(to: average, fraction: fraction) }
    }

    /// Lightens or darkens every color by one shared factor (scaling its RGB, so hue and
    /// saturation are kept) until the group's *average* perceived lightness equals `target` —
    /// lets a palette be pinned to a chosen overall lightness (e.g. slightly under the artwork's
    /// own average) without flattening the differences between its colors.
    func scaledToAverageLightness(_ target: CGFloat) -> [Color] {
        guard !isEmpty else { return self }
        let components: [(r: CGFloat, g: CGFloat, b: CGFloat)] = map { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return (red, green, blue)
        }
        func scaled(_ factor: CGFloat) -> [(r: CGFloat, g: CGFloat, b: CGFloat)] {
            components.map { (Swift.min($0.r * factor, 1), Swift.min($0.g * factor, 1), Swift.min($0.b * factor, 1)) }
        }
        func averageLightness(_ factor: CGFloat) -> CGFloat {
            scaled(factor).reduce(0) { $0 + 0.299 * $1.r + 0.587 * $1.g + 0.114 * $1.b } / CGFloat(count)
        }
        guard averageLightness(1) > 0 else { return self }

        // Channels clamp at 1, so the average only ever rises with the factor — bisect for it.
        var low: CGFloat = 0, high: CGFloat = 64
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if averageLightness(mid) < target { low = mid } else { high = mid }
        }
        return scaled((low + high) / 2).map { Color(red: $0.r, green: $0.g, blue: $0.b).darkened() }
    }

    /// Scales every color's HSB saturation by one shared factor (keeping hue and brightness) until
    /// the group's *average* saturation equals `target` — the saturation counterpart to
    /// `scaledToAverageLightness(_:)`, used to pin a palette's vividness relative to the artwork's
    /// own rather than leaving it at whatever `saturated(by:)`'s fixed factor happened to produce.
    func scaledToAverageSaturation(_ target: CGFloat) -> [Color] {
        guard !isEmpty else { return self }
        let components: [(hue: CGFloat, saturation: CGFloat, brightness: CGFloat)] = map { color in
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return (hue, saturation, brightness)
        }
        func scaled(_ factor: CGFloat) -> [(hue: CGFloat, saturation: CGFloat, brightness: CGFloat)] {
            components.map { ($0.hue, Swift.min($0.saturation * factor, 1), $0.brightness) }
        }
        func averageSaturation(_ factor: CGFloat) -> CGFloat {
            scaled(factor).reduce(0) { $0 + $1.saturation } / CGFloat(count)
        }
        guard averageSaturation(1) > 0 else { return self }

        // Saturation clamps at 1, so the average only ever rises with the factor — bisect for it.
        var low: CGFloat = 0, high: CGFloat = 64
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if averageSaturation(mid) < target { low = mid } else { high = mid }
        }
        return scaled((low + high) / 2).map { Color(hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness).darkened() }
    }
}
