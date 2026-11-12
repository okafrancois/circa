import AppKit
import BrowserCore
import BrowserEngine
import ImageIO

private struct PaletteDecodedImage: @unchecked Sendable { let image: CGImage }

/// Decodes bounded inline engine images on a utility task. No URL loading or shared-profile
/// image request is permitted here; image objects are cached on the main actor after decoding.
@MainActor
final class BrowserPaletteFaviconCache {
    private var images = BrowserCostCache<String, NSImage>(budget: 2 * 1024 * 1024)
    private var rejected = BrowserCostCache<String, Bool>(budget: 64 * 1024, countLimit: 512)
    private var pending: [String: Task<Void, Never>] = [:]
    private var notificationTask: Task<Void, Never>?
    private var pressure: BrowserMemoryPressure?
    init() { pressure = BrowserMemoryPressure { [weak self] in self?.clear() } }
    var onChange: (() -> Void)?

    func image(for image: BrowserFaviconImage) -> NSImage? {
        cached(key: image.contentHash) {
            await Task.detached(priority: .utility) {
                BrowserHistoryFavicon.reference(png: image.png)
            }.value
        }
    }

    func waitForPendingImages() async {
        for task in pending.values { await task.value }
        await notificationTask?.value
    }

    func image(for url: URL, resolve: (@MainActor () async -> URL?)? = nil) -> NSImage? {
        guard BrowserHistoryFavicon.isStoredReference(url) ||
              (url.scheme == "data" && url.absoluteString.utf8.count <= 262_144) else { return nil }
        return cached(key: url.absoluteString) {
            if BrowserHistoryFavicon.isStoredReference(url) { return await resolve?() }
            return url
        }
    }

    private func cached(key: String, reference: @escaping @MainActor () async -> URL?) -> NSImage? {
        if let image = images.value(for: key) { return image }
        guard rejected.value(for: key) == nil, pending[key] == nil, pending.count < 16 else { return nil }
        let pixels = Int(OrbitTokens.Metrics.CommandBar.iconTileSize * 2)
        pending[key] = Task { [weak self] in
            let url = await reference()
            let decoded = await Task.detached(priority: .utility) { url.flatMap { Self.decode($0, pixels: pixels) } }.value
            guard !Task.isCancelled, let self else { return }
            pending[key] = nil
            if let decoded {
                let image = NSImage(cgImage: decoded.image, size: NSSize(width: OrbitTokens.Metrics.CommandBar.iconTileSize, height: OrbitTokens.Metrics.CommandBar.iconTileSize))
                images.insert(image, for: key, cost: decoded.image.bytesPerRow * decoded.image.height + 384)
                if notificationTask == nil {
                    notificationTask = Task { [weak self] in
                        await Task.yield()
                        guard !Task.isCancelled, let self else { return }
                        notificationTask = nil
                        onChange?()
                    }
                }
            } else { rejected.insert(true, for: key, cost: 128) }
        }
        return nil
    }

    var cacheStatistics: [String: Int] {
        ["entries": images.count, "bytes": images.cost, "failures": rejected.count, "failureBytes": rejected.cost, "pending": pending.count]
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
