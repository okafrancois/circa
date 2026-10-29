import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Opaque theme migration")
struct ThemeCleanupMigrationTests {
    static let legacySurfaces = [
        #"{"material":"solid","transparency":0.25}"#,
        #"{"material":"frosted","transparency":0.73}"#,
        #"{"material":"liquidGlass","transparency":0.99}"#,
        #"{"material":"future","transparency":"invalid"}"#,
        "null"
    ]

    @Test("Legacy materials never discard colors, intensity, grain, mode or painted gradients", arguments: legacySurfaces)
    func themeMigration(surface: String) async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Strong theme", profileID: profile)
        let original = BrowserSpaceTheme.composed(colors: [.init(hex: 0xff3300), .init(hex: 0x1133ee)],
                                                   intensity: 0.91, noise: 0.67, mode: .light)
        try await store.setSpaceTheme(original, for: space)
        let before = await store.sessionDocument()
        var json = try #require(JSONSerialization.jsonObject(with: before.encoded()) as? [String: Any])
        var spaces = try #require(json["spaces"] as? [[String: Any]])
        var theme = try #require(spaces[0]["theme"] as? [String: Any])
        theme["surface"] = try JSONSerialization.jsonObject(with: Data(surface.utf8), options: .fragmentsAllowed)
        // Older top-level members are also ignored, without validating retired values.
        theme["material"] = "frosted"
        theme["transparency"] = 0.65
        spaces[0]["theme"] = theme
        json["spaces"] = spaces
        let restored = try BrowserSessionDocument.decode(JSONSerialization.data(withJSONObject: json))
        #expect(restored == before)
        #expect(restored.spaces.first?.theme == original)
        let newJSON = String(decoding: try restored.encoded(), as: UTF8.self)
        #expect(!newJSON.contains("surface"))
        #expect(!newJSON.contains("material"))
        #expect(!newJSON.contains("transparency"))
        #expect(try BrowserSessionDocument.decode(restored.encoded()) == before)

        // The sync record contains a theme JSON value; old values must materialize normally.
        var projection = try BrowserSyncMapping.project(session: before, settings: .init())
        let key = BrowserSyncMapping.id("space", space.rawValue)
        projection.entries[key]?["theme"] = try JSONSerialization.data(withJSONObject: theme)
        var replica = BrowserSyncReplica()
        try replica.capture(projection)
        let wire = try BrowserSyncReplica.encodeValue(replica)
        let decoded = try JSONDecoder().decode(BrowserSyncReplica.self, from: wire)
        let mapped = try BrowserSyncMapping.materialize(decoded.visible, local: before, settings: .init())
        #expect(mapped.spaces.first?.theme == original)
        try await store.applySync(mapped, expected: before)
        let clean = try BrowserSyncMapping.project(session: await store.sessionDocument(), settings: mapped.settings)
        let cleanTheme = try #require(clean.entries[key]?["theme"])
        #expect(try JSONDecoder().decode(BrowserSpaceTheme.self, from: cleanTheme) == original)
        let text = String(decoding: cleanTheme, as: UTF8.self)
        #expect(!text.contains("material") && !text.contains("transparency") && !text.contains("surface"))
    }

    @Test("Legacy settings drafts load without rewriting and disappear on the next settings save", arguments: legacySurfaces)
    func settingsMigration(surface: String) async throws {
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("ThemeCleanup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        var expected = BrowserSettingsDocument()
        let profile = ProfileID(), space = SpaceID()
        expected.profiles[profile] = .init()
        expected.profiles[profile]?.searchEngine = .bing
        expected.spaces[space] = .init()
        expected.spaces[space]?.palette = .rosePlum
        expected.reducedMotion = .reduce
        expected.memorySaver = .never
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        json["secondaryAppearanceDraft"] = try JSONSerialization.jsonObject(with: Data(surface.utf8), options: .fragmentsAllowed)
        let oldBytes = try JSONSerialization.data(withJSONObject: json)
        try oldBytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let settings = try BrowserSettingsStore(destination: url)
        #expect(await settings.snapshot() == expected)
        #expect(try Data(contentsOf: url) == oldBytes)
        try await settings.setReducedMotion(.full)
        expected.reducedMotion = .full
        let reopened = try BrowserSettingsStore(destination: url)
        #expect(await reopened.snapshot() == expected)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("secondaryAppearanceDraft") && !text.contains("material") && !text.contains("transparency"))
    }
}
