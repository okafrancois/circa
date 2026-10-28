import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import BrowserShell
import Darwin
import Testing
import SwiftUI
@testable import Orbit

/// Delegates documents to the shared synthetic engine and records the optional SITE service
/// calls. This proves settings orchestration, not actual engine cookie deletion.
@MainActor
private final class SettingsFixtureEngine: BrowserEngine, BrowserSiteDataAccess, BrowserSitePermissionAvailability {
    let backing = SyntheticEngine()
    var reportedKind: BrowserEngineKind = .synthetic
    var kind: BrowserEngineKind { reportedKind }
    var reportsProfileRemoval = true
    var capabilities: BrowserEngineCapabilities {
        var result = backing.capabilities
        if !reportsProfileRemoval { result.remove(.profileRemoval) }
        return result
    }
    var extensions: (any BrowserExtensionHost)? { nil }
    var settingsExtensionManager: (any BrowserExtensionManagement)?
    var extensionManagement: (any BrowserExtensionManagement)? { settingsExtensionManager }
    let supportedSitePermissions: Set<BrowserSitePermission> = [.camera, .microphone]
    var revocations: [(ProfileID, BrowserSiteOrigin, BrowserSitePermission?)] = []
    var clearedProfiles: [ProfileID] = []
    var clearedSites: [(ProfileID, BrowserSiteOrigin)] = []
    var domains = ["settings.test"]
    func profile(for id: ProfileID) -> BrowserEngineProfile { backing.profile(for: id) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<SyntheticSurface>) -> SyntheticSurface {
        backing.makeSurface(profileID: profileID, delegate: delegate)
    }
    var beforeProfileRemoval: ((ProfileID) async throws -> Void)?
    func removeProfile(_ profileID: ProfileID) async throws {
        try await beforeProfileRemoval?(profileID)
        try await backing.removeProfile(profileID)
        clearedProfiles.append(profileID)
    }
    func shutdown() async { await backing.shutdown() }
    func siteData(origin: BrowserSiteOrigin, profileID: ProfileID) async -> BrowserSiteDataSummary { .init(domains: domains, recordCount: 1) }
    func clearSiteData(origin: BrowserSiteOrigin, profileID: ProfileID, expectedDomains: [String]) async throws {
        guard expectedDomains == domains else { throw BrowserSiteDataError.scopeChanged }
        clearedSites.append((profileID, origin))
    }
    func clearSiteData(profileID: ProfileID) async throws { clearedProfiles.append(profileID) }
    func revokeSitePermission(_ permission: BrowserSitePermission?, origin: BrowserSiteOrigin, profileID: ProfileID) async {
        revocations.append((profileID, origin, permission))
    }
}

@MainActor
private func settingsModel(_ environment: BrowserEnvironment<SettingsFixtureEngine>, profile: ProfileID? = nil) -> BrowserSettingsModel<SettingsFixtureEngine> {
    BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: OrbitCommandCatalog.definitions,
                         defaultBrowser: .init(status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") },
                                               canRequest: { false }, request: { Issue.record("Unexpected default-browser request") }))
}

extension NativeWebKitTests {
@Suite("Native settings store effects", .serialized)
@MainActor
struct NativeSettingsTests {
    @Test("Search and separate Peek preferences apply live to the captured profile and after Space switches")
    func liveProfileEffects() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let first = try #require(controller.session.activeProfileID)
        let model = settingsModel(environment, profile: first)
        try await model.createProfileWithSpace(name: "Synthetic Second")
        let second = try #require(model.selectedProfileID)
        await model.reload()
        let secondSpace = try #require(model.catalog.spaces.first { $0.profileID == second })
        try await model.updateProfile(first) {
            $0.searchEngine = .duckDuckGo
            $0.opensPinnedLinksInPeek = false
            $0.shiftClickOpensPeek = false
        }
        #expect(try controller.addressResolver.resolve("test query").url.host == "duckduckgo.com")
        #expect(!controller.peek.settings.opensPinnedLinksInPeek && !controller.peek.settings.shiftClickOpensPeek)
        controller.session.activateSpace(secondSpace.id)
        await controller.session.waitForPendingCommands()
        #expect(controller.addressResolver.searchEngine == .google)
        #expect(controller.peek.settings.opensPinnedLinksInPeek && controller.peek.settings.shiftClickOpensPeek)
        try await model.updateProfile(first) { $0.searchEngine = .bing }
        #expect(controller.addressResolver.searchEngine == .google)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Auto archive options reach the existing policy, including inheritance and profile isolation")
    func archiveEffects() async throws {
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Archive One")
        let first = try #require(model.selectedProfileID)
        try await model.createProfileWithSpace(name: "Archive Two")
        let second = try #require(model.selectedProfileID)
        try await model.setArchiveThreshold(.never, profile: first)
        #expect(await environment.store.archivePolicy().threshold(for: first) == .never)
        #expect(await environment.store.archivePolicy().profileThresholds[second] == nil)
        try await model.setArchiveThreshold(.sevenDays, profile: first)
        #expect(await environment.store.archivePolicy().threshold(for: first) == .sevenDays)
        try await model.setArchiveThreshold(nil, profile: first)
        #expect(await environment.store.archivePolicy().profileThresholds[first] == nil)
    }

    @Test("Palette icon and motion changes reach the theme and accessibility paths without showing a window")
    func themeEffects() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let previousMotion = OrbitMotionPreferences.overrideReducedMotion
        defer { OrbitMotionPreferences.overrideReducedMotion = previousMotion }
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        let model = settingsModel(environment)
        try await model.updateSpace(space) { $0.palette = .rosePlum; $0.icon = "🧪" }
        #expect(controller.windowShell.theme == .rosePlum)
        #expect(controller.sidebar.footer.spaceButtons.first { $0.space.id == space }?.settingsIcon == "🧪")
        try await model.setReducedMotion(.reduce)
        #expect(OrbitMotionPreferences.prefersReducedMotion)
        try await model.setReducedMotion(.full)
        #expect(!OrbitMotionPreferences.prefersReducedMotion)
        try await model.setReducedMotion(.system)
        #expect(OrbitMotionPreferences.overrideReducedMotion == nil)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Permission edits update SITE authority and revoke active grants only for the captured profile")
    func permissionEffects() async throws {
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Permissions One")
        let first = try #require(model.selectedProfileID)
        try await model.createProfileWithSpace(name: "Permissions Two")
        let second = try #require(model.selectedProfileID)
        let origin = try #require(BrowserSiteOrigin(requestOrigin: "https://settings.test"))
        try await environment.changeSettingsPermission(.allow, permission: .camera, origin: origin, profile: first)
        let row = BrowserSettingsPermissionRow(origin: origin, permission: .camera, setting: .allow)
        try await model.changePermission(row, setting: .block, profile: first)
        #expect(await environment.settingsPermissions(origin: origin, profile: first)[.camera] == .block)
        #expect(await environment.settingsPermissions(origin: origin, profile: second)[.camera] == .ask)
        #expect(environment.engine.revocations.count == 1 && environment.engine.revocations[0].0 == first)
        await #expect(throws: BrowserSettingsServiceError.self) {
            try await model.changePermission(.init(origin: origin, permission: .usb, setting: .ask), setting: .allow, profile: first)
        }
        model.selectProfile(first)
        await model.waitForPendingActions()
        #expect(model.permissionRows.contains { $0.origin == origin && $0.permission == .camera && $0.setting == .block })
    }

    @Test("Site cleanup confirmations retain their profile and reject a changed domain scope")
    func siteDataEffects() async throws {
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Data One")
        let first = try #require(model.selectedProfileID)
        await model.reload()
        let origin = try #require(BrowserSiteOrigin(requestOrigin: "https://settings.test"))
        try await model.reviewSiteData(origin: origin, profile: first)
        let request = try #require(model.siteDataRequest)
        try await model.createProfileWithSpace(name: "Data Two")
        try await model.clearSiteData(request)
        #expect(environment.engine.clearedSites.count == 1 && environment.engine.clearedSites[0].0 == first)
        environment.engine.domains = ["different.test"]
        await #expect(throws: BrowserSiteDataError.self) { try await model.clearSiteData(request) }
        #expect(environment.engine.clearedSites.count == 1)
        try await model.clearSiteData(profile: first)
        #expect(environment.engine.clearedProfiles == [first])
    }

    @Test("Removing an unused profile cleans history permissions settings and SITE while preserving the other profile")
    func profileCleanup() async throws {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true).appendingPathComponent("Orbit-SETTINGS-History-" + UUID().uuidString)
        free(canonical)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = BrowserHistoryRecorder(directory: root, resolveProfile: { .init(profileID: $0, persistence: .persistent) })
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine(), history: history)
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Cleanup One")
        let first = try #require(model.selectedProfileID)
        try await model.createProfileWithSpace(name: "Cleanup Two")
        let second = try #require(model.selectedProfileID)
        let origin = try #require(BrowserSiteOrigin(requestOrigin: "https://settings.test"))
        for profile in [first, second] {
            _ = try await history.importDocument(.init(profileID: profile, visits: [.init(url: URL(string: "https://settings.test/history")!)]))
            try await environment.changeSettingsPermission(.allow, permission: .camera, origin: origin, profile: profile)
            try await model.updateProfile(profile) { $0.searchEngine = .bing }
        }
        for space in await environment.store.catalogSnapshot().spaces where space.profileID == first { try await model.deleteSpace(space.id) }
        try await model.deleteProfile(first)
        #expect(await environment.store.catalogSnapshot().profiles.contains { $0.id == second })
        #expect(!(await environment.store.catalogSnapshot().profiles.contains { $0.id == first }))
        #expect(await environment.settingsPermissionOrigins(profile: first).isEmpty)
        #expect(await environment.settingsPermissionOrigins(profile: second) == [origin])
        #expect(environment.engine.clearedProfiles == [first])
        #expect(environment.settings.document.profiles[first] == nil)
        #expect(environment.settings.document.profile(second).searchEngine == .bing)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(first.rawValue.uuidString).path))
        #expect(try await history.visits(for: second).count == 1)
        try await history.close()
    }

    @Test("Queued edits keep their original profile when Settings changes selection")
    func queuedProfileCapture() async throws {
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Queue One")
        let first = try #require(model.selectedProfileID)
        try await model.createProfileWithSpace(name: "Queue Two")
        let second = try #require(model.selectedProfileID)
        model.perform { try await model.updateProfile(first) { $0.searchEngine = .duckDuckGo } }
        model.selectProfile(second)
        model.perform { try await model.updateProfile(first) { $0.shiftClickOpensPeek = false } }
        await model.waitForPendingActions()
        #expect(environment.settings.document.profile(first).searchEngine == .duckDuckGo)
        #expect(!environment.settings.document.profile(first).shiftClickOpensPeek)
        #expect(environment.settings.document.profile(second) == .init())
        #expect(model.selectedProfileID == second && !model.isBusy && model.errorMessage == nil)
    }

    @Test("A restored environment reapplies durable settings to a new hidden window")
    func environmentRestoration() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let savedMotion = OrbitMotionPreferences.overrideReducedMotion
        defer { OrbitMotionPreferences.overrideReducedMotion = savedMotion }
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true).appendingPathComponent("Orbit-SETTINGS-Restore-" + UUID().uuidString)
        free(canonical)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json")
        let environment = try await BrowserEnvironment.open(engine: SettingsFixtureEngine(), sessionFile: file)
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Restored Settings")
        let profile = try #require(model.selectedProfileID)
        let space = try #require(await environment.store.catalogSnapshot().spaces.first { $0.profileID == profile }?.id)
        try await model.updateProfile(profile) { $0.searchEngine = .bing; $0.shiftClickOpensPeek = false }
        try await model.updateSpace(space) { $0.palette = .lavender; $0.icon = "🧪" }
        try await model.setArchiveThreshold(.never, profile: profile)
        try await model.setReducedMotion(.reduce)
        try await environment.finalize()
        let restored = try await BrowserEnvironment.open(engine: SettingsFixtureEngine(), sessionFile: file)
        let window = try await restored.makeWindow(spaceID: space)
        defer { restored.autoArchive.scheduler.stop(); window.window?.close() }
        #expect(window.addressResolver.searchEngine == .bing)
        #expect(!window.peek.settings.shiftClickOpensPeek)
        #expect(window.windowShell.theme == .lavender)
        #expect(OrbitMotionPreferences.prefersReducedMotion)
        #expect(await restored.store.archivePolicy().threshold(for: profile) == .never)
        #expect(window.window?.isVisible == false)
        try await restored.finalize()
    }

    @Test("Termination stops new settings actions and a cancelled quit preserves accepted work")
    func settingsTermination() async throws {
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let model = settingsModel(environment)
        var release = false
        var completed = false
        model.perform {
            while !release { await Task.yield() }
            completed = true
        }
        await #expect(throws: BrowserTerminationPreparationError.commandsDidNotSettle) {
            try await model.suspendForTermination(timeout: .zero)
        }
        #expect(!model.acceptsActions)
        var unexpected = false
        model.perform { unexpected = true }
        release = true
        model.resumeAfterCancelledTermination()
        await model.waitForPendingActions()
        #expect(completed && !unexpected && model.acceptsActions)
        try await model.suspendForTermination(timeout: .seconds(1))
        #expect(!model.acceptsActions)
    }

    @Test("Command-W closes only the hidden Settings window through its native key-equivalent path")
    func settingsCloseShortcut() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = BrowserSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        final class Delegate: NSObject, NSWindowDelegate {
            var closed = false
            func windowWillClose(_ notification: Notification) { closed = true }
        }
        let delegate = Delegate()
        window.delegate = delegate
        defer { window.close() }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(window.performKeyEquivalent(with: event))
        #expect(delegate.closed && !window.isVisible)
    }

    @Test("Shortcuts come from the registry and default-browser mutation is explicit and injectable")
    func commandAndDefaultBrowser() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in Issue.record("Unexpected window presentation") })
        #expect(app.commands.registry.isImplemented(.preferences))
        #expect(app.commands.registry.isEnabled(.preferences))
        #expect(app.commands.registry.definition(.preferences)?.shortcuts.contains(.init(key: ",", modifiers: .command)) == true)
        let synthetic = BrowserEnvironment(engine: SettingsFixtureEngine())
        var requests = 0
        let model = BrowserSettingsModel(environment: synthetic, profileID: nil, shortcuts: app.commands.registry.definitions,
            defaultBrowser: .init(status: { .init(http: "io.github.okatech.orbit", https: "io.github.okatech.orbit", html: "other") },
                                  canRequest: { true }, request: { requests += 1 }))
        try await model.createProfileWithSpace(name: "Default Synthetic")
        await model.reload()
        #expect(requests == 0 && model.defaultStatus?.isOrbit == false)
        #expect(!model.canRequestDefaultBrowser) // Synthetic and WebKit builds cannot request associations.
        #expect(model.shortcuts.contains { $0.id == .preferences })
        #expect(model.shortcuts.count == app.commands.registry.definitions.count)
        synthetic.engine.reportedKind = .chromium
        model.perform { try await model.requestDefaultBrowser() }
        await model.waitForPendingActions()
        #expect(requests == 1 && app.settingsWindow == nil)
    }
}
}

extension NativeWebKitTests.NativeSettingsTests {
    @Test("Corrupt and version-two Settings preserve the complete environment and refuse writes", arguments: ["broken settings", #"{"version":2}"#])
    func unavailableSettingsEnvironment(raw: String) async throws {
        let root = settingsR2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session.json")
        let source = BrowserStore()
        let profile = try await source.createSettingsFixtureProfileWithSpace(name: "Healthy Synthetic Session")
        let space = try #require(await source.catalogSnapshot().spaces.first?.id)
        let window = try await source.createWindow(activeSpaceID: space)
        _ = try await source.openTab(url: URL(string: "about:blank#preserved")!, from: source.captureContext(in: window), activate: true)
        let saved = await source.sessionDocument()
        try BrowserSessionFileStore().save(saved, to: session)
        let file = session.appendingPathExtension("settings.json")
        let original = Data(raw.utf8)
        try original.write(to: file)
        let environment = try await BrowserEnvironment.open(engine: SettingsFixtureEngine(), sessionFile: session)
        #expect(await environment.store.sessionDocument() == saved)
        #expect(environment.restoredWindowIDs == [window])
        #expect(environment.settings.isUnavailable)
        let model = settingsModel(environment, profile: profile)
        await model.reload()
        #expect(environment.engine.capabilities.contains(.profileRemoval))
        #expect(!model.supportsProfileRemoval && model.runtime === environment.settings)
        #expect(model.profileRemovalUnavailableReason == "Saved settings are unavailable. The existing file is kept and changes cannot be saved.")
        #expect(environment.settings.document.profile(profile) == BrowserProfileSettings())
        await #expect(throws: BrowserSettingsError.unavailable) {
            try await environment.settings.store.setReducedMotion(.reduce)
        }
        #expect(try Data(contentsOf: file) == original)
        try await environment.finalize()
        #expect(try Data(contentsOf: file) == original)

        let unavailableEnvironment = try await BrowserEnvironment.open(engine: SettingsFixtureEngine(), sessionFile: session)
        let unavailableModel = settingsModel(unavailableEnvironment, profile: profile)
        await unavailableModel.reload()
        let encoder = JSONEncoder()
        try encoder.encode(BrowserSettingsDocument()).write(to: file, options: .atomic)
        #expect(try !BrowserSettingsStore(destination: file).isUnavailable)
        await unavailableModel.runtime.refresh()
        await unavailableModel.reload()
        let reopenedSettings = settingsModel(unavailableEnvironment, profile: profile)
        await reopenedSettings.reload()
        #expect(!unavailableModel.supportsProfileRemoval && !reopenedSettings.supportsProfileRemoval)
        #expect(reopenedSettings.runtime === unavailableModel.runtime)
        try await unavailableEnvironment.finalize()
        let reopenedEnvironment = try await BrowserEnvironment.open(engine: SettingsFixtureEngine(), sessionFile: session)
        let repairedModel = settingsModel(reopenedEnvironment, profile: profile)
        await repairedModel.reload()
        #expect(!repairedModel.runtime.isUnavailable && repairedModel.supportsProfileRemoval)
        try await reopenedEnvironment.finalize()
    }

    @Test("Profile cleanup cannot race a Space switch or window creation while awaiting the engine")
    func profileRemovalRace() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SettingsFixtureEngine()
        let environment = BrowserEnvironment(engine: engine)
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Race Removed")
        let removed = try #require(model.selectedProfileID)
        let space = try #require(await environment.store.catalogSnapshot().spaces.first { $0.profileID == removed }?.id)
        try await model.createProfileWithSpace(name: "Race Preserved")
        let kept = try #require(model.selectedProfileID)
        let other = try #require(await environment.store.catalogSnapshot().spaces.first { $0.profileID == kept }?.id)
        let controller = try await environment.makeWindow(spaceID: other)
        defer { environment.autoArchive.scheduler.stop(); controller.window?.close() }
        var started = false, release = false
        engine.beforeProfileRemoval = { id in
            #expect(id == removed)
            started = true
            while !release { await Task.yield() }
        }
        try await model.deleteSpace(space)
        let removal = Task { try await model.deleteProfile(removed) }
        try await withNativeTestDeadline("profile cleanup reaches the suspended engine step", timeout: 5) {
            while !started { await Task.yield() }
        }
        #expect(await environment.store.isSettingsProfileBeingRemoved(removed))
        #expect(!(await environment.store.catalogSnapshot().profiles.contains { $0.id == removed }))
        await #expect(throws: BrowserStoreError.spaceMissing) { try await environment.store.createWindow(activeSpaceID: space) }
        await #expect(throws: BrowserStoreError.spaceMissing) { try await environment.store.activateSpace(space, in: controller.session.snapshot!.id) }
        await #expect(throws: BrowserStoreError.profileMissing) { try await environment.store.createSpace(name: "Forbidden", profileID: removed) }
        release = true
        try await removal.value
        #expect(await environment.settingsProfileRemovals.pending().isEmpty)
        #expect(controller.session.activeProfileID == kept && controller.window?.isVisible == false)
    }

    @Test("A history I/O failure leaves a retired profile retryable and lifts its history tombstone")
    func removalIOFailureAndRetry() async throws {
        let root = settingsR2TemporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let history = BrowserHistoryRecorder(directory: root, resolveProfile: { .init(profileID: $0, persistence: .persistent) })
        let engine = SettingsFixtureEngine()
        let environment = BrowserEnvironment(engine: engine, history: history)
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "IO Removed")
        let removed = try #require(model.selectedProfileID)
        try await model.createProfileWithSpace(name: "IO Preserved")
        let kept = try #require(model.selectedProfileID)
        _ = try await history.importDocument(.init(profileID: removed, visits: [.init(url: URL(string: "https://settings.test/before")!)]))
        // The real history remover closes its SQLite connections, then cannot unlink the profile
        // directory from this read-only parent. No mocked successful cleanup masks the failure.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        for space in await environment.store.catalogSnapshot().spaces where space.profileID == removed { try await model.deleteSpace(space.id) }
        await #expect(throws: BrowserHistoryError.temporarilyUnavailable) { try await model.deleteProfile(removed) }
        #expect(!(await environment.store.catalogSnapshot().profiles.contains { $0.id == removed }))
        #expect(await environment.settingsProfileRemovals.entry(removed)?.nextStep == .history)
        #expect(engine.clearedProfiles.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // Recording is explicitly available again after the failed step, instead of silently
        // returning zero due to the recorder's removed-profile tombstone.
        #expect(try await history.importDocument(.init(profileID: removed, visits: [.init(url: URL(string: "https://settings.test/after-failure")!)])) == 1)
        try await model.retryProfileRemovals()
        #expect(await environment.settingsProfileRemovals.pending().isEmpty)
        #expect(engine.clearedProfiles == [removed])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(removed.rawValue.uuidString).path))
        #expect(await environment.store.catalogSnapshot().profiles.contains { $0.id == kept })
        try await history.close()
    }

    @Test("Durable pending cleanup quarantines stale restored windows before retrying native removal")
    func removalRestartRecovery() async throws {
        let root = settingsR2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json")
        let source = BrowserStore()
        let removed = try await source.createSettingsFixtureProfileWithSpace(name: "Recovery Removed")
        let kept = try await source.createSettingsFixtureProfileWithSpace(name: "Recovery Preserved")
        let spaces = await source.catalogSnapshot().spaces
        let removedSpace = try #require(spaces.first { $0.profileID == removed }?.id)
        let keptSpace = try #require(spaces.first { $0.profileID == kept }?.id)
        let savedWindow = try await source.createWindow(activeSpaceID: removedSpace)
        try BrowserSessionFileStore().save(await source.sessionDocument(), to: file)
        let journal = try BrowserProfileRemovalStore(destination: file.appendingPathExtension("profile-removals.json"))
        try await journal.put(.init(profileID: removed, spaceIDs: [removedSpace], nextStep: .engine))
        let engine = SettingsFixtureEngine()
        engine.beforeProfileRemoval = { _ in throw CocoaError(.fileWriteNoPermission) }
        let environment = try await BrowserEnvironment.open(engine: engine, sessionFile: file)
        #expect(!(await environment.store.catalogSnapshot().profiles.contains { $0.id == removed }))
        #expect(try await environment.store.captureContext(in: savedWindow).spaceID == keptSpace)
        #expect(await environment.settingsProfileRemovals.entry(removed)?.nextStep == .history)
        engine.beforeProfileRemoval = nil
        try await environment.retrySettingsProfileRemovals()
        try await environment.finalize()
        let reopened = try await BrowserEnvironment.open(engine: SettingsFixtureEngine(), sessionFile: file)
        #expect(!(await reopened.store.catalogSnapshot().profiles.contains { $0.id == removed }))
        #expect(await reopened.settingsProfileRemovals.pending().isEmpty)
        try await reopened.finalize()
    }

    @Test("The default profile stays protected even after its last Space is removed")
    func defaultProfileRemoval() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let original = try await environment.makeWindow()
        let first = try #require(original.session.activeProfileID)
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Surviving Default")
        let kept = try #require(model.selectedProfileID)
        original.window?.close()
        await original.session.waitForPendingCommands()
        for space in await environment.store.catalogSnapshot().spaces where space.profileID == first { try await model.deleteSpace(space.id) }
        await #expect(throws: BrowserSettingsError.defaultProfile) { try await model.deleteProfile(first) }
        let reopened = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); reopened.window?.close() }
        #expect(reopened.session.activeProfileID == kept && reopened.window?.isVisible == false)
    }

    @Test("An icon draft tolerates typing and IME intermediate text and commits only valid submissions")
    func iconDraftComposition() {
        let draft = BrowserSettingsIconDraft(icon: "")
        var commits: [String] = []
        for input in ["n", "ni", "nihon", "日本", "👩🏽‍💻"] { draft.text = input }
        #expect(commits.isEmpty && draft.canSubmit)
        draft.submit { commits.append($0) }
        #expect(commits == ["👩🏽‍💻"])
        draft.text = "new unfinished composition"
        draft.receivePersisted("👩🏽‍💻")
        #expect(draft.text == "new unfinished composition" && !draft.canSubmit)
        draft.submit { commits.append($0) }
        #expect(commits.count == 1)
        draft.text = ""
        draft.submit { commits.append($0) }
        #expect(commits == ["👩🏽‍💻", ""])
    }

    @Test("Name and icon drafts remain independent across queued catalog refreshes")
    func independentSpaceDrafts() async throws {
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Draft Fixture")
        await model.reload()
        let space = try #require(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID }))
        let name = BrowserSettingsNameDraft(name: space.name)
        let icon = BrowserSettingsIconDraft(icon: "")
        for value in ["n", "ni", "日本", "日本語 Space"] { name.text = value }
        for value in ["k", "ka", "か", "🌿"] { icon.text = value }
        #expect(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })?.name == space.name)
        #expect(model.runtime.document.space(space.id).icon.isEmpty)
        name.submit { value in model.perform { try await model.renameSpace(space.id, name: value) } }
        await model.waitForPendingActions()
        name.receivePersisted(try #require(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })?.name))
        #expect(!name.canSubmit && name.text == "日本語 Space")
        #expect(icon.canSubmit && icon.text == "🌿")
        name.text = "another unfinished draft"
        icon.submit { value in model.perform { try await model.updateSpace(space.id) { $0.icon = value } } }
        await model.waitForPendingActions()
        name.receivePersisted(try #require(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })?.name))
        icon.receivePersisted(model.runtime.document.space(space.id).icon)
        #expect(name.text == "another unfinished draft")
        #expect(icon.text == "🌿" && !icon.canSubmit)
        #expect(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })?.name == "日本語 Space")
        for invalid in ["", "   ", "invalid\nname"] {
            name.text = invalid
            name.submit { _ in Issue.record("Invalid name submitted") }
            #expect(!name.canSubmit)
        }
    }

    @Test("Settings resolves forced light and dark and otherwise inherits system appearance")
    func settingsAppearance() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = settingsModel(BrowserEnvironment(engine: SettingsFixtureEngine()))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let controller = BrowserSettingsWindowController(model: model, appearanceOverride: appearance)
            let window = try #require(controller.window)
            #expect(window.appearance?.name == appearance)
            #expect(window.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
            #expect(!window.isVisible)
            window.close()
        }
        let system = BrowserSettingsWindowController(model: model, appearanceOverride: nil)
        defer { system.window?.close() }
        #expect(system.window?.appearance == nil)
        #expect(system.window?.effectiveAppearance.name == NSApplication.shared.effectiveAppearance.name)
        #expect(system.window?.isVisible == false)
    }

    @Test("Offscreen Space form keeps two independent fields and a marked-text editor across refreshes")
    func distinctSpaceEditors() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Form Fixture")
        await model.reload()
        let space = try #require(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID }))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 860, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BrowserSettingsView(model: model, runtime: model.runtime, initialSection: .spaces))
        defer { window.close() }
        func editorFields() -> [NSTextField] {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            func collect(_ view: NSView) -> [NSTextField] {
                ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(collect)
            }
            return Array(collect(view).suffix(2))
        }
        for iteration in 0..<3 {
            await Task.yield()
            var fields: [NSTextField] = []
            try await withNativeTestDeadline("Space editor fields reconcile after Settings publication", timeout: 5) {
                while true {
                    fields = editorFields()
                    let expected = [model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })!.name,
                                    model.runtime.document.space(space.id).icon]
                    if fields.count == 2 && fields.map(\.stringValue) == expected { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            #expect(fields.count == 2)
            if iteration == 0 {
                let nameField = try #require(fields.first)
                nameField.selectText(nil)
                let editor = try #require(nameField.currentEditor() as? NSTextView)
                editor.setMarkedText("に", selectedRange: .init(location: 1, length: 0),
                                     replacementRange: .init(location: NSNotFound, length: 0))
                #expect(editor.hasMarkedText())
                try await model.updateSpace(space.id) { $0.icon = "X" }
                await model.reload()
                _ = editorFields()
                #expect(nameField.currentEditor() === editor && editor.hasMarkedText())
                #expect(editor.string == "に")
                #expect(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })?.name == space.name)
                editor.unmarkText()
                window.makeFirstResponder(nil)
                // Restore the persisted field before the following external rename checks.
                window.contentViewController = NSHostingController(rootView: BrowserSettingsView(model: model, runtime: model.runtime, initialSection: .spaces))
            }
            try await model.renameSpace(space.id, name: "Renamed \(iteration)")
            try await model.updateSpace(space.id) { $0.icon = "🌿" }
            await model.reload()
        }
        #expect(!window.isVisible)
    }

    @Test("Default-browser confirmation refuses termination without cancelling the system request")
    func defaultConfirmationOwnsQuit() async throws {
        let engine = SettingsFixtureEngine()
        engine.reportedKind = .chromium
        let environment = BrowserEnvironment(engine: engine)
        var release = false
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [],
            defaultBrowser: .init(status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") }, canRequest: { true }, request: {
                while !release { await Task.yield() }
            }))
        model.perform { try await model.requestDefaultBrowser() }
        try await withNativeTestDeadline("synthetic system confirmation starts", timeout: 5) {
            while !model.isRequestingDefaultBrowser { await Task.yield() }
        }
        await #expect(throws: BrowserTerminationPreparationError.systemConfirmationPending) { try await model.suspendForTermination(timeout: .zero) }
        #expect(model.acceptsActions && model.isRequestingDefaultBrowser)
        release = true
        await model.waitForPendingActions()
        #expect(!model.isRequestingDefaultBrowser && !model.isBusy)
    }

    @Test("VoiceOver shortcut names expand modifiers and special keys")
    func accessibleShortcutNames() {
        #expect(shortcutAccessibilityLabel(.init(key: "\t", modifiers: [.control, .shift])) == "Control Shift Tab")
        #expect(shortcutAccessibilityLabel(.init(key: "\u{f703}", modifiers: .command)) == "Command Right Arrow")
        #expect(shortcutAccessibilityLabel(.init(key: "\u{f704}", modifiers: [])) == "F1")
    }
}

private func settingsR2TemporaryDirectory() -> URL {
    let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
    defer { free(canonical) }
    return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        .appendingPathComponent("Orbit-SETTINGS-R2-" + UUID().uuidString, isDirectory: true)
}
extension NativeWebKitTests.NativeSettingsTests {
    @Test("An external rename preserves marked text and reconciles after composition without recreating the view")
    func externalRenameDuringComposition() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = settingsModel(BrowserEnvironment(engine: SettingsFixtureEngine()))
        try await model.createProfileWithSpace(name: "Review Fixture")
        await model.reload()
        let space = try #require(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID }))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: BrowserSettingsView(model: model, runtime: model.runtime, initialSection: .spaces))
        defer { window.close() }
        func fields() -> [NSTextField] {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap) }
            func collect(_ view: NSView) -> [NSTextField] {
                ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(collect)
            }
            return Array(collect(view).suffix(2))
        }
        _ = fields()
        let nameField = try #require(fields().first)
        nameField.selectText(nil)
        let editor = try #require(nameField.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        for mode in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            window.appearance = NSAppearance(named: mode)
            _ = fields()
            #expect(editor.hasMarkedText() && editor.string == "に")
        }
        try await model.environment.store.renameSpace(space.id, name: "Sidebar Rename")
        await model.reload()
        _ = fields()
        #expect(editor.hasMarkedText())
        #expect(editor.string == "に")
        #expect(nameField.currentEditor() === editor)
        editor.unmarkText()
        _ = fields()
        #expect(!editor.hasMarkedText() && editor.string == "に")
        #expect(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })?.name == "Sidebar Rename")
        // A later publication must still preserve the now-committed local draft.
        try await model.environment.store.renameSpace(space.id, name: "Later Rename")
        await model.reload()
        _ = fields()
        #expect(nameField.currentEditor() === editor && editor.string == "に")
        let nativeField = try #require(nameField as? BrowserSettingsNameTextField)
        #expect(nativeField.control(nativeField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await model.waitForPendingActions()
        _ = fields()
        #expect(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })?.name == "に")
        try await model.environment.store.renameSpace(space.id, name: "After Commit")
        await model.reload()
        _ = fields()
        #expect(nameField.currentEditor() === editor && editor.string == "After Commit")
        #expect(!window.isVisible)
    }

    @Test("A confirmed normalized name save adopts the stored value and follows external renames")
    func normalizedDraftThenExternalRename() async throws {
        let model = settingsModel(BrowserEnvironment(engine: SettingsFixtureEngine()))
        try await model.createProfileWithSpace(name: "Original")
        await model.reload()
        let space = try #require(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID }))
        let draft = BrowserSettingsNameDraft(name: space.name)
        draft.text = "  New  "
        draft.submit { value in model.perform { try await model.renameSpace(space.id, name: value) } }
        await model.waitForPendingActions()
        let stored = try #require(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })?.name)
        #expect(stored == "New")
        draft.receivePersisted(stored)
        #expect(draft.text == "New" && !draft.canSubmit)
        try await model.environment.store.renameSpace(space.id, name: "Sidebar Rename")
        await model.reload()
        draft.receivePersisted(try #require(model.catalog.spaces.first(where: { $0.profileID == model.selectedProfileID })?.name))
        #expect(draft.text == "Sidebar Rename" && !draft.canSubmit)
        draft.submit { _ in Issue.record("A clean draft must not overwrite the external rename") }

        // An acknowledgement may normalize only the exact revision that was submitted.
        draft.text = "  Next  "
        draft.submit { _ in }
        draft.text = "Retyped"
        draft.receivePersisted("Next")
        draft.receivePersisted("External Update")
        #expect(draft.text == "Retyped" && draft.canSubmit)
        draft.text = "  Again  "
        draft.submit { _ in }
        draft.text = "Intermediate edit"
        draft.text = "  Again  "
        draft.receivePersisted("Again")
        #expect(draft.text == "  Again  ")
        draft.text = "  Composed  "
        draft.submit { _ in }
        draft.beginComposition()
        draft.receivePersisted("Composed")
        draft.finishComposition(text: "  Composed  ")
        #expect(draft.text == "  Composed  ")

        // A cancelled composition with no local change adopts the latest deferred value.
        let cancelled = BrowserSettingsNameDraft(name: "Original")
        cancelled.beginComposition()
        cancelled.receivePersisted("First Update")
        cancelled.receivePersisted("Latest Update")
        #expect(cancelled.text == "Original" && !cancelled.canSubmit)
        cancelled.finishComposition(text: "Original")
        #expect(cancelled.text == "Latest Update" && !cancelled.canSubmit)
    }
}

@MainActor
private extension BrowserSettingsModel {
    /// These legacy scenarios explicitly need both identities; production creation is separate.
    func createProfileWithSpace(name: String) async throws {
        try await createProfile(name: name)
        let id = try #require(selectedProfileID)
        try await createSpace(name: name, profile: id)
    }
}

extension NativeWebKitTests.NativeSettingsTests {
    @Test("Settings creates a visible profile with no implicit Space, then exactly one explicit Space")
    func separateProfileAndSpaceCreation() async throws {
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        _ = try await environment.initialContext.value
        let model = settingsModel(environment)
        await model.reload()
        let before = model.catalog
        try await model.createProfile(name: "Separate Profile")
        let profile = try #require(model.selectedProfileID)
        await model.reload()
        #expect(model.catalog.profiles.count == before.profiles.count + 1)
        #expect(model.catalog.spaces.count == before.spaces.count)
        #expect(model.catalog.profiles.contains { $0.id == profile })
        #expect(model.profileRemovalUnavailableReason == nil && model.supportsProfileRemoval)
        try await model.createSpace(name: "Explicit Space", profile: profile)
        #expect(model.catalog.spaces.filter { $0.profileID == profile }.count == 1)
        #expect(model.profileRemovalUnavailableReason == "Only Profiles not assigned to any Spaces can be deleted.")
        await #expect(throws: BrowserSettingsError.profileHasSpaces) { try await model.deleteProfile(profile) }
        #expect(environment.engine.clearedProfiles.isEmpty)
        try await model.deleteSpace(try #require(model.catalog.spaces.first { $0.profileID == profile }?.id))
        try await model.deleteProfile(profile)
        #expect(environment.engine.clearedProfiles == [profile])
    }

    @Test("Space deletion closes synthetic documents in every window and keeps the surviving profile isolated")
    func spaceDeletionClosesAllWindowsDocuments() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let first = try await environment.makeWindow()
        let second = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); first.window?.close(); second.window?.close() }
        let removed = try #require(first.session.snapshot?.activeSpaceID)
        let firstSurface = try #require(first.session.selectedSurface)
        let secondSurface = try #require(second.session.selectedSurface)
        let profile = try #require(first.session.activeProfileID)
        let fallback = try await environment.store.createSpace(name: "Survivor", profileID: profile)
        try await environment.refreshSettingsCatalog()
        let model = settingsModel(environment)
        await model.reload()
        try await model.deleteSpace(removed)
        #expect(firstSurface.isDisposed && secondSurface.isDisposed)
        #expect(first.session.snapshot?.activeSpaceID == fallback && second.session.snapshot?.activeSpaceID == fallback)
        #expect(first.session.ownedSurfaces.isEmpty && second.session.ownedSurfaces.isEmpty)
        #expect(first.sidebar.spaceTitles == ["Survivor"])
        #expect(first.window?.isVisible == false && second.window?.isVisible == false)
        #expect(environment.engine.clearedProfiles.isEmpty)
        await #expect(throws: BrowserSettingsError.lastSpace) { try await model.deleteSpace(fallback) }
        #expect(model.archivedSpaces.contains { $0.id == removed })
        try await model.restoreSpace(removed)
        #expect(model.catalog.spaces.contains { $0.id == removed })
        #expect(model.archivedSpaces.isEmpty)
        #expect(first.session.ownedSurfaces.isEmpty && second.session.ownedSurfaces.isEmpty)
        try await environment.store.sessionDocument().validate()
    }

    @Test("Both sidebar menus capture Space deletion and disable it for the final Space")
    func sidebarDeletionActions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let owner = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); owner.window?.close() }
        func deletionItem(_ menu: NSMenu?) throws -> NSMenuItem {
            try #require(menu?.items.first { $0.title == "Delete Space…" })
        }
        let initialSpace = try #require(owner.session.snapshot?.activeSpaceID)
        #expect(owner.sidebar.footer.actions(for: initialSpace).last?.enabled == false)
        #expect(try !deletionItem(owner.sidebar.page.spaceContextMenu).isEnabled)
        let profile = try #require(owner.session.activeProfileID)
        owner.createSpace(name: "Second", profileID: profile)
        await owner.session.waitForPendingCommands()
        let second = try #require(owner.session.snapshot?.activeSpaceID)
        var requested: [SpaceID] = []
        owner.sidebar.onDeleteSpace = { requested.append($0) }
        let button = try #require(owner.sidebar.footer.spaceButtons.last)
        owner.sidebar.footer.showContextMenu(for: button, present: false)
        let footerMenu = try #require(owner.sidebar.footer.contextMenu)
        let deleteIndex = try #require(footerMenu.actions.firstIndex { $0.kind == .delete })
        #expect(footerMenu.actions[deleteIndex].enabled)
        footerMenu.activate(deleteIndex)
        let title = try deletionItem(owner.sidebar.page.spaceContextMenu)
        for item in [title] {
            #expect(item.isEnabled)
            #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
        }
        #expect(requested == [second, second])
        #expect(await environment.store.catalogSnapshot().spaces.count == 2)
        #expect(owner.window?.attachedSheet == nil && owner.window?.isVisible == false)
    }
}

extension NativeWebKitTests.NativeSettingsTests {
    @Test("Profile removal after deleting an empty Space persists a valid session and retries failed engine cleanup")
    func emptySpaceProfileRemovalPersistenceAndRetry() async throws {
        let root = settingsR2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json")
        let engine = SettingsFixtureEngine()
        let environment = try await BrowserEnvironment.open(engine: engine, sessionFile: file)
        let model = settingsModel(environment)
        try await model.createProfile(name: "Empty Profile")
        let profile = try #require(model.selectedProfileID)
        try await model.createSpace(name: "Empty Space", profile: profile)
        let space = try #require(model.catalog.spaces.first { $0.profileID == profile }?.id)
        try await model.deleteSpace(space)
        engine.beforeProfileRemoval = { _ in throw CocoaError(.fileWriteNoPermission) }
        await #expect(throws: CocoaError.self) { try await model.deleteProfile(profile) }
        try await environment.store.sessionDocument().validate()
        #expect(await environment.settingsProfileRemovals.entry(profile) != nil)
        try await environment.finalize()
        let restored = try await BrowserEnvironment.open(engine: SettingsFixtureEngine(), sessionFile: file)
        #expect(await restored.store.catalogSnapshot().profiles.allSatisfy { $0.id != profile })
        #expect(await restored.settingsProfileRemovals.pending().isEmpty)
        #expect(await restored.store.sessionDocument().organization.archivedSpaces.allSatisfy { $0.space.profileID != profile })
        try await restored.store.sessionDocument().validate()
        try await restored.finalize()
    }
}


extension NativeWebKitTests.NativeSettingsTests {
    @Test("Settings reads Chromium removal capability dynamically after model creation and reload")
    func profileRemovalCapabilityIsNotCapturedAtOpening() async throws {
        let engine = SettingsFixtureEngine()
        engine.reportedKind = .chromium
        engine.reportsProfileRemoval = false
        let environment = BrowserEnvironment(engine: engine)
        _ = try await environment.initialContext.value
        let profile = try await environment.store.createSettingsProfile(name: "Removable synthetic profile")
        let model = settingsModel(environment, profile: profile)
        await model.reload()
        #expect(!model.supportsProfileRemoval && !model.runtime.isUnavailable)
        #expect(model.profileRemovalUnavailableReason == "The current engine does not support deleting profiles.")
        engine.reportsProfileRemoval = true
        #expect(model.supportsProfileRemoval && model.profileRemovalUnavailableReason == nil)
        await model.reload()
        #expect(model.supportsProfileRemoval && model.profileRemovalUnavailableReason == nil)
        engine.reportsProfileRemoval = false
        #expect(!model.supportsProfileRemoval)
        await model.reload()
        #expect(model.profileRemovalUnavailableReason == "The current engine does not support deleting profiles.")
        #expect(engine.clearedProfiles.isEmpty)
    }
}

extension NativeWebKitTests.NativeSettingsTests {
    @Test("Secondary appearance saves through the settings queue without publishing a browser change")
    func secondaryAppearanceDoesNotApplyBrowserTheme() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        // Finish synthetic bootstrap before comparing whole session documents.
        _ = try await environment.initialContext.value
        let model = settingsModel(environment)
        await model.reload()
        let before = await environment.store.sessionDocument()
        let settingsBefore = model.runtime.document
        var browserChanges = 0
        model.runtime.onChange = { browserChanges += 1 }
        model.perform {
            var draft = model.runtime.document.secondaryAppearanceDraft
            draft.material = .liquidGlass
            draft.transparency = 0.8
            try await model.runtime.setSecondaryAppearanceDraft(draft)
        }
        await model.waitForPendingActions()
        #expect(browserChanges == 0)
        #expect(model.runtime.document.secondaryAppearanceDraft.material == .liquidGlass)
        #expect(model.runtime.document.secondaryAppearanceDraft.transparency == 0.8)
        var settingsAfter = model.runtime.document
        settingsAfter.secondaryAppearanceDraft = settingsBefore.secondaryAppearanceDraft
        #expect(settingsAfter == settingsBefore)
        #expect(await environment.store.sessionDocument() == before)
        #expect(environment.engine.clearedProfiles.isEmpty)
    }

    @Test("Native Orbit secondary screens render hidden using packaged vector resources")
    func secondaryIdentityHiddenViews() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = settingsModel(BrowserEnvironment(engine: SettingsFixtureEngine()))
        await model.reload()
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        #expect(window.title == BrowserSettingsSection.general.title)
        #expect(window.identifier?.rawValue == "orbit-settings")
        for name in ["wordmark", "sign-color"] {
            let image = try #require(OrbitSecondaryIdentity.image(name))
            #expect(image.representations.contains { $0 is NSPDFImageRep })
        }
        for section in [BrowserSettingsSection.general, .appearance, .about, .profiles, .spaces, .shortcuts, .links, .icon, .privacy, .advanced] {
            model.settingsSection = section
            window.contentViewController = NSHostingController(rootView: BrowserSettingsView(model: model, runtime: model.runtime))
            let view = try #require(window.contentView)
            view.setFrameSize(NSSize(width: 860, height: 640))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            #expect(!window.isVisible)
        }
        #expect(OrbitSecondaryAppearancePreview.sampleOpacity(model.runtime.document.secondaryAppearanceDraft, reduceTransparency: true) == 1)
        #expect(OrbitSecondaryAppearancePreview.sampleOpacity(model.runtime.document.secondaryAppearanceDraft, reduceTransparency: false) < 1)
        #expect(!window.isVisible)
    }

    @Test("Preferences toolbar owns selectable native categories and follows model routes without replacing content")
    func nativePreferencesToolbar() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = settingsModel(BrowserEnvironment(engine: SettingsFixtureEngine()))
        await model.reload()
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        let hosting = try #require(window.contentViewController)
        let toolbar = try #require(window.toolbar)
        #expect(window.toolbarStyle == .preference)
        #expect(window.titlebarSeparatorStyle == .line)
        #expect(toolbar.displayMode == .iconAndLabel)
        #expect(!toolbar.allowsUserCustomization && !toolbar.autosavesConfiguration)
        let identifiers = BrowserSettingsSection.allCases.map(\.toolbarIdentifier)
        #expect(toolbar.items.map(\.itemIdentifier) == identifiers)
        #expect(controller.toolbarSelectableItemIdentifiers(toolbar) == identifiers)
        for (section, item) in zip(BrowserSettingsSection.allCases, toolbar.items) {
            #expect(item.view == nil) // Native toolbar items, not custom SwiftUI button views.
            #expect(item.label == section.title && item.image != nil)
            #expect(item.image?.accessibilityDescription == section.title)
            #expect(item.itemIdentifier.rawValue == "settings-category-" + section.rawValue)
            #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
            #expect(model.settingsSection == section)
            #expect(toolbar.selectedItemIdentifier == section.toolbarIdentifier)
            #expect(item.menuFormRepresentation?.state == .on)
            #expect(window.contentViewController === hosting)
        }
        model.settingsSection = .profiles
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(toolbar.selectedItemIdentifier == BrowserSettingsSection.profiles.toolbarIdentifier)
        await model.reload()
        window.close()
        // The application retains this controller on Close; no show/order call is needed
        // to exercise the same reopen path and retained selection.
        _ = controller.window
        #expect(model.settingsSection == .profiles)
        #expect(toolbar.selectedItemIdentifier == BrowserSettingsSection.profiles.toolbarIdentifier)
        #expect(!window.isVisible)
    }

    @Test("Small preferences windows retain every category through native overflow menu actions and keyboard equivalents")
    func nativePreferencesMinimumLayout() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = settingsModel(BrowserEnvironment(engine: SettingsFixtureEngine()))
        try await model.createProfileWithSpace(name: "Compact Settings Fixture")
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        let toolbar = try #require(window.toolbar)
        let hosting = try #require(window.contentViewController)
        #expect(window.contentMinSize == NSSize(width: 684, height: 400))
        for size in [NSSize(width: 684, height: 400), NSSize(width: 860, height: 640)] {
            window.setContentSize(size)
            for (index, item) in toolbar.items.enumerated() {
                let section = BrowserSettingsSection.allCases[index]
                let menu = try #require(item.menuFormRepresentation)
                #expect(menu.title == section.title)
                #expect(menu.keyEquivalent == String(index + 1) && menu.keyEquivalentModifierMask == .command)
                #expect(NSApplication.shared.sendAction(try #require(menu.action), to: menu.target, from: menu))
                #expect(model.settingsSection == section && toolbar.selectedItemIdentifier == section.toolbarIdentifier)
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(window.contentViewController === hosting)
                #expect(try #require(window.contentView).bounds.width <= size.width + 1)
                #expect(!window.isVisible)
            }
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 20))
        #expect(window.performKeyEquivalent(with: event))
        #expect(model.settingsSection == .shortcuts)
        try await model.suspendForTermination(timeout: .seconds(2))
        #expect(!controller.selectSection(.general))
        #expect(model.settingsSection == .shortcuts)
        model.resumeAfterCancelledTermination()
        #expect(controller.selectSection(.general))
    }

    @Test("Native category actions preserve marked-text focus and live Space form mutations")
    func nativeToolbarKeepsComposingSpaceForm() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SettingsFixtureEngine())
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Toolbar Form Fixture")
        let profile = try #require(model.selectedProfileID)
        let space = try #require(model.catalog.spaces.first { $0.profileID == profile })
        model.settingsSection = .spaces
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        let hosting = try #require(window.contentViewController)
        func fields(_ view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
        }
        var nameField: NSTextField?
        try await withNativeTestDeadline("Native toolbar Space form becomes available", timeout: 5) {
            while nameField == nil {
                window.contentView?.layoutSubtreeIfNeeded()
                nameField = fields(window.contentView!).first { $0.stringValue == space.name && $0.isEditable }
                if nameField == nil { try await Task.sleep(for: .milliseconds(20)) }
            }
        }
        let field = try #require(nameField)
        field.selectText(nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: .init(location: 1, length: 0),
                             replacementRange: .init(location: NSNotFound, length: 0))
        let general = try #require(window.toolbar?.items.first)
        #expect(NSApplication.shared.sendAction(try #require(general.action), to: general.target, from: general))
        #expect(model.settingsSection == .spaces)
        #expect(window.toolbar?.selectedItemIdentifier == nil)
        try await model.updateSpace(space.id) { $0.icon = "🌿" }
        await model.reload()
        #expect(field.currentEditor() === editor && editor.hasMarkedText())
        #expect(editor.string == "に")
        #expect(window.contentViewController === hosting)
        editor.unmarkText()
        window.makeFirstResponder(nil)
        let nativeField = try #require(field as? BrowserSettingsNameTextField)
        let draft = try #require(nativeField.draft)
        draft.text = "Toolbar Renamed Space"
        let submit = try #require(nativeField.onSubmit)
        submit()
        await model.waitForPendingActions()
        model.perform { try await model.updateProfile(profile) { $0.searchEngine = .bing } }
        await model.waitForPendingActions()
        #expect(model.catalog.spaces.first { $0.id == space.id }?.name == "Toolbar Renamed Space")
        #expect(model.runtime.document.space(space.id).icon == "🌿")
        #expect(model.runtime.document.profile(profile).searchEngine == .bing)
        #expect(!window.isVisible)
    }

}

@MainActor
private final class SettingsExtensionManager: BrowserExtensionManagement {
    var opened: [(shortcuts: Bool, profile: ProfileID)] = []
    func openManagement(on surface: any BrowserEngineSurface) throws { opened.append((false, surface.profileID)) }
    func openShortcuts(on surface: any BrowserEngineSurface) throws { opened.append((true, surface.profileID)) }
}

extension NativeWebKitTests.NativeSettingsTests {
    @Test("Settings panel edits survive product environment reopen with independent profile and app scopes")
    func settingsWindowPersistence() async throws {
        let root = settingsR2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json")
        let environment = try await BrowserEnvironment.open(engine: SettingsFixtureEngine(), sessionFile: file)
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Settings Window One")
        let first = try #require(model.selectedProfileID)
        try await model.createProfileWithSpace(name: "Settings Window Two")
        let second = try #require(model.selectedProfileID)
        try await model.renameProfile(first, name: "Renamed Profile")
        try await model.updateProfile(first) { $0.searchEngine = .duckDuckGo; $0.opensPinnedLinksInPeek = false }
        try await model.updateProfile(first) { $0.shiftClickOpensPeek = false }
        try await model.setArchiveThreshold(.sevenDays, profile: first)
        try await model.runtime.setOpensExternalLinksInQuickWindow(false)
        try await model.setReducedMotion(.reduce)
        defer { OrbitMotionPreferences.overrideReducedMotion = nil }
        try await environment.finalize()

        let restored = try await BrowserEnvironment.open(engine: SettingsFixtureEngine(), sessionFile: file)
        let saved = restored.settings.document
        #expect(saved.profile(first).searchEngine == .duckDuckGo)
        #expect(!saved.profile(first).opensPinnedLinksInPeek && !saved.profile(first).shiftClickOpensPeek)
        #expect(saved.profile(second) == BrowserProfileSettings())
        #expect(!saved.opensExternalLinksInQuickWindow && saved.reducedMotion == .reduce)
        #expect(await restored.store.archivePolicy().threshold(for: first) == .sevenDays)
        #expect(await restored.store.archivePolicy().profileThresholds[second] == nil)
        #expect(await restored.store.catalogSnapshot().profiles.first { $0.id == first }?.name == "Renamed Profile")
        try await restored.finalize()
    }

    @Test("Settings extension handoffs preserve the captured profile and existing page in a separate tab")
    func settingsExtensionRoutes() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SettingsFixtureEngine()
        engine.reportedKind = .chromium
        let manager = SettingsExtensionManager()
        engine.settingsExtensionManager = manager
        let environment = BrowserEnvironment(engine: engine)
        let model = settingsModel(environment)
        try await model.createProfileWithSpace(name: "Manager Target")
        let target = try #require(model.selectedProfileID)
        let space = try #require(model.catalog.spaces.first { $0.profileID == target })
        let controller = try await environment.makeWindow(spaceID: space.id)
        defer { controller.window?.close(); environment.autoArchive.scheduler.stop() }
        controller.session.openTab(url: URL(string: "about:blank#keep-original")!)
        await controller.session.waitForPendingCommands()
        let original = try #require(controller.session.selectedSurface)
        try await model.createProfileWithSpace(name: "Unrelated Profile")
        let other = try #require(model.selectedProfileID)
        var presented: [ProfileID] = []
        model.presentBrowserForProfile = { profile in
            presented.append(profile)
            // Simulate a profile selection change while the handoff is in flight.
            model.selectProfile(other)
            return controller
        }
        #expect(model.canOpenExtensionSettings(profile: target))
        try await model.openBrowserSettings(.extensions, profile: target)
        try await model.openBrowserSettings(.extensionShortcuts, profile: target)
        #expect(presented == [target, target])
        #expect(manager.opened.map(\.profile) == [target, target])
        #expect(manager.opened.map(\.shortcuts) == [false, true])
        #expect(original.currentURL?.fragment == "keep-original" && !original.isDisposed)
        #expect(controller.session.snapshot?.tabs.count == 4)
        #expect(!controller.window!.isVisible)
        engine.settingsExtensionManager = nil
        #expect(!model.canOpenExtensionSettings(profile: target))
        await #expect(throws: BrowserEngineError.unsupportedOperation) {
            try await model.openBrowserSettings(.extensions, profile: target)
        }
        #expect(controller.session.snapshot?.tabs.count == 4)
    }

    @Test("Settings lists installed shortcuts and omits unsupported or out-of-scope AI actions")
    func settingsShortcutAvailability() {
        let model = settingsModel(BrowserEnvironment(engine: SettingsFixtureEngine()))
        model.shortcutIsImplemented = { $0 == .preferences || $0 == .newChatGPTMessage }
        #expect(model.settingsShortcuts.map(\.id) == [.preferences])
    }

    @Test("Settings toolbar contains the public Orbit categories and resizing retains its top edge")
    func orbitSettingsCategoriesAndResize() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        #expect(BrowserSettingsSection.allCases == [.general, .profiles, .shortcuts, .links, .icon, .advanced])
        let model = settingsModel(BrowserEnvironment(engine: SettingsFixtureEngine()))
        await model.reload()
        let controller = BrowserSettingsWindowController(model: model)
        let window = try #require(controller.window)
        defer { window.close() }
        let top = window.frame.maxY
        for section in BrowserSettingsSection.allCases {
            #expect(controller.selectSection(section))
            #expect(window.title == section.title)
            #expect(abs(window.frame.maxY - top) < 1)
            #expect(!window.isVisible)
        }
        let azerty = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "é", charactersIgnoringModifiers: "é", isARepeat: false, keyCode: 19))
        #expect(window.performKeyEquivalent(with: azerty))
        #expect(model.settingsSection == .profiles && window.title == BrowserSettingsSection.profiles.title)
    }
}
