import AppKit
import QuartzCore

/// Address pill motion: 0.12 s ease-out,
/// 22 pt loupe exit, aligned status baseline.
/// The 28 Oct recording shows selection-triggered reflow, not a second pager spring.
enum AddressStatusMotion {
    static let duration: TimeInterval = 0.12
    static let baseline: CGFloat = -4
    static let iconTravel: CGFloat = 22
    static let timingFunction = CAMediaTimingFunctionName.easeOut

    @MainActor
    static func animate(_ view: NSView, changes: () -> Void, animated: Bool = true) {
        let enabled = animated && view.window?.isVisible == true && !OrbitMotionPreferences.prefersReducedMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = enabled ? duration : 0
            context.timingFunction = CAMediaTimingFunction(name: timingFunction)
            context.allowsImplicitAnimation = enabled
            changes()
            view.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    static func translate(_ view: NSView, from offset: CGFloat) {
        guard offset != 0, view.window?.isVisible == true, !OrbitMotionPreferences.prefersReducedMotion else {
            view.layer?.removeAnimation(forKey: "address-reflow")
            return
        }
        view.wantsLayer = true
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        // A new selection can interrupt the previous reflow without jumping back to its model frame.
        let current = view.layer?.presentation()?.transform.m41 ?? 0
        animation.fromValue = offset + current
        animation.toValue = 0
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timingFunction)
        view.layer?.add(animation, forKey: "address-reflow")
    }
}
