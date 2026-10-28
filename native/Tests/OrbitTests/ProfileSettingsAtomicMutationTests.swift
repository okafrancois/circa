import BrowserCore
import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Atomic profile settings edits", .serialized)
@MainActor
struct ProfileSettingsAtomicMutationTests {
    private func destination() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-profile-settings-\(UUID())", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test("A stale runtime changes one field without restoring older profile preferences")
    func staleRuntimePreservesOtherFields() async throws {
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: file)
        let runtime = BrowserSettingsRuntime(store: store)
        let target = ProfileID(), other = ProfileID()
        var latest = BrowserProfileSettings()
        latest.searchEngine = .duckDuckGo
        latest.opensPinnedLinksInPeek = false
        try await store.setProfile(latest, for: target)
        var unrelated = BrowserProfileSettings()
        unrelated.searchEngine = .bing
        try await store.setProfile(unrelated, for: other)

        try await runtime.updateProfile(target) { $0.shiftClickOpensPeek = false }

        let reopened = try BrowserSettingsStore(destination: file)
        let saved = await reopened.snapshot()
        #expect(saved.profile(target).searchEngine == .duckDuckGo)
        #expect(!saved.profile(target).opensPinnedLinksInPeek)
        #expect(!saved.profile(target).shiftClickOpensPeek)
        #expect(saved.profile(other) == unrelated)
        #expect(runtime.document == saved)
    }

    @Test("Independent runtime edits compose durably across three profile fields")
    func independentRuntimeEdits() async throws {
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: file)
        let search = BrowserSettingsRuntime(store: store)
        let pinned = BrowserSettingsRuntime(store: store)
        let shifted = BrowserSettingsRuntime(store: store)
        let target = ProfileID()
        let first = Task { try await search.updateProfile(target) { $0.searchEngine = .bing } }
        let second = Task { try await pinned.updateProfile(target) { $0.opensPinnedLinksInPeek = false } }
        let third = Task { try await shifted.updateProfile(target) { $0.shiftClickOpensPeek = false } }
        try await first.value
        try await second.value
        try await third.value

        let reopened = try BrowserSettingsStore(destination: file)
        let saved = await reopened.snapshot().profile(target)
        #expect(saved.searchEngine == .bing)
        #expect(!saved.opensPinnedLinksInPeek)
        #expect(!saved.shiftClickOpensPeek)
    }

    @Test("An explicit reset preserves other newer fields and unavailable writes never publish")
    func resetAndUnavailableWrite() async throws {
        let store = try BrowserSettingsStore()
        let stale = BrowserSettingsRuntime(store: store)
        let target = ProfileID()
        var current = BrowserProfileSettings()
        current.searchEngine = .bing
        current.opensPinnedLinksInPeek = false
        current.shiftClickOpensPeek = false
        try await store.setProfile(current, for: target)
        try await stale.updateProfile(target) { $0.searchEngine = .google }
        let saved = await store.snapshot().profile(target)
        #expect(saved.searchEngine == .google)
        #expect(!saved.opensPinnedLinksInPeek)
        #expect(!saved.shiftClickOpensPeek)

        let unavailable = BrowserSettingsStore.unavailable()
        let refused = BrowserSettingsRuntime(store: unavailable)
        await #expect(throws: BrowserSettingsError.unavailable) {
            try await refused.updateProfile(target) { $0.searchEngine = .bing }
        }
        #expect(refused.document == BrowserSettingsDocument())
        #expect(await unavailable.snapshot() == BrowserSettingsDocument())
    }
}
}
