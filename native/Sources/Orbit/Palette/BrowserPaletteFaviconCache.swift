import AppKit
import BrowserCore
import BrowserEngine
import ImageIO

private struct PaletteDecodedImage: @unchecked Sendable { let image: CGImage }

/// Decodes bounded engine PNG references through `BrowserUntrustedImage` on a utility task. No URL loading or shared-profile
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

    /// Accepts profile-local history addresses and the PNG references built from engine pixels.
    /// Page-declared favicon URLs are never decoded here: rows without engine pixels keep the
    /// placeholder.
    func image(for url: URL, resolve: (@MainActor () async -> URL?)? = nil) -> NSImage? {
        guard BrowserHistoryFavicon.isStoredReference(url) || BrowserHistoryFavicon.png(url) != nil else { return nil }
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
        guard let png = BrowserHistoryFavicon.png(url),
              let image = BrowserUntrustedImage.thumbnail(png, allowing: [.png], maximumBytes: BrowserFaviconImage.maximumBytes,
                                                          maximumPixelSize: pixels, maximumFrames: 1, maximumDimension: 512) else { return nil }
        return PaletteDecodedImage(image: image)
    }
}
