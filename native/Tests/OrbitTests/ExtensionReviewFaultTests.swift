import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@MainActor
private final class ReviewExtensionHost: BrowserExtensionHost {
    var supportsActions = true
    var onExtensionsChange: ((ProfileID) -> Void)?
    var failsInventory = true
    var calls = 0
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] {
        if failsInventory { throw BrowserEngineError.unsupportedOperation }
        return [.init(id: String(repeating: "a", count: 32), name: "Review Fixture", version: "1",
                      isEnabled: true, hasAction: true)]
    }
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws { calls += 1 }
    func remove(extensionID: String, in profileID: ProfileID) throws { calls += 1 }
    func openManagement(on surface: any BrowserEngineSurface) throws { calls += 1 }
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws { calls += 1 }
}

extension NativeWebKitTests {
@Suite("Independent extension fault review", .serialized)
@MainActor
struct ExtensionReviewFaultTests {
    @Test("Registry failure keeps management available without exposing Store or extension actions")
    func failedInventory() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let host = ReviewExtensionHost()
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        let surface = try #require(window.session.selectedSurface)
        var rows: [NSView] = []
        window.siteControls.appendExtensionRows(to: &rows, surface: surface, valid: { true })
        // extensions-daily-2026-10-27.md: management remains available independently of the registry.
        #expect(rows.count == 2)
        let buttons = rows.compactMap { $0 as? SiteControlButton }
        #expect(buttons.count == 1)
        let manager = try #require(buttons.first)
        #expect(manager.accessibilityIdentifier() == "extensions-manage")
        #expect(rows.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("not ready") })
        #expect(host.calls == 0)
        manager.onPress?()
        #expect(host.calls == 1)
        #expect(window.window?.isVisible == false)
        window.session.close()
        try await environment.finalize()
    }

    @Test("Revoked commands cannot navigate to Store or start a removal confirmation")
    func revokedCommands() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let host = ReviewExtensionHost()
        host.failsInventory = false
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        let surface = try #require(window.session.selectedSurface)
        let originalURL = surface.navigationState.url
        var rows: [NSView] = []
        window.siteControls.appendExtensionRows(to: &rows, surface: surface, valid: { false })
        let buttons = rows.compactMap { $0 as? SiteControlButton }
        #expect(buttons.count == 5)
        for button in buttons { button.onPress?() }
        #expect(host.calls == 0)
        #expect(surface.navigationState.url == originalURL)
        #expect(window.window?.attachedSheet == nil)
        #expect(window.window?.isVisible == false)
        window.session.close()
        try await environment.finalize()
    }
}
}
