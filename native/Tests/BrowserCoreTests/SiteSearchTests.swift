import BrowserCore
import Foundation
import Testing

struct SiteSearchTests {
    private func entry(_ shortcut: String = "lab") -> BrowserSiteSearch {
        .init(name: "Synthetic Search", shortcut: shortcut, template: "https://search.example.test/?q=%s")
    }

    @Test("Entries validate names, unique normalized shortcuts and web templates")
    func validation() throws {
        let valid = entry()
        try valid.validate(in: BrowserSiteSearch.builtIns)
        for template in ["javascript:alert('%s')", "data:text/plain,%s", "file:///tmp/%s", "https://example.test/", "https://%s.example.test/", "https://user:pass@example.test/?q=%s", "https://example.test:99999/?q=%s"] {
            var invalid = valid; invalid.template = template
            #expect(throws: BrowserSiteSearchError.invalidTemplate) { try invalid.validate(in: []) }
        }
        for shortcut in ["Google", " https://www.google.com/ ", "twitter.com", "x.com"] {
            #expect(throws: BrowserSiteSearchError.duplicateShortcut) { try entry(shortcut).validate(in: BrowserSiteSearch.builtIns) }
        }
        var empty = valid; empty.name = " "
        #expect(throws: BrowserSiteSearchError.emptyName) { try empty.validate(in: []) }
        empty = valid; empty.shortcut = " "
        #expect(throws: BrowserSiteSearchError.emptyShortcut) { try empty.validate(in: []) }
        var http = valid; http.template = "http://localhost:8080/find/%s#%s"
        try http.validate(in: [])
    }

    @Test("Settings migrate missing registry without writing and persist edits, switches and removal")
    func persistenceAndMigration() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("p2-sitesearch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserSettingsDocument())) as? [String: Any])
        legacy.removeValue(forKey: "siteSearches")
        let original = try JSONSerialization.data(withJSONObject: legacy)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = try BrowserSettingsStore(destination: file)
        #expect(await store.snapshot().siteSearches == BrowserSiteSearch.builtIns)
        #expect(try Data(contentsOf: file) == original)
        var custom = entry()
        try await store.saveSiteSearch(custom)
        custom.name = "Edited"; custom.shortcut = "edited"
        try await store.saveSiteSearch(custom)
        let restored = try BrowserSettingsStore(destination: file)
        #expect(await restored.snapshot().siteSearches.last == custom)
        try await restored.setSiteSearchEnabled(custom.id, false)
        #expect(BrowserSiteSearch.matching("edited", in: await restored.snapshot().siteSearches) == nil)
        let builtIn = BrowserSiteSearch.builtIns[0]
        try await restored.setSiteSearchEnabled(builtIn.id, false)
        #expect(BrowserSiteSearch.matching("google", in: await restored.snapshot().siteSearches) == nil)
        await #expect(throws: BrowserSiteSearchError.builtInRemoval) { try await restored.removeSiteSearch(builtIn.id) }
        try await restored.removeSiteSearch(custom.id)
        #expect(await restored.snapshot().siteSearches.count == BrowserSiteSearch.builtIns.count)
        let final = try BrowserSettingsStore(destination: file)
        #expect(await final.snapshot().siteSearches.first?.isEnabled == false)
    }

    @Test("Rejected duplicate writes preserve the previous persisted registry")
    func rejectedWrite() async throws {
        let store = try BrowserSettingsStore()
        let custom = entry()
        try await store.saveSiteSearch(custom)
        let before = await store.snapshot()
        await #expect(throws: BrowserSiteSearchError.duplicateShortcut) { try await store.saveSiteSearch(entry("LAB")) }
        #expect(await store.snapshot() == before)
    }

    @Test("App-wide entries stay local because the settings sync projection does not carry them")
    func localScope() throws {
        let session = BrowserSessionDocument(profiles: [], spaces: [], windows: [], tabs: [])
        let initial = BrowserSettingsDocument()
        var edited = initial
        edited.siteSearches.append(entry())
        #expect(try BrowserSyncMapping.project(session: session, settings: initial) == BrowserSyncMapping.project(session: session, settings: edited))
    }

    @Test("X replaces the former name while both domains and shortcuts stay recognized")
    func xRecognition() throws {
        #expect(!BrowserSiteSearch.builtIns.contains { $0.name == "Twitter" })
        for keyword in ["x", "x.com", "twitter", "https://www.twitter.com/"] {
            let site = try #require(BrowserSiteSearch.matching(keyword))
            #expect(site.name == "X" && site.url(for: "test")?.host == "x.com")
        }
    }

    @Test("Query, path and fragment substitutions encode spaces, Unicode and separators exactly once")
    func encoding() throws {
        let query = "two words café 猫 & # / + %"
        for template in ["https://example.test/?q=%s", "https://example.test/find/%s", "https://example.test/#%s"] {
            var custom = entry(); custom.template = template
            let url = try #require(custom.url(for: query))
            #expect(url.absoluteString.contains("%20") && url.absoluteString.contains("%26") && url.absoluteString.contains("%23"))
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            if template.contains("?q=") { #expect(parts.queryItems == [URLQueryItem(name: "q", value: query)]) }
            else if template.contains("#") { #expect(parts.fragment == query) }
            else { #expect(parts.path == "/find/" + query) }
        }
    }

    @Test("Perplexity selection survives settings persistence and builds its public query URL")
    func perplexity() async throws {
        let store = try BrowserSettingsStore()
        let profile = ProfileID()
        try await store.updateProfile(profile) { $0.searchEngine = .perplexity }
        let restored = try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONEncoder().encode(await store.snapshot()))
        #expect(restored.profile(profile).searchEngine == .perplexity)
        let query = "space café & #"
        let url = restored.profile(profile).searchEngine.searchURL(for: query)
        #expect(url.host == "www.perplexity.ai" && url.path == "/search")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: query)])
        #expect(SearchEngine.perplexity.suggestionURL(for: query) == nil)
    }
}
