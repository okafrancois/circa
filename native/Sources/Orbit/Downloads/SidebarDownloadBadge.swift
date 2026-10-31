import AppKit
import BrowserCore
import QuartzCore

@MainActor
final class SidebarDownloadBadge: NSView {
    private var active = false
    private var file: BrowserDownloadKey?
    private var image: NSImage?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func render(active: Bool, completion: BrowserDownloadSnapshot?) {
        let changed = active != self.active
        self.active = active
        if file != completion?.key {
            file = completion?.key
            image = completion.map { NSWorkspace.shared.icon(forFile: $0.destinationURL?.path ?? $0.suggestedFilename) }
        }
        if !active { layer?.removeAllAnimations() }
        isHidden = !active && completion == nil
        needsDisplay = true
        guard changed, active, window?.isVisible == true, !OrbitMotionPreferences.prefersReducedMotion else { return }
        wantsLayer = true
        let motion = CAKeyframeAnimation(keyPath: "transform.translation.y")
        motion.values = [-7.0, -5.5, -4.0, -3.5, -3.5, 6.0, 10.0, 11.5, 12.0, 12.0, 11.0, 8.0, 6.0, 2.0, 0.5, -1.0, -1.5, -2.0, -2.0, -2.0, -1.0, -1.0, -1.0, -0.5, 0]
        motion.keyTimes = [0.0, 0.036364, 0.072727, 0.109091, 0.145455, 0.200001, 0.236363, 0.272727, 0.309092, 0.345454, 0.381818, 0.418183, 0.454545, 0.509091, 0.545455, 0.581819, 0.618182, 0.654546, 0.69091, 0.727273, 0.781818, 0.818182, 0.854547, 0.890909, 1]
        motion.duration = 0.458333
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.022, 0.062, 0.129, 0.143, 0.143, 0.505, 0.611, 0.646, 0.72, 0.749, 0.784, 0.788, 0.827, 0.917, 0.873, 0.925, 0.907, 0.975, 0.989, 0.962, 0.953, 1, 0.948, 0.931, 1]; fade.keyTimes = motion.keyTimes; fade.duration = motion.duration
        layer?.add(fade, forKey: "download.opacity")
        layer?.add(motion, forKey: "download.badge")
    }
    override func draw(_ dirtyRect: NSRect) {
        if active {
            let rect = NSRect(x: 7, y: 9, width: 18, height: 18)
            OrbitFloatingMaterial.style(for: effectiveAppearance).tint.setFill(); NSBezierPath(ovalIn: rect).fill()
            OrbitTokens.Color.Text.vibrant.setStroke()
            let circle = NSBezierPath(ovalIn: rect); circle.lineWidth = 2; circle.stroke()
            let arrow = NSBezierPath(); arrow.lineWidth = 1.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: 16, y: 13)); arrow.line(to: NSPoint(x: 16, y: 22))
            arrow.move(to: NSPoint(x: 12.5, y: 18)); arrow.line(to: NSPoint(x: 16, y: 22)); arrow.line(to: NSPoint(x: 19.5, y: 18)); arrow.stroke()
        } else if let image { image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
    }
}
