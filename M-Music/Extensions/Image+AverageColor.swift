import SwiftUI
import CoreImage

extension UIImage {
    func averageColor() -> Color? {
        guard let inputImage = CIImage(image: self) else { return nil }

        let extent = inputImage.extent
        let extentVector = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)

        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: inputImage,
            kCIInputExtentKey: extentVector
        ]), let outputImage = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: kCFNull as Any])
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)

        return Color(
            red: Double(bitmap[0]) / 255,
            green: Double(bitmap[1]) / 255,
            blue: Double(bitmap[2]) / 255
        )
    }
}

extension Image {
    @MainActor
    func averageColor() -> Color? {
        ImageRenderer(content: self).uiImage?.averageColor()
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
}
