import AppKit
import QuartzCore
import BrowserShell

/// "Cannot Add New Pane": shown at the window's top-right corner when a tab is dropped on a split
/// that already holds the maximum number of panes. One bubble per window; a new refusal replaces it.
@MainActor
final class BrowserSplitLimitBubble: NSView {
    enum Metrics {
        static let inset: CGFloat = 4.5
        static let height: CGFloat = 41.5
        static let horizontalPadding: CGFloat = 12
        static let radius: CGFloat = 11.5
        static let fontSize: CGFloat = 14
        /// Scale-in spring from the top edge, 0 → 1 (mass 1).
        static let stiffness: CGFloat = 270
        static let damping: CGFloat = 23
        static let fadeIn: CFTimeInterval = 0.2
        static let hold: Duration = .seconds(2)
        static let fadeOut: CFTimeInterval = 0.2
    }

    static let identifier = "split-limit-bubble"

    private let fill = CAGradientLayer()
    private let label = NSTextField(labelWithString: uiText("Cannot Add New Pane"))
    private var dismissal: Task<Void, Never>?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(theme: OrbitTokens.SpaceTheme) {
        super.init(frame: .zero)
        wantsLayer = true
        label.font = BrandTextStyle.ui.font(size: Metrics.fontSize, weight: .medium)
        label.textColor = OrbitTokens.Color.Text.primary
        label.alignment = .center
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 2 * Metrics.horizontalPadding, height: Metrics.height)
        setFrameSize(size)
        fill.frame = bounds
        fill.cornerRadius = Metrics.radius
        fill.borderWidth = 0.5
        fill.masksToBounds = true
        layer?.addSublayer(fill)
        apply(theme)
        label.frame = NSRect(x: Metrics.horizontalPadding, y: (size.height - label.frame.height) / 2,
                             width: size.width - 2 * Metrics.horizontalPadding, height: label.frame.height)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier(Self.identifier)
        setAccessibilityLabel(uiText("Cannot Add New Pane"))
    }

    required init?(coder: NSCoder) { nil }

    /// The Space colour, lighter at the top edge than at the bottom one.
    private func apply(_ theme: OrbitTokens.SpaceTheme) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let first = theme.stops.first ?? OrbitTokens.Color.Surface.popover
            let last = theme.stops.last ?? first
            fill.colors = [last.cgColor, first.cgColor]
            fill.borderColor = OrbitTokens.Color.Text.primary.withAlphaComponent(0.25).cgColor
        }
    }

    static func show(in root: NSView, theme: OrbitTokens.SpaceTheme) {
        for old in root.subviews where old.accessibilityIdentifier() == identifier { old.removeFromSuperview() }
        let bubble = BrowserSplitLimitBubble(theme: theme)
        let size = bubble.frame.size
        let top = root.isFlipped ? Metrics.inset : root.bounds.maxY - Metrics.inset - size.height
        bubble.frame.origin = NSPoint(x: root.bounds.maxX - Metrics.inset - size.width, y: top)
        bubble.autoresizingMask = root.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        root.addSubview(bubble, positioned: .above, relativeTo: nil)
        bubble.animateIn()
        NSAccessibility.post(element: root, notification: .announcementRequested, userInfo: [
            .announcement: uiText("Cannot Add New Pane"), .priority: NSAccessibilityPriorityLevel.high.rawValue])
        bubble.scheduleDismissal()
    }

    private func animateIn() {
        guard let layer, !OrbitMotionPreferences.prefersReducedMotion else { return }
        // Layer-backed views scale about their origin; keep the top edge's centre fixed.
        let w = bounds.width, h = bounds.height
        let collapsed = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(w / 2, h, 0), 0.001, 0.001, 1),
                                               -w / 2, -h, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = Metrics.stiffness
        spring.damping = Metrics.damping
        spring.fromValue = NSValue(caTransform3D: collapsed)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "split-limit.scale")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Metrics.fadeIn
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "split-limit.fade")
    }

    private func scheduleDismissal() {
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Metrics.hold)
            guard !Task.isCancelled, let self, superview != nil else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = OrbitMotionPreferences.prefersReducedMotion ? 0 : Metrics.fadeOut
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.removeFromSuperview() }
            }
        }
    }

    override func removeFromSuperview() {
        dismissal?.cancel()
        super.removeFromSuperview()
    }
}
