import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@MainActor
private final class RefreshExtensionHost: BrowserExtensionHost {
    let changes = BrowserExtensionChangeHub()
    var reads = 0
    var supportsActions = true
    var onExtensionsChange: ((ProfileID) -> Void)?
    func observeChanges(in profileID: ProfileID, handler: @escaping () -> Void) throws -> BrowserExtensionObservation {
        changes.observe(in: profileID, handler: handler)
    }
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] {
        reads += 1
        return [.init(id: String(repeating: "a", count: 32), name: "Synthetic", version: "1", isEnabled: true, hasAction: true)]
    }
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws { throw BrowserEngineError.unsupportedOperation }
    func remove(extensionID: String, in profileID: ProfileID) throws {}
    func openManagement(on surface: any BrowserEngineSurface) throws {}
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws { throw BrowserEngineError.unsupportedOperation }
}

@MainActor
private final class DelayedSiteOwner: BrowserSiteControlsHost, BrowserEngineSurfaceDelegate {
    let engine: SiteSyntheticEngine
    var window: NSWindow? { nil }
    let engineEventHooks = BrowserSurfaceEventHooks<SiteSyntheticSurface>()
    var siteControlSurface: SiteSyntheticSurface?
    var siteControlSurfaces: [SiteSyntheticSurface] { siteControlSurface.map { [$0] } ?? [] }
    var siteControlsClosed = false
    var isPreparingForTermination = false
    var acceptsCommands = true
    var presentations = 0
    var rows: [NSView] = []
    var panel: BrowserSitePopover?
    init(engine: SiteSyntheticEngine) {
        self.engine = engine
        let surface = engine.makeSurface(profileID: ProfileID(), delegate: self)
        surface.navigate(to: URL(string: "https://synthetic-extension.test/")!)
        siteControlSurface = surface
    }
    func surfaceDidStartNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidCommitNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidFinishNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidFailNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidRequestClose(_ surface: SiteSyntheticSurface) {}
    func surface(_ surface: SiteSyntheticSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func surface(_ surface: SiteSyntheticSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> SiteSyntheticSurface) -> SiteSyntheticSurface? { nil }
    func surface(_ surface: SiteSyntheticSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
    func owns(_ surface: SiteSyntheticSurface) -> Bool { siteControlSurface === surface }
    func isSitePermissionTarget(_ surface: SiteSyntheticSurface) -> Bool { owns(surface) && !siteControlsClosed }
    func installSiteControlsButton(_ button: NSView) {}
    func openExtensionStore(from surface: SiteSyntheticSurface) {}
    func presentSiteControls(_ panel: BrowserSitePopover, rows: [NSView], button: NSView) {
        self.panel = panel; self.rows = rows; presentations += 1
    }
}

@MainActor
private final class PresentationGate {
    var started = false
    var settings: CheckedContinuation<[BrowserSitePermission: BrowserSitePermissionSetting], Never>?
    var media: CheckedContinuation<BrowserMediaState, Never>?
    var mediaCalls = 0
    func release() {
        settings?.resume(returning: [:]); settings = nil
        media?.resume(returning: .init()); media = nil
    }
}

extension NativeWebKitTests {
@Suite("R3 owned asynchronous extension presentation", .serialized)
@MainActor
struct ExtensionR3PresentationTests {
    private func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(condition(), "synthetic presentation gate did not progress")
    }

    @Test("Independent review: suspended inventory refresh loses document, selection and owner authority",
          arguments: ["settings", "media"], ["selection-aba", "document", "termination", "foreign-profile"])
    func reviewRevokedContext(stage: String, edge: String) async throws {
        let engine = SiteSyntheticEngine(), host = RefreshExtensionHost()
        engine.extensions = host
        let owner = DelayedSiteOwner(engine: engine)
        let controls = BrowserSiteControls(owner: owner)
        let source = try #require(owner.siteControlSurface)
        defer { controls.cancelPermission(); engine.surfaces.forEach { $0.dispose() } }
        controls.show()
        try await wait { owner.presentations == 1 }
        let gate = PresentationGate()
        defer { gate.release() }
        controls.presentationSettings = { _, _ in
            if stage == "settings" && !gate.started {
                gate.started = true
                return await withCheckedContinuation { gate.settings = $0 }
            }
            return [:]
        }
        source.mediaRequest = {
            if stage == "media" && !gate.started {
                gate.started = true
                return await withCheckedContinuation { gate.media = $0 }
            }
            return .init()
        }
        host.changes.emit(source.profileID)
        try await wait { gate.settings != nil || gate.media != nil }
        switch edge {
        case "selection-aba":
            owner.siteControlSurface = nil
            controls.render()
            owner.siteControlSurface = source
            controls.render()
        case "document": source.navigate(to: URL(string: "https://new-document.test/")!)
        case "termination": owner.isPreparingForTermination = true
        default:
            owner.siteControlSurface = engine.makeSurface(profileID: ProfileID(), delegate: owner)
        }
        gate.release()
        for _ in 0..<20 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(owner.presentations == 1)
        #expect(host.reads == 1, "a revoked refresh must not query an old or foreign profile")
        host.changes.emit(source.profileID)
        for _ in 0..<10 { await Task.yield() }
        #expect(owner.presentations == 1 && host.reads == 1)
    }

    @Test("A suspended registry refresh cannot reopen or resubscribe after dismissal, close or replacement",
          arguments: ["settings", "media"], ["dismiss", "native-dismiss", "close", "replace", "message"])
    func delayedRefresh(stage: String, action: String) async throws {
        let engine = SiteSyntheticEngine(), host = RefreshExtensionHost()
        engine.extensions = host
        let owner = DelayedSiteOwner(engine: engine)
        let controls = BrowserSiteControls(owner: owner)
        let surface = try #require(owner.siteControlSurface)
        defer { surface.dispose() }
        controls.show()
        try await wait { owner.presentations == 1 }
        let panel = try #require(owner.panel)
        let gate = PresentationGate()
        defer { gate.release() }
        controls.presentationSettings = { _, _ in
            if stage == "settings" && !gate.started {
                gate.started = true
                return await withCheckedContinuation { gate.settings = $0 }
            }
            return [:]
        }
        surface.mediaRequest = {
            gate.mediaCalls += 1
            if stage == "media" && !gate.started {
                gate.started = true
                return await withCheckedContinuation { gate.media = $0 }
            }
            return .init()
        }
        host.changes.emit(surface.profileID) // Execute the real product refresh -> show -> await pipeline.
        try await wait { gate.settings != nil || gate.media != nil }
        switch action {
        case "dismiss": panel.close()
        case "native-dismiss": panel.popoverWillClose(Notification(name: Notification.Name("SyntheticDismiss")))
        case "close": owner.siteControlsClosed = true; controls.cancelPermission()
        case "message":
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let action = try #require(owner.rows.flatMap(descendants).compactMap { $0 as? SiteControlButton }.first {
                ($0.accessibilityIdentifier() ?? "").hasPrefix("extension-action-")
            })
            action.onPress?()
        default:
            controls.show()
            try await wait { owner.presentations == 2 }
        }
        let expected = action == "replace" || action == "message" ? 2 : 1
        let expectedReads = action == "replace" ? 2 : 1
        gate.release()
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(owner.presentations == expected)
        #expect(host.reads == expectedReads, "revoked asynchronous work cannot read inventory or install a new observer")
        if stage == "settings" && action != "replace" {
            #expect(gate.mediaCalls == 0, "revocation after the first await must prevent the second engine request")
        }
        if action != "replace" {
            host.changes.emit(surface.profileID)
            for _ in 0..<10 { await Task.yield() }
            #expect(owner.presentations == expected && host.reads == expectedReads)
        }
        controls.cancelPermission()
    }
}
}
