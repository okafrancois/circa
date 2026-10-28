import Foundation

/// Orbit pager release: 100 ms position buffer , nearest page below
/// 5 pt/s, otherwise the adjacent page in the release direction .
/// Axis probation preserves native vertical scrolling before ownership is established.
struct SpaceSwipeGesture {
    enum Intent { case pending, horizontal, vertical }
    private(set) var intent: Intent = .pending
    private(set) var displacement = 0.0
    private(set) var velocity = 0.0
    private var horizontalDistance = 0.0
    private var verticalDistance = 0.0
    private var verticalSamples = 0
    private var samples: [(time: TimeInterval, position: Double)] = []

    init(displacement: Double = 0, velocity: Double = 0) {
        self.displacement = displacement
        self.velocity = velocity
    }

    mutating func update(x: Double, y: Double, time: TimeInterval, translationScale: Double = 1) {
        displacement += x * translationScale
        horizontalDistance += x
        verticalDistance += y
        if intent == .pending, max(abs(horizontalDistance), abs(verticalDistance)) >= 6 {
            if abs(horizontalDistance) > abs(verticalDistance) * 1.3 { intent = .horizontal }
            else if abs(verticalDistance) > abs(horizontalDistance) * 1.3 {
                // One small initial Y sample is not yet ownership: retain its original phase
                // for the next direction sample. Large vertical motion hands off immediately;
                // two consecutive vertical samples hand off without a timer or lost distance.
                verticalSamples = abs(y) > abs(x) * 1.3 ? verticalSamples + 1 : 0
                if abs(verticalDistance) >= 12 || verticalSamples >= 2 { intent = .vertical }
            } else { verticalSamples = 0 }
        }
        if samples.isEmpty || x != 0 && translationScale != 0 {
            samples.append((time, displacement))
            samples.removeAll { time - $0.time > 0.1 }
            velocity = releaseVelocity(at: time)
        }
    }

    func releaseVelocity(at time: TimeInterval) -> Double {
        let recent = samples.filter { time - $0.time < 0.1 }
        guard let first = recent.first, let last = recent.last, last.time > first.time else { return 0 }
        return (last.position - first.position) / (last.time - first.time)
    }

    /// Positive offset means previous Space. Never wraps; overscroll has finite resistance.
    func offset(width: Double, hasPrevious: Bool, hasNext: Bool) -> Double {
        guard intent == .horizontal, width > 0 else { return 0 }
        let edge = displacement > 0 ? !hasPrevious : !hasNext
        if edge { return displacement / (1 + abs(displacement) / (width * 0.18)) }
        return max(-width, min(width, displacement))
    }

    func destination(width: Double, hasPrevious: Bool, hasNext: Bool, at time: TimeInterval) -> Int? {
        guard intent == .horizontal, width > 0 else { return nil }
        let speed = releaseVelocity(at: time)
        let direction: Int
        if abs(speed) >= 5 {
            // Reversing before the midpoint settles back to the source page.
            if speed * displacement < 0 { return nil }
            direction = speed > 0 ? -1 : 1
        } else {
            guard abs(displacement) >= width / 2 else { return nil }
            direction = displacement > 0 ? -1 : 1
        }
        guard direction < 0 ? hasPrevious : hasNext else { return nil }
        return direction
    }
}
