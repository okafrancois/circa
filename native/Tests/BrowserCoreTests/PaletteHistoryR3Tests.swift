@testable import BrowserCore
import Foundation
import SQLite3
import Testing

/// Synthetic data only. Never prints titles, URLs, SQL or SQLite messages.
@Suite("Palette R3 history: display escaping and ranked short candidates", .serialized)
struct PaletteHistoryR3Tests {
    @Test("Display escapes only Cc and bidi controls; ZWNJ, ZWJ and soft hyphen stay as text")
    func displayPolicy() {
        let escaped: [UInt32] = [0x0000, 0x000A, 0x001B, 0x007F, 0x0085, 0x061C, 0x200E, 0x200F,
                                 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        for value in escaped {
            let scalar = Unicode.Scalar(value)!
            #expect(BrowserSuggestionText.safeDisplay("a\(Character(scalar))b") == String(format: "a\\u{%04X}b", value), "U+\(String(value, radix: 16))")
        }
        for value: UInt32 in [0x200C, 0x200D, 0x00AD] {
            let text = "a\(Character(Unicode.Scalar(value)!))b"
            #expect(BrowserSuggestionText.safeDisplay(text) == text, "U+\(String(value, radix: 16))")
        }
        #expect(BrowserSuggestionText.safeDisplay("Café résumé") == "Café résumé")
    }

    @Test("Search text is unescaped; only the display form carries escapes")
    func searchTextIsUnescaped() {
        // Persian word with a ZWNJ, then a right-to-left override and a newline.
        let url = URL(string: "https://fa.test/%D9%85%DB%8C%E2%80%8C%D8%AE%D9%88%D8%A7%D9%87%D9%85/%E2%80%AEx%0Ay")!
        let search = BrowserSuggestionText.searchableURL(url)
        #expect(search == "fa.test/می\u{200C}خواهم/\u{202E}x\ny")
        #expect(!search.contains("\\u{"))
        let display = BrowserSuggestionText.displayURL(url)
        #expect(display.contains("می\u{200C}خواهم"))
        #expect(display.contains("\\u{202E}x\\u{000A}y"))
        #expect(!display.contains("\u{202E}"))
        #expect(url.absoluteString.hasSuffix("%E2%80%AEx%0Ay"))
        #expect(BrowserSuggestionText.matches("خواهم", title: "", url: url))
        #expect(!BrowserSuggestionText.matches("u{200c}", title: "", url: url))
    }

    @Test("Pages are indexed and found by their real text, never by display escapes")
    func storeIndexesRealText() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserHistoryStore(profileID: ProfileID(), policy: .persistent, directory: root)
        let url = URL(string: "https://fa.test/%D9%85%DB%8C%E2%80%8C%D8%AE%D9%88%D8%A7%D9%87%D9%85")!
        try await store.record(.init(url: url, title: "Synthetic"))
        #expect(try await store.suggestions("می\u{200C}خواهم").map(\.url) == [url])
        #expect(try await store.suggestions("fa.test/می\u{200C}", mode: .prefix).map(\.url) == [url])
        #expect(try await store.suggestions("u{200c}").isEmpty)
        #expect(try await store.memoryIndex().suggestions("می\u{200C}خواهم").map(\.url) == [url])
        try await store.close()
    }

    @Test("Version three rows indexed with display escapes are renormalized once by the v4 upgrade")
    func upgradeFromThreeRenormalizesEscapedRows() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let affected = [
            URL(string: "https://fa.test/%D9%85%DB%8C%E2%80%8C%D8%AE%D9%88%D8%A7%D9%87%D9%85")!, // ZWNJ
            URL(string: "https://joiner.test/a%E2%80%8Db%C2%ADc")!,                              // ZWJ, soft hyphen
            URL(string: "https://www.bidi.test/%E2%80%AEtxt%0Aline")!,                            // RLO, newline
        ]
        let literal = URL(string: "https://literal.test/%5Cu%7B200c%7D")! // real backslash-u text
        let plain = URL(string: "https://plain.test/page")!
        var visits: [BrowserHistoryVisit] = []
        for (index, url) in (affected + [literal, plain]).enumerated() {
            visits.append(BrowserHistoryVisit(url: url, title: "Synthetic \(index)", typedCount: index % 2))
        }
        _ = try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: visits))
        try await store.close()

        // Recreate the v3 document: the old normalization stored `fold(safeDisplay(...))`, with
        // every Cc and Cf scalar escaped. Updating through the triggers keeps the FTS consistent.
        let file = root.appendingPathComponent(profile.rawValue.uuidString).appendingPathComponent("history.sqlite")
        let raw = try HistoryDatabase(url: file, profileID: profile)
        try raw.discardSyncSchemaForLegacyFixture()
        for url in affected {
            try raw.execute("UPDATE pages SET searchURL=? WHERE url=?", [.text(Self.legacySearchURL(url)), .text(url.absoluteString)])
        }
        try raw.execute("UPDATE identity SET version=3")
        try raw.execute("PRAGMA user_version=3")
        #expect(try raw.scalarInt("SELECT COUNT(*) FROM pages WHERE instr(searchURL,'\\u{')>0") == 4)
        let untouchedRowIDs = try Self.rowIDs(raw)
        try raw.close()

        let migrated = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        #expect(try await migrated.visits(limit: 10).count == visits.count)
        #expect(try await migrated.suggestions("می\u{200C}خواهم").map(\.url) == [affected[0]])
        #expect(try await migrated.suggestions("a\u{200D}b\u{00AD}c").map(\.url) == [affected[1]])
        #expect(try await migrated.suggestions("bidi.test/\u{202E}txt", mode: .prefix).map(\.url) == [affected[2]])
        #expect(try await migrated.suggestions("u{200c}").map(\.url) == [literal])
        #expect(try await migrated.suggestions("u{202e}").isEmpty)
        #expect(try await migrated.suggestions("plain.test/page", mode: .prefix).map(\.url) == [plain])
        #expect(try await migrated.suggestions("synthetic 3").first?.typedCount == 1)
        // Triggers are restored: a later metadata update stays indexed in both FTS tables.
        let visit = try #require(try await migrated.visits(limit: 10).first { $0.url == affected[0] })
        try await migrated.updateMetadata(visitID: visit.id, title: "Renamed after upgrade")
        #expect(try await migrated.suggestions("renamed").map(\.url) == [affected[0]])
        #expect(try await migrated.suggestions("re", limit: 5).map(\.url) == [affected[0]])
        try await migrated.close()

        let inspect = try HistoryDatabase(url: file, profileID: profile)
        #expect(try inspect.scalarInt("PRAGMA user_version") == HistoryDatabase.currentVersion)
        #expect(try inspect.scalarInt("SELECT version FROM identity") == HistoryDatabase.currentVersion)
        #expect(try Self.rowIDs(inspect) == untouchedRowIDs)
        for url in affected + [literal, plain] {
            let statement = try inspect.prepare("SELECT searchURL FROM pages WHERE url=?")
            try inspect.bind(statement, [.text(url.absoluteString)])
            #expect(try inspect.next(statement))
            #expect(inspect.text(statement, 0) == BrowserSuggestionText.searchableURL(url))
            sqlite3_finalize(statement)
        }
        #expect(try inspect.scalarInt("SELECT COUNT(*) FROM pages WHERE instr(searchURL,'\\u{')>0") == 1)
        #expect(try inspect.scalarInt("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('pages_update','titleWords_update')") == 2)
        try inspect.execute("INSERT INTO search(search,rank) VALUES('integrity-check',1)")
        try inspect.execute("INSERT INTO titleWords(titleWords,rank) VALUES('integrity-check',1)")
        try inspect.close()
    }

    @Test("Short-query candidate caps keep the best-ranked pages, not B-tree or rowid order")
    func shortCandidatesFollowRanking() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BrowserHistoryStore(profileID: ProfileID(), policy: .persistent, directory: root)
        let now = Date(timeIntervalSince1970: 5_000_000)
        let filler = BrowserHistoryStore.shortTermCandidates + 200
        // Targets are inserted first (lowest rowids) and sort last in their prefix indexes.
        let hostTarget = URL(string: "https://gz.test/")!
        let titleTarget = URL(string: "https://y.test/")!
        var visits = [
            BrowserHistoryVisit(url: hostTarget, title: "Synthetic", visitedAt: now, typedCount: 6),
            BrowserHistoryVisit(url: titleTarget, title: "Kilo target", visitedAt: now, typedCount: 6),
        ]
        for index in 0..<filler {
            let old = now.addingTimeInterval(-Double(index + 1) * 600)
            visits.append(BrowserHistoryVisit(url: URL(string: "https://g\(index).test/")!, title: "Synthetic", visitedAt: old))
            visits.append(BrowserHistoryVisit(url: URL(string: "https://x\(index).test/")!, title: "Kilo \(index)", visitedAt: old))
        }
        _ = try await store.importDocument(BrowserHistoryDocument(profileID: store.profileID, visits: visits))
        #expect(try await store.suggestions("g", limit: 12, now: now).first?.url == hostTarget)
        #expect(try await store.suggestions("gz", limit: 12, now: now).first?.url == hostTarget)
        #expect(try await store.suggestions("k", limit: 12, now: now).first?.url == titleTarget)
        #expect(try await store.suggestions("ki", limit: 12, now: now).first?.url == titleTarget)
        // A single short term selects exactly the full ranking: SQL equals the complete in-memory
        // ranking over every page (all pages are recent, hence significant).
        let index = try await store.memoryIndex(capacity: 10_000, now: now)
        #expect(index.count == visits.count)
        for query in ["g", "gz", "g1", "k", "ki", "x", "x1"] {
            let sql = try await store.suggestions(query, limit: 50, now: now).map(\.url)
            let memory = index.suggestions(query, limit: 50, now: now).map(\.url)
            #expect(sql == memory, "query length \(query.count)")
        }
        try await store.close()
    }

    // MARK: - Synthetic fixtures

    /// The version three normalization, kept for building legacy documents.
    private static func legacySearchURL(_ url: URL) -> String {
        let readable = BrowserSuggestionText.readableURL(url)
        let escaped = readable.unicodeScalars.map { scalar -> String in
            let value = scalar.value
            if CharacterSet.controlCharacters.contains(scalar) || (0x202A...0x202E).contains(value)
                || (0x2066...0x2069).contains(value) || [0x061C, 0x200E, 0x200F, 0x200B, 0xFEFF].contains(value) {
                return String(format: "\\u{%04X}", value)
            }
            return String(scalar)
        }.joined()
        var text = escaped
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return BrowserSuggestionText.fold(text)
    }

    private static func rowIDs(_ db: HistoryDatabase) throws -> [String: Int64] {
        let statement = try db.prepare("SELECT url,id FROM pages")
        defer { sqlite3_finalize(statement) }
        var ids: [String: Int64] = [:]
        while try db.next(statement) { ids[db.text(statement, 0)] = sqlite3_column_int64(statement, 1) }
        return ids
    }

    private static func root() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-palette-r3-synthetic-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
