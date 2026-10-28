import BrowserCore
import Foundation
import Darwin
import Testing

@Suite("Automatic video window settings")
struct AutomaticPictureInPictureSettingsTests {
    @Test func defaultsMigrationAndPersistence() async throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("media-pip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let store = try BrowserSettingsStore(destination: file)
        #expect(await store.snapshot().automaticPictureInPicture)
        try await store.setAutomaticPictureInPicture(false)
        try await store.setMemorySaver(.never)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().automaticPictureInPicture == false)
        #expect(await reopened.snapshot().memorySaver == .never)
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy.removeValue(forKey: "automaticPictureInPicture")
        let bytes = try JSONSerialization.data(withJSONObject: legacy)
        try bytes.write(to: file)
        let migrated = try BrowserSettingsStore(destination: file)
        #expect(await migrated.snapshot().automaticPictureInPicture)
        #expect(try Data(contentsOf: file) == bytes)
    }
}
