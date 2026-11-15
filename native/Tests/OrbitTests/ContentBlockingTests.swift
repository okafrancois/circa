import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

@MainActor
private final class BlockingHost: BrowserSiteControlsHost {
    let engine = SiteSyntheticEngine()
    var window: NSWindow? { nil }
    let engineEventHooks = BrowserSurfaceEventHooks<SiteSyntheticSurface>()
    var siteControlSurface: SiteSyntheticSurface?
    var siteControlSurfaces: [SiteSyntheticSurface] { siteControlSurface.map { [$0] } ?? [] }
    var siteControlsClosed = false
    var isPreparingForTermination = false
    var acceptsCommands = true
    var rows: [NSView] = []
    private let navigation = AllowingDelegate()
    init(url: String) {
        siteControlSurface = engine.makeSurface(profileID: ProfileID(), delegate: navigation)
        siteControlSurface?.navigate(to: URL(string: url)!)
    }
    func owns(_ surface: SiteSyntheticSurface) -> Bool { siteControlSurface === surface }
    func isSitePermissionTarget(_ surface: SiteSyntheticSurface) -> Bool { owns(surface) }
    func installSiteControlsButton(_ button: NSView) {}
    func openExtensionStore(from surface: SiteSyntheticSurface) {}
    func presentSiteControls(_ panel: BrowserSitePopover, rows: [NSView], button: NSView) { self.rows = rows }
    func canPerformSiteAction(_ action: BrowserSiteTopAction, on surface: SiteSyntheticSurface) -> Bool { false }
    func performSiteAction(_ action: BrowserSiteTopAction, on surface: SiteSyntheticSurface) {}
}

@MainActor
private final class AllowingDelegate: BrowserEngineSurfaceDelegate {
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
}

private struct BlockerFailure: Error {}

extension NativeWebKitTests {
@Suite("Built-in content blocking", .serialized)
@MainActor
struct ContentBlockingTests {
    private func settingButtons(_ view: NSView) -> [ControlCenterSettingButton] {
        (view as? ControlCenterSettingButton).map { [$0] } ?? view.subviews.flatMap { settingButtons($0) }
    }

    @Test("The coordinator applies only changes, clears exceptions while off and retries failures")
    func coordinator() async throws {
        let fake = BrowserFakeContentBlocking()
        let profile = ProfileID()
        var enabled = true
        var hosts = ["b.example.test", "a.example.test"]
        let coordinator = BrowserContentBlockingCoordinator(blocker: fake, isEnabled: { _ in enabled }, exceptions: { _ in hosts })
        await coordinator.synchronize(profile)
        #expect(fake.configurations[profile] == .init(isEnabled: true, allowedHosts: ["a.example.test", "b.example.test"]))
        await coordinator.synchronize(profile)
        #expect(fake.configureCount == 1)
        enabled = false
        await coordinator.synchronizePrepared()
        #expect(fake.configurations[profile] == .init(isEnabled: false))
        enabled = true; hosts = []
        fake.failure = BlockerFailure()
        var errors = 0
        coordinator.onError = { _ in errors += 1 }
        await coordinator.synchronize(profile)
        #expect(errors == 1 && fake.configurations[profile]?.isEnabled == false)
        fake.failure = nil
        await coordinator.synchronize(profile)
        #expect(fake.configurations[profile] == .init(isEnabled: true))
        coordinator.forget(profile)
        await coordinator.synchronizePrepared()
        #expect(fake.configureCount == 3)
    }

    @Test("The site row toggles a host exception, applies it and reloads the page")
    func siteRow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = BlockingHost(url: "https://news.example.test/article")
        let controls = BrowserSiteControls(owner: host)
        let fake = BrowserFakeContentBlocking()
        var profileEnabled = true
        let coordinator = BrowserContentBlockingCoordinator(blocker: fake, isEnabled: { _ in profileEnabled },
            exceptions: { [controls] in controls.preferences.contentBlockingExceptions(profileID: $0) })
        controls.contentBlocking = coordinator
        let surface = try #require(host.siteControlSurface)
        controls.render(); controls.show()
        try await waitForNativeState("site controls presented") { !host.rows.isEmpty }
        let row = try #require(host.rows.flatMap { settingButtons($0) }.first { $0.accessibilityIdentifier() == "site-content-blocking" })
        #expect(row.accessibilityLabel() == uiText("Ads & Trackers") + ", " + uiText("Blocked"))
        let generation = surface.findDocumentGeneration
        row.performClick(nil)
        #expect(!controls.preferences.preferences(url: surface.currentURL, profileID: surface.profileID).blocksAdsAndTrackers)
        try await waitForNativeState("exception applied and page reloaded") {
            fake.configurations[surface.profileID] == .init(isEnabled: true, allowedHosts: ["news.example.test"])
                && surface.findDocumentGeneration > generation
        }
        // Without profile-level blocking or a blocker the row is absent.
        profileEnabled = false
        host.rows = []; controls.show()
        try await waitForNativeState("site controls presented again") { !host.rows.isEmpty }
        #expect(!host.rows.flatMap { settingButtons($0) }.contains { $0.accessibilityIdentifier() == "site-content-blocking" })
        profileEnabled = true; controls.contentBlocking = nil
        host.rows = []; controls.show()
        try await waitForNativeState("site controls presented without a blocker") { !host.rows.isEmpty }
        #expect(!host.rows.flatMap { settingButtons($0) }.contains { $0.accessibilityIdentifier() == "site-content-blocking" })
    }

    @Test("Private windows follow their parents, keep session exceptions in memory and forget them at the end")
    func privateSession() async throws {
        let fake = BrowserFakeContentBlocking()
        let parent = ProfileID(), other = ProfileID()
        var enabled: [ProfileID: Bool] = [parent: true, other: true]
        var persistent: [ProfileID: [String]] = [parent: ["kept.example.test"], other: []]
        let coordinator = BrowserContentBlockingCoordinator(blocker: fake, isEnabled: { enabled[$0] ?? false },
            exceptions: { persistent[$0] ?? [] })
        // Nothing is configured before a private window; the engine is readied before its context.
        await coordinator.synchronizePrivate()
        #expect(fake.privateConfiguration == nil && !coordinator.blocksPrivately)
        #expect(await coordinator.preparePrivateWindow() && fake.preparedPrivateWindows == 1)
        let first = UUID(), second = UUID()
        await coordinator.openPrivateWindow(first, parent: parent)
        #expect(fake.privateConfiguration == .init(isEnabled: true, allowedHosts: ["kept.example.test"]))
        // A parent's exception is read-only; other hosts take a private exception.
        #expect(coordinator.privateSiteState(host: "kept.example.test") == (false, false))
        #expect(coordinator.privateSiteState(host: "news.example.test") == (true, true))
        #expect(coordinator.setPrivateException(host: "News.Example.Test", allowed: true))
        await coordinator.synchronizePrivate(waitsForAcknowledgement: true)
        #expect(fake.privateConfiguration?.allowedHosts == ["kept.example.test", "news.example.test"])
        #expect(coordinator.privateSiteState(host: "news.example.test") == (false, true))
        // The private exception never reaches the persistent configuration.
        #expect(fake.configurations.isEmpty && persistent[parent] == ["kept.example.test"])
        // The parent's switch turns private blocking off and on again.
        enabled[parent] = false
        await coordinator.synchronizePrepared()
        #expect(fake.privateConfiguration == .init(isEnabled: false) && !coordinator.blocksPrivately)
        enabled[parent] = true
        await coordinator.synchronize(parent)
        #expect(fake.privateConfiguration?.isEnabled == true)
        // A second window with another parent: every switch must be on; both exception lists apply.
        persistent[other] = ["other.example.test"]
        await coordinator.openPrivateWindow(second, parent: other)
        #expect(fake.privateConfiguration?.allowedHosts == ["kept.example.test", "news.example.test", "other.example.test"])
        enabled[other] = false
        await coordinator.synchronizePrepared()
        #expect(fake.privateConfiguration == .init(isEnabled: false))
        enabled[other] = true
        // Closing one window keeps the session; closing the last forgets its exceptions.
        await coordinator.closePrivateWindow(second)
        #expect(fake.privateConfiguration?.allowedHosts == ["kept.example.test", "news.example.test"])
        #expect(fake.endedPrivateSessions == 0)
        await coordinator.closePrivateWindow(first)
        #expect(fake.privateConfiguration == nil && fake.endedPrivateSessions == 1 && !coordinator.blocksPrivately)
        await coordinator.openPrivateWindow(UUID(), parent: parent)
        #expect(fake.privateConfiguration == .init(isEnabled: true, allowedHosts: ["kept.example.test"]))
        #expect(coordinator.privateSiteState(host: "news.example.test") == (true, true) && coordinator.blocksPrivately)
        // A configuration the engine refused never claims private blocking.
        fake.failure = BlockerFailure()
        coordinator.setPrivateException(host: "x.example.test", allowed: true)
        await coordinator.synchronizePrivate()
        #expect(!coordinator.blocksPrivately)
    }

    @Test("Private windows show the same site row, backed by the private session")
    func privateSiteRow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = BlockingHost(url: "https://news.example.test/article")
        let controls = BrowserSiteControls(owner: host)
        let fake = BrowserFakeContentBlocking()
        var parentEnabled = true
        let parent = ProfileID()
        let coordinator = BrowserContentBlockingCoordinator(blocker: fake, isEnabled: { _ in parentEnabled },
            exceptions: { $0 == parent ? ["kept.example.test"] : [] })
        controls.privateContentBlocking = coordinator
        let surface = try #require(host.siteControlSurface)
        func row() async throws -> ControlCenterSettingButton? {
            host.rows = []; controls.render(); controls.show()
            try await waitForNativeState("site controls presented") { !host.rows.isEmpty }
            return host.rows.flatMap { settingButtons($0) }.first { $0.accessibilityIdentifier() == "site-content-blocking" }
        }
        // No open private window registered: no private blocking, no row.
        #expect(try await row() == nil)
        await coordinator.openPrivateWindow(UUID(), parent: parent)
        let blocked = try #require(try await row())
        #expect(blocked.accessibilityLabel() == uiText("Ads & Trackers") + ", " + uiText("Blocked") && blocked.isEnabled)
        let generation = surface.findDocumentGeneration
        blocked.performClick(nil)
        try await waitForNativeState("private exception applied and page reloaded") {
            fake.privateConfiguration == .init(isEnabled: true, allowedHosts: ["kept.example.test", "news.example.test"])
                && surface.findDocumentGeneration > generation
        }
        // Nothing reached the window's site preferences or the persistent configuration.
        #expect(controls.preferences.contentBlockingExceptions(profileID: surface.profileID).isEmpty && fake.configurations.isEmpty)
        #expect(try await row()?.accessibilityLabel() == uiText("Ads & Trackers") + ", " + uiText("Allowed"))
        // The parent's switch off hides the row, as in normal windows.
        parentEnabled = false
        await coordinator.synchronizePrepared()
        #expect(try await row() == nil)
        // A parent's persistent exception shows as allowed and is read-only.
        parentEnabled = true
        await coordinator.synchronizePrivate()
        surface.navigate(to: URL(string: "https://kept.example.test/")!)
        try await waitForNativeState("navigated") { surface.currentURL?.host == "kept.example.test" }
        let kept = try #require(try await row())
        #expect(kept.accessibilityLabel() == uiText("Ads & Trackers") + ", " + uiText("Allowed") && !kept.isEnabled)
    }

    @Test("Startup prepares visible profiles with blocking on, and the Settings switch turns it off")
    func environmentDefaults() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: "/private/tmp/Orbit-ContentBlocking-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionFile = directory.appendingPathComponent("session.json")
        let source = BrowserStore()
        let profile = await source.createProfile(name: "Synthetic")
        let space = try await source.createSpace(name: "Synthetic", profileID: profile)
        let windowID = try await source.createWindow(activeSpaceID: space)
        let context = try await source.captureContext(in: windowID)
        _ = try await source.openTab(url: URL(string: "https://example.test")!, from: context, activate: true)
        try BrowserSessionFileStore().save(await source.sessionDocument(), to: sessionFile)
        let engine = SiteSyntheticEngine()
        let fake = BrowserFakeContentBlocking()
        engine.contentBlocking = fake
        let environment = try await BrowserEnvironment.open(engine: engine, sessionFile: sessionFile)
        #expect(fake.configurations[profile] == .init(isEnabled: true))
        let window = try await environment.makeWindow(id: windowID.rawValue)
        defer { window.window?.close() }
        #expect(window.siteControls.contentBlocking === environment.contentBlocking)
        // No private window yet: launch only readies private filtering.
        try await waitForNativeState("private filtering readied") { fake.preparedPrivateWindows == 1 }
        #expect(fake.privateConfiguration == nil)
        try await environment.settings.updateProfile(profile) { $0.blocksAdsAndTrackers = false }
        try await waitForNativeState("Settings switch applied") { fake.configurations[profile] == .init(isEnabled: false) }
        try await environment.finalize()
    }
}
}
