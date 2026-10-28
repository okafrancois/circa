import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Secondary draft member recovery")
struct BrowserSecondaryDraftRecoveryTests {
    private func temporaryRoot() -> URL {
        let path = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    @Test("Malformed optional drafts recover member by member without losing any known browser preference",
          arguments: [
            (#"{"material":"future","transparency":0.6}"#, "solid", 0.6),
            (#"{"transparency":0.7}"#, "solid", 0.7),
            (#"{"material":"liquidGlass"}"#, "liquidGlass", 0.25),
            (#"{"material":42,"transparency":0.8}"#, "solid", 0.8),
            (#"{"material":"frosted","transparency":"opaque"}"#, "frosted", 0.25),
            (#"{"material":"frosted","transparency":-0.1}"#, "frosted", 0.25),
            (#"{"material":"liquidGlass","transparency":1.1}"#, "liquidGlass", 0.25),
            (#"{"material":null,"transparency":null}"#, "solid", 0.25),
            (#"{}"#, "solid", 0.25),
            (#"null"#, "solid", 0.25),
            (#"[]"#, "solid", 0.25),
            (#""draft""#, "solid", 0.25),
            (#"true"#, "solid", 0.25)
          ])
    func memberRecovery(_ input: (String, String, Double)) async throws {
        let root = temporaryRoot()
            .appendingPathComponent("OrbitDraftRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        var expected = BrowserSettingsDocument()
        expected.reducedMotion = .full
        expected.opensExternalLinksInQuickWindow = false
        expected.lastActiveWindowID = WindowID()
        expected.lastActiveSpaceID = SpaceID()
        let profile = ProfileID(), space = SpaceID()
        var profileSettings = BrowserProfileSettings()
        profileSettings.searchEngine = .duckDuckGo
        profileSettings.opensPinnedLinksInPeek = false
        profileSettings.shiftClickOpensPeek = false
        expected.profiles[profile] = profileSettings
        var spaceSettings = BrowserSpaceSettings()
        spaceSettings.icon = "X"
        spaceSettings.palette = .rosePlum
        expected.spaces[space] = spaceSettings
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        object["secondaryAppearanceDraft"] = try JSONSerialization.jsonObject(with: Data(input.0.utf8), options: .fragmentsAllowed)
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: file)
        let store = try BrowserSettingsStore(destination: file)
        expected.secondaryAppearanceDraft.material = try #require(.init(rawValue: input.1))
        expected.secondaryAppearanceDraft.transparency = input.2
        #expect(await store.snapshot() == expected)
        #expect(try Data(contentsOf: file) == bytes)
        try await store.setSecondaryAppearanceDraft(expected.secondaryAppearanceDraft)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot() == expected)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // Write-time validation is strict even though optional draft reads are tolerant.
        var invalid = expected.secondaryAppearanceDraft
        invalid.transparency = 2
        let savedBytes = try Data(contentsOf: file)
        await #expect(throws: BrowserSettingsError.invalidSecondaryAppearanceDraft) { try await store.setSecondaryAppearanceDraft(invalid) }
        #expect(await store.snapshot() == expected)
        #expect(try Data(contentsOf: file) == savedBytes)
    }

    @Test("Existing version-zero and version-one files without drafts stay unchanged on load and round-trip known preferences", arguments: [0, 1])
    func absentDraftCompatibility(_ version: Int) async throws {
        let root = temporaryRoot().appendingPathComponent("OrbitAbsentDraft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        var expected = BrowserSettingsDocument()
        expected.reducedMotion = .reduce
        var profile = BrowserProfileSettings()
        profile.searchEngine = .bing
        profile.opensPinnedLinksInPeek = false
        profile.shiftClickOpensPeek = false
        expected.profiles[ProfileID()] = profile
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        object.removeValue(forKey: "secondaryAppearanceDraft")
        object["version"] = version
        if version == 0 {
            object.removeValue(forKey: "reducedMotion")
            object["reduceMotion"] = true
        }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        try bytes.write(to: file)
        let store = try BrowserSettingsStore(destination: file)
        #expect(await store.snapshot() == expected)
        #expect(try Data(contentsOf: file) == bytes)
        try await store.setSecondaryAppearanceDraft(.init())
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot() == expected)
    }

    @Test("Draft recovery does not swallow invalid core preferences or unsupported versions")
    func coreRemainsStrict() throws {
        for core in [#""reducedMotion":"unknown""#, #""profiles":"invalid""#, #""spaces":false"#, #""opensExternalLinksInQuickWindow":42"#, #""version":99"#] {
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserSettingsDocument())) as? [String: Any])
            let replacement = try #require(JSONSerialization.jsonObject(with: Data(("{" + core + "}").utf8)) as? [String: Any])
            object.merge(replacement) { _, new in new }
            object["secondaryAppearanceDraft"] = ["material": "future"]
            let bytes = try JSONSerialization.data(withJSONObject: object)
            let root = temporaryRoot().appendingPathComponent("OrbitStrictCore-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("settings.json")
            try bytes.write(to: file)
            if replacement["version"] != nil {
                #expect(throws: BrowserSettingsError.unsupportedVersion) { try BrowserSettingsStore(destination: file) }
            } else {
                #expect(throws: DecodingError.self) { try BrowserSettingsStore(destination: file) }
            }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
}
