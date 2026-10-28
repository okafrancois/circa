import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@MainActor
private final class EntryHost: BrowserSiteControlsHost {
    let engine = SiteSyntheticEngine()
    var window: NSWindow? { nil }
    let engineEventHooks = BrowserSurfaceEventHooks<SiteSyntheticSurface>()
    var siteControlSurface: SiteSyntheticSurface?
    var siteControlSurfaces: [SiteSyntheticSurface] { siteControlSurface.map { [$0] } ?? [] }
    var siteControlsClosed = false
    var isPreparingForTermination = false
    var acceptsCommands = true
    var rows: [NSView] = []
    var performed: [(BrowserSiteTopAction, SiteSyntheticSurface)] = []
    var disabled: BrowserSiteTopAction?
    init() {
        siteControlSurface = engine.makeSurface(profileID: ProfileID())
        siteControlSurface?.navigate(to: URL(string: "https://example.test")!)
    }
    func owns(_ surface: SiteSyntheticSurface) -> Bool { siteControlSurface === surface }
    func isSitePermissionTarget(_ surface: SiteSyntheticSurface) -> Bool { owns(surface) }
    func installSiteControlsButton(_ button: NSView) {}
    func openExtensionStore(from surface: SiteSyntheticSurface) {}
    func presentSiteControls(_ panel: BrowserSitePopover, rows: [NSView], button: NSView) { self.rows = rows }
    func canPerformSiteAction(_ action: BrowserSiteTopAction, on surface: SiteSyntheticSurface) -> Bool {
        acceptsCommands && owns(surface) && disabled != action
    }
    func performSiteAction(_ action: BrowserSiteTopAction, on surface: SiteSyntheticSurface) { performed.append((action, surface)) }
}

extension NativeWebKitTests {
@Suite("Site and Library entries", .serialized)
@MainActor
struct SiteLibraryEntryTests {
    private func buttons(_ view: NSView) -> [SiteControlButton] {
        (view as? SiteControlButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }

    @Test("All four top actions retain their order, targets, geometry and accessible tooltips")
    func actions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = EntryHost()
        let panel = BrowserSiteControls(owner: host)
        panel.render()
        for action in BrowserSiteTopAction.allCases {
            host.rows = []
            panel.show()
            try await waitForNativeState("site actions presented") { !host.rows.isEmpty }
            let center = try #require(host.rows.first as? OrbitSiteControlCenterView)
            let entries = buttons(center).filter { ["site-share", "site-new-boost", "site-capture-region", "site-capture-full-page"].contains($0.accessibilityIdentifier()) }
            #expect(entries.map { $0.accessibilityIdentifier() } == ["site-share", "site-new-boost", "site-capture-region", "site-capture-full-page"])
            for (index, button) in entries.enumerated() {
                #expect(button.frame.size == NSSize(width: 48, height: 32))
                #expect(button.superview?.frame.origin == NSPoint(x: 9 + CGFloat(index) * 56, y: 9))
                #expect(button.toolTip == button.accessibilityLabel())
                #expect(button.image != nil && button.isEnabled)
            }
            let index = try #require(BrowserSiteTopAction.allCases.firstIndex(of: action)) + 1
            entries[index].onPress?()
            #expect(host.performed.last?.0 == action)
            #expect(host.performed.last?.1 === host.siteControlSurface)
        }
    }

    @Test("A retained entry rejects navigation, selection changes and newly disabled operations", arguments: [0, 1, 2])
    func staleAction(change: Int) async throws {
        let host = EntryHost()
        let controls = BrowserSiteControls(owner: host)
        controls.render(); controls.show()
        try await waitForNativeState("site actions presented") { !host.rows.isEmpty }
        let entry = try #require(host.rows.flatMap { buttons($0) }.first { $0.accessibilityIdentifier() == "site-new-boost" })
        switch change {
        case 0:
            controls.navigationWillStart(try #require(host.siteControlSurface))
        case 1: host.siteControlSurface = host.engine.makeSurface(profileID: ProfileID())
        default: host.disabled = .newBoost
        }
        controls.render()
        entry.onPress?()
        #expect(host.performed.isEmpty)
    }

    @Test("Global Boost disable and a foreign tab refuse the production entry point")
    func productionAdmission() async throws {
        let engine = PeekSyntheticEngine()
        engine.capabilities = [.snapshots, .fullPageSnapshots]
        let environment = BrowserEnvironment(engine: engine)
        let owner = try await environment.makeWindow()
        defer { owner.window?.close() }
        owner.submitAddress("https://example.test")
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        #expect(owner.canPerformSiteAction(.newBoost, on: surface))
        try await environment.settings.setEnablesBoostsOnWebsites(false)
        #expect(!owner.canPerformSiteAction(.newBoost, on: surface))
        owner.performSiteAction(.newBoost, on: surface)
        #expect(owner.boostEditor == nil && owner.boostTask == nil)
        #expect(owner.canPerformSiteAction(.captureRegion, on: surface))
        #expect(owner.canPerformSiteAction(.captureFullPage, on: surface))
        owner.openTab(url: URL(string: "https://other.test")!)
        await owner.session.waitForPendingCommands()
        for action in BrowserSiteTopAction.allCases { #expect(!owner.canPerformSiteAction(action, on: surface)) }
    }
}
}
