import AppKit
import QuartzCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Orbit Command Bar, Peek and Little Orbit motion", .serialized)
@MainActor
struct MotionATests {
    @Test("Immediate Split promotion cancels an unfinished background transition")
    func immediateBackgroundRestoration() {
        let card = BrowserContentCardView()
        card.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        card.setPeekDimmed(true, animated: true)
        #expect(card.layer?.animation(forKey: "peek.background.opacity") != nil)
        card.setPeekDimmed(false, animated: false)
        #expect(card.peekRecede == 0 && card.alphaValue == 1)
        #expect(card.layer?.animation(forKey: "peek.background.opacity") == nil)
        #expect(card.layer?.animation(forKey: "peek.background.transform") == nil)
    }

    @Test("Peek uses Orbit's distinct CA springs without doubling their Core Animation time")
    func recoveredSprings() {
        let cases: [(OrbitTokens.Spring, Double, Double)] = [
            (BrowserPeekMotion.present, 0.245, 0.865),
            (BrowserPeekMotion.dismiss, 0.225, 0.895),
            (BrowserPeekMotion.promote, 0.18, 0.885),
            (BrowserPeekMotion.sourcePresent, 0.1225, 0.95),
            (BrowserPeekMotion.sourceDismiss, 0.14625, 0.95)
        ]
        for (spring, response, ratio) in cases {
            #expect(abs(spring.response - response) < 1e-12)
            #expect(abs(spring.dampingFraction - ratio) < 1e-12)
            let animation = spring.animation(keyPath: "position")
            #expect(animation.mass == 1 && animation.initialVelocity == 0)
            #expect(abs(animation.stiffness - pow(2 * .pi / response, 2)) < 1e-9)
            #expect(abs(animation.damping - 4 * .pi * ratio / response) < 1e-9)
            #expect(animation.duration == animation.settlingDuration)
            #expect(animation.speed == 1 && animation.beginTime == 0)
        }
        #expect(abs(BrowserPeekMotion.sourceDismissDelay - 0.07875) < 1e-12)
        #expect(BrowserPeekMotion.dim == BrowserPeekMotion.dismiss)
        #expect(BrowserPeekMotion.undim == BrowserPeekMotion.present)
        #expect(BrowserPeekMotion.backgroundInset == 9 && BrowserPeekMotion.backgroundOpacity == 0.3)
    }

    @Test("A link keeps its aspect ratio at the start; the modal uses 80 percent width and 12 point insets")
    func linkGeometry() {
        let overlay = BrowserPeekOverlayView()
        overlay.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        #expect(overlay.cardFrame == NSRect(x: 80, y: 12, width: 640, height: 576))
        let link = NSRect(x: 200, y: 100, width: 160, height: 20)
        let source = BrowserPeekMotion.sourceGeometry(source: link, card: overlay.cardFrame)
        #expect(source.scale == 0.25 && source.height == 80)
        #expect(source.height * source.scale == link.height)
        // Orbit interpolates scale and clipped height separately, so the visible height is
        // their product. A stretched page would be 298 points at the same half progress.
        let halfScale = source.scale + (1 - source.scale) * 0.5
        let halfHeight = source.height + (overlay.cardFrame.height - source.height) * 0.5
        #expect(halfScale * halfHeight == 205)
    }

    @Test("The modal fills the document column's window height and pivots around its clip centre")
    func windowColumnGeometry() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780))
        let document = NSView(frame: NSRect(x: 280, y: 10, width: 830, height: 760))
        let overlay = BrowserPeekOverlayView()
        root.addSubview(document)
        root.addSubview(overlay)
        overlay.frame = root.bounds
        overlay.contentAnchor = document
        overlay.show(NSView(), animated: false)
        #expect(overlay.cardFrame == NSRect(x: 364, y: 12, width: 672, height: 756))
        let card = overlay.subviews[1]
        #expect(card.layer?.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        #expect(card.layer?.position == CGPoint(x: 700, y: 390))
    }

    @Test("Little Orbit uses the same AppKit panel window family with no second content zoom")
    func nativePanelPresentation() {
        _ = NSApplication.shared
        let panel = BrowserQuickWindowPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 329),
                                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(panel.animationBehavior == .default)
        #expect(panel.canBecomeKey && panel.canBecomeMain)
        #expect(panel.alphaValue == 1)
        #expect(panel.contentView?.layer?.animation(forKey: "quickWindow.present") == nil)
        #expect(!panel.isVisible)
    }
}
}
