import AppKit
import QuartzCore

/// Finite Core Animation timing, distinct from Motion's response-based spring clock.
struct OrbitAnimationTiming: Equatable {
    var duration: TimeInterval
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double

    var mediaTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }

    func progress(after elapsed: TimeInterval) -> Double {
        guard duration > 0, elapsed > 0 else { return elapsed > 0 ? 1 : 0 }
        let x = min(1, elapsed / duration)
        if x == 1 { return 1 }
        func coordinate(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        // Invert the time coordinate, including curves whose tangent is flat at an endpoint.
        var lower = 0.0, upper = 1.0
        for _ in 0..<40 {
            let t = (lower + upper) / 2
            if coordinate(t, x1, x2) < x { lower = t } else { upper = t }
        }
        return coordinate((lower + upper) / 2, y1, y2)
    }
}

struct OrbitTimedSegment: Equatable {
    let from: Double
    let target: Double
    let start: CFTimeInterval
    let timing: OrbitAnimationTiming

    func value(at time: CFTimeInterval) -> Double {
        from + (target - from) * timing.progress(after: time - start)
    }
    func isSettled(at time: CFTimeInterval) -> Bool { time - start >= timing.duration }
}

/// A single geometry progress for AppKit's finite transitions. Reversal begins at the currently
/// displayed position. Only Motion springs use CoreVideo target-minus-current elapsed time.
@MainActor
final class OrbitTimedAnimator {
    private(set) var value: Double
    private(set) var target: Double
    private var segment: OrbitTimedSegment?
    private var link: CADisplayLink?
    private var proxy: OrbitTimedDisplayLinkProxy?
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    var onChange: ((Double) -> Void)?
    var onSettle: (() -> Void)?
    var isAnimating: Bool { segment != nil }

    init(value: Double) { self.value = value; target = value }

    func set(_ value: Double) {
        stopTicking()
        segment = nil
        self.value = value; target = value
        onChange?(value)
    }

    func beginSegment(to target: Double, timing: OrbitAnimationTiming) {
        let now = clock()
        value = segment?.value(at: now) ?? value
        self.target = target
        segment = OrbitTimedSegment(from: value, target: target, start: now, timing: timing)
        if value == target || timing.duration <= 0 { finish() }
    }

    func animate(to target: Double, timing: OrbitAnimationTiming, in view: NSView?) {
        guard let view, view.window?.isVisible == true else { set(target); onSettle?(); return }
        beginSegment(to: target, timing: timing)
        guard isAnimating, link == nil else { return }
        let proxy = OrbitTimedDisplayLinkProxy { [weak self] in
            guard let self else { return false }
            advance(to: clock()); return true
        }
        let link = view.displayLink(target: proxy, selector: #selector(OrbitTimedDisplayLinkProxy.step(_:)))
        link.add(to: .main, forMode: .common)
        self.proxy = proxy; self.link = link
    }

    func advance(to time: CFTimeInterval) {
        guard let segment else { return }
        if segment.isSettled(at: time) { finish(); return }
        value = segment.value(at: time)
        onChange?(value)
    }

    private func finish() {
        stopTicking(); segment = nil; value = target
        onChange?(value); onSettle?()
    }
    private func stopTicking() { link?.invalidate(); link = nil; proxy = nil }
}

@MainActor
private final class OrbitTimedDisplayLinkProxy: NSObject {
    let tick: () -> Bool
    init(_ tick: @escaping () -> Bool) { self.tick = tick }
    @objc func step(_ link: CADisplayLink) { if !tick() { link.invalidate() } }
}

extension OrbitAnimationTiming {
    /// WindowLayoutController: /814/910
    /// cubic (0.25, 0.46, 0.45, 0.94), 80 ms.
    static let sidebar = Self(duration: 0.08, x1: 0.25, y1: Double(Float(0.46)), x2: Double(Float(0.45)), y2: Double(Float(0.94)))
    /// The separate container layout group at uses the same cubic over 200 ms.
    static let sidebarContainer = Self(duration: 0.2, x1: sidebar.x1, y1: sidebar.y1, x2: sidebar.x2, y2: sidebar.y2)
    /// Orbit's OutlineViewDiffableDataSource, : 120 ms, AppKit default.
    static let tabList = Self(duration: 0.12, x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    /// SplitViewController layout groups, /: 200 ms ease-out.
    static let split = Self(duration: 0.2, x1: 0, y1: 0, x2: Double(Float(0.58)), y2: 1)
}
