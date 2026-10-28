import AppKit
import BrowserEngine

/// Memory-only LRU. Switchers may reuse last-attached paint; folder previews require attachment.
@MainActor
final class BrowserSwitcherSnapshots<Surface: BrowserEngineSurface> {
    enum AttachmentPolicy { case lastAttachedPaint, attachedOnly }
    private let attachmentPolicy: AttachmentPolicy

    init(attachmentPolicy: AttachmentPolicy = .lastAttachedPaint) {
        self.attachmentPolicy = attachmentPolicy
    }

    private struct Entry {
        let generation: UInt64
        let token: UUID
        let created: TimeInterval
        var access: UInt64
        var image: NSImage?
        var task: Task<Void, Never>?
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var visible: Set<ObjectIdentifier> = []
    private var clock: UInt64 = 0
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var onChange: (() -> Void)?
    /// Attachment admission is injectable for engine-free capture race tests.
    var isAttached: (Surface) -> Bool = { $0.hostView.window != nil }
    let capacity = 12
    let maximumAge: TimeInterval = 30

    func protect(_ surfaces: [Surface]) { visible = Set(surfaces.map(ObjectIdentifier.init)) }

    func image(for surface: Surface) -> NSImage? {
        guard admitsAttachment(surface) else { invalidate(surface); return nil }
        let key = ObjectIdentifier(surface)
        guard let entry = entries[key], entry.generation == surface.documentGeneration,
              now() - entry.created <= maximumAge,
              !surface.isDisposed, !surface.navigationState.isLoading else { return nil }
        touch(key)
        return entry.image
    }

    /// force refreshes SPA pixels on every outgoing selection, even at the same generation.
    @discardableResult
    func request(_ surface: Surface, force: Bool = false) -> Task<Void, Never>? {
        let key = ObjectIdentifier(surface)
        guard admitsAttachment(surface) else { invalidate(surface); return nil }
        guard !surface.isDisposed, !surface.navigationState.isLoading else { invalidate(surface); return nil }
        if !force, let entry = entries[key], entry.generation == surface.documentGeneration,
           now() - entry.created <= maximumAge { touch(key); return entry.task }
        // A detached browser may return a successful white image. Do not replace its cached paint.
        guard isAttached(surface) else { return nil }
        if entries[key] == nil, entries.count >= capacity {
            guard let victim = entries.filter({ !visible.contains($0.key) })
                .min(by: { $0.value.access < $1.value.access })?.key else { return nil }
            entries.removeValue(forKey: victim)?.task?.cancel()
        }
        invalidate(surface)
        let generation = surface.documentGeneration
        let token = UUID()
        clock &+= 1
        entries[key] = Entry(generation: generation, token: token, created: now(), access: clock)
        let task = Task { [weak self, weak surface] in
            guard let surface else { return }
            let result = try? await surface.captureSnapshot(.init(width: OrbitTokens.Switcher.thumbnailWidth,
                afterScreenUpdates: true, documentGeneration: generation))
            guard let self, self.entries[key]?.token == token else { return }
            self.entries[key]?.task = nil
            guard !Task.isCancelled, self.admitsAttachment(surface),
                  !surface.isDisposed, !surface.navigationState.isLoading,
                  surface.documentGeneration == generation else {
                self.entries[key] = nil
                return
            }
            // Retain failed attempts until invalidation/expiry, preventing retry loops on redraw.
            guard let result, result.documentGeneration == generation,
                  !Self.isBlank(result.image) else { return }
            self.entries[key]?.image = NSImage(cgImage: result.image, size: .zero)
            self.onChange?()
        }
        entries[key]?.task = task
        return task
    }

    private func admitsAttachment(_ surface: Surface) -> Bool {
        attachmentPolicy == .lastAttachedPaint || isAttached(surface)
    }

    /// Uniform or almost uniform transparent/white/black frames are placeholders, not previews.
    /// A genuinely uniform page intentionally falls back to its title/favicon too.
    static func isBlank(_ image: CGImage) -> Bool {
        let side = 24
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let drew = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return true }
        var minimum = [UInt8](repeating: 255, count: 4)
        var maximum = [UInt8](repeating: 0, count: 4)
        for pixel in 0..<(side * side) {
            for channel in 0..<4 {
                let value = bytes[pixel * 4 + channel]
                minimum[channel] = min(minimum[channel], value)
                maximum[channel] = max(maximum[channel], value)
            }
        }
        return (0..<4).allSatisfy { Int(maximum[$0]) - Int(minimum[$0]) <= 3 }
    }

    private func touch(_ key: ObjectIdentifier) { clock &+= 1; entries[key]?.access = clock }

    /// Returning to a document supersedes its earlier outgoing paint. A completed cache entry
    /// stays useful; only a pending request is invalidated before the native host is reparented.
    func cancelPendingCapture(for surface: Surface) {
        let key = ObjectIdentifier(surface)
        guard entries[key]?.task != nil else { return }
        entries.removeValue(forKey: key)?.task?.cancel()
    }

    func invalidate(_ surface: Surface) {
        entries.removeValue(forKey: ObjectIdentifier(surface))?.task?.cancel()
    }

    func retain(_ surfaces: [Surface]) {
        let keys = Set(surfaces.map(ObjectIdentifier.init))
        visible.formIntersection(keys)
        for key in Array(entries.keys) where !keys.contains(key) {
            entries.removeValue(forKey: key)?.task?.cancel()
        }
    }

    func shutdown() {
        for entry in entries.values { entry.task?.cancel() }
        entries.removeAll()
        visible.removeAll()
    }
}
