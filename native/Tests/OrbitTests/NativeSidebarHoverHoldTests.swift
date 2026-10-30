import AppKit
import Testing
@testable import Orbit

/// Native shell wiring tests. Actual OS pointer routing is covered separately by the signed
/// synthetic Chromium run; posting a notification here does not simulate menu tracking.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeSidebarHoverHoldTests {
    private func makeShell() -> (NSWindow, OrbitWindowShell) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = OrbitWindowRootView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root
        // The owner may be using the Mac during the suite: never read the physical mouse.
        let shell = OrbitWindowShell(isMouseButtonPressed: { false })
        shell.prepare(window: window, root: root)
        shell.hoverReveal.isPointerInside = { false }
        shell.setDocked(false, animated: false)
        return (window, shell)
    }

    /// Timer-driven transitions can land late under full-suite load; wait for them, bounded.
    private func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func reveal(_ shell: OrbitWindowShell) async throws {
        shell.hoverReveal.pointerEnteredEdge()
        try await Task.sleep(for: .milliseconds(150))
        try await settle { shell.hoverReveal.isRevealed }
        #expect(shell.hoverReveal.isRevealed)
    }

    @Test("A real visible child window is not an owned sidebar presentation")
    func unrelatedChildDoesNotHold() async throws {
        let (window, shell) = makeShell()
        defer { window.close() }
        // A borderless nonactivating child is sufficient to exercise the old broad predicate.
        // Prohibited activation policy prevents the test application from taking focus.
        let child = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false
        window.addChildWindow(child, ordered: .above)
        child.orderBack(nil)
        defer { window.removeChildWindow(child); child.close() }
        #expect(child.isVisible)
        #expect(window.childWindows?.contains(child) == true)
        #expect(!shell.hoverReveal.isHeld())
        try await reveal(shell)
        shell.hoverReveal.pointerExitedPanel()
        try await Task.sleep(for: .milliseconds(100))
        try await settle { shell.hoverReveal.phase == .idle }
        #expect(shell.hoverReveal.phase == .idle)
    }

    @Test("Owned holds survive exit and release outside schedules dismissal without docking")
    func ownedHoldRelease() async throws {
        let (window, shell) = makeShell()
        defer { window.close() }
        var ownedPresentation = true
        shell.isHoverHeld = { ownedPresentation }
        shell.hoverReveal.isPointerInside = { false }
        try await reveal(shell)
        shell.hoverReveal.pointerExitedPanel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(shell.hoverReveal.phase == .revealed)
        ownedPresentation = false
        shell.hoverHoldDidChange()
        try await Task.sleep(for: .milliseconds(100))
        try await settle { shell.hoverReveal.phase == .idle }
        #expect(shell.hoverReveal.phase == .idle && !shell.isDocked)
        shell.setDocked(true, animated: false)
        shell.hoverHoldDidChange()
        #expect(shell.isDocked && shell.hoverReveal.phase == .disabled)
    }

    @Test("Native menu notification wiring holds until end tracking outside the panel")
    func menuNotificationWiring() async throws {
        let (window, shell) = makeShell()
        defer { window.close() }
        shell.hoverReveal.isPointerInside = { false }
        try await reveal(shell)
        let menu = NSMenu(title: "Synthetic menu")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        shell.hoverReveal.pointerExitedPanel()
        #expect(shell.hoverReveal.isHeld() && shell.hoverReveal.phase == .revealed)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        try await Task.sleep(for: .milliseconds(100))
        try await settle { shell.hoverReveal.phase == .idle }
        #expect(!shell.hoverReveal.isHeld() && shell.hoverReveal.phase == .idle)
    }
}
}
