import AppKit
import BrowserCore
import BrowserEngine
import ImageIO
import UniformTypeIdentifiers

/// Compressed pixels only; decoded backing is created only for a visible wake cover.
struct BrowserSuspensionCover: Sendable {
    let jpeg: Data
    let size: CGSize
    let scale: CGFloat
    let url: URL
    let generation: UInt64

    static func encode(_ snapshot: BrowserSurfaceSnapshot, size: CGSize, scale: CGFloat,
                       url: URL, maximumBytes: Int) -> Self? {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, snapshot.image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), bytes.length <= maximumBytes else { return nil }
        return Self(jpeg: bytes as Data, size: size, scale: scale, url: url, generation: snapshot.documentGeneration)
    }

    func image() -> CGImage? {
        guard let provider = CGDataProvider(data: jpeg as CFData) else { return nil }
        // The provider keeps compressed JPEG bytes; no retained full-resolution bitmap cache.
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct BrowserSuspensionCoverStore {
    let budget: Int
    let perTabLimit: Int
    private var entries: [TabOccurrenceID: BrowserSuspensionCover] = [:]
    private var order: [TabOccurrenceID] = []
    private(set) var byteCount = 0
    var count: Int { entries.count }

    init(budget: Int = 48 * 1024 * 1024, perTabLimit: Int = 4 * 1024 * 1024) {
        self.budget = budget
        self.perTabLimit = perTabLimit
    }
    mutating func insert(_ cover: BrowserSuspensionCover, for id: TabOccurrenceID) {
        remove(id)
        guard cover.jpeg.count <= min(budget, perTabLimit) else { return }
        while byteCount + cover.jpeg.count > budget, let oldest = order.first { remove(oldest) }
        entries[id] = cover; order.append(id); byteCount += cover.jpeg.count
    }
    mutating func value(for id: TabOccurrenceID) -> BrowserSuspensionCover? {
        guard let value = entries[id] else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return value
    }
    mutating func remove(_ id: TabOccurrenceID) {
        if let value = entries.removeValue(forKey: id) { byteCount -= value.jpeg.count }
        order.removeAll { $0 == id }
    }
    mutating func retain(_ ids: Set<TabOccurrenceID>) {
        for id in order where !ids.contains(id) { remove(id) }
    }
}

@MainActor
final class BrowserSuspensionCoverView: NSView {
    var resized: (() -> Void)?
    private let capturedScale: CGFloat
    override var wantsUpdateLayer: Bool { true }
    // Contents are supplied once; AppKit must not redraw an empty view over the image.
    override func updateLayer() {}
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window, window.backingScaleFactor != capturedScale { resized?() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { resized?() }
    }
    init(image: CGImage, size: NSSize, scale: CGFloat) {
        capturedScale = scale
        super.init(frame: NSRect(origin: .zero, size: size))
        autoresizingMask = [.width, .height]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        wantsLayer = true
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                          "opacity": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
        layer?.contents = image
        layer?.contentsScale = scale
        layer?.contentsGravity = .resize
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
}
