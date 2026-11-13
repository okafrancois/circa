import AppKit
import BrowserShell
import SwiftUI

/// One shared, deterministic paper tile; it never receives an input event.
@MainActor
final class OrbitPaperGrainView: NSView {
    static let tile: NSImage? = {
        let image = BrowserText.secondaryBrandResource("paper-grain", extension: "png").flatMap { NSImage(contentsOf: $0) }
        image?.size = NSSize(width: 220, height: 220)
        return image
    }()
    /// Existing stored strengths stay untouched. The standard 0.3 dial value reproduces
    /// the onboarding's 50% multiply tile; zero removes the texture completely.
    static func opacity(for strength: CGFloat) -> CGFloat {
        let value = min(1, max(0, strength))
        return value <= 0.3 ? value / 0.3 * 0.5 : 0.5 + (value - 0.3) / 0.7 * 0.5
    }
    var strength: CGFloat = 0.3 { didSet { alphaValue = Self.opacity(for: strength) } }
    var patternOffset: CGPoint = .zero { didSet { if oldValue != patternOffset { needsDisplay = true } } }
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
        NSGraphicsContext.current?.patternPhase = NSPoint(x: -patternOffset.x, y: patternOffset.y)
        NSColor(patternImage: tile).setFill()
        dirtyRect.fill()
    }
}

struct OrbitPaperGrainSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { OrbitPaperGrainView() }
    func updateNSView(_ view: NSView, context: Context) {}
}
