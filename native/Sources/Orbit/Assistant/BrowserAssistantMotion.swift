import AppKit
import QuartzCore

/// Timing shared by the two conversation presentations.
@MainActor enum BrowserAssistantMotion {
    static func progress(_ time: Double, opening: Bool) -> Double {
        let x = min(1, max(0, time))
        if !opening { return x * x * x }
        return cubicProgress(x, first: CGPoint(x: 0.19, y: 1), second: CGPoint(x: 0.22, y: 1))
    }

    static func citationHoverProgress(_ time: Double) -> Double {
        cubicProgress(min(1, max(0, time)), first: CGPoint(x: 0.25, y: 0.1), second: CGPoint(x: 0.25, y: 1))
    }

    private static func cubicProgress(_ x: Double, first: CGPoint, second: CGPoint) -> Double {
        func curve(_ t: Double, _ p: Double, _ q: Double) -> Double {
            3 * (1-t) * (1-t) * t * p + 3 * (1-t) * t * t * q + t*t*t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<18 {
            let mid = (lo + hi) / 2
            if curve(mid, first.x, second.x) < x { lo = mid } else { hi = mid }
        }
        return curve((lo + hi) / 2, first.y, second.y)
    }
}
