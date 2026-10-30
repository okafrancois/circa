import AppKit
import BrowserShell
import QuartzCore

@MainActor
final class BrowserQuickWindowCopyFeedback: NSView {
    static let size = NSSize(width: 205, height: 48)
    static let topInset: CGFloat = 8
    static let trailingInset: CGFloat = 4
    static let fadeInDuration: TimeInterval = 1 / 15
    static let entranceDuration: TimeInterval = 0.25
    static let dismissalDuration: TimeInterval = 0.2
    static let visibleDuration: TimeInterval = 3.2
    static let fadeOutDuration: TimeInterval = 0
    let label = NSTextField(labelWithString: uiText("Copied Current URL"))
    let shareButton = BrowserQuickWindowButton()
    var onShare: (() -> Void)?
    private var dismissal: Task<Void, Never>?
    private(set) var presentation: UInt64 = 0

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        OrbitFloatingMaterial.install(in: self, radius: 12)
        shadow = NSShadow()
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow?.shadowBlurRadius = 16
        shadow?.shadowOffset = NSSize(width: 0, height: -8)
        label.font = BrandTextStyle.ui.font(size: 14, weight: .semibold)
        label.textColor = OrbitFloatingMaterial.body
        shareButton.image = OrbitIcon.image(sfName: "square.and.arrow.up", pointSize: 18,
                                            accessibilityDescription: uiText("Share…"))
        shareButton.isBordered = false
        shareButton.contentTintColor = OrbitFloatingMaterial.body
        shareButton.wantsLayer = true
        shareButton.layer?.cornerRadius = 6
        shareButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        shareButton.target = self
        shareButton.action = #selector(share)
        shareButton.setAccessibilityLabel(uiText("Share…"))
        for view in [label, shareButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: shareButton.leadingAnchor, constant: -8),
            shareButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shareButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            shareButton.widthAnchor.constraint(equalToConstant: 32),
            shareButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        setAccessibilityIdentifier("quick-window-copy-feedback")
        setAccessibilityLabel(label.stringValue)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func share() { onShare?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return shareButton.frame.contains(local) ? shareButton : nil
    }

    func show(in view: NSView) {
        dismissal?.cancel()
        presentation &+= 1
        let current = presentation
        layer?.removeAllAnimations()
        frame = NSRect(x: view.bounds.maxX - Self.size.width - Self.trailingInset,
                       y: view.isFlipped ? Self.topInset : view.bounds.maxY - Self.size.height - Self.topInset,
                       width: Self.size.width, height: Self.size.height)
        autoresizingMask = view.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        if superview !== view {
            removeFromSuperview()
            view.addSubview(self, positioned: .above, relativeTo: nil)
        }
        alphaValue = 1
        layoutSubtreeIfNeeded()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Self.fadeInDuration
            layer?.add(fade, forKey: "copy-opacity")
            // Grow from the top centre, with the top edge remaining eight points below the window.
            let scale = CAKeyframeAnimation(keyPath: "sublayerTransform")
            let values: [CGFloat] = [0.01, 0.16, 0.35, 0.52, 0.68, 0.84, 0.93, 0.98, 1]
            scale.values = values.map { value -> NSValue in
                NSValue(caTransform3D: Self.topAnchoredTransform(scale: value))
            }
            scale.keyTimes = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.65, 0.8, 1]
            scale.duration = Self.entranceDuration
            layer?.add(scale, forKey: "copy-entrance")
        }
        NSAccessibility.post(element: view, notification: .announcementRequested,
                             userInfo: [.announcement: label.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Self.visibleDuration)) } catch { return }
            guard let self, current == presentation else { return }
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let exit = CAKeyframeAnimation(keyPath: "sublayerTransform")
                exit.values = [CGFloat(1), 0.975, 0.934, 0.903, 0.842, 0.73, 0.684, 0.607, 0.536, 0.49, 0.444, 0.383, 0.337, 0.286, 0.265, 0.24, 0.15, 0.08, 0.01].map {
                    NSValue(caTransform3D: Self.topAnchoredTransform(scale: $0))
                }
                exit.keyTimes = [0, 0.0833, 0.125, 0.1667, 0.2083, 0.2917, 0.3333, 0.375, 0.4167, 0.4583, 0.5, 0.5417, 0.5833, 0.625, 0.6667, 0.7083, 0.8, 0.9, 1]
                exit.duration = Self.dismissalDuration
                exit.fillMode = .forwards
                exit.isRemovedOnCompletion = false
                layer?.add(exit, forKey: "copy-dismissal")
                do { try await Task.sleep(for: .seconds(Self.dismissalDuration)) } catch { return }
            }
            dismiss(presentation: current)
        }
    }

    static func topAnchoredTransform(scale: CGFloat) -> CATransform3D {
        // Sublayers use the view's unflipped local coordinates, with the top at height.
        let translation = CATransform3DMakeTranslation(size.width * (1 - scale) / 2, size.height * (1 - scale), 0)
        return CATransform3DScale(translation, scale, scale, 1)
    }

    func dismiss(presentation current: UInt64) {
        guard current == presentation else { return }
        dismissal?.cancel()
        dismissal = nil
        layer?.removeAllAnimations()
        removeFromSuperview()
    }
}
