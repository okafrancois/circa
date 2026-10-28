import AppKit
import Testing
@testable import Orbit

@MainActor
private final class ReviewHoverTimer: OrbitCancellable {
    let deadline: TimeInterval
    var action: (@MainActor () -> Void)?
    init(_ deadline: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        self.deadline = deadline
        self.action = action
    }
    func cancel() { action = nil }
}

@MainActor
private final class ReviewHoverClock {
    var now: TimeInterval = 0
    var timers: [ReviewHoverTimer] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> any OrbitCancellable {
        let timer = ReviewHoverTimer(now + delay, action)
        timers.append(timer)
        return timer
    }
    func advance(_ delta: TimeInterval) {
        now += delta
        let due = timers.filter { $0.deadline <= now }
        for timer in due {
            let action = timer.action
            timer.action = nil
            action?()
        }
    }
}

/// Independent boundary probes; hidden windows and notification injection do not prove OS routing.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct FullscreenHoverIndependentReviewTests {
    private func fixture(isMouseButtonPressed: @escaping () -> Bool = { false }) -> (NSWindow, OrbitWindowShell, ReviewHoverClock) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = OrbitWindowRootView(frame: window.contentLayoutRect)
        window.contentView = root
        let shell = OrbitWindowShell(isMouseButtonPressed: isMouseButtonPressed)
        shell.prepare(window: window, root: root)
        shell.setDocked(false, animated: false)
        shell.hoverReveal.isPointerInside = { false }
        let clock = ReviewHoverClock()
        shell.hoverReveal.schedule = { delay, action in clock.schedule(delay, action) }
        return (window, shell, clock)
    }

    private func reveal(_ shell: OrbitWindowShell, _ clock: ReviewHoverClock) {
        shell.hoverReveal.pointerEnteredEdge()
        clock.advance(0.18)
        #expect(shell.hoverReveal.phase == .revealed)
    }

    @Test("Foreign window notifications cannot alter fullscreen or dismiss this shell")
    func foreignWindowNotifications() async throws {
        let (window, shell, clock) = fixture()
        let (other, _, _) = fixture()
        defer { window.close(); other.close() }
        reveal(shell, clock)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: other)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        #expect(!shell.isFullScreen && shell.hoverReveal.phase == .revealed)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(shell.hoverReveal.phase == .idle)
    }

    @Test("Foreign popover close reevaluation preserves an active owned hold")
    func foreignPopoverWithOwnedHold() async throws {
        let (window, shell, clock) = fixture()
        defer { window.close() }
        var held = true
        shell.isHoverHeld = { held }
        reveal(shell, clock)
        shell.hoverReveal.pointerExitedPanel()
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: NSPopover())
        clock.advance(0.12)
        #expect(shell.hoverReveal.phase == .revealed)
        held = false
        shell.hoverHoldDidChange()
        clock.advance(0.12)
        #expect(shell.hoverReveal.phase == .idle)
    }

    @Test("A replacement hold during pending dismissal cancels stale release")
    func replacementHold() async throws {
        let (window, shell, clock) = fixture()
        defer { window.close() }
        var held = false
        shell.isHoverHeld = { held }
        reveal(shell, clock)
        shell.hoverReveal.pointerExitedPanel()
        #expect(shell.hoverReveal.phase == .leaving)
        held = true
        shell.hoverHoldDidChange()
        clock.advance(0.12)
        #expect(shell.hoverReveal.phase == .revealed)
        held = false
        shell.hoverHoldDidChange()
        shell.setDocked(true, animated: false)
        clock.advance(0.12)
        #expect(shell.isDocked && shell.hoverReveal.phase == .disabled)
    }

    @Test("Nested menu notifications release only after the last end")
    func nestedMenus() async throws {
        let (window, shell, clock) = fixture()
        defer { window.close() }
        reveal(shell, clock)
        let menu = NSMenu(title: "Synthetic nested tracking")
        for _ in 0..<2 {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        }
        shell.hoverReveal.pointerExitedPanel()
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(shell.hoverReveal.isHeld())
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        clock.advance(0.12)
        #expect(!shell.hoverReveal.isHeld() && shell.hoverReveal.phase == .idle)
    }

    @Test("A pressed mouse holds the sidebar until release and the leave deadline")
    func mouseRelease() {
        var pressed = true
        let (window, shell, clock) = fixture(isMouseButtonPressed: { pressed })
        defer { window.close() }
        reveal(shell, clock)
        shell.hoverReveal.pointerExitedPanel()
        clock.advance(0.12)
        #expect(shell.hoverReveal.isHeld() && shell.hoverReveal.phase == .revealed)
        pressed = false
        shell.hoverHoldDidChange()
        #expect(!shell.hoverReveal.isHeld() && shell.hoverReveal.phase == .leaving)
        clock.advance(shell.hoverReveal.leaveDelay / 2)
        #expect(shell.hoverReveal.phase == .leaving)
        clock.advance(shell.hoverReveal.leaveDelay)
        #expect(shell.hoverReveal.phase == .idle)
    }

    @Test("Window and installed monitor do not retain a discarded shell")
    func shellLifetime() async throws {
        let (window, initial, _) = fixture()
        defer { window.close() }
        // A separate scope avoids a strong tuple binding obscuring the lifetime under test.
        weak var discarded: OrbitWindowShell?
        do {
            let shell = OrbitWindowShell(isMouseButtonPressed: { false })
            shell.prepare(window: window, root: try #require(window.contentView as? OrbitWindowRootView))
            discarded = shell
        }
        #expect(discarded == nil)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        #expect(!initial.hoverReveal.isHeld())
    }
}
}
