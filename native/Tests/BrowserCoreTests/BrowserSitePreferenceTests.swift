import Foundation
import Testing
@testable import BrowserCore

@Suite("Site preferences")
@MainActor
struct BrowserSitePreferenceTests {
    @Test("Host preferences survive restart and remain independent across profiles")
    func persistenceAndScope() throws {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-site-preferences-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json")
        let profile = ProfileID(), other = ProfileID()
        let url = URL(string: "https://example.test/path")!
        let store = try BrowserSitePreferenceStore(destination: file)
        var settings = store.preferences(url: url, profileID: profile)
        #expect(!settings.developerMode && settings.automaticPictureInPicture)
        settings.developerMode = true; settings.automaticPictureInPicture = false
        try store.set(settings, url: url, profileID: profile)
        let restored = try BrowserSitePreferenceStore(destination: file)
        #expect(restored.preferences(url: URL(string: "http://example.test:8080/another"), profileID: profile) == settings)
        #expect(restored.preferences(url: url, profileID: other) == BrowserSitePreferences())
        #expect(restored.preferences(url: URL(string: "https://sub.example.test"), profileID: profile) == BrowserSitePreferences())
        settings.developerMode = false
        try restored.set(settings, url: url, profileID: profile)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("backup").path))
    }

    @Test("Only nondefault permissions enter the compact site panel; a dismissed request stays hidden")
    func contextualPermissions() async throws {
        let store = BrowserSitePermissionStore.ephemeral(), profile = ProfileID(), other = ProfileID()
        let origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        #expect(await store.relevantPermissions(origin: origin, profileID: profile).isEmpty)
        try await store.set(.ask, for: [.camera], origin: origin, profileID: profile)
        #expect(await store.setting(for: .camera, origin: origin, profileID: profile) == .ask)
        try await store.set(.block, for: [.notifications], origin: origin, profileID: profile)
        #expect(await store.relevantPermissions(origin: origin, profileID: profile) == [.notifications])
        #expect(await store.relevantPermissions(origin: origin, profileID: other).isEmpty)
        try await store.reset(origin: origin, profileID: profile)
        #expect(await store.relevantPermissions(origin: origin, profileID: profile).isEmpty)
    }
}
