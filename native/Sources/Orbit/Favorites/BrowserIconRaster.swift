import AppKit
import BrowserEngine
import ImageIO

/// A single, eagerly decoded representation sized for the largest sidebar tile at 2x.
/// Avoid NSImage(data:), which can retain the source and lazily create full-size variants.
@MainActor
enum BrowserIconRaster {
    /// Bytes are engine PNGs (extension icons, the profile icon cache); they still pass the gate.
    static func image(data: Data, pixels: Int = 64, size: CGFloat = 32) -> NSImage? {
        guard let image = BrowserUntrustedImage.thumbnail(data, allowing: [.png], maximumBytes: 524_288,
                                                          maximumPixelSize: pixels) else { return nil }
        let scale = max(1, CGFloat(max(image.width, image.height)) / size)
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    static func cost(_ image: NSImage) -> Int {
        image.representations.reduce(256) { total, rep in
            total + ((rep as? NSBitmapImageRep).map { $0.bytesPerRow * $0.pixelsHigh }
                ?? max(0, rep.pixelsWide * rep.pixelsHigh * 4))
        }
    }
}
