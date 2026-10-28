import AppKit
import BrowserCore
import Testing
@testable import Orbit

@MainActor
@Suite(.serialized)
struct MotionBTests {
    @Test("Finite sidebar timing inverts the cubic time coordinate and ends at exactly 80 ms")
    func sidebarTiming() {
        let timing = OrbitAnimationTiming.sidebar
        // The cubic's parametric midpoint has x=0.3875 and y=0.65.
        let timeCoordinate = 0.375 * timing.x1 + 0.375 * timing.x2 + 0.125
        let expected = 0.375 * timing.y1 + 0.375 * timing.y2 + 0.125
        #expect(abs(timing.progress(after: timing.duration * timeCoordinate) - expected) < 1e-9)
        #expect(timing.progress(after: 0) == 0)
        #expect(timing.progress(after: 0.08) == 1)
        #expect(timing.progress(after: 1) == 1)
    }

    @Test("An interrupted finite transition starts at its displayed position and releases its flight")
    func reverseSidebar() {
        let animator = OrbitTimedAnimator(value: 1)
        var time = 10.0
        animator.clock = { time }
        animator.beginSegment(to: 0, timing: .sidebar)
        time += 0.03
        animator.advance(to: time)
        let current = animator.value
        #expect(current > 0 && current < 1)
        animator.beginSegment(to: 1, timing: .sidebar)
        #expect(abs(animator.value - current) < 1e-10)
        time += 0.081
        animator.advance(to: time)
        #expect(animator.value == 1 && !animator.isAnimating)
    }

    @Test("List insertion, removal and drag gaps finish on the 120 ms native update boundary")
    func listTiming() throws {
        let animator = SidebarListAnimator()
        animator.move(.newTab, from: 40, to: 81, at: 10)
        let midpoint = try #require(animator.value(of: .newTab, at: 10.06))
        #expect(midpoint > 40 && midpoint < 81)
        animator.move(.newTab, from: 40, to: 122, at: 10.06)
        #expect(abs(try #require(animator.value(of: .newTab, at: 10.06)) - midpoint) < 1e-9)
        animator.advance(to: 10.179)
        #expect(animator.isAnimating)
        animator.advance(to: 10.181)
        #expect(!animator.isAnimating)
    }

    @Test("Floating sidebar uses the native springyFast preset and its small overshoot")
    func floatingSidebarSpring() {
        let spring = OrbitTokens.Motion.sidebarHoverReveal
        #expect(spring.response == 0.18 && spring.dampingFraction == 0.8)
        let peakTime = Double.pi / (spring.angularFrequency * sqrt(1 - 0.8 * 0.8))
        let progress = 1 + spring.state(after: peakTime, displacement: -1, velocity: 0).displacement
        #expect(progress > 1.01 && progress < 1.02)
        #expect(OrbitTokens.Motion.sidebarHoverExit == spring)
    }

    @Test("A divider double-click balances only its adjacent panes through the persistence callback")
    func resetAdjacentPanes() throws {
        let ids = [TabID(), TabID(), TabID()]
        let group = BrowserSplitGroup(tabIDs: ids, ratios: [0.2, 0.3, 0.5])
        let view = BrowserSplitView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.present(group, panes: ids.map { .init(id: $0, view: NSView(), address: "https://example.test/") },
                     active: ids[0], accent: .defaultPurple)
        var published: [[Double]] = []
        view.onResize = { published.append($0) }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1,
            clickCount: 2, pressure: 1))
        view.dividers[0].mouseDown(with: event)
        #expect(published == [[0.25, 0.25, 0.5]])
        #expect(view.group?.ratios == [0.2, 0.3, 0.5])
    }

    @Test("Split layout keeps the source pane geometry and uses a 200 ms ease-out")
    func splitTiming() {
        let from = CGRect(x: 0, y: 0, width: 800, height: 600)
        let to = CGRect(x: 0, y: 0, width: 395, height: 600)
        let progress = CGFloat(OrbitAnimationTiming.split.progress(after: 0.1))
        #expect(progress > 0.5 && progress < 1)
        let mid = BrowserSplitView.interpolate(from: from, to: to, progress: progress)
        #expect(mid.width > to.width && mid.width < from.width)
        #expect(BrowserSplitView.interpolate(from: from, to: to, progress: 1) == to)
    }
}
