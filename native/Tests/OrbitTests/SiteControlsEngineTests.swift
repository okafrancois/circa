import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
import WebKit
import WebKitEngine
@testable import Orbit

/// Only the expected domain error permits the scenario to continue on the same store.
/// A deadline or cancellation must escape before another operation can be issued.
@MainActor
private func requireSiteDataScopeChange(_ operation: @MainActor () async throws -> Void) async throws {
    var didReject = false
    do {
        try await operation()
    } catch BrowserSiteDataError.scopeChanged {
        didReject = true
    }
    try #require(didReject, "Changing site data scope must reject the operation")
}

extension NativeWebKitTests {
@Suite("Site controls engine integration", .serialized)
@MainActor
struct SiteControlsEngineTests {
    @Test("An explicit notification Allow registers the app before completing the site request",
          arguments: [true, false])
    func notificationAuthorizationTrigger(osAllows: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://example.test")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        var authorizations = 0
        window.siteControls.authorizeNotifications = {
            authorizations += 1
            #expect(await window.siteControls.policy.store.setting(for: .notifications,
                origin: origin, profileID: surface.profileID) == .allow)
            return osAllows
        }
        window.siteControls.permissionPrompt = { _, _ in .alwaysAllow }
        #expect(authorizations == 0)
        let request = BrowserPermissionRequest(kind: .notifications, origin: origin.value, isMainFrame: true)
        #expect(await surface.requestPermission(request) == .grant)
        #expect(authorizations == 1)
        // Cached grants don't cause another shell authorization or change the web grant.
        #expect(await surface.requestPermission(request) == .grant)
        #expect(authorizations == 1)
        #expect(await surface.requestPermission(BrowserPermissionRequest(kind: .camera,
            origin: origin.value, isMainFrame: true)) == .grant)
        #expect(authorizations == 1)
        #expect(!window.window!.isVisible)
    }

    @Test("Refused and stale notification choices never ask macOS", arguments: ["block", "dismiss", "stale"])
    func notificationAuthorizationExcluded(choice: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://example.test")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        var authorizations = 0
        window.siteControls.authorizeNotifications = { authorizations += 1; return true }
        window.siteControls.permissionPrompt = { _, _ in
            if choice == "stale" { surface.reload(); return .alwaysAllow }
            return choice == "block" ? .block : .dismiss
        }
        #expect(await surface.requestPermission(BrowserPermissionRequest(kind: .notifications,
            origin: "https://example.test", isMainFrame: true)) == .deny)
        #expect(authorizations == 0)
        #expect(!window.window!.isVisible)
    }

    @Test("Synthetic engine requests use the owning profile and never fall through to an engine prompt")
    func syntheticEngineDecisions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://example.test")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        let request = BrowserPermissionRequest(kind: .camera, origin: origin.value, isMainFrame: true)
        // Hidden windows do not show permission UI or invoke system services.
        #expect(await surface.requestPermission(request) == .deny)
        try await window.siteControls.policy.store.set(.allow, for: [.camera], origin: origin, profileID: surface.profileID)
        #expect(await surface.requestPermission(request) == .grant)
        #expect(await surface.requestPermission(BrowserPermissionRequest(kind: .cameraAndMicrophone, origin: origin.value, isMainFrame: true)) == .deny)
        try await window.siteControls.policy.store.set(.block, for: [.camera], origin: origin, profileID: surface.profileID)
        #expect(await surface.requestPermission(request) == .deny)
        let foreign = environment.engine.makeSurface(profileID: ProfileID(), delegate: window)
        defer { foreign.dispose() }
        #expect(await foreign.requestPermission(request) == .deny)
        #expect(await surface.requestPermission(BrowserPermissionRequest(kind: .camera, origin: "https://other.test", isMainFrame: true)) == .deny)
        window.session.close()
        #expect(await surface.requestPermission(request) == .deny)
    }

    @Test("Synthetic pending permission cannot survive selection ABA navigation or closure",
          arguments: ["selection", "navigation", "closure"])
    func pendingContextInvalidation(action: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://example.test")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let occurrence = try #require(window.session.snapshot?.selectedOccurrenceID)
        let origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        var continuation: CheckedContinuation<BrowserSitePermissionChoice, Never>?
        window.siteControls.permissionPrompt = { _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        let task = Task { await surface.requestPermission(BrowserPermissionRequest(kind: .camera, origin: origin.value, isMainFrame: true)) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let response = try #require(continuation)
        switch action {
        case "selection":
            window.openTab(url: URL(string: "https://other.test")!)
            await window.session.waitForPendingCommands()
            window.session.selectOccurrence(occurrence)
            await window.session.waitForPendingCommands()
            #expect(window.session.selectedSurface === surface)
        case "navigation":
            surface.reload()
        default:
            window.session.close()
        }
        response.resume(returning: .alwaysAllow)
        #expect(await task.value == .deny)
        #expect(await window.siteControls.policy.store.setting(for: .camera, origin: origin, profileID: surface.profileID) == .ask)
        #expect(window.window?.isVisible == false)
    }

    @Test("Corrupt or future permission files preserve a healthy restored tab session",
          arguments: ["not json", "{\"version\":99,\"entries\":[]}"])
    func degradedRestoration(raw: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: "/private/tmp/Orbit-SITE-Restore-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionFile = directory.appendingPathComponent("session.json")
        let source = BrowserStore()
        let profile = await source.createProfile(name: "Synthetic")
        let space = try await source.createSpace(name: "Synthetic", profileID: profile)
        let windowID = try await source.createWindow(activeSpaceID: space)
        let context = try await source.captureContext(in: windowID)
        let tab = try await source.openTab(url: URL(string: "https://example.test")!, from: context, activate: true)
        try BrowserSessionFileStore().save(await source.sessionDocument(), to: sessionFile)
        let permissionsFile = sessionFile.appendingPathExtension("site-permissions.json")
        try Data(raw.utf8).write(to: permissionsFile)
        let environment = try await BrowserEnvironment.open(engine: SiteSyntheticEngine(), sessionFile: sessionFile)
        #expect(environment.restoredWindowIDs == [windowID])
        let window = try await environment.makeWindow(id: windowID.rawValue)
        #expect(window.session.snapshot?.selectedOccurrenceID == tab)
        #expect(window.session.selectedSurface?.profileID == profile)
        #expect(window.siteControls.permissionsUnavailable)
        let surface = try #require(window.session.selectedSurface)
        #expect(await surface.requestPermission(BrowserPermissionRequest(kind: .camera, origin: "https://example.test", isMainFrame: true)) == .deny)
        #expect(try String(contentsOf: permissionsFile, encoding: .utf8) == raw)
        #expect(!window.window!.isVisible)
        window.window?.close()
        try await environment.finalize()
    }

    @Test("Failed block ask and reset actions still revoke synthetic capture and clear errors after retry",
          arguments: ["block", "ask", "reset"])
    func failedRevocation(action: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: "/private/tmp/Orbit-SITE-Revoke-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("permissions.json")
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://example.test")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        let store = try BrowserSitePermissionStore(destination: destination)
        window.siteControls.policy.store = store
        try await store.set(.allow, for: [.camera], origin: origin, profileID: surface.profileID)
        surface.media.camera = .active
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        if action == "reset" {
            await window.siteControls.resetPermissions(origin: origin, surface: surface, valid: { true })
        } else {
            await window.siteControls.changePermission(action == "block" ? .block : .ask, permission: .camera,
                origin: origin, surface: surface, valid: { true })
        }
        #expect(environment.engine.revocations == 1)
        #expect(surface.media.camera == .none)
        #expect(window.siteControls.statusMessage?.contains("session") == true)
        #expect(await store.setting(for: .camera, origin: origin, profileID: surface.profileID) != .allow)
        try FileManager.default.removeItem(at: destination)
        await window.siteControls.changePermission(.block, permission: .camera, origin: origin, surface: surface, valid: { true })
        #expect(window.siteControls.statusMessage == nil)
        #expect(!window.window!.isVisible)
    }

    @Test("SITE command is registered in CMD and rejects a captured target after navigation")
    func siteCommandRegistry() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { controller, action in controller.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry)
        #expect(!registry.isEnabled(.showSiteControls))
        let id = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let window = try #require(router.windows[id])
        await window.session.waitForPendingCommands()
        #expect(registry.isImplemented(.showSiteControls))
        #expect(registry.isEnabled(.showSiteControls))
        // Like Site Controls is reached from the URL pill and context menus, not the View menu.
        let bar = BrowserCommandMenus(registry: registry).makeMenuBar()
        let viewMenu = bar.items.first { $0.title == "View" }?.submenu
        #expect(viewMenu?.items.contains { $0.identifier?.rawValue == BrowserCommandID.showSiteControls.rawValue } != true)
        let target = try #require(registry.captureTarget())
        #expect(registry.dispatch(.showSiteControls, origin: .contextMenu, target: target))
        await router.waitForPendingCommands()
        await window.session.waitForPendingCommands()
        window.submitAddress("https://other.test")
        await window.session.waitForPendingCommands()
        #expect(!registry.dispatch(.showSiteControls, origin: .contextMenu, target: target))
        #expect(window.window?.isVisible == false)
    }

    @Test("A live transfer invalidates the source permission request and binds the destination delegate")
    func transferredPermissionOwner() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let first = try await environment.makeWindow()
        let second = try await environment.makeWindow()
        defer { first.window?.close(); second.window?.close() }
        first.submitAddress("https://example.test")
        await first.session.waitForPendingCommands()
        let surface = try #require(first.session.selectedSurface)
        let origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        let request = BrowserPermissionRequest(kind: .camera, origin: origin.value, isMainFrame: true)
        var continuation: CheckedContinuation<BrowserSitePermissionChoice, Never>?
        first.siteControls.permissionPrompt = { _, _ in await withCheckedContinuation { continuation = $0 } }
        let pending = Task { await surface.requestPermission(request) }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let response = try #require(continuation)
        let transfer = first.moveSurface(surface, to: second)
        _ = await transfer?.value
        await first.session.waitForPendingCommands()
        await second.session.waitForPendingCommands()
        response.resume(returning: .alwaysAllow)
        #expect(await pending.value == .deny)
        #expect(!first.owns(surface))
        #expect(second.session.selectedSurface === surface)
        #expect(await second.siteControls.policy.store.setting(for: .camera, origin: origin, profileID: surface.profileID) == .ask)
        try await second.siteControls.policy.store.set(.allow, for: [.camera], origin: origin, profileID: surface.profileID)
        #expect(await surface.requestPermission(request) == .grant)
        #expect(surface.focusDocument())
        #expect(second.window?.firstResponder === surface.documentView)
        #expect(!first.window!.isVisible && !second.window!.isVisible)
    }

    @Test("Audio hook reports engine state with no fabricated audibility and muting preserves selection")
    func syntheticMediaState() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        let surface = try #require(window.session.selectedSurface)
        var states: [BrowserMediaState] = []
        window.siteControls.onMediaStateChange = { _, state in states.append(state) }
        window.siteControls.refreshMedia(surface)
        for _ in 0..<30 where states.isEmpty { await Task.yield() }
        #expect(states.last?.playback == .playing)
        #expect(states.last?.isAudible == true)
        let selection = window.session.snapshot?.selectedOccurrenceID
        try surface.setAudioMuted(true)
        window.siteControls.refreshMedia(surface)
        for _ in 0..<30 where states.last?.isAudioMuted != true { await Task.yield() }
        #expect(states.last?.isAudioMuted == true)
        #expect(window.session.snapshot?.selectedOccurrenceID == selection)
        #expect(window.window?.isVisible == false)
    }

    @Test("WebKit site deletion removes domain records only in the captured profile")
    func siteDataIsolation() async throws {
        let engine = WebKitBrowserEngine()
        let first = ProfileID(), second = ProfileID()
        let one = BrowserSiteOrigin(requestOrigin: "https://one.test")!
        let two = BrowserSiteOrigin(requestOrigin: "https://two.test")!
        func cookie(_ domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: "synthetic", .value: "fixture", .secure: "TRUE"])!
        }
        func setCookie(_ domain: String, profile: ProfileID) async throws {
            let store = engine.websiteDataStore(for: profile)
            try await withNativeTestDeadline("set synthetic profile cookie",
                observed: { nativeWebKitNetworkingState(store) }
            ) { await store.httpCookieStore.setCookie(cookie(domain)) }
        }
        func summary(_ origin: BrowserSiteOrigin, profile: ProfileID) async throws -> BrowserSiteDataSummary {
            try await withNativeTestDeadline("read synthetic profile site data",
                observed: { nativeWebKitNetworkingState(engine.websiteDataStore(for: profile)) }
            ) { await engine.siteData(origin: origin, profileID: profile) }
        }
        try await setCookie("one.test", profile: first)
        try await setCookie("two.test", profile: first)
        try await setCookie("one.test", profile: second)
        let before = try await summary(one, profile: first)
        #expect(before.recordCount > 0)
        try await requireSiteDataScopeChange {
            try await withNativeTestDeadline("reject changed synthetic site data scope") {
                try await engine.clearSiteData(origin: one, profileID: first, expectedDomains: [])
            }
        }
        try await withNativeTestDeadline("clear captured synthetic profile domain",
            observed: { nativeWebKitNetworkingState(engine.websiteDataStore(for: first)) }
        ) { try await engine.clearSiteData(origin: one, profileID: first, expectedDomains: before.domains) }
        #expect(try await summary(one, profile: first).recordCount == 0)
        #expect(try await summary(two, profile: first).recordCount > 0)
        #expect(try await summary(one, profile: second).recordCount > 0)
        try await withNativeTestDeadline("clear synthetic profile data",
            observed: { nativeWebKitNetworkingState(engine.websiteDataStore(for: first)) }
        ) { try await engine.clearSiteData(profileID: first) }
        #expect(try await summary(two, profile: first).recordCount == 0)
        #expect(try await summary(one, profile: second).recordCount > 0)
    }

    @Test("A timed-out scope rejection stops before sending another site-data operation")
    func scopeRejectionTimeoutStopsScenario() async throws {
        var operationsSent = 0
        var callback: CheckedContinuation<Void, Never>?
        var lateOperationReturned = false
        var now = ContinuousClock.now
        var timeoutCallback: NativeTestDeadlineTiming.Callback?
        let timing = NativeTestDeadlineTiming(now: { now }, schedule: { seconds, callback in
            #expect(seconds == 0.04)
            timeoutCallback = callback
            return {}
        })
        func clearSyntheticSiteData() async {
            operationsSent += 1
            if operationsSent == 1 {
                await withCheckedContinuation { callback = $0 }
                lateOperationReturned = true
            }
        }
        func scenario() async throws {
            try await requireSiteDataScopeChange {
                try await withNativeTestDeadline("pending synthetic scope rejection", timeout: 0.04, timing: timing) {
                    await clearSyntheticSiteData()
                    throw BrowserSiteDataError.scopeChanged
                }
            }
            await clearSyntheticSiteData()
        }
        let task = Task { @MainActor in try await scenario() }
        try await waitForNativeState("synthetic scope operation installed before timeout", timeout: 2) {
            callback != nil && timeoutCallback != nil
        }
        now += .milliseconds(41)
        let expire = try #require(timeoutCallback)
        timeoutCallback = nil
        expire()
        do {
            try await withNativeTestDeadline("expired scope scenario returns", timeout: 2) {
                try await task.value
            }
            Issue.record("A timed-out rejection must abort the site-data scenario")
        } catch is NativeTestWaitTimeout {}
        #expect(operationsSent == 1)
        let lateCallback = try #require(callback)
        callback = nil
        lateCallback.resume()
        try await waitForNativeState("late synthetic scope rejection drained", timeout: 2) {
            lateOperationReturned
        }
        #expect(operationsSent == 1)
    }
}

}
