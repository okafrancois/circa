import CloudKit
import Darwin
import Foundation
import SQLite3
import Testing
@testable import BrowserCore

extension BrowserHistoryStore {
    /// Every byte of the sync journal and saved batches, for "is this text gone" checks.
    func syncJournalText() throws -> String {
        guard let database else { return "" }
        var text = ""
        for sql in ["SELECT payload FROM historySyncEvents", "SELECT payload FROM historySyncBatches"] {
            let rows = try database.prepare(sql)
            defer { sqlite3_finalize(rows) }
            while try database.next(rows) { text += database.text(rows, 0) + "\n" }
        }
        return text
    }

    var faviconCollectionCount: Int { database?.faviconCollections ?? -1 }

    func rawExecute(_ sql: String, _ values: [HistoryValue] = []) throws { try database?.execute(sql, values) }
}

@Suite("History purge", .serialized)
struct BrowserHistoryPurgeTests {
    private let now = Date()

    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-history-purge-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Each visit carries a unique marker in its URL and title so leftovers are easy to find.
    private func visit(_ marker: String, host: String = "keep.test", age: TimeInterval = 60) -> BrowserHistoryVisit {
        BrowserHistoryVisit(url: URL(string: "https://\(host)/\(marker)")!, title: "Title \(marker)",
            visitedAt: now.addingTimeInterval(-age), transition: .link,
            faviconReference: URL(string: "https://\(host)/icon.png"), typedCount: 0)
    }

    private func sync(_ store: BrowserHistoryStore, _ cloud: BrowserHistorySyncMemoryCloud, at date: Date? = nil) async throws {
        let date = date ?? now
        let incoming = try await cloud.exchange(try await store.historySyncBatches(now: date), now: date)
        try await store.applyHistorySync(incoming, now: date)
    }

    private func cloudText(_ cloud: BrowserHistorySyncMemoryCloud) async throws -> String {
        try await cloud.recordedBatches.map { String(decoding: try $0.encoded(), as: UTF8.self) }.joined(separator: "\n")
    }

    @Test("Clear all, time range and site deletions leave no deleted URL or title in the journal, batches or cloud")
    func journalPurge() async throws {
        let cases: [(String, (Date) -> BrowserHistoryDeletion)] = [
            ("all", { _ in .all }),
            ("range", { now in .interval(DateInterval(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-1800))) }),
            ("site", { _ in .site("gone.test") })]
        for (label, deletion) in cases {
            let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
            let profile = ProfileID(), cloud = BrowserHistorySyncMemoryCloud()
            let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
            let doomed = [visit("doomed-a-\(label)", host: "gone.test", age: 3600), visit("doomed-b-\(label)", host: "gone.test", age: 3000)]
            let survivor = visit("survivor-\(label)", age: label == "range" ? 60 : 30)
            #expect(try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: doomed + [survivor])) == 3)
            try await sync(store, cloud)
            #expect(try await store.syncJournalText().contains("doomed-a-\(label)"))
            #expect(try await cloudText(cloud).contains("doomed-a-\(label)"))

            #expect(try await store.delete(deletion(now), now: now) == (label == "all" ? 3 : 2))
            let journal = try await store.syncJournalText()
            for marker in ["doomed-a-\(label)", "doomed-b-\(label)", "Title doomed"] { #expect(!journal.contains(marker), "\(label)") }
            if label == "site" { #expect(!journal.contains("gone.test"), "the site tombstone carries no plain host") }

            // The next exchange republishes survivors and deletes the old records remotely.
            let outgoing = try await store.historySyncBatches(now: now)
            #expect(outgoing.contains { $0.isRetraction })
            _ = try await cloud.exchange(outgoing, now: now)
            let remote = try await cloudText(cloud)
            for marker in ["doomed-a-\(label)", "doomed-b-\(label)"] { #expect(!remote.contains(marker), "\(label)") }
            if label != "all" { #expect(remote.contains("survivor-\(label)"), "\(label)") }
            try await store.close()
        }
    }

    @Test("Deletions converge between two replicas, survivors reach a new replica and remote copies are purged")
    func twoReplicas() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), cloud = BrowserHistorySyncMemoryCloud()
        let a = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("a"))
        let b = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("b"))
        let doomed = visit("doomed-shared", host: "gone.test"), survivor = visit("survivor-shared")
        let offline = visit("doomed-offline", host: "gone.test", age: 10)
        try await a.importDocument(BrowserHistoryDocument(profileID: profile, visits: [doomed, survivor]))
        try await sync(a, cloud); try await sync(b, cloud)
        #expect(try await b.visits().count == 2)
        // B records a visit of the site offline; A deletes the site before seeing it.
        try await b.record(offline)
        try await a.delete(.site("gone.test"), now: now)
        try await sync(a, cloud); try await sync(b, cloud); try await sync(a, cloud); try await sync(b, cloud)
        for store in [a, b] {
            #expect(try await store.visits().map(\.id) == [survivor.id])
            let journal = try await store.syncJournalText()
            #expect(!journal.contains("doomed-shared") && !journal.contains("doomed-offline") && !journal.contains("gone.test"))
            #expect(journal.contains("survivor-shared"))
        }
        let remote = try await cloudText(cloud)
        #expect(!remote.contains("doomed-shared") && !remote.contains("doomed-offline") && !remote.contains("gone.test"))
        #expect(remote.contains("survivor-shared"))
        // A Mac joining later gets the survivor and the tombstone, never the deleted visits.
        let c = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("c"))
        try await sync(c, cloud)
        #expect(try await c.visits().map(\.id) == [survivor.id])
        #expect(try await c.importDocument(BrowserHistoryDocument(profileID: profile, visits: [doomed])) == 0)
        #expect(try await c.visits().map(\.id) == [survivor.id])
        // Clear-all propagates the same way and stays converged across further exchanges.
        try await b.delete(.all, now: now.addingTimeInterval(1))
        for _ in 0..<2 { try await sync(b, cloud); try await sync(a, cloud); try await sync(c, cloud) }
        for store in [a, b, c] {
            #expect(try await store.visits().isEmpty)
            #expect(try await !store.syncJournalText().contains("survivor-shared"))
        }
        #expect(try await !cloudText(cloud).contains("survivor-shared"))
        try await a.close(); try await b.close(); try await c.close()
    }

    @Test("Plain-host site tombstones from earlier builds still decode and delete; new ones are salted digests")
    func tombstoneFormat() async throws {
        let legacy = #"{"end":800000000,"endInclusive":true,"site":"example.test"}"#
        let decoded = try JSONDecoder().decode(BrowserHistorySyncDeletion.self, from: Data(legacy.utf8))
        let old = BrowserHistoryVisit(url: URL(string: "https://example.test/a")!, visitedAt: Date(timeIntervalSinceReferenceDate: 799_000_000))
        let other = BrowserHistoryVisit(url: URL(string: "https://sub.example.test/a")!, visitedAt: old.visitedAt)
        #expect(decoded.matches(old) && !decoded.matches(other))
        let hashed = BrowserHistorySyncDeletion(.site("EXAMPLE.test"), now: now)
        #expect(hashed.site.map(BrowserHistorySyncDeletion.isHashedSite) == true)
        #expect(hashed.site?.contains("example") == false)
        #expect(hashed.matches(old) && !hashed.matches(other))
        #expect(try JSONDecoder().decode(BrowserHistorySyncDeletion.self, from: BrowserSyncReplica.encodeValue(hashed)) == hashed)

        // A replica applies a legacy plain-host tombstone received from iCloud.
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let doomed = visit("legacy-doomed", host: "example.test"), kept = visit("legacy-kept")
        try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: [doomed, kept]))
        var plain = BrowserHistorySyncDeletion(.all, now: now)
        plain.site = "example.test"
        let batch = BrowserHistorySyncBatch(profileID: profile, cutoff: BrowserHistorySyncSchema.cutoff(now),
                                            events: [BrowserHistorySyncEvent(deletion: plain, time: now)])
        #expect(try await store.applyHistorySync([batch], now: now))
        #expect(try await store.visits().map(\.id) == [kept.id])
        #expect(try await !store.syncJournalText().contains("legacy-doomed"))
        try await store.close()
    }

    @Test("Upgrading purges visits deleted by earlier builds and rewrites plain-host tombstones")
    func upgradeSanitizes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        var store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let doomed = visit("pre-upgrade-doomed", host: "gone.test"), kept = visit("pre-upgrade-kept")
        try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: [doomed, kept]))
        var plain = BrowserHistorySyncDeletion(.all, now: now)
        plain.site = "gone.test"
        let tombstone = BrowserHistorySyncEvent(deletion: plain, time: now)
        try await store.appendSyncEvent(tombstone)
        let published = try await store.historySyncBatches(now: now)
        #expect(!published.contains { $0.isRetraction })
        // What an earlier build left behind: the visit row deleted, its journal rows kept.
        try await store.rawExecute("DELETE FROM visits WHERE id=?", [.text(doomed.id.uuidString)])
        try await store.close()
        let file = root.appendingPathComponent(profile.rawValue.uuidString).appendingPathComponent("history.sqlite")
        let raw = try HistoryDatabase(url: file, profileID: profile)
        try raw.discardJournalPurgeSchemaForLegacyFixture()
        try raw.execute("UPDATE identity SET version=8")
        try raw.execute("PRAGMA user_version=8")
        try raw.close()

        store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let journal = try await store.syncJournalText()
        #expect(!journal.contains("pre-upgrade-doomed"))
        #expect(!journal.contains("gone.test"))
        #expect(journal.contains("pre-upgrade-kept"))
        let outgoing = try await store.historySyncBatches(now: now)
        #expect(Set(outgoing.filter(\.isRetraction).map(\.id)) == Set(published.map(\.id)))
        let republished = outgoing.filter { !$0.isRetraction }.flatMap(\.events)
        #expect(republished.contains { $0.visit?.id == kept.id })
        #expect(republished.contains { $0.id == tombstone.id && $0.deletion?.site.map(BrowserHistorySyncDeletion.isHashedSite) == true })
        try await store.close()
    }

    @Test("The CloudKit transport deletes retracted records from its cache and never uploads them again")
    func transportRetraction() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.cloudkit")
        let profile = ProfileID(), cutoff = BrowserHistorySyncSchema.cutoff(now)
        let doomed = BrowserHistorySyncBatch(profileID: profile, cutoff: cutoff,
            events: [BrowserHistorySyncEvent(visit: visit("transport-doomed"), time: now)])
        let kept = BrowserHistorySyncBatch(profileID: profile, cutoff: cutoff,
            events: [BrowserHistorySyncEvent(visit: visit("transport-kept"), time: now)])
        var transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        #expect(try await transport.exchange([doomed, kept], now: now).count == 2)
        #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self).contains("transport-doomed"))
        let notice = BrowserHistorySyncBatch.retraction(of: doomed.id, profileID: profile)
        // A stale store may still list the batch in the same exchange; it is not kept.
        #expect(try await transport.exchange([doomed, kept, notice], now: now.addingTimeInterval(1)).map(\.id) == [kept.id])
        #expect(await transport.pendingDeletions.contains(doomed.id.uuidString))
        #expect(!String(decoding: try Data(contentsOf: destination), as: UTF8.self).contains("transport-doomed"))
        // The server can still send it back before the deletion lands: it stays out of the cache.
        let fetched = CKRecord(recordType: BrowserHistorySyncSchema.recordType,
            recordID: .init(recordName: doomed.id.uuidString, zoneID: .init(zoneName: BrowserHistorySyncSchema.zone)))
        fetched["payload"] = try doomed.encoded() as CKRecordValue
        try await transport.accept(fetched)
        #expect(await !transport.cachedRecordIDs.contains(doomed.id.uuidString))
        // Reopened from disk (retirement persisted), a stale listing still cannot re-upload it.
        transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        #expect(try await transport.exchange([doomed, kept], now: now.addingTimeInterval(2)).map(\.id) == [kept.id])
        // A deletion made by another Mac retires the record the same way.
        await transport.remoteDeletion(kept.id.uuidString)
        #expect(try await transport.exchange([kept], now: now.addingTimeInterval(400)).isEmpty)
        #expect(await transport.cachedRecordIDs.isEmpty)
    }

    @Test("A no-op cutoff advance and a zero-row deletion run no favicon collection")
    func faviconCollectionGuards() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        try await store.importDocument(BrowserHistoryDocument(profileID: profile, visits: [visit("gc-a"), visit("gc-b", host: "gone.test")]))
        _ = try await store.historySyncBatches(now: now)
        _ = try await store.historySyncBatches(now: now.addingTimeInterval(60))
        _ = try await store.applyHistorySync([], now: now.addingTimeInterval(120))
        #expect(await store.faviconCollectionCount == 0)
        #expect(try await store.delete(.site("absent.test"), now: now) == 0)
        #expect(try await store.deleteSuggestions(url: URL(string: "https://absent.test/")!) == 0)
        #expect(await store.faviconCollectionCount == 0)
        #expect(try await store.delete(.site("gone.test"), now: now) == 1)
        #expect(await store.faviconCollectionCount == 1)
        // The next day moves the cutoff once: one maintenance pass, still no rows, no collection.
        _ = try await store.historySyncBatches(now: now.addingTimeInterval(86400))
        #expect(await store.faviconCollectionCount == 1)
        try await store.close()
    }
}

@Suite("Engine history purge", .serialized)
struct BrowserEngineHistoryPurgeTests {
    private func makeRoot() throws -> (URL, URL) {
        let data = URL(fileURLWithPath: "/private/tmp/orbit-engine-history-purge-\(UUID())")
        let engine = data.appendingPathComponent("Chromium", isDirectory: true)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        return (data, engine)
    }

    private func populate(_ engine: URL, _ profile: ProfileID) throws -> URL {
        let folder = engine.appendingPathComponent("profile-" + profile.rawValue.uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Favicons",
                     "Shortcuts", "Network Action Predictor", "Preferences", "Cookies"] {
            try Data("synthetic".utf8).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    @Test("A scheduled purge deletes only the engine history files before launch, without following links")
    func purge() throws {
        let (data, engine) = try makeRoot(); defer { try? FileManager.default.removeItem(at: data) }
        let cleared = ProfileID(), untouched = ProfileID(), removed = ProfileID()
        let folder = try populate(engine, cleared), other = try populate(engine, untouched)
        let outside = data.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Favicons-journal"), withDestinationURL: outside)
        #expect(try BrowserEngineHistoryPurge.pendingProfiles(dataRoot: data).isEmpty)
        try BrowserEngineHistoryPurge.schedule(cleared, dataRoot: data)
        try BrowserEngineHistoryPurge.schedule(cleared, dataRoot: data)
        try BrowserEngineHistoryPurge.schedule(removed, dataRoot: data)
        #expect(try BrowserEngineHistoryPurge.pendingProfiles(dataRoot: data) == [cleared, removed])
        #expect(try BrowserEngineHistoryPurge.performPending(dataRoot: data, engineRoot: engine) == 2)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(remaining == ["Cookies", "Preferences"])
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).count == 10)
        #expect(try BrowserEngineHistoryPurge.pendingProfiles(dataRoot: data).isEmpty)
        #expect(try BrowserEngineHistoryPurge.performPending(dataRoot: data, engineRoot: engine) == 0)
    }

    @Test("A symbolic link in place of the profile directory refuses the purge and keeps the request")
    func refusesLinkedProfile() throws {
        let (data, engine) = try makeRoot(); defer { try? FileManager.default.removeItem(at: data) }
        let profile = ProfileID()
        let elsewhere = data.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("History"))
        try FileManager.default.createSymbolicLink(at: engine.appendingPathComponent("profile-" + profile.rawValue.uuidString.lowercased()),
                                                   withDestinationURL: elsewhere)
        try BrowserEngineHistoryPurge.schedule(profile, dataRoot: data)
        #expect(throws: BrowserEngineHistoryPurge.Failure.unsafePath) {
            try BrowserEngineHistoryPurge.performPending(dataRoot: data, engineRoot: engine)
        }
        #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("History").path))
        #expect(try BrowserEngineHistoryPurge.pendingProfiles(dataRoot: data) == [profile])
    }
}
