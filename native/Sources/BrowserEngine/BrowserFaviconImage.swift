import AppKit
import ImageIO
import CryptoKit

/// An owned, memory-only representation received from this surface's engine/profile.
/// Metadata URL remains separate from bytes; consumers must preserve surface ownership checks.
public struct BrowserFaviconImage: Equatable, Sendable {
    public let sourceURL: URL
    public let png: Data
    public let contentHash: String
    public static let maximumBytes = 131_072
    public static let maximumDimension = 128

    public init?(sourceURL: URL, png: Data) {
        guard Self.allowsSourceURL(sourceURL),
              BrowserUntrustedImage.source(png, allowing: [.png], maximumBytes: Self.maximumBytes, maximumFrames: 1,
                                           maximumDimension: Self.maximumDimension) != nil else { return nil }
        self.sourceURL = sourceURL
        self.png = png
        contentHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
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
              let image = BrowserUntrustedImage.thumbnail(data, allowing: [.png], maximumBytes: BrowserFaviconImage.maximumBytes,
                                                          maximumPixelSize: 64, maximumFrames: 1,
                                                          maximumDimension: BrowserFaviconImage.maximumDimension) else { return nil }
        return DecodedFavicon(image: image)
    }
}
