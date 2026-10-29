import AppKit
import BrowserCore
import BrowserEngine
import ImageIO

private struct PaletteDecodedImage: @unchecked Sendable { let image: CGImage }

/// Decodes bounded inline engine images on a utility task. No URL loading or shared-profile
/// image request is permitted here; image objects are cached on the main actor after decoding.
@MainActor
final class BrowserPaletteFaviconCache {
    private var images: [URL: NSImage] = [:]
    private var rejected: Set<URL> = []
    private var pending: [URL: Task<Void, Never>] = [:]
    private var notificationTask: Task<Void, Never>?
    var onChange: (() -> Void)?

    func image(for image: BrowserFaviconImage) -> NSImage? {
        guard let reference = BrowserHistoryFavicon.reference(png: image.png) else { return nil }
        return self.image(for: reference)
    }

    func waitForPendingImages() async {
        for task in pending.values { await task.value }
        await notificationTask?.value
    }

    func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard !rejected.contains(url), pending[url] == nil, url.scheme == "data", url.absoluteString.utf8.count <= 262_144 else { return nil }
        let pixels = Int(OrbitTokens.Metrics.CommandBar.iconTileSize * 2)
        pending[url] = Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) { Self.decode(url, pixels: pixels) }.value
            guard !Task.isCancelled, let self else { return }
            pending[url] = nil
            if let decoded {
                if images.count >= 256 { images.removeAll(keepingCapacity: true) }
                images[url] = NSImage(cgImage: decoded.image, size: NSSize(width: OrbitTokens.Metrics.CommandBar.iconTileSize, height: OrbitTokens.Metrics.CommandBar.iconTileSize))
                if notificationTask == nil {
                    notificationTask = Task { [weak self] in
                        await Task.yield()
                        guard !Task.isCancelled, let self else { return }
                        notificationTask = nil
                        onChange?()
                    }
                }
            } else { rejected.insert(url) }
        }
        return nil
    }

    func clear() {
        notificationTask?.cancel()
        notificationTask = nil
        for task in pending.values { task.cancel() }
        pending.removeAll()
        images.removeAll()
        rejected.removeAll()
    }

    private nonisolated static func decode(_ url: URL, pixels: Int) -> PaletteDecodedImage? {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[..<comma].lowercased()
        guard header.hasPrefix("data:image/"), header.hasSuffix(";base64"),
              let data = Data(base64Encoded: String(text[text.index(after: comma)...])), data.count <= 131_072,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...512).contains(width), (1...512).contains(height),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
              ] as CFDictionary) else { return nil }
        return PaletteDecodedImage(image: image)
    }
}
