import BrowserEngine
import CoreGraphics
import Foundation
import ImageIO

/// ImageIO decoding and resampling never need the surface or AppKit's main actor.
enum ChromiumSnapshotDecoder {
    static func decode(_ data: Data, width: CGFloat?, generation: UInt64) -> (snapshot: BrowserSurfaceSnapshot, decodedBytes: Int)? {
        guard !Task.isCancelled,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !Task.isCancelled, let base64 = object["data"] as? String,
              let png = Data(base64Encoded: base64), !Task.isCancelled,
              let source = CGImageSourceCreateWithData(png as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let image: CGImage
        if let width, width.isFinite, width >= 1, width <= 32768,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Double,
           let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Double,
           sourceWidth > 0, sourceHeight > 0, width < sourceWidth {
            let longest = max(width, (sourceHeight * width / sourceWidth).rounded())
            guard !Task.isCancelled,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: longest,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            image = thumbnail
        } else {
            guard !Task.isCancelled,
                  let original = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            image = original
        }
        guard !Task.isCancelled else { return nil }
        return (BrowserSurfaceSnapshot(image: image, documentGeneration: generation), image.bytesPerRow * image.height)
    }
}
