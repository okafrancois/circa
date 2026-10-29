import Foundation

/// Shared critically damped colour response. The visible 2–98% interval is 0.175 seconds (within one 110 Hz capture interval of 0.184).
enum OrbitThemeTransition {
    static let omega = 32.00782466
    static let spring = OrbitTokens.Spring(response: 2 * .pi / omega, dampingFraction: 1)
    static func progress(at seconds: Double) -> Double {
        let t = max(0, seconds)
        return 1 - (1 + omega * t) * exp(-omega * t)
    }
}
