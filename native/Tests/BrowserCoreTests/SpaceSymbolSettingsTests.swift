import Foundation
import Testing
@testable import BrowserCore

@Suite("Typed Space icon persistence")
struct SpaceSymbolSettingsTests {
    private func location() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-space-symbol-core-\(UUID())", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test("Version zero and legacy version one load without changing a byte")
    func legacyFiles() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = SpaceID(), profile = ProfileID()
        var document = BrowserSettingsDocument()
        var settings = BrowserSpaceSettings(); settings.icon = "👩🏽‍💻"; settings.palette = .rosePlum
        document.spaces[id] = settings
        var profileSettings = BrowserProfileSettings(); profileSettings.searchEngine = .duckDuckGo
        document.profiles[profile] = profileSettings
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for bytes in [Data(#"{ "version": 0, "reduceMotion": true }"#.utf8), try encoder.encode(document)] {
            try bytes.write(to: url)
            let store = try BrowserSettingsStore(destination: url)
            let loaded = await store.snapshot()
            if loaded.spaces[id] != nil {
                #expect(loaded.space(id).iconSelection == .grapheme("👩🏽‍💻"))
                #expect(loaded.space(id).palette == .rosePlum && loaded.profile(profile) == profileSettings)
            } else { #expect(loaded.reducedMotion == .reduce) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test("Symbols reopen, atomic edits retain unrelated fields, and both legacy writes replace them")
    func replacementAndIsolation() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: url)
        let one = SpaceID(), other = SpaceID(), first = ProfileID(), second = ProfileID()
        try await store.updateSpace(one) { $0.palette = .lavender; $0.icon = "🇫🇷" }
        try await store.updateSpace(other) { $0.icon = "🌈"; $0.palette = .limeCitrus }
        try await store.updateProfile(first) { $0.searchEngine = .bing }
        try await store.updateProfile(second) { $0.opensPinnedLinksInPeek = false }
        let before = await store.snapshot()
        try await store.updateSpace(one) { $0.iconSelection = .systemSymbol("briefcase.fill") }
        let reopened = try BrowserSettingsStore(destination: url)
        let symbol = await reopened.snapshot()
        #expect(symbol.space(one).icon.isEmpty)
        #expect(symbol.space(one).iconSelection == .systemSymbol("briefcase.fill"))
        #expect(symbol.space(one).palette == .lavender)
        #expect(symbol.space(other) == before.space(other) && symbol.profiles == before.profiles)
        try await reopened.updateSpace(one) { $0.icon = "👩🏽‍💻" }
        #expect(await reopened.snapshot().space(one).iconSelection == .grapheme("👩🏽‍💻"))
        try await reopened.updateSpace(one) { $0.iconSelection = .systemSymbol("star.fill") }
        try await reopened.updateSpace(one) { $0.icon = "" }
        let cleared = try BrowserSettingsStore(destination: url)
        #expect(await cleared.snapshot().space(one).iconSelection == .none)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("systemSymbol"))
    }

    @Test("Optional future symbol metadata degrades locally without quarantining settings or rewriting load")
    func futureMetadata() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let id = SpaceID()
        var document = BrowserSettingsDocument()
        var value = BrowserSpaceSettings(); value.icon = "🌈"; value.palette = .amberCoral
        document.spaces[id] = value
        let base = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        for metadata in [#"{"kind":"future","value":42}"#, "42", "null", #""../../bad""#, #""star..fill""#] {
            let bytes = Data(base.replacingOccurrences(of: #""icon":"🌈""#, with: #""icon":"🌈","systemSymbol":\#(metadata)"#).utf8)
            #expect(bytes != Data(base.utf8))
            try bytes.write(to: url)
            let store = try BrowserSettingsStore(destination: url)
            #expect(await store.snapshot().space(id) == value)
            #expect(try Data(contentsOf: url) == bytes)
        }
        // An OS-new, well-formed symbol stays typed and survives an unrelated field edit.
        let future = Data(base.replacingOccurrences(of: #""icon":"🌈""#,
            with: #""icon":"🌈","systemSymbol":"future.symbol.2""#).utf8)
        try future.write(to: url)
        let store = try BrowserSettingsStore(destination: url)
        #expect(await store.snapshot().space(id).iconSelection == .systemSymbol("future.symbol.2"))
        #expect(await store.snapshot().space(id).icon.isEmpty)
        #expect(try Data(contentsOf: url) == future)
        try await store.updateSpace(id) { $0.palette = .lavender }
        let reopened = try BrowserSettingsStore(destination: url)
        #expect(await reopened.snapshot().space(id).iconSelection == .systemSymbol("future.symbol.2"))
    }

    @Test("Symbol identifiers are bounded data and invalid writes leave disk and memory unchanged")
    func invalidSelection() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = SpaceID(), store = try BrowserSettingsStore(destination: url)
        try await store.updateSpace(id) { $0.iconSelection = .systemSymbol("star.fill") }
        let bytes = try Data(contentsOf: url)
        for invalid in ["", "Star", ".star", "star.", "star..fill", "a/b", "a\n", "a b", "é", String(repeating: "a", count: 97)] {
            #expect(!BrowserSpaceIcon.isValidSymbolIdentifier(invalid))
            await #expect(throws: BrowserSettingsError.invalidIcon) {
                try await store.updateSpace(id) { $0.iconSelection = .systemSymbol(invalid) }
            }
            #expect(try Data(contentsOf: url) == bytes)
            #expect(await store.snapshot().space(id).iconSelection == .systemSymbol("star.fill"))
        }
        #expect(BrowserSpaceIcon.isValidSymbolIdentifier("person.2.fill"))
    }
}
