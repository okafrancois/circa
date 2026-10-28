import AppKit

/// The edge affordance precedes the creation page: a restrained pull, ring, then a filled plus.
@MainActor
final class SpaceCreationEdgeView: NSView {
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    var confirmation: CGFloat = 0 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 2, dy: 2)
        let dark = NSColor(srgbRed: 0.28, green: 0.29, blue: 0.40, alpha: 0.96)
        dark.blended(withFraction: confirmation, of: .white)!.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.white.withAlphaComponent(0.94).setStroke()
        let ring = NSBezierPath()
        ring.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: circle.width / 2,
                       startAngle: -90, endAngle: -90 + 360 * min(1, progress), clockwise: false)
        ring.lineWidth = 2.5; ring.lineCapStyle = .round; ring.stroke()
        let plus = NSBezierPath()
        let radius: CGFloat = 5.5 * (1 - sin(confirmation * .pi) * 0.8)
        plus.move(to: NSPoint(x: bounds.midX - radius, y: bounds.midY)); plus.line(to: NSPoint(x: bounds.midX + radius, y: bounds.midY))
        plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - radius)); plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + radius))
        NSColor.white.blended(withFraction: confirmation, of: dark)!.setStroke()
        plus.lineWidth = 1.8; plus.lineCapStyle = .round; plus.stroke()
    }
}

struct SpaceCreationMotion {
    static let confirmationDuration: Double = 0.15
    // Lead presentation by one 60 Hz frame.
    static let presentationLead: Double = 1 / 60
    static let spring = OrbitTokens.Spring(response: 0.30, dampingFraction: 1)
    static func edgeOffset(displacement: CGFloat) -> CGFloat {
        -18 * (1 - exp(-max(0, -displacement) / 90))
    }
    static func edgeProgress(displacement: CGFloat, width: CGFloat) -> CGFloat {
        min(1, max(0, -displacement / max(1, width / 2)))
    }
}

@MainActor
final class SpaceCreationEdgeViewport: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Normalized remaining distance over a 0.30 s settlement with a fast initial step.
struct SpaceCreationSettlement {
    let from: CGFloat
    let target: CGFloat
    let start: CFTimeInterval
    private static let samples: [(Double, Double)] = [
        (0, 1), (0.025, 0.3913), (0.041667, 0.2853), (0.066667, 0.2002),
        (0.083333, 0.1380), (0.1, 0.0923), (0.116667, 0.0612), (0.133333, 0.0405),
        (0.15, 0.0259), (0.166667, 0.0166), (0.191667, 0.0083), (0.208333, 0.0042),
        (0.225, 0.0031), (0.241667, 0.0021), (0.258333, 0.0010), (0.30, 0),
    ]
    func state(at time: CFTimeInterval) -> (value: CGFloat, velocity: Double) {
        let elapsed = time - start
        guard elapsed > 0 else { return (from, 0) }
        guard let index = Self.samples.indices.dropFirst().first(where: { Self.samples[$0].0 >= elapsed }) else { return (target, 0) }
        let (t0, p0) = Self.samples[index - 1], (t1, p1) = Self.samples[index]
        let fraction = (elapsed - t0) / (t1 - t0)
        return (target + (from - target) * (p0 + (p1 - p0) * fraction), Double(from - target) * (p1 - p0) / (t1 - t0))
    }
    func isSettled(at time: CFTimeInterval) -> Bool {
        abs(from - target) <= SidebarSlotMotion.tolerance || time - start >= 0.30
    }
}
