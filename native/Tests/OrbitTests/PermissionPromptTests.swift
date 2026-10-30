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

    @Test("The app notification follow-up dismisses once and leaves the site decision alone")
    func notificationFollowUp() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        var choices: [Bool] = []
        let prompt = NotificationSettingsPromptView { choices.append($0) }
        prompt.show(over: root)
        #expect(prompt.card.frame.size == NSSize(width: 450, height: 290))
        #expect(prompt.card.frame.midX == root.bounds.midX)
        #expect(prompt.dismissButton.title == uiText("Never Mind"))
        #expect(prompt.settingsButton.title == uiText("Open System Preferences"))
        prompt.finish(openSettings: false)
        prompt.finish(openSettings: true)
        #expect(choices == [false])
        #expect(prompt.superview == nil)
    }

    @Test("Notification keycap glyphs have symmetric painted insets at both display scales and appearances")
    func keycapInsets() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for scale in [1, 2] {
                for hint in ["↩", "ESC"] {
                    let button = NotificationSettingsButton()
                    button.frame = NSRect(x: 0, y: 0, width: 217, height: 36)
                    button.primary = true
                    button.hint = hint
                    button.appearance = NSAppearance(named: appearance)
                    let (cap, glyph) = button.keycapLayout
                    #expect(cap.size == NSSize(width: hint == "↩" ? 28 : 35, height: 20))
                    #expect(cap.contains(glyph))
                    #expect(abs(glyph.minX - cap.minX - (cap.maxX - glyph.maxX)) < 0.001)
                    #expect(abs(glyph.minY - cap.minY - (cap.maxY - glyph.maxY)) < 0.001)
                    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: 217 * scale, pixelsHigh: 36 * scale, bitsPerSample: 8,
                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
                    NSGraphicsContext.saveGraphicsState()
                    context.translateBy(x: 0, y: CGFloat(36 * scale))
                    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    button.effectiveAppearance.performAsCurrentDrawingAppearance { button.draw(button.bounds) }
                    NSGraphicsContext.restoreGraphicsState()
                    var painted: NSRect = .null
                    let pixels = cap.applying(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
                    for y in Int(pixels.minY)..<Int(pixels.maxY) {
                        for x in Int(pixels.minX)..<Int(pixels.maxX) {
                            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            if color.redComponent > 0.6 && color.greenComponent > 0.6 {
                                painted = painted.union(NSRect(x: x, y: y, width: 1, height: 1))
                            }
                        }
                    }
                    #expect(!painted.isNull)
                    #expect(painted.minX > pixels.minX && painted.maxX < pixels.maxX)
                    #expect(painted.minY > pixels.minY && painted.maxY < pixels.maxY)
                    #expect(abs(painted.minX - pixels.minX - (pixels.maxX - painted.maxX)) <= 1)
                    #expect(abs(painted.minY - pixels.minY - (pixels.maxY - painted.maxY)) <= 1)
                }
            }
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
