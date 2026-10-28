import BrowserCore
import Darwin
import Foundation
import Testing

@Suite("Memory Saver settings migration and persistence")
struct PerfMemorySettingsTests {
    @Test func oldSettingsMigrateAndChoiceSurvivesReopen() async throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("settings.json")
        let store = try BrowserSettingsStore(destination: file)
        try await store.setReducedMotion(.reduce)
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        old.removeValue(forKey: "memorySaver")
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        let migrated = try BrowserSettingsStore(destination: file)
        #expect(await migrated.snapshot().memorySaver == .fourHours)
        try await migrated.setMemorySaver(.never)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().memorySaver == .never)
        #expect(await reopened.snapshot().reducedMotion == .reduce)
        #expect(BrowserMemorySaverSetting.never.interval == nil)
        #expect(BrowserMemorySaverSetting.fiveMinutes.interval == 300)
    }
}
