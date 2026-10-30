import Darwin
import Foundation
import Testing
@testable import BrowserCore

struct SettingsUnionRegressionTests {
    @Test("Earlier settings preserve every stored key while new preferences survive successive saves")
    func migrationAndUnion() async throws {
        let canonical = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("settings-union-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let profile = ProfileID(), space = SpaceID(), window = WindowID()
        var earlier = BrowserSettingsDocument()
        earlier.reducedMotion = .reduce
        earlier.interaction.warnBeforeQuitting = false
        earlier.interaction.playSoundEffects = false
        earlier.downloads.asksWhereToSave = true
        earlier.downloads.folderPath = root.appendingPathComponent("Downloads").path
        earlier.memorySaver = .fourHours
        earlier.automaticPictureInPicture = false
        earlier.enablesBoostsOnWebsites = false
        earlier.hasSeenBoostsIntroduction = true
        earlier.opensExternalLinksInQuickWindow = false
        earlier.lastActiveWindowID = window
        earlier.lastActiveSpaceID = space
        earlier.profiles[profile] = .init()
        earlier.profiles[profile]?.searchEngine = .duckDuckGo
        earlier.profiles[profile]?.opensPinnedLinksInPeek = false
        earlier.spaces[space] = .init()
        earlier.spaces[space]?.icon = "🧪"
        // These are the additive keys absent from the earlier version-two schema.
        let additions = ["siteSearches", "safeBrowsingEnabled", "quickWindowArchiveThreshold", "quickWindowProfilesByDomain"]
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(earlier)) as? [String: Any])
        for key in additions { old.removeValue(forKey: key) }
        let oldData = try JSONSerialization.data(withJSONObject: old, options: .sortedKeys)
        try oldData.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = try BrowserSettingsStore(destination: url)
        #expect(await store.snapshot() == earlier)
        #expect(try Data(contentsOf: url) == oldData)
        try await store.setSafeBrowsingEnabled(true)
        let entry = BrowserSiteSearch(name: "Synthetic Search", shortcut: "fixture", template: "https://search.invalid/?q=%s")
        try await store.saveSiteSearch(entry)
        try await store.setQuickWindowArchiveThreshold(.never)
        try await store.rememberQuickWindowProfile(for: URL(string: "https://synthetic.invalid/path")!, profileID: profile)
        let reopened = try BrowserSettingsStore(destination: url)
        let saved = await reopened.snapshot()
        #expect(saved.safeBrowsingEnabled && saved.siteSearches.contains(entry))
        #expect(saved.quickWindowArchiveThreshold == .never && saved.quickWindowProfilesByDomain["synthetic.invalid"] == profile)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for (key, value) in old {
            #expect(NSDictionary(dictionary: [key: value]).isEqual(to: [key: try #require(object[key])]))
        }
        for key in additions { #expect(object[key] != nil) }
        try await reopened.setSafeBrowsingEnabled(false)
        let final = try BrowserSettingsStore(destination: url)
        #expect(await final.snapshot().siteSearches == saved.siteSearches)
        #expect(await final.snapshot().quickWindowArchiveThreshold == saved.quickWindowArchiveThreshold)
        #expect(await final.snapshot().quickWindowProfilesByDomain == saved.quickWindowProfilesByDomain)
    }
}
