import Foundation
import Testing
@testable import BrowserCore

@Suite("Site preferences")
@MainActor
struct BrowserSitePreferenceTests {
    @Test("Localhost defaults to Developer Mode with durable host-scoped opt-out")
    func localhostDefaults() throws {
        let root = URL(fileURLWithPath: "/private/tmp/site-localhost-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json")
        let profile = ProfileID(), other = ProfileID()
        let store = try BrowserSitePreferenceStore(destination: file)
        for text in ["http://localhost", "https://localhost:8080/path", "http://app.localhost:3000", "http://deep.app.localhost"] {
            let url = URL(string: text)!
            #expect(store.preferences(url: url, profileID: profile).developerMode)
            var settings = store.preferences(url: url, profileID: profile)
            settings.developerMode = false
            try store.set(settings, url: url, profileID: profile)
            #expect(try !BrowserSitePreferenceStore(destination: file).preferences(url: url, profileID: profile).developerMode)
            #expect(store.preferences(url: url, profileID: other).developerMode)
            settings.developerMode = true
            try store.set(settings, url: url, profileID: profile)
        }
        for text in ["http://127.0.0.1:8080", "http://[::1]:3000", "https://localhost.example.test", "https://notlocalhost", "file:///localhost"] {
            #expect(!store.preferences(url: URL(string: text), profileID: profile).developerMode)
        }
    }

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

    @Test("Never-translate is durable per host/profile, undoable and backward compatible")
    func translationPreference() throws {
        let root = URL(fileURLWithPath: "/private/tmp/translation-preferences-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json")
        let profile = ProfileID(), other = ProfileID()
        let url = URL(string: "https://example.test/page")!
        let store = try BrowserSitePreferenceStore(destination: file)
        var value = store.preferences(url: url, profileID: profile)
        value.neverTranslate = true
        try store.set(value, url: url, profileID: profile)
        let restarted = try BrowserSitePreferenceStore(destination: file)
        #expect(restarted.preferences(url: URL(string: "http://example.test:8080/next"), profileID: profile).neverTranslate)
        #expect(!restarted.preferences(url: url, profileID: other).neverTranslate)
        #expect(!restarted.preferences(url: URL(string: "https://sub.example.test"), profileID: profile).neverTranslate)
        value.neverTranslate = false
        try restarted.set(value, url: url, profileID: profile)
        #expect(try !BrowserSitePreferenceStore(destination: file).preferences(url: url, profileID: profile).neverTranslate)
        let old = try JSONDecoder().decode(BrowserSitePreferences.self, from: Data(#"{"developerMode":true,"automaticPictureInPicture":false}"#.utf8))
        #expect(old.developerMode && !old.automaticPictureInPicture && !old.neverTranslate)
        let memory = try BrowserSitePreferenceStore()
        value.neverTranslate = true
        try memory.set(value, url: url, profileID: profile)
        #expect(try !BrowserSitePreferenceStore().preferences(url: url, profileID: profile).neverTranslate)
        #expect(try !BrowserSitePreferenceStore(destination: file).preferences(url: url, profileID: profile).neverTranslate)
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
