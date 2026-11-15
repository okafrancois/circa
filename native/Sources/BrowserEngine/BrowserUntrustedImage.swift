import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The single gate for image bytes that come from a page, the network, sync or another
/// untrusted origin. The engine stays the preferred decoder; the shell only decodes here.
///
/// The gate never lets ImageIO sniff the format: bytes must start with an allowed magic
/// number, the source is created with that type as a hint, and ImageIO must report exactly
/// the same type. Frame count, source dimensions and output size are bounded, and the
/// source is never cached. Process-wide `CGImageSourceSetAllowableTypes` is deliberately
/// not used, so bundled app images keep every format.
public enum BrowserUntrustedImage {
    public enum Format: String, CaseIterable, Sendable {
        case png, jpeg, gif, ico

        public var typeIdentifier: String {
            switch self {
            case .png: UTType.png.identifier
            case .jpeg: UTType.jpeg.identifier
            case .gif: UTType.gif.identifier
            case .ico: UTType.ico.identifier
            }
        }

        fileprivate var signatures: [[UInt8]] {
            switch self {
            case .png: [[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]]
            case .jpeg: [[0xFF, 0xD8, 0xFF]]
            case .gif: [Array("GIF87a".utf8), Array("GIF89a".utf8)]
            case .ico: [[0x00, 0x00, 0x01, 0x00]]
            }
        }
    }

    /// Formats a site may legitimately serve as a favicon. SVG is rendered by the engine only.
    public static let webIconFormats: Set<Format> = [.png, .jpeg, .gif, .ico]
    public static let defaultMaximumFrames = 64
    public static let defaultMaximumDimension = 1_024

    /// Format from the leading bytes only; nil for anything outside the allow-list.
    public static func sniff(_ data: Data) -> Format? {
        Format.allCases.first { format in format.signatures.contains { data.starts(with: $0) } }
    }

    /// A validated, uncached source. Callers may read properties; pixels must come from
    /// `thumbnail`. Returns nil when any check fails.
    public static func source(_ data: Data, allowing formats: Set<Format>, maximumBytes: Int,
                              maximumFrames: Int = defaultMaximumFrames,
                              maximumDimension: Int = defaultMaximumDimension) -> (source: CGImageSource, format: Format)? {
        guard !data.isEmpty, data.count <= maximumBytes, let format = sniff(data), formats.contains(format) else { return nil }
        let options = [kCGImageSourceTypeIdentifierHint: format.typeIdentifier as CFString,
                       kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              (CGImageSourceGetType(source) as String?) == format.typeIdentifier,
              CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        let frames = CGImageSourceGetCount(source)
        guard frames >= 1, frames <= maximumFrames,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else { return nil }
        return (source, format)
    }

    /// First frame decoded at no more than `maximumPixelSize` on its longest side.
    public static func thumbnail(_ data: Data, allowing formats: Set<Format>, maximumBytes: Int, maximumPixelSize: Int,
                                 maximumFrames: Int = defaultMaximumFrames,
                                 maximumDimension: Int = defaultMaximumDimension) -> CGImage? {
        guard maximumPixelSize > 0,
              let (source, _) = source(data, allowing: formats, maximumBytes: maximumBytes,
                                       maximumFrames: maximumFrames, maximumDimension: maximumDimension) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Re-encodes an allowed web icon as the owned PNG representation the shell stores.
    public static func favicon(_ data: Data, sourceURL: URL, allowing formats: Set<Format> = webIconFormats,
                               maximumBytes: Int, maximumDimension: Int = 2_048) -> BrowserFaviconImage? {
        guard let image = thumbnail(data, allowing: formats, maximumBytes: maximumBytes,
                                    maximumPixelSize: BrowserFaviconImage.maximumDimension,
                                    maximumDimension: maximumDimension) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return BrowserFaviconImage(sourceURL: sourceURL, png: png as Data)
    }

    /// Reads at most `maximumBytes` from an async byte stream; nil once the cap is exceeded.
    public static func collect<S: AsyncSequence>(_ bytes: S, expectedLength: Int64, maximumBytes: Int) async throws -> Data?
        where S.Element == UInt8 {
        guard expectedLength <= Int64(maximumBytes) else { return nil }
        var data = Data()
        if expectedLength > 0 { data.reserveCapacity(Int(expectedLength)) }
        for try await byte in bytes {
            guard !Task.isCancelled, data.count < maximumBytes else { return nil }
            data.append(byte)
        }
        return data
    }
}
