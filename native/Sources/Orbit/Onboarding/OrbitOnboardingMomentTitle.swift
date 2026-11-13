import AppKit
import BrowserShell

/// The display title retains its paragraph layout and tracking throughout its reveal.
@MainActor
final class OrbitOnboardingMomentTitle: NSTextField {
    func play(delay: Double, stagger: Double) {
        wantsLayer = true
        OrbitOnboardingMotion.entrance(self, y: 32, duration: 0.5, delay: delay)
    }
}
