import BrowserEngine
import CoreGraphics
import Foundation
import ImageIO

/// ImageIO decoding and resampling never need the surface or AppKit's main actor.
enum ChromiumSnapshotDecoder {
    static func decode(_ data: Data, width: CGFloat?, generation: UInt64) -> BrowserSurfaceSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base64 = object["data"] as? String, let png = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard let width, width.isFinite, width >= 1, width <= 32768, Int(width) != image.width else {
            return BrowserSurfaceSnapshot(image: image, documentGeneration: generation)
        }
        let height = max(1, Int((CGFloat(image.height) * width / CGFloat(image.width)).rounded()))
        guard let context = CGContext(data: nil, width: Int(width), height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(width), height: height))
        guard let scaled = context.makeImage() else { return nil }
        return BrowserSurfaceSnapshot(image: scaled, documentGeneration: generation)
    }
}
