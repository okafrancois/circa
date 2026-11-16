import CloudKit
import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("History sync state store", .serialized)
struct BrowserHistorySyncStateStoreTests {
    private let now = Date()

    /// The JSON shape earlier builds wrote (one file rewritten in full).
    private struct LegacyFile: Codable {
        var records: [String: BrowserHistorySyncBatch]
        var dirty: Set<String>
        var deleting: Set<String>
        var systemFields: [String: Data]
        var retired: [String: Date]?
    }

    private func root() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/orbit-history-state-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func visit(_ marker: String, at date: Date? = nil) -> BrowserHistoryVisit {
        BrowserHistoryVisit(url: URL(string: "https://state.test/\(marker)")!, title: "Synthetic \(marker)",
                            visitedAt: date ?? now.addingTimeInterval(-60), transition: .link, typedCount: 0)
    }

    private func batch(_ marker: String, profile: ProfileID, events: Int = 3, at date: Date? = nil) -> BrowserHistorySyncBatch {
        let date = date ?? now
        return BrowserHistorySyncBatch(profileID: profile, cutoff: BrowserHistorySyncSchema.cutoff(date),
            events: (0..<events).map { BrowserHistorySyncEvent(visit: visit("\(marker)-\($0)", at: date.addingTimeInterval(-60)), time: date) })
    }

    private func remoteRecord(_ batch: BrowserHistorySyncBatch) throws -> CKRecord {
        let record = CKRecord(recordType: BrowserHistorySyncSchema.recordType,
            recordID: .init(recordName: batch.id.uuidString, zoneID: .init(zoneName: BrowserHistorySyncSchema.zone)))
        record["payload"] = try batch.encoded() as CKRecordValue
        return record
    }

    private func legacyBytes(_ snapshot: BrowserHistorySyncStateSnapshot) throws -> Data {
        try BrowserSyncReplica.encodeValue(LegacyFile(records: snapshot.records, dirty: snapshot.dirty, deleting: snapshot.deleting,
            systemFields: snapshot.systemFields, retired: snapshot.retired.isEmpty ? nil : snapshot.retired))
    }

    private func exists(_ url: URL) -> Bool { var info = stat(); return lstat(url.path, &info) == 0 }

    /// A state with every kind of row: records, dirty and pending deletions, system fields, retirement.
    private func richSnapshot(profile: ProfileID) throws -> BrowserHistorySyncStateSnapshot {
        let batches = (0..<6).map { batch("legacy-\($0)", profile: profile) }
        var snapshot = BrowserHistorySyncStateSnapshot()
        for batch in batches { snapshot.records[batch.id.uuidString] = batch }
        snapshot.dirty = [batches[0].id.uuidString, batches[1].id.uuidString]
        snapshot.deleting = [UUID().uuidString]
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        try remoteRecord(batches[2]).encodeSystemFields(with: archiver); archiver.finishEncoding()
        snapshot.systemFields[batches[2].id.uuidString] = archiver.encodedData
        snapshot.retired = [UUID().uuidString: now.addingTimeInterval(86400 * 3).addingTimeInterval(0.123456789)]
        return snapshot
    }

    @Test("The legacy JSON file is imported once, verified, then deleted; nothing is uploaded again")
    func migration() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("session.json.sync.json.history.cloudkit")
        let profile = ProfileID()
        let legacy = try richSnapshot(profile: profile)
        try BrowserPermissionFile.save(try legacyBytes(legacy), to: destination, maximumBytes: 256 * 1024 * 1024)
        // A checkpoint that does not decode as an engine serialization never counts.
        try Data("{}".utf8).write(to: destination.appendingPathExtension("engine"))
        // These records were already rewritten sealed; the one-time rewrite is not under test here.
        try Data("1".utf8).write(to: destination.appendingPathExtension("sealed-v1"))

        let transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        #expect(await transport.snapshot == legacy)
        #expect(!exists(destination))
        #expect(!exists(destination.appendingPathExtension("engine")))
        #expect(exists(BrowserHistoryCloudKitTransport.storeURL(destination)))
        // The same listing changes nothing: no validation, no new dirty record, no write.
        let listing = Array(legacy.records.values)
        _ = try await transport.exchange(listing, now: now)
        #expect(await transport.validations == 0)
        #expect(await transport.snapshot.dirty == legacy.dirty)
        #expect(await transport.stateWrites == 0)

        let reopened = try BrowserHistoryCloudKitTransport(testDestination: destination)
        #expect(await reopened.snapshot == legacy)
    }

    @Test("An interrupted migration resumes at the next launch without loss or a second import")
    func interruptedMigration() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.cloudkit")
        let profile = ProfileID()
        let legacy = try richSnapshot(profile: profile)
        let bytes = try legacyBytes(legacy)
        try BrowserPermissionFile.save(bytes, to: destination, maximumBytes: 256 * 1024 * 1024)

        // Stopped before the import committed: the store exists, empty, without a digest.
        do { let store = try BrowserHistorySyncStateStore(url: BrowserHistoryCloudKitTransport.storeURL(destination)); try store.close() }
        var transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        #expect(await transport.snapshot == legacy)
        #expect(!exists(destination))

        // Stopped after the import committed but before the file was deleted, and the rows moved
        // on since: the file is only deleted, the newer rows are kept.
        await transport.retract([.retraction(of: legacy.records.values.first!.id, profileID: profile)],
                                    cutoff: BrowserHistorySyncSchema.cutoff(now), now: now)
        try await transport.persistEngineCheckpoint(Data("token".utf8))
        let advanced = await transport.snapshot
        #expect(advanced != legacy)
        try BrowserPermissionFile.save(bytes, to: destination, maximumBytes: 256 * 1024 * 1024)
        transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        #expect(await transport.snapshot == advanced)
        #expect(!exists(destination))

        // A file with another digest was written by an earlier build after a downgrade: it
        // replaces the rows, as that build would resume from it.
        var downgraded = legacy
        downgraded.dirty = []
        try BrowserPermissionFile.save(try legacyBytes(downgraded), to: destination, maximumBytes: 256 * 1024 * 1024)
        transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        #expect(await transport.snapshot == downgraded)

        // An unreadable legacy file refuses the launch and stays for a later build.
        try Data("not json".utf8).write(to: destination)
        #expect(throws: (any Error).self) { try BrowserHistoryCloudKitTransport(testDestination: destination) }
        #expect(exists(destination))
    }

    @Test("After every cycle the stored rows equal the state the single JSON file held")
    func equivalence() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.cloudkit")
        let profile = ProfileID()
        let transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        var listing: [BrowserHistorySyncBatch] = []
        var step = 0
        func check() async throws {
            step += 1
            let live = await transport.snapshot
            // New store: what the next launch loads from the rows.
            let reopened = try BrowserHistoryCloudKitTransport(testDestination: destination)
            #expect(await reopened.snapshot == live, "step \(step)")
            // Old store: the same state written as the legacy file, imported by a fresh launch.
            let folder = root.appendingPathComponent("legacy-\(step)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let legacy = folder.appendingPathComponent("history.cloudkit")
            try BrowserPermissionFile.save(try legacyBytes(live), to: legacy, maximumBytes: 256 * 1024 * 1024)
            var expected = live; expected.engine = nil
            #expect(try await BrowserHistoryCloudKitTransport(testDestination: legacy).snapshot == expected, "step \(step)")
        }
        for index in 0..<4 { listing.append(batch("cycle-\(index)", profile: profile)) }
        _ = try await transport.exchange(listing, now: now); try await check()
        // A remote record arrives with system fields; another Mac deletes one of ours.
        let remote = batch("remote", profile: profile)
        try await transport.accept(try remoteRecord(remote))
        try await transport.persistEngineCheckpoint(Data("token-1".utf8)); try await check()
        await transport.remoteDeletion(listing[1].id.uuidString)
        listing.append(batch("cycle-4", profile: profile))
        _ = try await transport.exchange(listing, now: now.addingTimeInterval(1)); try await check()
        // A purge retracts a batch; the stale listing still names it.
        listing.append(.retraction(of: listing[0].id, profileID: profile))
        _ = try await transport.exchange(listing, now: now.addingTimeInterval(2)); try await check()
        // The retention window moves past every record: they expire into pending deletions.
        let later = now.addingTimeInterval(BrowserHistorySyncSchema.retention + 2 * 86400)
        let fresh = batch("fresh", profile: profile, at: later)
        _ = try await transport.exchange([fresh], now: later); try await check()
        #expect(await transport.snapshot.records.keys.sorted() == [fresh.id.uuidString])
        #expect(await transport.pendingDeletions.count >= 4)
        #expect(await transport.snapshot.retired.isEmpty)
    }

    @Test("Clearing all history leaves none of its URLs or titles in the transport files")
    func clearAllPurgesTransportRows() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.cloudkit")
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("History"))
        for index in 0..<40 { _ = try await store.record(visit("purge-marker-\(index)")) }
        let transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        _ = try await transport.exchange(try await store.historySyncBatches(now: now), now: now)
        func text() throws -> String {
            let url = BrowserHistoryCloudKitTransport.storeURL(destination)
            var bytes = try Data(contentsOf: url)
            if let wal = try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")) { bytes += wal }
            return String(decoding: bytes, as: UTF8.self)
        }
        #expect(try text().contains("purge-marker-7"))
        _ = try await store.delete(.all, now: now.addingTimeInterval(1))
        let retractions = try await store.historySyncBatches(now: now.addingTimeInterval(2))
        #expect(!retractions.filter(\.isRetraction).isEmpty)
        _ = try await transport.exchange(retractions, now: now.addingTimeInterval(2))
        // Only the clear-all tombstone remains cached; it carries no URL or title.
        #expect(await transport.snapshot.records.values.allSatisfy { $0.events.allSatisfy { $0.visit == nil } })
        #expect(try !text().contains("purge-marker"))
        #expect(try !text().contains("state.test"))
        try await store.close()
    }

    @Test("Transport cycles and history writes run concurrently without loss")
    func concurrencyWithHistoryWrites() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.cloudkit")
        let profile = ProfileID()
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root.appendingPathComponent("History"))
        let transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        let start = now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<300 { _ = try await store.record(visit("concurrent-\(index)", at: start.addingTimeInterval(-Double(index)))) }
            }
            group.addTask {
                for cycle in 0..<30 {
                    let moment = start.addingTimeInterval(Double(cycle))
                    let incoming = try await transport.exchange(try await store.historySyncBatches(now: moment), now: moment)
                    _ = try await store.applyHistorySync(incoming, now: moment)
                }
            }
            try await group.waitForAll()
        }
        let final = start.addingTimeInterval(31)
        _ = try await transport.exchange(try await store.historySyncBatches(now: final), now: final)
        let visits = Set(await transport.snapshot.records.values.flatMap(\.events).compactMap(\.visit?.id))
        #expect(visits.count == 300)
        let reopened = try BrowserHistoryCloudKitTransport(testDestination: destination)
        #expect(await reopened.snapshot == transport.snapshot)
        try await store.close()
    }

    @Test("A cycle writes only its changed rows; launch loads the rows (set ORBIT_SYNC_STATE_BENCH for 200k visits)")
    func measurement() async throws {
        let visits = Int(ProcessInfo.processInfo.environment["ORBIT_SYNC_STATE_BENCH"] ?? "") ?? 5000
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.cloudkit")
        let profile = ProfileID()
        let cutoff = BrowserHistorySyncSchema.cutoff(now)
        // Realistic events: a 60-90 byte URL and a 30-60 byte title each.
        var events: [BrowserHistorySyncEvent] = []
        for index in 0..<visits {
            let url = URL(string: "https://www.example-\(index % 977).test/articles/\(index)/synthetic-page-title-\(index % 31)?ref=feed")!
            let title = "Synthetic page \(index) — " + String(repeating: "word ", count: 4 + index % 6)
            events.append(BrowserHistorySyncEvent(visit: BrowserHistoryVisit(url: url, title: title,
                visitedAt: now.addingTimeInterval(-Double(index)), transition: .link, typedCount: 0), time: now))
        }
        let batches = try BrowserHistorySyncBatch.pack(profileID: profile, cutoff: cutoff, events: events)
        var snapshot = BrowserHistorySyncStateSnapshot()
        for batch in batches {
            let id = batch.id.uuidString
            snapshot.records[id] = batch
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            try remoteRecord(batch).encodeSystemFields(with: archiver); archiver.finishEncoding()
            snapshot.systemFields[id] = archiver.encodedData
        }
        // Old store: every changing barrier encoded the whole state and rewrote the file
        // (atomic replace, F_FULLFSYNC).
        var clock = ContinuousClock.now
        let legacy = try legacyBytes(snapshot)
        try BrowserPermissionFile.save(legacy, to: destination, maximumBytes: 256 * 1024 * 1024)
        let oldWrite = ContinuousClock.now - clock
        clock = .now
        _ = try JSONDecoder().decode(LegacyFile.self, from: try BrowserPermissionFile.load(destination, maximumBytes: 256 * 1024 * 1024)!)
        let oldLoad = ContinuousClock.now - clock

        // One-time import, then a launch from the rows (sealed rewrite already done).
        try Data("1".utf8).write(to: destination.appendingPathExtension("sealed-v1"))
        clock = .now
        var transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        let migration = ContinuousClock.now - clock
        clock = .now
        transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        let newLoad = ContinuousClock.now - clock
        #expect(await transport.snapshot.records.count == batches.count)

        // One changed visit: the exchange stores its new batch, the send stores its system fields
        // and the engine tokens. The old store rewrote the whole file at both barriers.
        let storeURL = BrowserHistoryCloudKitTransport.storeURL(destination)
        func walSize() -> Int { (try? FileManager.default.attributesOfItem(atPath: storeURL.path + "-wal")[.size] as? Int) ?? 0 }
        var cycleTimes: [Duration] = [], cycleBytes: [Int] = [], persistTimes: [Duration] = []
        var listing = Array(snapshot.records.values)
        let rowsBefore = await transport.stateStore?.rowsWritten ?? 0
        for cycle in 0..<5 {
            try await transport.stateStore?.checkpoint()
            let applied = await transport.stateStore?.applyTime ?? .zero
            let changed = BrowserHistorySyncBatch(profileID: profile, cutoff: cutoff,
                events: [BrowserHistorySyncEvent(visit: visit("changed-\(cycle)"), time: now)])
            listing.append(changed)
            clock = .now
            _ = try await transport.exchange(listing, now: now.addingTimeInterval(Double(cycle * 400)))
            try await transport.accept(try remoteRecord(changed))
            try await transport.persistEngineCheckpoint(Data("token-\(cycle)".utf8))
            cycleTimes.append(ContinuousClock.now - clock)
            persistTimes.append((await transport.stateStore?.applyTime ?? .zero) - applied)
            cycleBytes.append(walSize())
        }
        let rows = (await transport.stateStore?.rowsWritten ?? 0) - rowsBefore
        #expect(rows <= 5 * 4)
        #expect(cycleBytes.allSatisfy { $0 < legacy.count / 20 || legacy.count < 1_000_000 })
        func ms(_ duration: Duration) -> Double { Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000 }
        let median = cycleTimes.map(ms).sorted()[cycleTimes.count / 2]
        let persistMedian = persistTimes.map(ms).sorted()[persistTimes.count / 2]
        let storeBytes = (try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.size] as? Int) ?? 0
        print("SYNC_STATE_BENCH visits=\(visits) batches=\(batches.count) legacy_bytes=\(legacy.count) store_bytes=\(storeBytes)"
            + " old_cycle_bytes=\(legacy.count * 2) old_cycle_ms=\(ms(oldWrite) * 2) new_cycle_wal_bytes=\(cycleBytes.sorted()[cycleBytes.count / 2])"
            + " new_cycle_persist_ms=\(persistMedian) new_cycle_total_ms=\(median) new_rows_per_cycle=\(rows / 5) old_load_ms=\(ms(oldLoad)) new_load_ms=\(ms(newLoad)) migration_ms=\(ms(migration))")
    }
}
