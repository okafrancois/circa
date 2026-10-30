import AppKit
import BrowserShell
import BrowserCore
import QuartzCore

@MainActor
final class OrbitOnboardingBackgroundView: NSView {
    let glow = CAGradientLayer()
    private(set) var theme: BrowserSpaceTheme?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = OrbitOnboardingColors.stage.cgColor
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = BrandPalette.glowStops
        layer?.addSublayer(glow)
        apply(theme: nil)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        glow.frame = CGRect(x: bounds.midX - 900, y: bounds.height - 380, width: 1800, height: 900)
    }
    func apply(theme: BrowserSpaceTheme?) {
        self.theme = theme
        glow.colors = BrandPalette.glowColors
    }
}
