import Darwin
import Foundation
import Testing
@testable import BrowserCore

struct BrowserQuickWindowSettingsTests {
    @Test("Existing v1 settings gain Little Orbit routing without changing profile, Space or motion choices")
    func additiveMigration() throws {
        var document = BrowserSettingsDocument()
        let profile = ProfileID(), space = SpaceID()
        var settings = BrowserProfileSettings()
        settings.searchEngine = .duckDuckGo
        document.profiles[profile] = settings
        document.spaces[space] = .init()
        document.reducedMotion = .reduce
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        object.removeValue(forKey: "opensExternalLinksInQuickWindow")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(BrowserSettingsDocument.self, from: legacy)
        #expect(restored == document)
        #expect(restored.version == BrowserSettingsDocument.currentVersion && restored.opensExternalLinksInQuickWindow)
    }

    @Test("The routing toggle persists and reopens independently of the session document")
    func persistedToggle() async throws {
        let canonical = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true).appendingPathComponent("Orbit-LITTLE-" + UUID().uuidString)
        let destination = root.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserSettingsStore(destination: destination)
        #expect(await store.snapshot().opensExternalLinksInQuickWindow)
        try await store.setOpensExternalLinksInQuickWindow(false)
        let reopened = try BrowserSettingsStore(destination: destination)
        #expect(await !reopened.snapshot().opensExternalLinksInQuickWindow)
        try await reopened.setOpensExternalLinksInQuickWindow(true)
        #expect(try await BrowserSettingsStore(destination: destination).snapshot().opensExternalLinksInQuickWindow)
    }
}
