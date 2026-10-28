import Foundation

/// WindowLayoutController's pager uses
/// PageSwipeController.select , with no settlingAnimationHandler.
/// The transform and alpha mappings are and .
enum LibraryMotion {
    static let spring = OrbitTokens.Spring(response: 0.4, dampingFraction: 1)

    static func sidebarScale(at progress: Double) -> Double { 1 - 0.1 * clamped(progress) }
    static func sidebarTranslation(at progress: Double) -> Double { 26 * clamped(progress) }
    static func sidebarOpacity(at progress: Double) -> Double { max(0, 1 - 2 * clamped(progress)) }
    private static func clamped(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// Library is the previous WindowLayoutPage. Keep its contact/release policy independent
/// of SidebarPagingContainerViewController's separate Space pager.
/// Orbit: half scroll deltas , 100 ms velocity buffer
/// nearest page below 5 pt/s, otherwise the page in the release direction .
struct LibrarySwipeGesture {
    private(set) var gesture = LibrarySwipeContact()
    let startsPresented: Bool
    let initialWidth: Double
    let width: Double

    init(presented: Bool, visibleWidth: Double, width: Double) {
        startsPresented = presented
        initialWidth = visibleWidth
        self.width = max(1, width)
    }

    mutating func update(x: Double, y: Double, time: TimeInterval, began: Bool = false) {
        gesture.update(x: x, y: y, time: time, began: began)
    }

    var visibleWidth: Double { min(width, max(0, initialWidth + gesture.displacement)) }
    var takesBoundary: Bool {
        gesture.intent == .horizontal && (startsPresented || gesture.displacement > 0)
    }

    func destination(at time: TimeInterval, cancelled: Bool) -> Bool {
        guard !cancelled else { return startsPresented }
        let speed = gesture.releaseVelocity(at: time)
        if abs(speed) >= 5 { return speed > 0 }
        return visibleWidth >= width / 2
    }
}

struct LibrarySwipeContact {
    enum Intent { case pending, horizontal, vertical }
    private(set) var intent: Intent = .pending
    private(set) var displacement = 0.0
    private var samples: [(time: TimeInterval, position: Double)] = []

    mutating func update(x: Double, y: Double, time: TimeInterval, began: Bool = false) {
        if intent == .pending, x != 0 || y != 0 {
            intent = abs(x) >= abs(y) ? .horizontal : .vertical
        }
        // Orbit seeds its velocity buffer at began; only changed events displace the page.
        if began { samples = [(time, displacement)]; return }
        displacement += x * 0.5
        if x != 0 {
            samples.append((time, displacement))
            samples.removeAll { time - $0.time > 0.1 }
        }
    }

    func releaseVelocity(at time: TimeInterval) -> Double {
        let recent = samples.filter { time - $0.time < 0.1 }
        guard let first = recent.first, let last = recent.last,
              last.time > first.time else { return 0 }
        return (last.position - first.position) / (last.time - first.time)
    }
}
