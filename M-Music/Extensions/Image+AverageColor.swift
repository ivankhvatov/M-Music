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

extension Color {
    /// Caps brightness so the color stays legible as a backdrop behind light text, matching Apple Music's darkened artwork background.
    func darkened(maxBrightness: CGFloat = 0.35) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: saturation, brightness: min(brightness, maxBrightness))
    }
}
