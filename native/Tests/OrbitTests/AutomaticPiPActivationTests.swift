import AppKit
import Testing
@testable import Orbit

@MainActor
struct AutomaticPiPActivationTests {
    @Test("Only the selected window departs on an application switch", arguments: [true, false])
    func applicationSwitch(ownsWindow: Bool) async {
        let center = NotificationCenter()
        var context = BrowserAutomaticPiPActivation.Context(ownsActiveWindow: ownsWindow,
            isHidden: false, isMiniaturized: false, isActive: true)
        var departures: [Bool] = []
        var activation: BrowserAutomaticPiPActivation!
        activation = BrowserAutomaticPiPActivation(center: center, context: { context },
            changed: { departures.append(activation.isAway) })
        defer { activation = nil }
        center.post(name: NSApplication.willResignActiveNotification, object: nil)
        // Key/main ownership can disappear before didResignActive.
        context.ownsActiveWindow = false
        context.isActive = false
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(activation.isAway == ownsWindow)
        context.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(!activation.isAway)
        #expect(departures == (ownsWindow ? [true, false] : []))
    }

    @Test("Hide, minimize and occlusion never create a departure",
          arguments: ["hide-before", "hide-after", "hidden", "minimize", "occlusion"])
    func visibilityOnly(action: String) async {
        let center = NotificationCenter()
        var context = BrowserAutomaticPiPActivation.Context(ownsActiveWindow: true,
            isHidden: false, isMiniaturized: false, isActive: true)
        var changes = 0
        let activation = BrowserAutomaticPiPActivation(center: center, context: { context }, changed: { changes += 1 })
        if action == "hide-before" { center.post(name: NSApplication.willHideNotification, object: nil) }
        if action != "occlusion" {
            context.isActive = false
            context.isHidden = action == "hidden"
            context.isMiniaturized = action == "minimize"
            center.post(name: NSApplication.didResignActiveNotification, object: nil)
        } else {
            center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        }
        if action == "hide-after" { center.post(name: NSApplication.willHideNotification, object: nil) }
        for _ in 0..<20 { await Task.yield() }
        #expect(!activation.isAway)
        #expect(changes == 0)
    }

    @Test("Hiding an automatic session retains it until activation returns")
    func existingSessionHide() async {
        let center = NotificationCenter()
        var context = BrowserAutomaticPiPActivation.Context(ownsActiveWindow: true,
            isHidden: false, isMiniaturized: false, isActive: false)
        let activation = BrowserAutomaticPiPActivation(center: center, context: { context }, changed: {})
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(activation.isAway)
        center.post(name: NSApplication.willHideNotification, object: nil)
        context.isHidden = true
        #expect(activation.isAway)
        context.isHidden = false
        center.post(name: NSApplication.didUnhideNotification, object: nil)
        #expect(activation.isAway)
        context.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(!activation.isAway)
    }

    @Test("An immediate return cancels pending automatic entry")
    func immediateReturn() async {
        let center = NotificationCenter()
        var context = BrowserAutomaticPiPActivation.Context(ownsActiveWindow: true,
            isHidden: false, isMiniaturized: false, isActive: false)
        let activation = BrowserAutomaticPiPActivation(center: center, context: { context }, changed: {})
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        context.isActive = true
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<20 { await Task.yield() }
        #expect(!activation.isAway)
    }
}
