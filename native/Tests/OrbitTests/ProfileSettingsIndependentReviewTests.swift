import BrowserCore
import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Independent profile settings review", .serialized)
@MainActor
struct ProfileSettingsIndependentReviewTests {
    private func destination() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-profile-review-\(UUID())", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test("A read-dependent edit uses durable current fields and publishes the complete saved document")
    func readDependentEditAndPublication() async throws {
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: file)
        let runtime = BrowserSettingsRuntime(store: store)
        let target = ProfileID(), other = ProfileID(), space = SpaceID()
        var current = BrowserProfileSettings()
        current.searchEngine = .bing
        current.opensPinnedLinksInPeek = false
        try await store.setProfile(current, for: target)
        try await store.setProfile(current, for: other)
        var appearance = BrowserSpaceSettings()
        appearance.icon = "R"
        appearance.palette = .lavender
        try await store.setSpace(appearance, for: space)
        try await store.setOpensExternalLinksInQuickWindow(false)
        var expected = await store.snapshot()
        current.opensPinnedLinksInPeek = true
        current.shiftClickOpensPeek = false
        expected.profiles[target] = current
        var publications: [BrowserSettingsDocument] = []
        runtime.onChange = {
            publications.append(runtime.document)
            // The callback must observe bytes already committed, not an optimistic form.
            let disk = try? Data(contentsOf: file)
            let saved = disk.flatMap { try? JSONDecoder().decode(BrowserSettingsDocument.self, from: $0) }
            #expect(saved == runtime.document)
        }
        defer { runtime.onChange = nil }

        try await runtime.updateProfile(target) {
            let previousPinned = $0.opensPinnedLinksInPeek
            $0.opensPinnedLinksInPeek = $0.shiftClickOpensPeek
            $0.shiftClickOpensPeek = previousPinned
        }

        #expect(publications == [expected])
        #expect(await store.snapshot() == expected)
        #expect(try await BrowserSettingsStore(destination: file).snapshot() == expected)
    }

    @Test("Overlapping edits on one runtime use each preceding actor mutation")
    func overlappingReadDependentEdits() async throws {
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: file)
        let runtime = BrowserSettingsRuntime(store: store)
        let target = ProfileID()
        // Both tasks are accepted before awaiting either. Whichever edit runs first,
        // the second must read its result; two false fields are never a serial outcome.
        let first = Task {
            try await runtime.updateProfile(target) { $0.opensPinnedLinksInPeek = !$0.shiftClickOpensPeek }
        }
        let second = Task {
            try await runtime.updateProfile(target) { $0.shiftClickOpensPeek = !$0.opensPinnedLinksInPeek }
        }
        try await first.value
        try await second.value
        let saved = try await BrowserSettingsStore(destination: file).snapshot()
        #expect(saved.profile(target).opensPinnedLinksInPeek != saved.profile(target).shiftClickOpensPeek)
        #expect(saved.profile(target).searchEngine == .google)
        await runtime.refresh()
        #expect(runtime.document == saved)
    }

    @Test("A refused file replacement refreshes stale UI without publishing the edit and permits a safe retry")
    func refusedWriteRefreshAndRetry() async throws {
        let file = destination()
        let sentinel = file.deletingLastPathComponent().appendingPathComponent("untouched.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: file)
        let runtime = BrowserSettingsRuntime(store: store)
        let target = ProfileID(), other = ProfileID()
        var current = BrowserProfileSettings()
        current.searchEngine = .duckDuckGo
        current.opensPinnedLinksInPeek = false
        try await store.setProfile(current, for: target)
        try await store.setProfile(current, for: other)
        let before = await store.snapshot()
        let originalBytes = try Data(contentsOf: file)
        try FileManager.default.moveItem(at: file, to: sentinel)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel)
        var publications: [BrowserSettingsDocument] = []
        runtime.onChange = { publications.append(runtime.document) }
        defer { runtime.onChange = nil }

        await #expect(throws: (any Error).self) {
            try await runtime.updateProfile(target) { $0.shiftClickOpensPeek = false }
        }

        #expect(await store.snapshot() == before)
        #expect(runtime.document == before)
        #expect(publications == [before])
        #expect(try Data(contentsOf: sentinel) == originalBytes)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == sentinel.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: sentinel, to: file)
        try await runtime.updateProfile(target) { $0.shiftClickOpensPeek = false }
        var expected = before
        current.shiftClickOpensPeek = false
        expected.profiles[target] = current
        #expect(publications == [before, expected])
        #expect(try await BrowserSettingsStore(destination: file).snapshot() == expected)
    }
}
}
