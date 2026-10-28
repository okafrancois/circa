import Foundation
import Darwin
import Testing
@testable import BrowserCore

@Suite("Applied Space surface persistence")
struct AppliedThemeSurfaceTests {
    @Test("Surface round-trips with the session and preserves independent Spaces and settings drafts")
    func sessionReload() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let first = try await store.createSpace(name: "Mint", profileID: profile)
        let second = try await store.createSpace(name: "Amber", profileID: profile)
        let original = BrowserSpaceTheme.composed(colors: [.init(hex: 0x22aa99)], intensity: 0.42, noise: 0.12)
        try await store.setSpaceTheme(original, for: first)
        let settings = try BrowserSettingsStore()
        var draft = BrowserSecondaryAppearanceDraft()
        draft.material = .liquidGlass
        draft.transparency = 0.99
        try await settings.setSecondaryAppearanceDraft(draft)
        try await store.setSpaceThemeSurface(for: first, profileID: profile, material: .liquidGlass, transparency: 0.87)
        let document = await store.sessionDocument()
        let canonical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(canonical) }
        let directory = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("Orbit-Applied-Surface-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("session.json")
        try BrowserSessionFileStore().save(document, to: destination)
        let restored = try BrowserStore(restoring: BrowserSessionFileStore().load(from: destination))
        let result = try #require(try await restored.spaceTheme(first))
        #expect(result.surface == BrowserThemeSurface(material: .liquidGlass, transparency: 0.87))
        var colorsOnly = result
        colorsOnly.surface = nil
        #expect(colorsOnly == original)
        #expect(try await restored.spaceTheme(second) == nil)
        #expect(await settings.snapshot().secondaryAppearanceDraft == draft)
        #expect(await restored.sessionDocument() == document)
        var recomposed = result.recomposed(intensity: 0.25)
        #expect(recomposed.surface == result.surface)
        recomposed = result.recomposed(mode: .dark)
        #expect(recomposed.surface == result.surface)
    }

    @Test("Absent applied policy stays absent; strict finite unit interval rejects without mutation")
    func validationAndCompatibility() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Mint", profileID: profile)
        let theme = BrowserSpaceThemePresets.default
        let encoded = try JSONEncoder().encode(theme)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("surface"))
        #expect(try JSONDecoder().decode(BrowserSpaceTheme.self, from: encoded).surface == nil)
        try await store.setSpaceTheme(theme, for: space)
        let before = await store.sessionDocument()
        for value in [-0.00001, 1.00001, Double.nan, .infinity, -.infinity] {
            await #expect(throws: BrowserSessionError.invalidSpaceTheme) {
                try await store.setSpaceThemeSurface(for: space, profileID: profile, transparency: value)
            }
            #expect(await store.sessionDocument() == before)
        }
        for value in [0.0, 1.0] {
            try await store.setSpaceThemeSurface(for: space, profileID: profile, transparency: value)
            #expect(try await store.spaceTheme(space)?.surface?.transparency == value)
        }
    }

    @Test("Queued stale ownership and deleted Spaces cannot change an applied theme")
    func ownership() async throws {
        let store = BrowserStore()
        let first = await store.createProfile(name: "First")
        let second = await store.createProfile(name: "Second")
        let space = try await store.createSpace(name: "Mint", profileID: first)
        try await store.setSpaceThemeSurface(for: space, profileID: first, material: .solid, transparency: 0.25)
        try await store.assignSettingsSpace(space, to: second)
        let before = await store.sessionDocument()
        await #expect(throws: BrowserSpaceThemeError.conflict) {
            try await store.setSpaceThemeSurface(for: space, profileID: first, material: .liquidGlass)
        }
        #expect(await store.sessionDocument() == before)
        await #expect(throws: BrowserStoreError.spaceMissing) {
            try await store.setSpaceThemeSurface(for: SpaceID(), profileID: first, transparency: 0.9)
        }
    }
}
