import AppKit
import BrowserShell
import SwiftUI

/// One shared, deterministic paper tile; it never receives an input event.
@MainActor
final class OrbitPaperGrainView: NSView {
    private static let tile: NSImage? = {
        let image = BrowserText.secondaryBrandResource("paper-grain", extension: "png").flatMap { NSImage(contentsOf: $0) }
        image?.size = NSSize(width: 220, height: 220)
        return image
    }()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0.5
        layer?.compositingFilter = "multiplyBlendMode"
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let tile = Self.tile else { return }
        NSColor(patternImage: tile).setFill()
        dirtyRect.fill()
    }
}

struct OrbitPaperGrainSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { OrbitPaperGrainView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
