import AppKit
import ImageIO

/// An owned, memory-only representation received from this surface's engine/profile.
/// Metadata URL remains separate from bytes; consumers must preserve surface ownership checks.
public struct BrowserFaviconImage: Equatable, Sendable {
    public let sourceURL: URL
    public let png: Data
    public static let maximumBytes = 131_072
    public static let maximumDimension = 128

    public init?(sourceURL: URL, png: Data) {
        guard Self.allowsSourceURL(sourceURL), png.count <= Self.maximumBytes, png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Self.maximumDimension, height <= Self.maximumDimension else { return nil }
        self.sourceURL = sourceURL
        self.png = png
    }

    /// Source identity validation only. This never loads the URL.
    public static func allowsSourceURL(_ url: URL) -> Bool {
        let text = url.absoluteString
        guard text.utf8.count <= 8_192 else { return false }
        switch url.scheme?.lowercased() {
        case "http", "https": return url.host?.isEmpty == false
        case "data": return text.lowercased().hasPrefix("data:image/") && text.contains(",")
        default: return false
        }
    }

    /// Pixel decompression happens off the main thread, even for engine-owned PNGs.
    @MainActor public func nativeImage() async -> NSImage? {
        let data = png
        let decoded = await FaviconDecoder.shared.decode(data)
        guard !Task.isCancelled, let decoded else { return nil }
        return NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
    }
}

private struct DecodedFavicon: @unchecked Sendable { let image: CGImage }

/// Serial actor bounds native pixel-decompression concurrency to one across all consumers.
private actor FaviconDecoder {
    static let shared = FaviconDecoder()
    func decode(_ data: Data) -> DecodedFavicon? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return DecodedFavicon(image: image)
    }
}
