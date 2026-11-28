import AppKit
import BrowserEngine
import ImageIO

/// Eagerly decoded, bounded representations sized for sidebar controls.
/// Avoid NSImage(data:), which can retain the source and lazily create full-size variants.
@MainActor
enum BrowserIconRaster {
    /// Bytes are engine PNGs (extension icons, the profile icon cache); they still pass the gate.
    static func image(data: Data, pixels: Int = 64, size: CGFloat = 32,
                      preserveOneX: Bool = false) -> NSImage? {
        guard let image = BrowserUntrustedImage.thumbnail(data, allowing: [.png], maximumBytes: 524_288,
                                                          maximumPixelSize: pixels) else { return nil }
        let scale = max(1, CGFloat(max(image.width, image.height)) / size)
        let displaySize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        guard preserveOneX, scale == 1, let doubled = doublePixels(of: image) else {
            return NSImage(cgImage: image, size: displaySize)
        }
        // NSImage(cgImage:size:) can cache the 1x source at screen scale with interpolation.
        // Explicit bitmap representations let AppKit choose the correct pixels for each scale.
        let result = NSImage(size: displaySize)
        for bitmap in [image, doubled] {
            let rep = NSBitmapImageRep(cgImage: bitmap)
            rep.size = displaySize
            result.addRepresentation(rep)
        }
        return result
    }

    private static func doublePixels(of image: CGImage) -> CGImage? {
        let width = image.width * 2
        let height = image.height * 2
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func cost(_ image: NSImage) -> Int {
        image.representations.reduce(256) { total, rep in
            total + ((rep as? NSBitmapImageRep).map { $0.bytesPerRow * $0.pixelsHigh }
                ?? max(0, rep.pixelsWide * rep.pixelsHigh * 4))
        }
    }
}
