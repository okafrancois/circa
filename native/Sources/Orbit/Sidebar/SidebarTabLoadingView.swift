import AppKit
import QuartzCore

/// A favicon-sized activity ring. Detaching, hiding or recycling a row stops the animation.
@MainActor
final class SidebarTabLoadingView: NSView {
    private let ring = CAShapeLayer()
    var tint = OrbitTokens.ThemeAccent.defaultSpace.icon { didSet { updateColor() } }
    var isLoading = false { didSet { updateAnimation() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = OrbitTokens.Metrics.Sidebar.loadingRingWidth
        ring.lineCap = .round
        ring.strokeStart = 0.1
        ring.strokeEnd = 0.82
        layer?.addSublayer(ring)
        setAccessibilityElement(false)
        updateColor()
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: OrbitTokens.Metrics.Sidebar.loadingRingInset,
                                                       dy: OrbitTokens.Metrics.Sidebar.loadingRingInset), transform: nil)
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    override func viewDidHide() { super.viewDidHide(); updateAnimation() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateAnimation() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
    private func updateColor() { ring.strokeColor = tint.resolvedCGColor(for: effectiveAppearance) }
    private func updateAnimation() {
        guard isLoading, window != nil, !isHiddenOrHasHiddenAncestor, !OrbitTokens.Motion.prefersReducedMotion else {
            ring.removeAnimation(forKey: "loading")
            return
        }
        guard ring.animation(forKey: "loading") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi
        animation.duration = OrbitTokens.Motion.tabLoadingRotation
        animation.repeatCount = .infinity
        ring.add(animation, forKey: "loading")
    }
}
