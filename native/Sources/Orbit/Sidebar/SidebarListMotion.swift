import AppKit
import QuartzCore

/// Vertical position of one list slot moving along a spring. Retargeting mid-flight starts from
/// the current value and velocity (design rule 7), so reorders, folder toggles and drag gaps that
/// interrupt each other never jump. Same analytic spring as `OrbitSpringAnimator`.
struct SidebarSlotMotion: Equatable {
    private(set) var target: CGFloat
    private var start: CFTimeInterval
    private var displacement: Double
    private var velocity: Double
    private var spring: OrbitTokens.Spring

    /// Rest tolerance in points (and points per radian for the velocity).
    static let tolerance = 0.25

    init(from value: CGFloat, to target: CGFloat, at time: CFTimeInterval, spring: OrbitTokens.Spring,
         velocity: Double = 0) {
        self.target = target
        start = time
        displacement = Double(value - target)
        self.velocity = velocity
        self.spring = spring
    }

    func state(at time: CFTimeInterval) -> (value: CGFloat, velocity: Double) {
        let state = spring.state(after: time - start, displacement: displacement, velocity: velocity)
        return (target + CGFloat(state.displacement), state.velocity)
    }

    func value(at time: CFTimeInterval) -> CGFloat {
        isSettled(at: time) ? target : state(at: time).value
    }

    mutating func retarget(to newTarget: CGFloat, at time: CFTimeInterval, spring: OrbitTokens.Spring) {
        let current = state(at: time)
        self = SidebarSlotMotion(from: current.value, to: newTarget, at: time, spring: spring, velocity: current.velocity)
    }

    func isSettled(at time: CFTimeInterval) -> Bool {
        let state = spring.state(after: time - start, displacement: displacement, velocity: velocity)
        return abs(state.displacement) <= Self.tolerance
            && abs(state.velocity) / spring.angularFrequency <= Self.tolerance
    }
}

/// Drives Orbit's finite native list updates on one display link. Slots at rest have no entry, so
/// a 500-row list costs nothing while idle.
@MainActor
final class SidebarListAnimator {
    private(set) var motions: [SidebarListSlot: OrbitTimedSegment] = [:]
    private var link: CADisplayLink?
    private var proxy: SidebarDisplayLinkProxy?
    /// AppKit's finite updates use elapsed wall time; tests substitute the clock.
    var clock: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// Called with the frame time after positions advanced (the owner moves its views); the last
    /// call happens once everything has settled.
    var onFrame: ((CFTimeInterval) -> Void)?

    var isAnimating: Bool { !motions.isEmpty }
    var now: CFTimeInterval { clock() }

    func value(of slot: SidebarListSlot, at time: CFTimeInterval) -> CGFloat? {
        motions[slot].map { CGFloat($0.value(at: time)) }
    }

    /// Orbit's NSOutlineView update group uses a finite 120 ms animation. Reorders that interrupt
    /// an update begin at its current displayed position, without extending the previous segment.
    func move(_ slot: SidebarListSlot, from: CGFloat, to target: CGFloat,
              timing: OrbitAnimationTiming = .tabList, at time: CFTimeInterval) {
        if motions[slot]?.target == Double(target) { return }
        let current = motions[slot]?.value(at: time) ?? Double(from)
        guard abs(current - Double(target)) > SidebarSlotMotion.tolerance else { motions[slot] = nil; return }
        motions[slot] = OrbitTimedSegment(from: current, target: Double(target), start: time, timing: timing)
    }

    func stop(_ slot: SidebarListSlot) { motions[slot] = nil }

    func stopAll() {
        motions.removeAll()
        stopTicking()
    }

    /// Starts ticking on `view`'s display link if motions are pending.
    func run(in view: NSView) {
        guard isAnimating, link == nil else { return }
        // The run loop retains the link and the link its proxy: a proxy whose animator is gone
        // (page replaced mid-flight) invalidates the link on its next tick.
        let proxy = SidebarDisplayLinkProxy { [weak self] link in
            guard let self else { return false }
            advance(to: clock())
            return true
        }
        let link = view.displayLink(target: proxy, selector: #selector(SidebarDisplayLinkProxy.step(_:)))
        link.add(to: .main, forMode: .common)
        self.proxy = proxy
        self.link = link
    }

    /// Drops settled motions and notifies the owner. Internal for tests, which drive time.
    /// True while a display link is registered (tests).
    var hasDisplayLink: Bool { link != nil }

    func advance(to time: CFTimeInterval) {
        motions = motions.filter { !$0.value.isSettled(at: time) }
        onFrame?(time)
        if motions.isEmpty { stopTicking() }
    }

    private func stopTicking() {
        link?.invalidate()
        link = nil
        proxy = nil
    }
}

@MainActor
final class SidebarDisplayLinkProxy: NSObject {
    /// Returns false once its owner is gone.
    private let tick: (CADisplayLink) -> Bool
    init(_ tick: @escaping (CADisplayLink) -> Bool) { self.tick = tick }
    @objc func step(_ link: CADisplayLink) {
        if !tick(link) { link.invalidate() }
    }
}
