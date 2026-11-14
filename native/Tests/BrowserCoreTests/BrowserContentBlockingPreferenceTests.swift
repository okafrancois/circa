import Foundation
import Testing
@testable import BrowserCore

@Suite("Content blocking preferences")
@MainActor
struct BrowserContentBlockingPreferenceTests {
    @Test("Blocking is on by default, also for documents saved before the setting existed")
    func defaultsOn() throws {
        #expect(BrowserProfileSettings().blocksAdsAndTrackers)
        #expect(BrowserSitePreferences().blocksAdsAndTrackers)
        let legacyProfile = #"{"searchEngine":"google","opensPinnedLinksInPeek":true,"shiftClickOpensPeek":true}"#
        #expect(try JSONDecoder().decode(BrowserProfileSettings.self, from: Data(legacyProfile.utf8)).blocksAdsAndTrackers)
        let legacySite = #"{"developerMode":true}"#
        #expect(try JSONDecoder().decode(BrowserSitePreferences.self, from: Data(legacySite.utf8)).blocksAdsAndTrackers)
        var off = BrowserProfileSettings(); off.blocksAdsAndTrackers = false
        #expect(try !JSONDecoder().decode(BrowserProfileSettings.self, from: JSONEncoder().encode(off)).blocksAdsAndTrackers)
    }

    @Test("Per-site exceptions are host-scoped, per profile and durable")
    func exceptions() throws {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-content-blocking-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json")
        let profile = ProfileID(), other = ProfileID()
        let store = try BrowserSitePreferenceStore(destination: file)
        #expect(store.contentBlockingExceptions(profileID: profile).isEmpty)
        for text in ["https://news.example.test/a", "http://Shop.Example.TEST:8080/b"] {
            let url = URL(string: text)!
            var value = store.preferences(url: url, profileID: profile)
            value.blocksAdsAndTrackers = false
            try store.set(value, url: url, profileID: profile)
        }
        // Another preference of a host does not make it an exception.
        var developer = store.preferences(url: URL(string: "https://dev.example.test"), profileID: profile)
        developer.developerMode = true
        try store.set(developer, url: URL(string: "https://dev.example.test"), profileID: profile)
        #expect(store.contentBlockingExceptions(profileID: profile) == ["news.example.test", "shop.example.test"])
        #expect(store.contentBlockingExceptions(profileID: other).isEmpty)
        let restored = try BrowserSitePreferenceStore(destination: file)
        #expect(restored.contentBlockingExceptions(profileID: profile) == ["news.example.test", "shop.example.test"])
        var on = restored.preferences(url: URL(string: "https://news.example.test"), profileID: profile)
        on.blocksAdsAndTrackers = true
        try restored.set(on, url: URL(string: "https://news.example.test"), profileID: profile)
        #expect(restored.contentBlockingExceptions(profileID: profile) == ["shop.example.test"])
        try restored.clear(profileID: profile)
        #expect(restored.contentBlockingExceptions(profileID: profile).isEmpty)
    }
}
