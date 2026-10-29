import BrowserCore
import Darwin
import Foundation
import Testing

@Suite("Memory Saver settings migration and persistence")
struct PerfMemorySettingsTests {
    @Test func newDefault() throws {
        #expect(BrowserSettingsDocument().memorySaver == .oneHour)
        #expect(BrowserMemorySaverSetting.oneHour.interval == 3600)
    }

    @Test("Legacy choices migrate once and later explicit choices survive",
          arguments: BrowserMemorySaverSetting.allCases)
    func legacyChoice(_ choice: BrowserMemorySaverSetting) async throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("settings.json")
        var legacy = BrowserSettingsDocument()
        legacy.version = 1
        legacy.memorySaver = choice
        legacy.reducedMotion = .reduce
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: file)
        let store = try BrowserSettingsStore(destination: file)
        #expect(await store.snapshot().memorySaver == (choice == .fourHours ? .oneHour : choice))
        #expect(await store.snapshot().version == BrowserSettingsDocument.currentVersion)
        #expect(try Data(contentsOf: file) == original, "Loading does not rewrite preferences")
        try await store.setReducedMotion(.full)
        let saved = try JSONDecoder().decode(BrowserSettingsDocument.self, from: Data(contentsOf: file))
        #expect(saved.version == BrowserSettingsDocument.currentVersion)
        try await store.setMemorySaver(choice)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().memorySaver == choice)
    }

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
        old["version"] = 1
        old.removeValue(forKey: "memorySaver")
        try JSONSerialization.data(withJSONObject: old).write(to: file)
        let migrated = try BrowserSettingsStore(destination: file)
        #expect(await migrated.snapshot().memorySaver == .oneHour)
        try await migrated.setMemorySaver(.never)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().memorySaver == .never)
        #expect(await reopened.snapshot().reducedMotion == .reduce)
        #expect(BrowserMemorySaverSetting.never.interval == nil)
        #expect(BrowserMemorySaverSetting.fiveMinutes.interval == 300)
    }
}
