import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@MainActor
private final class InventoryHost: BrowserExtensionHost {
    let changes = BrowserExtensionChangeHub()
    var supportsActions = false
    var onExtensionsChange: ((ProfileID) -> Void)?
    var failsToggle = false
    var readProfiles: [ProfileID] = []
    func observeChanges(in profileID: ProfileID, handler: @escaping () -> Void) throws -> BrowserExtensionObservation {
        changes.observe(in: profileID, handler: handler)
    }
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] {
        readProfiles.append(profileID)
        return [.init(id: String(repeating: "a", count: 32), name: "Synthetic", version: "1", isEnabled: false, hasAction: false)]
    }
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws {
        if failsToggle { throw BrowserEngineError.unsupportedOperation }
    }
    func remove(extensionID: String, in profileID: ProfileID) throws {}
    func openManagement(on surface: any BrowserEngineSurface) throws {}
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws {}
}

@MainActor
private final class InventoryOwner: BrowserSiteControlsHost {
    let engine: SiteSyntheticEngine
    var window: NSWindow? { nil }
    let engineEventHooks = BrowserSurfaceEventHooks<SiteSyntheticSurface>()
    var siteControlSurface: SiteSyntheticSurface?
    var siteControlSurfaces: [SiteSyntheticSurface] { siteControlSurface.map { [$0] } ?? [] }
    var siteControlsClosed = false
    var isPreparingForTermination = false
    var acceptsCommands = true
    var presentations: [[NSView]] = []
    var presentationEvents: [String] = []
    init(engine: SiteSyntheticEngine, profile: ProfileID) { self.engine = engine; siteControlSurface = engine.makeSurface(profileID: profile) }
    func owns(_ surface: SiteSyntheticSurface) -> Bool { siteControlSurface === surface }
    func isSitePermissionTarget(_ surface: SiteSyntheticSurface) -> Bool { owns(surface) && !siteControlsClosed }
    func installSiteControlsButton(_ button: NSView) {}
    func openExtensionStore(from surface: SiteSyntheticSurface) {}
    func presentSiteControls(_ panel: BrowserSitePopover, rows: [NSView], button: NSView) {
        presentations.append(rows)
        presentationEvents.append("present")
        panel.onCloseRequest = { [weak self] in self?.presentationEvents.append("close") }
    }
}

extension NativeWebKitTests {
@Suite("Extension R2 presentation ownership", .serialized)
@MainActor
struct ExtensionR2InventoryTests {
    @Test("Two window controllers fan out same-profile changes and reject foreign profiles or stale epochs")
    func independentWindows() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine(), host = InventoryHost()
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let first = try await environment.makeWindow(), second = try await environment.makeWindow()
        defer { first.window?.close(); second.window?.close() }
        let a = try #require(first.session.selectedSurface)
        let b = try #require(second.session.selectedSurface)
        #expect(a.profileID == b.profileID, "both real hidden window controllers use the same profile")
        let otherProfile = await environment.store.createProfile(name: "Synthetic Other")
        let otherSpace = try await environment.store.createSpace(name: "Synthetic Other", profileID: otherProfile)
        let different = try await environment.makeWindow(spaceID: otherSpace)
        defer { different.window?.close() }
        let c = try #require(different.session.selectedSurface)
        #expect(c.profileID == otherProfile && c.profileID != a.profileID)
        var readsA = 0, readsB = 0, readsOther = 0, collectedReads = 0, legacy = 0
        host.onExtensionsChange = { _ in legacy += 1 }
        first.siteControls.observeExtensionInventory(on: a, valid: { true }) { readsA += 1 }
        second.siteControls.observeExtensionInventory(on: b, valid: { true }) { readsB += 1 }
        different.siteControls.observeExtensionInventory(on: c, valid: { true }) { readsOther += 1 }
        let readsBefore = host.readProfiles.count
        host.changes.emit(a.profileID)
        #expect(readsA == 1 && readsB == 1 && readsOther == 0)
        host.changes.emit(c.profileID)
        #expect(readsA == 1 && readsB == 1 && readsOther == 1)
        first.siteControls.stopObservingExtensions()
        host.changes.emit(a.profileID)
        #expect(readsA == 1 && readsB == 2 && readsOther == 1)
        first.siteControls.observeExtensionInventory(on: a, valid: { false }) { readsA += 100 }
        host.changes.emit(a.profileID)
        #expect(readsA == 1 && readsB == 3)
        // A controller cannot subscribe a foreign live surface as its own target.
        first.siteControls.observeExtensionInventory(on: c, valid: { true }) { readsA += 100 }
        host.changes.emit(c.profileID)
        #expect(readsA == 1 && readsOther == 2)
        second.siteControls.cancelPermission() // Actual close/termination uses this teardown hook.
        host.changes.emit(a.profileID)
        #expect(readsB == 3)
        different.session.close()
        different.siteControls.cancelPermission()
        host.changes.emit(c.profileID)
        #expect(readsOther == 2)
        let collectorOwner = InventoryOwner(engine: engine, profile: c.profileID)
        var collector: BrowserSiteControls<SiteSyntheticEngine>? = BrowserSiteControls(owner: collectorOwner)
        weak var weakCollector = collector
        collector?.observeExtensionInventory(on: collectorOwner.siteControlSurface!, valid: { true }) { collectedReads += 1 }
        collector = nil
        #expect(weakCollector == nil, "service callbacks must not retain a collected presentation")
        host.changes.emit(c.profileID)
        #expect(collectedReads == 0)
        #expect(host.readProfiles.count == readsBefore, "notifications alone must not read another profile")
        host.onExtensionsChange?(a.profileID)
        #expect(legacy == 1, "controllers never replace or clear the service's single legacy callback")
        collectorOwner.siteControlSurface?.dispose()
        first.session.close(); second.session.close()
        try await environment.finalize()
    }

    @Test("A policy-blocked toggle leaves an explanation as the final presentation")
    func toggleErrorSurvives() throws {
        let engine = SiteSyntheticEngine(), host = InventoryHost()
        engine.extensions = host; host.failsToggle = true
        let owner = InventoryOwner(engine: engine, profile: ProfileID())
        let controls = BrowserSiteControls(owner: owner)
        let surface = try #require(owner.siteControlSurface)
        var rows: [NSView] = []
        controls.appendExtensionRows(to: &rows, surface: surface, valid: { true })
        let toggle = try #require(rows.compactMap { $0 as? SiteControlButton }.first {
            ($0.accessibilityIdentifier() ?? "").hasPrefix("extension-toggle-")
        })
        toggle.onPress?()
        #expect(owner.presentationEvents.last == "present", "the explanation must not be immediately closed")
        let last = try #require(owner.presentations.last)
        #expect(last.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("could not be changed") })
        surface.dispose()
    }
}
}
