import Foundation
import QuartzCore

/// Scalar part of Orbit's Motion spring. Its native value and velocity both resolve within
/// 0.01 point , rather than a frequency-normalized tolerance.
@MainActor
final class LibrarySpringAnimator {
    private(set) var value: Double
    private(set) var target: Double
    private(set) var isAnimating = false
    var pointsPerUnit: Double = 417
    var clock: (() -> CFTimeInterval)?
    var onChange: ((Double) -> Void)?
    var onSettle: (() -> Void)?
    private var start: CFTimeInterval = 0
    private var displacement = 0.0
    private var velocity = 0.0
    private var spring = LibraryMotion.spring

    init(value: Double = 0) { self.value = value; target = value }

    func set(_ value: Double) {
        isAnimating = false
        self.value = value
        target = value
        onChange?(value)
    }

    func beginSegment(to target: Double, spring: OrbitTokens.Spring, velocity: Double? = nil) {
        let now = clock?() ?? CACurrentMediaTime()
        let current = currentState(at: now)
        value = current.value
        self.target = target
        self.spring = spring
        start = now
        displacement = value - target
        self.velocity = velocity ?? current.velocity
        isAnimating = true
        advance(to: now)
    }

    func currentState(at time: CFTimeInterval) -> (value: Double, velocity: Double) {
        guard isAnimating else { return (value, 0) }
        let state = spring.state(after: time - start, displacement: displacement, velocity: velocity)
        return (target + state.displacement, state.velocity)
    }

    func advance(to time: CFTimeInterval) {
        guard isAnimating else { return }
        let state = currentState(at: time)
        let scale = max(1, pointsPerUnit)
        if abs(state.value - target) * scale <= 0.01 && abs(state.velocity) * scale <= 0.01 {
            isAnimating = false
            value = target
            onChange?(value)
            onSettle?()
        } else {
            value = state.value
            onChange?(value)
        }
    }
}
