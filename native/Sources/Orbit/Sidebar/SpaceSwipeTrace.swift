import Foundation
import OSLog
import QuartzCore

/// Signposts for the Space swipe and the publication it triggers (subsystem `local.orbit`, category
/// `space-swipe`). Disabled paths return before optional interval/timing work. Actual release
/// overhead remains to be measured. Payloads contain only numbers and static phase names.
/// The goal is to tell apart, on an owned synthetic candidate, a missing input event, a busy main
/// thread (named interval spanning the gap) and a display callback that arrives late.
enum SpaceSwipeTrace {
    static let signposter = OSSignposter(subsystem: "local.orbit", category: "space-swipe")

    @discardableResult
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let signposter = signposter
        guard signposter.isEnabled else { return try body() }
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// The sidebar projection, often the largest synchronous part of a publication.
    static func tabStrip(_ body: () -> Void) { interval("RenderTabStrip", body) }

    /// One scroll event handled by the swipe controller; `phase` is the raw `NSEvent.Phase` value.
    static func input(phase: UInt, momentum: UInt, deltaX: CGFloat) {
        guard signposter.isEnabled else { return }
        signposter.emitEvent("SwipeInput", "phase \(phase) momentum \(momentum) dx \(Double(deltaX), format: .fixed(precision: 2))")
    }

    /// One display-link step: how late the callback runs relative to the frame it targets.
    static func displayStep(targetTimestamp: CFTimeInterval, now: CFTimeInterval? = nil) {
        guard signposter.isEnabled else { return }
        let lateness = ((now ?? CACurrentMediaTime()) - targetTimestamp) * 1000
        signposter.emitEvent("SwipeDisplayStep", "late \(lateness, format: .fixed(precision: 3)) ms")
    }
}
