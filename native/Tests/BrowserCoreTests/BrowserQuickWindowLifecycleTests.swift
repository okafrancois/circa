import Foundation
import Darwin
import Testing
@testable import BrowserCore

struct BrowserQuickWindowLifecycleTests {
    @Test("External URL identity folds host, scheme, default port and empty path only")
    func normalizedIdentity() throws {
        func key(_ value: String) -> String { BrowserQuickWindowURL.key(URL(string: value)!) }
        #expect(key("HTTPS://EXAMPLE.test:443") == key("https://example.test/"))
        #expect(key("http://EXAMPLE.test:80/a") == key("http://example.test/a"))
        #expect(key("https://example.test/a") != key("https://example.test/A"))
        #expect(key("https://example.test/?a=1") != key("https://example.test/?a=2"))
        #expect(key("https://example.test/#a") != key("https://example.test/#b"))
        #expect(key("https://example.test:444/") != key("https://example.test/"))
    }

    @Test("Old settings gain a six-hour Little interval and empty domain preferences")
    func migration() throws {
        let original = BrowserSettingsDocument()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "quickWindowArchiveThreshold")
        object.removeValue(forKey: "quickWindowProfilesByDomain")
        let decoded = try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == original)
        #expect(decoded.quickWindowArchiveThreshold.interval == 21600.0)
        #expect(decoded.quickWindowProfilesByDomain.isEmpty)
    }

    @Test("Domain preferences persist only the exact host and profile and disappear with profile removal")
    func preferences() async throws {
        let canonical = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("little-preferences-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let settings = try BrowserSettingsStore(destination: file)
        let profile = ProfileID()
        try await settings.rememberQuickWindowProfile(for: URL(string: "https://EXAMPLE.test:444/private-path?token=synthetic#fragment")!, profileID: profile)
        try await settings.rememberQuickWindowProfile(for: URL(string: "file:///tmp/synthetic")!, profileID: profile)
        try await settings.setQuickWindowArchiveThreshold(.oneHour)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().quickWindowProfilesByDomain == ["example.test": profile])
        #expect(await reopened.snapshot().quickWindowArchiveThreshold == .oneHour)
        let encoded = try String(contentsOf: file, encoding: .utf8)
        #expect(!encoded.contains("private-path") && !encoded.contains("token") && !encoded.contains("fragment"))
        try await reopened.removeProfile(profile, spaces: [])
        #expect(await reopened.snapshot().quickWindowProfilesByDomain.isEmpty)
    }

    @Test("Little preferences never enter the synchronization projection")
    func deviceLocal() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        _ = try await store.createSpace(name: "Synthetic", profileID: profile)
        let session = await store.sessionDocument()
        var settings = BrowserSettingsDocument()
        let before = try BrowserSyncMapping.project(session: session, settings: settings)
        settings.quickWindowProfilesByDomain = ["synthetic.test": profile]
        settings.quickWindowArchiveThreshold = .oneHour
        #expect(try BrowserSyncMapping.project(session: session, settings: settings) == before)
    }

    @Test("Little archive origin and automatic reason survive session persistence; old Today records stay ordinary")
    func archivePersistence() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let tab = BrowserOrganizedTab(id: TabID(), url: URL(string: "https://synthetic.test/archived")!, pageTitle: "Synthetic Little", createdAt: date, lastActiveAt: date)
        try await store.archiveQuickWindow(.init(tab: tab, profileID: profile, spaceID: space, origin: .quickWindow, reason: .automatic, archivedAt: date))
        let data = try await store.sessionDocument().encoded()
        let reopened = try BrowserStore(restoring: BrowserSessionDocument.decode(data))
        let record = try #require(await reopened.sessionDocument().organization.archive.first)
        #expect(record.isLittleWindow && record.reason == .automatic && record.archivedAt == date)
        #expect(record.tab.pageTitle == "Synthetic Little" && record.tab.id == tab.id)
        let old = BrowserArchivedTab(tab: tab, profileID: profile, spaceID: space, origin: .today, reason: .closed, archivedAt: date)
        #expect(try !JSONDecoder().decode(BrowserArchivedTab.self, from: JSONEncoder().encode(old)).isLittleWindow)
    }
}
