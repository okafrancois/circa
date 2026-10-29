@testable import BrowserCore
import Foundation
import Testing

@Suite("Palette history semantics", .serialized)
struct PaletteHistoryTests {
    @Test("Multiple terms match across URL and title; decoded Unicode and www prefix match")
    func semantics() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-palette-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let url = URL(string: "https://www.xn--bcher-kva.test/caf%C3%A9/read%20me")!
        try await store.record(.init(url: url, title: "Reference manual Swift", typedCount: 2))
        try await store.record(.init(url: URL(string: "https://other.test/concatenate")!, title: "Letters"))
        #expect(try await store.suggestions("swift reference").map(\.url) == [url])
        #expect(try await store.suggestions("bücher café").map(\.url) == [url])
        #expect(try await store.suggestions("bücher", mode: .prefix).map(\.url) == [url])
        #expect(try await store.suggestions("www.bücher", mode: .prefix).map(\.url) == [url])
        #expect(try await store.suggestions("read%20me").map(\.url) == [url])
        #expect(try await store.suggestions("reference missing").isEmpty)
        #expect(BrowserSuggestionText.displayURL(url).contains("bücher.test/café/read me"))
        #expect(try await store.delete(.site("www.bücher.test")) == 1)
        try await store.close()
    }

    @Test("Host and word-start quality outrank substring matches before frecency ties")
    func quality() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-palette-quality-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserHistoryStore(profileID: ProfileID(), policy: .persistent, directory: root)
        let urls = ["https://cat.test/", "https://animal.test/", "https://other.test/concatenate"]
        for (index, url) in urls.enumerated() {
            try await store.record(.init(url: URL(string: url)!, title: index == 1 ? "A-cat handbook" : "Reference", typedCount: index * 2))
        }
        #expect(try await store.suggestions("cat").map { $0.url.absoluteString } == urls)
        #expect(try await store.suggestions("cat", mode: .prefix).count == 2)
        try await store.close()
    }
    @Test("Version two normalization migrates once and retains visits, identities and typed counts")
    func migrationFromTwo() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-palette-v2-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let visit = BrowserHistoryVisit(url: URL(string: "https://www.xn--bcher-kva.test/caf%C3%A9")!, title: "Synthetic guide", typedCount: 3)
        try await store.record(visit)
        try await store.close()
        let raw = try HistoryDatabase(url: root.appendingPathComponent(profile.rawValue.uuidString).appendingPathComponent("history.sqlite"), profileID: profile)
        try raw.discardSyncSchemaForLegacyFixture()
        for statement in ["DROP TRIGGER titleWords_insert", "DROP TRIGGER titleWords_delete", "DROP TRIGGER titleWords_update", "DROP TABLE titleWords",
                          "UPDATE pages SET searchURL='www.xn--bcher-kva.test/caf%C3%A9'", "UPDATE identity SET version=2", "PRAGMA user_version=2"] {
            try raw.execute(statement)
        }
        try raw.close()
        let migrated = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        #expect(try await migrated.visits() == [visit])
        #expect(try await migrated.suggestions("bücher café").first?.typedCount == 3)
        #expect(try await migrated.suggestions("guide", mode: .prefix).count == 1)
        try await migrated.close()
    }

}
