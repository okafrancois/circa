import AppKit
import QuartzCore

/// Timing shared by the two conversation presentations.
@MainActor enum BrowserAssistantMotion {
    static func progress(_ time: Double, opening: Bool) -> Double {
        let x = min(1, max(0, time))
        let a = opening ? 0.19 : 0.55
        let b = opening ? 0.22 : 1.0
        let c = opening ? 1.0 : 0.085
        let d = opening ? 1.0 : 0.68
        func curve(_ t: Double, _ p: Double, _ q: Double) -> Double {
            3 * (1-t) * (1-t) * t * p + 3 * (1-t) * t * t * q + t*t*t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<18 {
            let mid = (lo + hi) / 2
            if curve(mid, a, b) < x { lo = mid } else { hi = mid }
        }
        return curve((lo + hi) / 2, c, d)
    }
}
