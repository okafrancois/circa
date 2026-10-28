import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Fresh R2 draft boundary review")
struct OrbitSecondaryR2FreshReviewTests {
    @Test("Extreme and mistyped draft members recover through a normal browser preference write")
    func recoveredDraftSurvivesCoreWrite() async throws {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("OrbitR2Fresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let profile = ProfileID(), other = ProfileID(), space = SpaceID()
        var expected = BrowserSettingsDocument()
        expected.reducedMotion = .full
        expected.opensExternalLinksInQuickWindow = false
        expected.lastActiveWindowID = WindowID()
        expected.lastActiveSpaceID = space
        var preferences = BrowserProfileSettings()
        preferences.searchEngine = .bing
        preferences.opensPinnedLinksInPeek = false
        preferences.shiftClickOpensPeek = false
        expected.profiles[profile] = preferences
        expected.profiles[other] = .init()
        var palette = BrowserSpaceSettings()
        palette.icon = "X"
        palette.palette = .limeCitrus
        expected.spaces[space] = palette
        let encoded = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        // Overflowing JSON numbers cannot be represented as finite Double; strings are not coerced.
        for fragment in [#"{"material":"liquidGlass","transparency":1e400}"#,
                         #"{"material":"liquidGlass","transparency":true}"#,
                         #"{"material":"liquidGlass","transparency":{}}"#,
                         #"{"material":"liquidGlass","transparency":"NaN"}"#] {
            var object = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
            object.removeValue(forKey: "secondaryAppearanceDraft")
            let base = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let bytes = Data((String(base.dropLast()) + ",\"secondaryAppearanceDraft\":" + fragment + "}").utf8)
            try bytes.write(to: file)
            let store = try BrowserSettingsStore(destination: file)
            expected.secondaryAppearanceDraft.material = .liquidGlass
            #expect(await store.snapshot() == expected)
            #expect(try Data(contentsOf: file) == bytes)
            var updated = preferences
            updated.searchEngine = .duckDuckGo
            try await store.setProfile(updated, for: profile)
            var after = expected
            after.profiles[profile] = updated
            #expect(try await BrowserSettingsStore(destination: file).snapshot() == after)
        }
    }

    @Test("A non-finite Double decoder strategy still recovers only the draft member")
    func nonFiniteDecoder() throws {
        var draft = BrowserSecondaryAppearanceDraft()
        draft.material = .frosted
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        for value in ["Infinity", "-Infinity", "NaN"] {
            let decoded = try decoder.decode(BrowserSecondaryAppearanceDraft.self,
                from: Data(("{\"material\":\"frosted\",\"transparency\":\"" + value + "\"}").utf8))
            #expect(decoded == draft)
        }
    }
}
