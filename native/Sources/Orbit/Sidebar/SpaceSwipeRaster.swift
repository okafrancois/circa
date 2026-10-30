import AppKit
import QuartzCore

/// Prepaint a detached, metadata-only neighbor at the window's backing scale. Its native
/// geometry remains authoritative, but SF Symbol rasterization and text drawing happen at
/// idle instead of inside the first tracking frame. Live controls return at adoption.
@MainActor
final class SpaceSwipeRaster {
    private weak var view: NSView?
    private let layer = CALayer()
    private let children: [(NSView, Bool)]
    private let foreground: NSColor?
    private let overlays: [NSColor]
    var size: CGSize { layer.bounds.size }

    init?(view: NSView, scale: CGFloat, foreground: NSColor? = nil, overlays: [NSColor] = []) {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(view.bounds.width * scale)),
                pixelsHigh: Int(ceil(view.bounds.height * scale)), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        self.overlays = overlays.map { $0.resolved(for: view.effectiveAppearance) }
        self.foreground = foreground?.resolved(for: view.effectiveAppearance)
        self.view = view
        children = view.subviews.map { ($0, $0.isHidden) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.frame = view.bounds
        layer.contentsScale = scale
        layer.contents = image
        layer.zPosition = 100
        // Cached AppKit pixels use a top-left origin inside these flipped sidebar views.
        layer.contentsGravity = .resize
        view.layer?.addSublayer(layer)
        // Merely hiding ancestors still makes AppKit prepare descendant NSImageView layers
        // on attachment. Retain the native subtree off-window until the page is adopted.
        for (child, _) in children { child.removeFromSuperview() }
        CATransaction.commit()
    }

    /// Cached state overlays must preserve contrast as the underlying fill changes too.
    func matchesPaint(foreground color: NSColor, background: NSColor?, appearance: NSAppearance) -> Bool {
        let ink = color.resolved(for: appearance)
        guard foreground == ink else { return false }
        guard let background else { return true }
        return overlays.allSatisfy { OrbitThemeForeground.contrastRatio(ink, on: OrbitThemeForeground.composite($0, on: background)) >= 3 }
    }

    func restore() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        for (child, hidden) in children {
            view?.addSubview(child)
            child.isHidden = hidden
        }
        view?.needsDisplay = true
        CATransaction.commit()
    }
}
