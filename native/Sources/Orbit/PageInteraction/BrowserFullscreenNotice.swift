import AppKit
import QuartzCore

/// "To exit full screen, press ⎋." pill shown at the top right while a web page holds element or
/// page fullscreen. It stays until fullscreen ends (no timer) and leaves with the fullscreen layout.
/// Values come from frame measurements: 14 pt medium label, 12 pt horizontal padding, 42 pt tall,
/// 12 pt corners, 4 pt from the top and right edges of the page area, the same navy in light and dark.
@MainActor
final class BrowserFullscreenNotice: NSView {
    static let height: CGFloat = 42
    static let cornerRadius: CGFloat = 12
    static let edgeInset: CGFloat = 4
    static let horizontalPadding: CGFloat = 12
    /// Entry spring (scale 0.42 → 1, anchored top centre) and linear opacity ramp, measured at 60 fps.
    static let springStiffness: CGFloat = 324
    static let springDamping: CGFloat = 22.68
    static let startScale: CGFloat = 0.42
    static let fadeDelay: CFTimeInterval = 0.023
    static let fadeDuration: CFTimeInterval = 0.135

    private let label: NSTextField

    init(in root: NSView) {
        label = NSTextField(labelWithString: uiText("To exit full screen, press ⎋."))
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label.stringValue)

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        root.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
            trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -Self.edgeInset),
            topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: Self.edgeInset)
        ])
        root.layoutSubtreeIfNeeded()
        playEntry()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func makeBackingLayer() -> CALayer {
        let gradient = CAGradientLayer()
        // Top to bottom navy, measured: rgb(34, 24, 91) to rgb(26, 19, 70).
        gradient.colors = [NSColor(srgbRed: 34 / 255, green: 24 / 255, blue: 91 / 255, alpha: 1).cgColor,
                           NSColor(srgbRed: 26 / 255, green: 19 / 255, blue: 70 / 255, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.cornerRadius = Self.cornerRadius
        gradient.cornerCurve = .continuous
        gradient.borderWidth = 0.5
        gradient.borderColor = NSColor.black.withAlphaComponent(0.18).cgColor
        gradient.shadowColor = NSColor.black.cgColor
        gradient.shadowOpacity = 0.3
        gradient.shadowRadius = 8
        gradient.shadowOffset = CGSize(width: 0, height: -2)
        return gradient
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.cornerRadius,
                                   cornerHeight: Self.cornerRadius, transform: nil)
    }

    private func playEntry() {
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let height = Self.height
        func spring(_ keyPath: String, from: CGFloat, to: CGFloat) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.mass = 1
            animation.stiffness = Self.springStiffness
            animation.damping = Self.springDamping
            animation.initialVelocity = 0
            animation.duration = animation.settlingDuration
            return animation
        }
        // The scale is about the centre: translate by half the lost height to keep the top edge fixed.
        // Layer space is y-up: the shift is positive (up) while scaled.
        let group = CAAnimationGroup()
        let scale = spring("transform.scale", from: Self.startScale, to: 1)
        let shift = spring("transform.translation.y", from: height / 2 * (1 - Self.startScale), to: 0)
        group.animations = [scale, shift]
        group.duration = scale.duration
        layer.add(group, forKey: "entry")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = CACurrentMediaTime() + Self.fadeDelay
        fade.duration = Self.fadeDuration
        fade.fillMode = .backwards
        layer.add(fade, forKey: "fade")
    }

    func dismiss() {
        layer?.removeAllAnimations()
        removeFromSuperview()
    }
}
