import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite("Orbit control center layout", .serialized)
@MainActor
struct ControlCenterLayoutTests {
    @Test("Extension tiles keep Orbit's four-column pitch and new functional settings insert before the footer")
    func gridAndFutureSettings() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let tiles = (0..<5).map { _ in NSView() }
        let settings = (0..<4).map { _ in NSView() }
        let share = NSView(), secure = NSView(), more = NSView()
        let view = OrbitSiteControlCenterView(topActions: [share], tiles: tiles, settings: settings,
            manage: NSButton(), secure: secure, more: more)
        view.layoutSubtreeIfNeeded()
        #expect(view.frame.width == 236)
        #expect(share.frame == NSRect(x: 9, y: 9, width: 48, height: 32))
        #expect(tiles[0].frame.origin == NSPoint(x: 10, y: 79))
        #expect(tiles[3].frame.origin == NSPoint(x: 178, y: 79))
        #expect(tiles[4].frame.origin == NSPoint(x: 10, y: 119))
        #expect(settings[0].frame.origin.y == 193)
        #expect(settings.last!.frame.maxY < secure.frame.minY)
        #expect(secure.frame.size == more.frame.size)
        #expect(more.frame.maxX == 226 && more.frame.maxY <= view.bounds.maxY - 10)
        let footer = secure.frame.minY
        let inserted = [NSView(), NSView()] + settings
        let expanded = OrbitSiteControlCenterView(topActions: [NSView()], tiles: tiles, settings: inserted,
            manage: NSButton(), secure: secure, more: more)
        expanded.layoutSubtreeIfNeeded()
        #expect(secure.frame.minY == footer + 86)
    }

    @Test("The connection control uses a centered icon and the same target as More without losing its accessible action")
    func iconOnlyConnection() {
        var presses = 0
        let button = OrbitSiteControlCenterView.connectionButton(isSecure: true) { presses += 1 }
        let more = OrbitSiteControlCenterView.footerButton(symbol: "ellipsis", label: "More", identifier: "more", onPress: {})
        #expect(button.title.isEmpty && button.image != nil)
        #expect(button.imagePosition == .imageOnly && button.imageScaling == .scaleNone)
        #expect(button.frame.size == more.frame.size && button.frame.width == 32)
        #expect(button.layer?.cornerRadius == more.layer?.cornerRadius)
        #expect(button.accessibilityLabel() == "Secure connection" && button.toolTip == "Secure connection")
        button.performClick(nil)
        #expect(presses == 1)
    }

    @Test("Permission rows preserve native Ask, Allow and Block selection and dispatch the selected setting")
    func permissionChoice() throws {
        var chosen: BrowserSitePermissionSetting?
        let picker = ControlCenterPermissionPicker(permission: .camera, setting: .ask, symbol: "camera.fill") { chosen = $0 }
        #expect(picker.itemTitles == ["Ask", "Allow", "Block"])
        for (index, value) in BrowserSitePermissionSetting.allCases.enumerated() {
            picker.selectItem(at: index)
            #expect(picker.sendAction(try #require(picker.action), to: picker.target))
            #expect(chosen == value)
        }
    }

    @Test("Pin order writes serialize and are shared before the settings actor finishes")
    func pinOrderPersistence() async throws {
        let store = try BrowserSettingsStore()
        let runtime = BrowserSettingsRuntime(store: store)
        let profile = ProfileID(), other = ProfileID()
        let first = String(repeating: "a", count: 32), second = String(repeating: "b", count: 32)
        runtime.saveExtensionPinOrder([second], profileID: profile) { _ in Issue.record("Pin order write failed") }
        runtime.saveExtensionPinOrder([second, first], profileID: profile) { _ in Issue.record("Pin order write failed") }
        #expect(runtime.extensionPinOrder(for: profile) == [second, first])
        await runtime.flushExtensionPinOrders()
        #expect(await store.snapshot().profile(profile).extensionPinOrder == [second, first])
        #expect(runtime.extensionPinOrder(for: other).isEmpty)
    }
}
