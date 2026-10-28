import BrowserCore
import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Daily UI Space mutation R2", .serialized)
@MainActor
struct DailyUIFixR2Tests {
    @Test("Independent runtimes sharing one durable settings actor preserve concurrent fields after reopening")
    func sharedActorAndReopen() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-space-mutations-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("settings.json")
        let store = try BrowserSettingsStore(destination: destination)
        let first = BrowserSettingsRuntime(store: store)
        let second = BrowserSettingsRuntime(store: store)
        let id = SpaceID(), unrelated = SpaceID()
        let color = Task { try await first.updateSpace(id) { $0.palette = .lavender } }
        let icon = Task { try await second.updateSpace(id) { $0.icon = "🧪" } }
        try await color.value
        try await icon.value
        let reopened = try BrowserSettingsStore(destination: destination)
        let saved = await reopened.snapshot()
        #expect(saved.space(id).palette == .lavender)
        #expect(saved.space(id).icon == "🧪")
        #expect(saved.space(unrelated) == BrowserSpaceSettings())
    }

    @Test("A stale published runtime can explicitly clear an icon without resetting newer fields")
    func explicitClearAndFailedMutation() async throws {
        let store = try BrowserSettingsStore()
        let stale = BrowserSettingsRuntime(store: store)
        let id = SpaceID()
        try await store.updateSpace(id) { $0.icon = "🧪"; $0.palette = .rosePlum }
        #expect(stale.document.space(id).icon.isEmpty)
        try await stale.updateSpace(id) { $0.icon = "" }
        let cleared = await store.snapshot().space(id)
        #expect(cleared.icon.isEmpty && cleared.palette == .rosePlum)
        await #expect(throws: BrowserSettingsError.invalidIcon) {
            try await stale.updateSpace(id) { $0.icon = "\n"; $0.palette = .automatic }
        }
        #expect(await store.snapshot().space(id) == cleared)
        try await stale.updateSpace(id) { $0.icon = "👩🏽‍💻" }
        #expect(await store.snapshot().space(id).palette == .rosePlum)
        #expect(await store.snapshot().space(id).icon == "👩🏽‍💻")
    }
}
}
