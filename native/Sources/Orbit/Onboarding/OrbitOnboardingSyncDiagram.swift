import AppKit
import BrowserShell
import QuartzCore

@MainActor
final class OrbitOnboardingSyncDiagram: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for x: CGFloat in [0, 292] {
            let screen = CALayer(); screen.frame = CGRect(x: x, y: 0, width: 110, height: 70)
            screen.cornerRadius = 8; screen.masksToBounds = true
            screen.backgroundColor = NSColor.white.cgColor
            screen.borderColor = BrandPalette.controlBorder.cgColor; screen.borderWidth = 1
            let sidebar = CAGradientLayer(); sidebar.frame = CGRect(x: 0, y: 0, width: 32, height: 70)
            sidebar.colors = BrandPalette.sidebarPreviewColors
            sidebar.startPoint = CGPoint(x: 0, y: 1); sidebar.endPoint = CGPoint(x: 1, y: 0)
            screen.addSublayer(sidebar); layer?.addSublayer(screen)
        }
        let cloud = NSImageView(frame: NSRect(x: 179, y: 13, width: 44, height: 44))
        cloud.wantsLayer = true; cloud.layer?.cornerRadius = 22
        cloud.layer?.backgroundColor = NSColor.white.cgColor
        cloud.layer?.borderColor = BrandPalette.controlBorder.cgColor; cloud.layer?.borderWidth = 1
        cloud.image = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil)
        cloud.contentTintColor = BrandPalette.ink
        cloud.imageScaling = .scaleNone
        addSubview(cloud)
        for (index, x) in [CGFloat(124), CGFloat(237)].enumerated() {
            let link = CAShapeLayer(); link.frame = CGRect(x: x, y: 34, width: 26, height: 2)
            let path = CGMutablePath(); path.move(to: .zero); path.addLine(to: CGPoint(x: 26, y: 0))
            link.path = path; link.strokeColor = BrandPalette.ink3.cgColor; link.lineWidth = 2; link.lineDashPattern = [4, 4]
            layer?.addSublayer(link)
            if !OrbitMotionPreferences.prefersReducedMotion {
                let pulse = CABasicAnimation(keyPath: "opacity"); pulse.fromValue = 0.35; pulse.toValue = 1
                pulse.duration = 1.2; pulse.autoreverses = true; pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pulse.beginTime = CACurrentMediaTime() + Double(index) * 1.2
                link.add(pulse, forKey: "orbit.sync.pulse")
            }
        }
    }
    required init?(coder: NSCoder) { nil }
}
