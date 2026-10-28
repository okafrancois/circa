@testable import BrowserCore
import Foundation
import Testing

@Suite("source browser history import", .serialized)
struct OrbitImportHistoryTests {
    @Test("Chunks follow visit ids; Chromium epoch, transitions and filters are converted")
    func readerChunksAndFilters() throws {
        let root = try OrbitFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        var rows = OrbitFixture.historyRows(count: 5_200, base: base)
        rows += [
            .init(url: "file:///tmp/synthetic", time: OrbitFixture.chromeTime(base)),
            .init(url: "chrome://settings/", time: OrbitFixture.chromeTime(base)),
            .init(url: "https://user:secret@history-one.example.test/", time: OrbitFixture.chromeTime(base)),
            .init(url: "https://history-one.example.test/" + String(repeating: "x", count: 5000), time: OrbitFixture.chromeTime(base)),
            .init(url: "https://history-one.example.test/frame", time: OrbitFixture.chromeTime(base), transition: 3),
            .init(url: "https://history-one.example.test/hidden", time: OrbitFixture.chromeTime(base), hidden: true),
            .init(url: "https://history-one.example.test/zero", time: 0),
            .init(url: "https://history-two.example.test/back", time: OrbitFixture.chromeTime(base), transition: 0x0100_0000),
            .init(url: "https://history-two.example.test/reload", time: OrbitFixture.chromeTime(base), transition: 8),
            .init(url: "https://history-two.example.test/redirect", time: OrbitFixture.chromeTime(base), transition: 0x4000_0000),
        ]
        let file = root.appendingPathComponent("History")
        try OrbitFixture.writeHistory(rows, to: file)
        let reader = try ArcChromiumHistoryReader(snapshotFile: file, directory: "Default", identity: ArcImportIdentity())
        #expect(reader.totalVisits == rows.count)
        var chunks: [[BrowserHistoryVisit]] = []
        while let chunk = try reader.nextChunk(size: 2_000) { chunks.append(chunk) }
        #expect(chunks.map(\.count) == [2_000, 2_000, 1_203])
        let all = chunks.flatMap { $0 }
        #expect(reader.counts.rows == rows.count && reader.counts.importable == 5_203)
        #expect(reader.counts.nonWebURLs == 2 && reader.counts.credentialURLs == 1 && reader.counts.oversizedURLs == 1)
        #expect(reader.counts.subframesOrHidden == 2 && reader.counts.invalidTimes == 1)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all[0].visitedAt == base && all[0].transition == .typed && all[0].typedCount == 1)
        #expect(all[1].transition == .link && all[1].typedCount == 0)
        let byPath = Dictionary(all.map { ($0.url.path, $0.transition) }, uniquingKeysWith: { first, _ in first })
        #expect(byPath["/back"] == .backForward && byPath["/reload"] == .reload && byPath["/redirect"] == .redirect)
        #expect(all.allSatisfy(BrowserHistoryStore.accepts))
        // Identities are stable between reads.
        let again = try ArcChromiumHistoryReader(snapshotFile: file, directory: "Default", identity: ArcImportIdentity())
        #expect(try again.nextChunk(size: 10)?.map(\.id) == Array(all.prefix(10).map(\.id)))
    }

    @Test("A malformed or foreign database is refused without reading it as history")
    func refusesForeignDatabase() throws {
        let root = try OrbitFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History")
        try Data("not a database".utf8).write(to: file)
        #expect(throws: ArcImportError.historyDatabaseUnreadable) {
            try ArcChromiumHistoryReader(snapshotFile: file, directory: "Default", identity: ArcImportIdentity())
        }
    }

    @Test("Chunked import is idempotent and readable between chunks")
    func chunkedIdempotentImport() async throws {
        let root = try OrbitFixture.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("History")
        try OrbitFixture.writeHistory(OrbitFixture.historyRows(count: 4_500), to: file)
        let profile = ProfileID()
        let sink = ArcDirectHistorySink(directory: root.appendingPathComponent("Target"))
        let probe = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("Target"))
        func run(checkingProgress: Bool) async throws -> (inserted: Int, chunks: Int) {
            let reader = try ArcChromiumHistoryReader(snapshotFile: file, directory: "Default", identity: ArcImportIdentity())
            var inserted = 0, chunks = 0
            while let visits = try reader.nextChunk(size: 1_000) {
                inserted += try await sink.importChunk(BrowserHistoryDocument(profileID: profile, visits: visits))
                chunks += 1
                // Each chunk is committed: another connection already sees it.
                if checkingProgress { #expect(try await probe.visits(limit: 10_000).count == min(4_500, chunks * 1_000)) }
            }
            return (inserted, chunks)
        }
        let first = try await run(checkingProgress: true)
        #expect(first.inserted == 4_500 && first.chunks == 5)
        let second = try await run(checkingProgress: false)
        #expect(second.inserted == 0)
        #expect(try await probe.visits(limit: 10_000).count == 4_500)
        await sink.close()
        try await probe.close()
    }
}
