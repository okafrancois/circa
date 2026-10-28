import AppKit
import BrowserCore
import BrowserEngineConformance
import Darwin
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Independent Orbit draft fault regressions", .serialized)
@MainActor
struct OrbitSecondaryIndependentReviewTests {
    private func destination() -> URL {
        let path = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
            .appendingPathComponent("OrbitReview-" + UUID().uuidString)
            .appendingPathComponent("settings.json")
    }

    @Test("Rejected disk write leaves the runtime, motion and browser callback untouched")
    func failedWriteIsIsolated() async throws {
        let previousMotion = OrbitMotionPreferences.overrideReducedMotion
        defer { OrbitMotionPreferences.overrideReducedMotion = previousMotion }
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: url)
        try await store.setReducedMotion(.reduce)
        let runtime = BrowserSettingsRuntime(store: store)
        await runtime.refresh()
        let before = runtime.document
        let motion = OrbitMotionPreferences.overrideReducedMotion
        var callbacks = 0
        runtime.onChange = { callbacks += 1 }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/dev/null")
        var draft = BrowserSecondaryAppearanceDraft()
        draft.material = .liquidGlass
        draft.transparency = 0.9
        await #expect(throws: (any Error).self) { try await runtime.setSecondaryAppearanceDraft(draft) }
        #expect(runtime.document == before)
        #expect(await store.snapshot() == before)
        #expect(callbacks == 0)
        #expect(OrbitMotionPreferences.overrideReducedMotion == motion)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == "/dev/null")
    }

    @Test("Unavailable storage rejects a draft without falsely publishing success")
    func unavailableIsIsolated() async throws {
        let runtime = BrowserSettingsRuntime(store: .unavailable())
        let before = runtime.document
        var callbacks = 0
        runtime.onChange = { callbacks += 1 }
        await #expect(throws: BrowserSettingsError.unavailable) {
            try await runtime.setSecondaryAppearanceDraft(.init())
        }
        #expect(runtime.document == before && callbacks == 0)
    }

    @Test("Queued material and slider edits retain each other and leave two windows unchanged")
    func queuedEditsAreIsolated() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let first = try await environment.makeWindow()
        let second = try await environment.makeWindow()
        defer {
            environment.autoArchive.scheduler.stop()
            first.window?.close()
            second.window?.close()
        }
        let model = BrowserSettingsModel(environment: environment, profileID: first.session.activeProfileID,
            shortcuts: [], defaultBrowser: .init(
                status: { .init(http: "synthetic", https: "synthetic", html: "synthetic") },
                canRequest: { false }, request: { Issue.record("Unexpected system browser request") }))
        await model.reload()
        let before = await environment.store.sessionDocument()
        let firstTheme = first.windowShell.theme
        let secondTheme = second.windowShell.theme
        let selected = model.selectedProfileID
        var callbacks = 0
        model.runtime.onChange = { callbacks += 1 }
        model.perform {
            var draft = model.runtime.document.secondaryAppearanceDraft
            draft.material = .liquidGlass
            try await model.runtime.setSecondaryAppearanceDraft(draft)
        }
        model.perform {
            var draft = model.runtime.document.secondaryAppearanceDraft
            draft.transparency = 0.87
            try await model.runtime.setSecondaryAppearanceDraft(draft)
        }
        await model.waitForPendingActions()
        #expect(model.runtime.document.secondaryAppearanceDraft.material == .liquidGlass)
        #expect(model.runtime.document.secondaryAppearanceDraft.transparency == 0.87)
        #expect(model.errorMessage == nil && callbacks == 0)
        #expect(await environment.store.sessionDocument() == before)
        #expect(first.windowShell.theme == firstTheme && second.windowShell.theme == secondTheme)
        #expect(model.selectedProfileID == selected)
        #expect(first.window?.isVisible == false && second.window?.isVisible == false)
    }

    @Test("Unknown draft material preserves known browser preferences, valid transparency and original file bytes")
    func unknownMaterialPreservesFile() async throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var before = BrowserSettingsDocument()
        before.reducedMotion = .reduce
        before.opensExternalLinksInQuickWindow = false
        let profile = ProfileID(), space = SpaceID()
        var search = BrowserProfileSettings()
        search.searchEngine = .bing
        search.opensPinnedLinksInPeek = false
        search.shiftClickOpensPeek = false
        before.profiles[profile] = search
        var theme = BrowserSpaceSettings()
        theme.palette = .lavender
        theme.icon = "X"
        before.spaces[space] = theme
        before.lastActiveWindowID = WindowID()
        before.lastActiveSpaceID = space
        before.secondaryAppearanceDraft.transparency = 0.4
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        json["secondaryAppearanceDraft"] = ["material": "future", "transparency": 0.4]
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: url)
        let store = try BrowserSettingsStore(destination: url)
        #expect(await store.snapshot() == before)
        #expect(!store.isUnavailable)
        #expect(try Data(contentsOf: url) == bytes)
        // A later explicit write publishes the recovered known values, with no browser preference loss.
        try await store.setSecondaryAppearanceDraft(before.secondaryAppearanceDraft)
        let reopened = try BrowserSettingsStore(destination: url)
        #expect(await reopened.snapshot() == before)
    }

    @Test("Environment restoration keeps saved browser preferences available despite an unknown draft material")
    func environmentRecoveryPreservesPreferences() async throws {
        let previousMotion = OrbitMotionPreferences.overrideReducedMotion
        defer { OrbitMotionPreferences.overrideReducedMotion = previousMotion }
        let url = destination()
        let root = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionFile = root.appendingPathComponent("session.json")
        let settingsFile = sessionFile.appendingPathExtension("settings.json")
        var expected = BrowserSettingsDocument()
        expected.reducedMotion = .reduce
        expected.opensExternalLinksInQuickWindow = false
        var profile = BrowserProfileSettings()
        profile.searchEngine = .bing
        profile.opensPinnedLinksInPeek = false
        profile.shiftClickOpensPeek = false
        expected.profiles[ProfileID()] = profile
        var space = BrowserSpaceSettings()
        space.palette = .rosePlum
        expected.spaces[SpaceID()] = space
        expected.secondaryAppearanceDraft.transparency = 0.45
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        json["secondaryAppearanceDraft"] = ["material": "future", "transparency": 0.45]
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: settingsFile)
        let environment = try await BrowserEnvironment.open(engine: SyntheticEngine(), sessionFile: sessionFile)
        #expect(!environment.settings.isUnavailable)
        #expect(environment.settings.document == expected)
        #expect(try Data(contentsOf: settingsFile) == bytes)
        try await environment.finalize()
    }

    @Test("Unknown keys do not block loading or change known preferences on draft save")
    func unknownKeysPreserveKnownValues() async throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var before = BrowserSettingsDocument()
        before.reducedMotion = .reduce
        let profile = ProfileID(), space = SpaceID()
        var search = BrowserProfileSettings()
        search.searchEngine = .bing
        before.profiles[profile] = search
        var theme = BrowserSpaceSettings()
        theme.palette = .lavender
        before.spaces[space] = theme
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        json["futureField"] = ["enabled": true]
        var draftJSON = try #require(json["secondaryAppearanceDraft"] as? [String: Any])
        draftJSON["futureDraftField"] = "unknown"
        json["secondaryAppearanceDraft"] = draftJSON
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try bytes.write(to: url)
        let store = try BrowserSettingsStore(destination: url)
        #expect(await store.snapshot() == before)
        #expect(try Data(contentsOf: url) == bytes)
        var draft = before.secondaryAppearanceDraft
        draft.transparency = 0.66
        try await store.setSecondaryAppearanceDraft(draft)
        let reopened = try BrowserSettingsStore(destination: url)
        var after = await reopened.snapshot()
        after.secondaryAppearanceDraft = before.secondaryAppearanceDraft
        #expect(after == before)
    }
}
}
