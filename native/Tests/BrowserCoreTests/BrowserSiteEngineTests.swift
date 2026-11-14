import Foundation
import Testing
@testable import BrowserCore

@Suite("Site engine routing")
@MainActor
struct BrowserSiteEngineTests {
    @Test("Protected-streaming domains match by suffix, never by substring or a foreign suffix")
    func protectedDomains() {
        for text in ["https://www.netflix.com/browse", "https://netflix.com", "https://www.disneyplus.com/fr-fr",
                     "https://play.hbomax.com", "https://auth.max.com/login", "https://tv.apple.com/fr",
                     "https://www.primevideo.com/", "http://WWW.NETFLIX.COM./title/1"] {
            #expect(BrowserProtectedStreamingSites.domain(for: URL(string: text)) != nil, "\(text)")
            #expect(BrowserProtectedStreamingSites.engine(for: URL(string: text), saved: nil) == .webKit, "\(text)")
        }
        for text in ["https://notnetflix.com", "https://netflix.com.example.test", "https://apple.com",
                     "https://www.apple.com/tv", "https://example.test/netflix.com", "file:///netflix.com",
                     "about:blank", "chrome://settings", "https://amazon.com/gp/video"] {
            #expect(BrowserProtectedStreamingSites.engine(for: URL(string: text), saved: nil) == .chromium, "\(text)")
        }
        #expect(BrowserProtectedStreamingSites.engine(for: nil, saved: .webKit) == .chromium)
    }

    @Test("A saved choice wins over the list, and only non-default choices are saved")
    func savedChoice() {
        let netflix = URL(string: "https://www.netflix.com")!, example = URL(string: "https://example.test")!
        #expect(BrowserProtectedStreamingSites.engine(for: netflix, saved: .chromium) == .chromium)
        #expect(BrowserProtectedStreamingSites.engine(for: example, saved: .webKit) == .webKit)
        #expect(BrowserProtectedStreamingSites.savedChoice(.webKit, for: netflix) == nil)
        #expect(BrowserProtectedStreamingSites.savedChoice(.chromium, for: netflix) == .chromium)
        #expect(BrowserProtectedStreamingSites.savedChoice(.chromium, for: example) == nil)
        #expect(BrowserProtectedStreamingSites.savedChoice(.webKit, for: example) == .webKit)
        // Non-web pages never leave Chromium, whatever was saved.
        #expect(BrowserProtectedStreamingSites.engine(for: URL(string: "about:blank"), saved: .webKit) == .chromium)
    }

    @Test("The per-host choice persists per profile and host, and an unknown value reads as automatic")
    func persistence() throws {
        let root = URL(fileURLWithPath: "/private/tmp/site-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preferences.json")
        let profile = ProfileID(), other = ProfileID()
        let netflix = URL(string: "https://www.netflix.com/title/1")!
        let example = URL(string: "https://example.test/watch")!
        let store = try BrowserSitePreferenceStore(destination: file)
        #expect(store.siteEngine(for: netflix, profileID: profile) == .webKit)
        try store.setSiteEngine(.chromium, for: netflix, profileID: profile)
        try store.setSiteEngine(.webKit, for: example, profileID: profile)
        let reopened = try BrowserSitePreferenceStore(destination: file)
        #expect(reopened.siteEngine(for: netflix, profileID: profile) == .chromium)
        #expect(reopened.siteEngine(for: example, profileID: profile) == .webKit)
        #expect(reopened.siteEngine(for: URL(string: "https://example.test/other")!, profileID: profile) == .webKit)
        #expect(reopened.siteEngine(for: URL(string: "https://other.example.test")!, profileID: profile) == .chromium)
        #expect(reopened.siteEngine(for: netflix, profileID: other) == .webKit)
        // Going back to the default clears the saved value.
        try reopened.setSiteEngine(.webKit, for: netflix, profileID: profile)
        #expect(reopened.preferences(url: netflix, profileID: profile).siteEngine == nil)

        let future = Data(#"{"developerMode":true,"siteEngine":"gecko"}"#.utf8)
        let decoded = try JSONDecoder().decode(BrowserSitePreferences.self, from: future)
        #expect(decoded.siteEngine == nil)
        #expect(decoded.developerMode)
        let legacy = try JSONDecoder().decode(BrowserSitePreferences.self, from: Data("{}".utf8))
        #expect(legacy.siteEngine == nil)
    }
}
