import BrowserEngine
import CoreGraphics
import Foundation
import ImageIO

/// ImageIO decoding and resampling never need the surface or AppKit's main actor.
enum ChromiumSnapshotDecoder {
    /// Native output uses pixels, matching the existing explicit-width PNG thumbnail contract.
    static func nativeRequest(size: CGSize, scale: CGFloat, width: CGFloat?) -> BrowserNativeCaptureRequest? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              scale.isFinite, scale > 0 else { return nil }
        let outputWidth = (width ?? size.width * scale).rounded()
        let outputHeight = (size.height * outputWidth / size.width).rounded()
        guard outputWidth.isFinite, outputHeight.isFinite,
              outputWidth >= 1, outputHeight >= 1, outputWidth <= 4096, outputHeight <= 4096 else { return nil }
        return .init(outputWidth: Int32(outputWidth), outputHeight: Int32(outputHeight))
    }

    /// The provider retains the owned Data; no PNG/base64 decode or second bitmap is needed.
    static func nativeImage(_ capture: BrowserNativeCapture) -> CGImage? {
        guard !Task.isCancelled, capture.status == .captured,
              capture.width > 0, capture.height > 0, capture.width <= 4096, capture.height <= 4096,
              capture.rowBytes == UInt32(capture.width) * 4,
              capture.pixels.count == Int(capture.rowBytes) * Int(capture.height),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: capture.pixels as CFData) else { return nil }
        return CGImage(width: Int(capture.width), height: Int(capture.height), bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: Int(capture.rowBytes), space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                           .union(.byteOrder32Little), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

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
