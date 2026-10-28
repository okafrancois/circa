import AppKit
import QuartzCore

/// Accessibility preferences that change motion. Read at every animation (design rule 9).
@MainActor
enum OrbitMotionPreferences {
    /// Tests force a value; nil follows the system setting and the validation flag.
    static var overrideReducedMotion: Bool?
    /// `--reduce-motion` lets visible validation exercise the reduced path without changing the
    /// user's System Settings.
    static let launchForcesReducedMotion = ProcessInfo.processInfo.arguments.contains("--reduce-motion")

    static var prefersReducedMotion: Bool {
        if let overrideReducedMotion { return overrideReducedMotion }
        return launchForcesReducedMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Orbit's chrome is opaque, so reduced transparency has no visible effect on it ( C20).
    /// Exposed for surfaces that add translucency later.
    static var prefersReducedTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
}

// MARK: - Spring solution

extension OrbitTokens.Spring {
    /// Undamped angular frequency ω₀ = 2π / response (mass 1).
    var angularFrequency: Double { 2 * .pi / response }

    /// Displacement from the target and velocity after `time`, for a spring released at
    /// displacement `x0` with velocity `v0` (units per second). Same model as SwiftUI's
    /// `spring(response:dampingFraction:)` and `CASpringAnimation` with the stiffness/damping above.
    func state(after time: Double, displacement x0: Double, velocity v0: Double) -> (displacement: Double, velocity: Double) {
        let w = angularFrequency
        let z = Double(dampingFraction)
        let t = max(0, time)
        if z < 1 {
            let wd = w * (1 - z * z).squareRoot()
            let b = (v0 + z * w * x0) / wd
            let envelope = exp(-z * w * t)
            let c = cos(wd * t), s = sin(wd * t)
            let x = envelope * (x0 * c + b * s)
            let v = envelope * (-z * w * (x0 * c + b * s) + wd * (b * c - x0 * s))
            return (x, v)
        }
        if z == 1 {
            let b = v0 + w * x0
            let envelope = exp(-w * t)
            return (envelope * (x0 + b * t), envelope * (b - w * (x0 + b * t)))
        }
        let root = (z * z - 1).squareRoot()
        let r1 = -w * (z - root), r2 = -w * (z + root)
        let c2 = (v0 - r1 * x0) / (r2 - r1)
        let c1 = x0 - c2
        let e1 = exp(r1 * t), e2 = exp(r2 * t)
        return (c1 * e1 + c2 * e2, c1 * r1 * e1 + c2 * r2 * e2)
    }

    /// Time after which a unit step stays within `tolerance` of its target, both in position and
    /// in velocity per radian (numerical, 1/600 s steps, capped at 10 s).
    func settlingDuration(tolerance: Double = 0.001) -> TimeInterval {
        let step = 1.0 / 600
        var lastOutside = 0.0
        var t = 0.0
        while t <= 10 {
            let (x, v) = state(after: t, displacement: 1, velocity: 0)
            if abs(x) > tolerance || abs(v) / angularFrequency > tolerance { lastOutside = t }
            t += step
        }
        return lastOutside + step
    }

    var settlingDuration: TimeInterval { settlingDuration() }
}

// MARK: - Interruptible spring driver

/// Drives one scalar along an `OrbitTokens.Spring` on the display link. Retargeting mid-flight starts
/// from the current value with the current velocity (design rule 7), so interrupted transitions
/// never jump.
@MainActor
final class OrbitSpringAnimator {
    private(set) var value: Double
    private(set) var target: Double
    private var spring = OrbitTokens.Motion.sidebarToggle
    private var segmentStart: CFTimeInterval = 0
    private var segmentDisplacement = 0.0
    private var segmentVelocity = 0.0
    private var isInFlight = false
    private var link: CADisplayLink?
    private var proxy: OrbitDisplayLinkProxy?
    private var coreVideoDriver: OrbitCoreVideoMotionDriver?
    private let usesCoreVideoClock: Bool
    /// An injected timebase drives both retargeting and display callbacks. Nil uses the
    /// display link's predicted timestamp and the system clock for a new segment.
    var clock: (() -> CFTimeInterval)?
    /// Rest tolerance in value units (the shell drives 0…1 progress values).
    var restTolerance = 0.0005
    var onChange: ((Double) -> Void)?
    var onSettle: (() -> Void)?

    var isAnimating: Bool { isInFlight }

    init(value: Double, usesCoreVideoClock: Bool = false) {
        self.usesCoreVideoClock = usesCoreVideoClock
        self.value = value
        target = value
    }

    /// Jumps to `newValue`, cancelling any flight.
    func set(_ newValue: Double) {
        stopTicking()
        isInFlight = false
        value = newValue
        target = newValue
        onChange?(value)
    }

    /// Animates towards `newTarget` on `view`'s display link. Without a visible driver view the value
    /// jumps: nobody can see the motion and offscreen windows get no display-link callbacks.
    func animate(to newTarget: Double, spring: OrbitTokens.Spring, in view: NSView?, velocity: Double? = nil,
                 delay: TimeInterval = 0) {
        guard let view, view.window?.isVisible == true else {
            set(newTarget)
            onSettle?()
            return
        }
        if usesCoreVideoClock, coreVideoDriver == nil {
            coreVideoDriver = OrbitCoreVideoMotionDriver(time: clock?() ?? CACurrentMediaTime())
        }
        beginSegment(to: newTarget, spring: spring, velocity: velocity, delay: delay)
        if usesCoreVideoClock {
            guard isInFlight, let driver = coreVideoDriver else { return }
            driver.onFrame = { [weak self, weak driver] in
                guard let self, let driver else { return }
                advance(to: clock?() ?? driver.time)
            }
            if !driver.start() { set(newTarget); onSettle?() }
            return
        }
        guard isInFlight, link == nil else { return }
        let proxy = OrbitDisplayLinkProxy { [weak self] link in
            guard let self else { return }
            advance(to: clock?() ?? link.targetTimestamp)
        }
        let link = view.displayLink(target: proxy, selector: #selector(OrbitDisplayLinkProxy.step(_:)))
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
    }

    /// Starts a new spring segment from the current value and velocity. Internal for tests, which
    /// drive time through `advance(to:)`.
    func beginSegment(to newTarget: Double, spring: OrbitTokens.Spring, velocity: Double? = nil, delay: TimeInterval = 0) {
        let now = clock?() ?? coreVideoDriver?.time ?? CACurrentMediaTime()
        let current = currentState(at: now)
        value = current.value
        target = newTarget
        self.spring = spring
        segmentStart = now + max(0, delay)
        segmentDisplacement = current.value - newTarget
        segmentVelocity = velocity ?? current.velocity
        isInFlight = abs(segmentDisplacement) > restTolerance || abs(segmentVelocity) > restTolerance
        if !isInFlight { finish() }
    }

    /// Value and velocity the animator has at `time` (velocity 0 at rest).
    func currentState(at time: CFTimeInterval) -> (value: Double, velocity: Double) {
        guard isInFlight else { return (value, 0) }
        let state = spring.state(after: time - segmentStart, displacement: segmentDisplacement, velocity: segmentVelocity)
        return (target + state.displacement, state.velocity)
    }

    func advance(to time: CFTimeInterval) {
        guard isInFlight else { return stopTicking() }
        let state = spring.state(after: time - segmentStart, displacement: segmentDisplacement, velocity: segmentVelocity)
        if abs(state.displacement) <= restTolerance && abs(state.velocity) / spring.angularFrequency <= restTolerance {
            finish()
            return
        }
        value = target + state.displacement
        onChange?(value)
    }

    private func finish() {
        stopTicking()
        isInFlight = false
        value = target
        onChange?(value)
        onSettle?()
    }

    private func stopTicking() {
        coreVideoDriver?.stop(); coreVideoDriver = nil
        link?.invalidate()
        link = nil
        proxy = nil
    }
}

@MainActor
private final class OrbitDisplayLinkProxy: NSObject {
    private let tick: (CADisplayLink) -> Void
    init(_ tick: @escaping (CADisplayLink) -> Void) { self.tick = tick }
    @objc func step(_ link: CADisplayLink) { tick(link) }
}

// MARK: - Motion policy

/// How a state change is presented (design rule 9,  C20 for the reduced path).
enum OrbitMotionStyle: Equatable {
    /// The measured or estimated spring.
    case spring
    /// "Reduce motion": the spring becomes a 0.12 s cross-fade to the final state.
    case crossfade
    /// No visible motion: unanimated changes, hidden or occluded windows, live resize.
    case jump

    static func resolve(animated: Bool, canAnimate: Bool, reducedMotion: Bool) -> OrbitMotionStyle {
        guard animated, canAnimate else { return .jump }
        return reducedMotion ? .crossfade : .spring
    }
}

// MARK: - Transitions

@MainActor
enum OrbitTransitions {
    /// Reduced-motion replacement for a spring ( C20): the next change of `layer`'s
    /// rendered tree cross-fades over 0.12 s.
    static func crossfade(_ layer: CALayer?, duration: TimeInterval = OrbitTokens.Motion.reducedMotionCrossfade) {
        guard let layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transition, forKey: "orbit.crossfade")
    }

    /// `CASpringAnimation.initialVelocity` is expressed in fractions of the travelled distance per
    /// second, towards the target.
    static func normalizedVelocity(_ velocity: Double, from: Double, to: Double) -> Double {
        let distance = to - from
        return abs(distance) < .ulpOfOne ? 0 : velocity / distance
    }
}
