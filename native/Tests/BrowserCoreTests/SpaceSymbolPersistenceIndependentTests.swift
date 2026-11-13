import Foundation
import Testing
@testable import BrowserCore

@Suite("Independent Space symbol persistence")
struct SpaceSymbolPersistenceIndependentTests {
    private func file() -> URL {
        URL(fileURLWithPath: "/private/tmp").appendingPathComponent("orbit-independent-symbol-\(UUID())/settings.json")
    }

    @Test("Malformed optional metadata falls back per Space, with original bytes intact until an explicit save")
    func optionalMetadataIsolation() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = SpaceID(), other = SpaceID(), profile = ProfileID()
        var document = BrowserSettingsDocument()
        var first = BrowserSpaceSettings(); first.icon = "🇫🇷"; first.palette = .lavender
        var second = BrowserSpaceSettings(); second.iconSelection = .systemSymbol("star.fill"); second.palette = .rosePlum
        document.spaces[id] = first; document.spaces[other] = second
        var preferences = BrowserProfileSettings(); preferences.searchEngine = .bing
        document.profiles[profile] = preferences
        let original = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        for metadata in ["[]", "true", "1.5", #"{"kind":"future"}"#, #""star/../../file""#, #""star\u0000fill""#, #""stаr.fill""#] {
            let bytes = Data(original.replacingOccurrences(of: #""icon":"🇫🇷""#,
                with: #""icon":"🇫🇷","systemSymbol":\#(metadata),"futureIconPayload":{"v":3}"#).utf8)
            #expect(bytes != Data(original.utf8))
            try bytes.write(to: url)
            let store = try BrowserSettingsStore(destination: url)
            let loaded = await store.snapshot()
            #expect(loaded.space(id) == first && loaded.space(other) == second)
            #expect(loaded.profile(profile) == preferences)
            #expect(try Data(contentsOf: url) == bytes)
            try await store.setReducedMotion(.reduce)
            let reopened = try BrowserSettingsStore(destination: url)
            #expect(await reopened.snapshot().space(id) == first)
            #expect(await reopened.snapshot().space(other) == second)
        }
    }

    @Test("Every explicit invalid choice refuses both memory and disk publication, including replacement of a valid symbol")
    func invalidWritesAreAtomic() async throws {
        let url = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: url), id = SpaceID()
        try await store.updateSpace(id) { $0.iconSelection = .systemSymbol("star.fill"); $0.palette = .limeCitrus }
        let before = await store.snapshot(), bytes = try Data(contentsOf: url)
        let invalid: [BrowserSpaceIcon] = [.grapheme("ab"), .grapheme("\n"),
            .systemSymbol("a\\b"), .systemSymbol("a\0b"), .systemSymbol("a:b"),
            .systemSymbol("a..2"), .systemSymbol("../star"), .systemSymbol("a\u{202e}b"),
            .systemSymbol(String(repeating: "a", count: 97))]
        for choice in invalid {
            #expect(!choice.isValid)
            await #expect(throws: BrowserSettingsError.invalidIcon) {
                try await store.updateSpace(id) { $0.iconSelection = choice; $0.palette = .automatic }
            }
            var replacement = BrowserSpaceSettings(); replacement.iconSelection = choice
            let immutable = replacement
            await #expect(throws: BrowserSettingsError.invalidIcon) { try await store.setSpace(immutable, for: id) }
            #expect(await store.snapshot() == before)
            #expect(try Data(contentsOf: url) == bytes)
        }
        let future = String(repeating: "a", count: 96)
        #expect(BrowserSpaceIcon.systemSymbol(future).isValid)
        try await store.updateSpace(id) { $0.iconSelection = .systemSymbol(future) }
        let reopened = try BrowserSettingsStore(destination: url)
        #expect(await reopened.snapshot().space(id).iconSelection == .systemSymbol(future))
        #expect(await reopened.snapshot().space(id).palette == .limeCitrus)
    }

    @Test("Independent concurrent field edits preserve the symbol, palettes, profiles and unrelated Space")
    func concurrentFields() async throws {
        let store = try BrowserSettingsStore(), one = SpaceID(), two = SpaceID(), profile = ProfileID()
        try await store.updateSpace(one) { $0.iconSelection = .systemSymbol("future.unknown.9") }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await store.updateSpace(one) { $0.palette = .rosePlum } }
            group.addTask { try await store.updateSpace(two) { $0.iconSelection = .grapheme("👨‍👩‍👧‍👦") } }
            group.addTask { try await store.updateProfile(profile) { $0.searchEngine = .duckDuckGo } }
            group.addTask { try await store.setReducedMotion(.reduce) }
            try await group.waitForAll()
        }
        let value = await store.snapshot()
        #expect(value.space(one).iconSelection == .systemSymbol("future.unknown.9"))
        #expect(value.space(one).palette == .rosePlum && value.space(two).iconSelection == .grapheme("👨‍👩‍👧‍👦"))
        #expect(value.profile(profile).searchEngine == .duckDuckGo && value.reducedMotion == .reduce)
    }
}

/// Keep the rejected-write counterexample separate so later invalid cases have a clean control.
@Suite("Independent Space symbol adverse persistence")
struct SpaceSymbolPersistenceAdverseTests {
    @Test("An explicitly invalid empty grapheme must not clear an existing symbol or publish other field edits")
    func emptyGraphemePublication() async throws {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("orbit-empty-grapheme-\(UUID())/settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: url), id = SpaceID()
        try await store.updateSpace(id) { $0.iconSelection = .systemSymbol("star.fill"); $0.palette = .limeCitrus }
        let before = await store.snapshot(), bytes = try Data(contentsOf: url)
        #expect(!BrowserSpaceIcon.grapheme("").isValid)
        await #expect(throws: BrowserSettingsError.invalidIcon) {
            try await store.updateSpace(id) { $0.iconSelection = .grapheme(""); $0.palette = .automatic }
        }
        #expect(await store.snapshot() == before)
        #expect(try Data(contentsOf: url) == bytes)
    }
}
