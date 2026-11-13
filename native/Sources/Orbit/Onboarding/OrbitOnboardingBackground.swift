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
        glow.type = .axial
        glow.startPoint = CGPoint(x: 0.5, y: 0)
        glow.endPoint = CGPoint(x: 0.5, y: 1)
        glow.locations = [0, 0.55, 0.92]
        layer?.addSublayer(glow)
        apply(theme: nil)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        glow.frame = bounds
    }
    func apply(theme: BrowserSpaceTheme?) {
        self.theme = theme
        glow.colors = [BrandPalette.rgb(0xC9D8FA).cgColor, BrandPalette.rgb(0xE4E6F1).cgColor, BrandPalette.paper.cgColor]
    }
}
