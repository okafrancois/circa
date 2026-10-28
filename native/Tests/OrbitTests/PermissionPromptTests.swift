import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite("Permission prompt structure")
@MainActor
struct PermissionPromptTests {
    private let origin = BrowserSiteOrigin(requestOrigin: "http://localhost:48963")!

    @Test("Permission prompts share compact geometry and expose the full requesting origin",
          arguments: [[BrowserSitePermission.notifications], [.camera], [.microphone], [.camera, .microphone],
                      [.geolocation], [.clipboardRead], [.screenSharing]])
    func compactPrompt(permissions: [BrowserSitePermission]) {
        let prompt = SitePermissionPromptView(origin: origin, permissions: permissions, onChoice: { _ in })
        #expect(prompt.frame.width == 236)
        #expect(prompt.frame.height < 180)
        #expect(prompt.message.stringValue.contains("http://localhost:48963"))
        #expect(prompt.message.frame.minX == 50)
        #expect(prompt.message.font?.pointSize == 14)
        #expect(prompt.notNowButton.title == uiText("Not Now"))
        #expect(prompt.allowButton.title == uiText("Allow"))
        #expect(prompt.notNowButton.frame.maxX < prompt.allowButton.frame.minX)
        #expect(prompt.notNowButton.frame.height == 32)
        #expect(prompt.allowButton.keyEquivalent.isEmpty)
        #expect(prompt.subviews.count == 4)
    }

    /// Target/action directly: `performClick` routes through NSApp, which parallel suites can
    /// hold in a modal session.
    private func press(_ button: NSButton) {
        #expect(button.isEnabled)
        _ = (button.target as? NSObject)?.perform(button.action, with: button)
    }

    @Test("Not Now blocks the origin; Allow respects fresh screen-capture grants")
    func choices() {
        var blocked = false
        var persisted = false
        var allowedOnce = false
        let prompt = SitePermissionPromptView(origin: origin, permissions: [.notifications]) {
            if case .block = $0 { blocked = true }
            if case .alwaysAllow = $0 { persisted = true }
        }
        press(prompt.notNowButton)
        #expect(blocked)
        #expect(!persisted)
        press(prompt.allowButton)
        #expect(persisted)
        let capture = SitePermissionPromptView(origin: origin, permissions: [.screenSharing]) {
            if case .allowOnce = $0 { allowedOnce = true }
        }
        press(capture.allowButton)
        #expect(allowedOnce)
    }

    @Test("Observed permission copy and symbols distinguish each capability")
    func observedMessages() {
        #expect(SitePermissionPromptView.message(origin: origin, permissions: [.notifications]) ==
                "Allow http://localhost:48963 to send you notifications?")
        #expect(SitePermissionPromptView.message(origin: origin, permissions: [.camera, .microphone]) ==
                "Allow http://localhost:48963 to access your camera, microphone?")
        #expect(SitePermissionPromptView.symbol(for: [.camera]) == "camera.fill")
        #expect(SitePermissionPromptView.symbol(for: [.microphone]) == "mic.fill")
        #expect(SitePermissionPromptView.symbol(for: [.notifications]) == "bell.fill")
        #expect(SitePermissionPromptView.symbol(for: [.geolocation]) == "location.fill")
        #expect(SitePermissionPromptView.symbol(for: [.clipboardRead]) == "clipboard.fill")
    }

    @Test("Generic site detail popovers leave the native material visible in both appearances")
    func nativeMaterial() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let content = BrowserSitePopover.makeContent(rows: [BrowserSitePopover.label("Synthetic site")], maximumHeight: 300)
            content.appearance = NSAppearance(named: appearance)
            #expect(!content.drawsBackground)
        }
    }

    @Test("Immediate dismissal invalidates before closing and preserves later motion preferences")
    func immediateDismissal() {
        for animates in [true, false] {
            let panel = BrowserSitePopover()
            panel.popover.animates = animates
            var events: [String] = []
            panel.onWillClose = { events.append("invalidate") }
            panel.onCloseRequest = {
                #expect(!panel.popover.animates)
                events.append("close")
            }
            panel.close(animating: false)
            #expect(events == ["invalidate", "close"])
            #expect(panel.popover.animates == animates)

            panel.onCloseRequest = { #expect(panel.popover.animates == animates) }
            panel.close()
            #expect(panel.popover.animates == animates)
            panel.onCloseRequest = nil
        }
    }
}
