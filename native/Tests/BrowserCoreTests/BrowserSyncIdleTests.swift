import Darwin
import Foundation
import SQLite3
import Testing
@testable import BrowserCore

@Suite(.serialized)
struct BrowserSyncIdleTests {
    func root() -> URL { URL(fileURLWithPath: "/private/tmp/sync-idle-\(UUID())") }
    func snapshot(_ document: BrowserSessionDocument) -> BrowserSyncWorker.Snapshot { .init(session: document, settings: .init()) }
    func shared(_ value: BrowserSyncMapping.Materialized) -> BrowserSessionDocument {
        .init(profiles: value.profiles, spaces: value.spaces, windows: [], tabs: [], organization: value.organization)
    }

    @Test("A failed durability barrier invalidates byte equality, including failure after replacement")
    func writeFailures() throws {
        var file = BrowserSyncPersistence(), count = 0
        let destination = root().appendingPathComponent("state")
        let a = Data("a".utf8), b = Data("b".utf8)
        func write(_ bytes: Data, _ url: URL, _ limit: Int) { count += 1 }
        try file.save(a, to: destination, maximumBytes: 100, write: write)
        try file.save(a, to: destination, maximumBytes: 100, write: write)
        #expect(count == 1)
        #expect(throws: BrowserPermissionFile.Failure.committedButNotDurable) {
            try file.save(b, to: destination, maximumBytes: 100) { _, _, _ in
                throw BrowserPermissionFile.Failure.committedButNotDurable
            }
        }
        try file.save(a, to: destination, maximumBytes: 100, write: write)
        #expect(count == 2)
    }

    @Test("Three synthetic devices preserve exact replicas, clocks, tombstones and durable outboxes", arguments: [UInt64(2477492513), UInt64(17), UInt64(991)])
    func randomizedDevices(seed: UInt64) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = BrowserSyncTests(), oldCloud = BrowserSyncMemoryCloud(), newCloud = BrowserSyncMemoryCloud()
        var originals = (0..<3).map { i -> BrowserSyncState in
            var state = BrowserSyncState(); state.replica = .init(device: "device-\(i)"); return state
        }
        var workers = originals.enumerated().map { BrowserSyncWorker(state: $0.element, destination: root.appendingPathComponent("\($0.offset).json")) }
        let oldTransports = (0..<3).map { _ in BrowserSyncMemoryTransport(cloud: oldCloud, account: "synthetic") }
        let newTransports = (0..<3).map { _ in BrowserSyncMemoryTransport(cloud: newCloud, account: "synthetic") }
        var locals = Array(repeating: fixture.document(nested: true), count: 3)
        var random = seed
        for turn in 0..<312 {
            random = random &* 6364136223846793005 &+ 1
            let index = turn < 300 ? Int((random >> 32) % 3) : turn % 3
            let now = fixture.date.addingTimeInterval(-Double(turn % 5))
            // Reopen before every turn, including after offline captures.
            let destination = root.appendingPathComponent("\(index).json")
            if FileManager.default.fileExists(atPath: destination.path) {
                let recovered = try BrowserSyncState.load(destination)
                #expect(try BrowserSyncReplica.encodeValue(recovered) == BrowserSyncReplica.encodeValue(originals[index]))
                workers[index] = BrowserSyncWorker(state: recovered, destination: destination)
            }
            if turn < 300 && turn % 4 != 0 {
                locals[index] = fixture.document(order: random & 1 == 0 ? [fixture.first, fixture.second] : [fixture.second, fixture.first],
                    name: "Space \(turn / 4)", title: "Title \(turn)", nested: true, moved: random & 2 != 0, restored: random & 4 != 0)
            }
            let local = locals[index]
            try originals[index].account.admit("synthetic"); try await workers[index].admit("synthetic")
            let projection = try LegacySyncMapping.project(session: local, settings: .init())
            #expect(projection == (try BrowserSyncMapping.project(session: local, settings: .init())))
            try originals[index].replica.capture(projection, now: now)
            let outgoing = try await workers[index].capture(snapshot(local), now: now)
            #expect(Dictionary(uniqueKeysWithValues: outgoing.map { ($0.id, $0) }) == originals[index].replica.records)
            // Compare the durable outbox before any network operation; some turns stay offline.
            var persisted = try BrowserSyncState.load(root.appendingPathComponent("\(index).json"))
            #expect(try BrowserSyncReplica.encodeValue(persisted) == BrowserSyncReplica.encodeValue(originals[index]))
            if turn < 300 && turn % 7 == 0 { continue }
            let oldIncoming = try await oldTransports[index].exchange(Array(originals[index].replica.records.values))
            let newIncoming = try await newTransports[index].exchange(outgoing)
            try originals[index].replica.merge(oldIncoming)
            try await workers[index].merge(newIncoming, identity: "synthetic")
            try originals[index].replica.capture(projection, now: now)
            let legacy = try LegacySyncMapping.materialize(originals[index].replica.visible, local: local, settings: .init())
            let prepared = try await workers[index].prepare(snapshot(local), now: now)
            let oldShared = BrowserSessionDocument(profiles: legacy.profiles, spaces: legacy.spaces, windows: [], tabs: [], organization: legacy.organization)
            // New remote tabs receive a local wall-clock timestamp in both implementations.
            // Compare those separately from canonical sync state (which excludes that field).
            let known = Set(local.organization.tabs.map(\.id))
            func comparable(_ document: BrowserSessionDocument) throws -> Data {
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as! [String: Any]
                var organization = object["organization"] as! [String: Any]
                var tabs = organization["tabs"] as! [[String: Any]]
                for i in tabs.indices where !known.contains(document.organization.tabs[i].id) { tabs[i]["lastActiveAt"] = 0 }
                organization["tabs"] = tabs; object["organization"] = organization
                return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            }
            #expect(try comparable(oldShared) == comparable(shared(prepared.value)))
            let acknowledged = try LegacySyncMapping.project(session: oldShared, settings: legacy.settings, boosts: legacy.boosts)
            #expect(acknowledged == prepared.projection)
            try originals[index].replica.acknowledge(acknowledged)
            try await workers[index].acknowledge(prepared.projection)
            locals[index] = oldShared
            persisted = try BrowserSyncState.load(root.appendingPathComponent("\(index).json"))
            #expect(try BrowserSyncReplica.encodeValue(persisted) == BrowserSyncReplica.encodeValue(originals[index]))
        }
        #expect(originals[0].replica.records == originals[1].replica.records)
        #expect(originals[1].replica.records == originals[2].replica.records)
        for index in 0..<3 {
            await #expect(throws: BrowserSyncError.signedOut) { try await workers[index].admit(nil) }
            #expect(throws: BrowserSyncError.signedOut) { try originals[index].account.admit(nil) }
            await #expect(throws: BrowserSyncError.accountChanged) { try await workers[index].admit("other") }
            #expect(throws: BrowserSyncError.accountChanged) { try originals[index].account.admit("other") }
            let persisted = try BrowserSyncState.load(root.appendingPathComponent("\(index).json"))
            #expect(persisted.account == originals[index].account)
        }
    }

    @Test("Restart after durable capture replays the same identities without lost or duplicated edits")
    func restartBeforeSend() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("replica.json"), fixture = BrowserSyncTests()
        let cloud = BrowserSyncMemoryCloud(), transport = BrowserSyncMemoryTransport(cloud: cloud, account: "synthetic")
        let worker = BrowserSyncWorker(state: .init(), destination: destination)
        try await worker.admit("synthetic")
        let outgoing = try await worker.capture(snapshot(fixture.document()), now: fixture.date)
        let recovered = try BrowserSyncState.load(destination)
        #expect(recovered.replica.records.count == outgoing.count)
        let restarted = BrowserSyncWorker(state: recovered, destination: destination)
        let once = try await transport.exchange(Array(recovered.replica.records.values))
        let twice = try await transport.exchange(Array(recovered.replica.records.values))
        #expect(Dictionary(uniqueKeysWithValues: once.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: twice.map { ($0.id, $0) }))
        try await restarted.merge(twice, identity: "synthetic")
        let result = try await restarted.prepare(snapshot(fixture.document()), now: fixture.date)
        #expect(result.value.organization.tabs.count == fixture.document().organization.tabs.count)
        try await restarted.acknowledge(result.projection)
    }

    @Test("History cache observes metadata, deletions, rollback, pending overflow, cutoff and restart")
    func historyInvalidation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let visits = (0..<5001).map { BrowserHistoryVisit(url: URL(string: "https://example.invalid/\($0)")!, title: "Synthetic", visitedAt: now) }
        try await store.importDocument(.init(profileID: profile, visits: visits))
        let first = try await store.historySyncBatches(now: now)
        let second = try await store.historySyncBatches(now: now)
        #expect(second.flatMap(\.events).count > first.flatMap(\.events).count)
        #expect(try await store.historySyncBatches(now: now) == second)
        try await store.updateMetadata(visitID: visits[0].id, title: "Changed")
        #expect(try await store.historySyncBatches(now: now) != second)
        try await store.delete(.visit(visits[1].id), now: now)
        let deleted = try await store.historySyncBatches(now: now)
        #expect(deleted.flatMap(\.events).contains { $0.deletion != nil })
        try await store.rollbackSyncFixture()
        #expect(try await store.historySyncBatches(now: now) == deleted)
        let later = try await store.historySyncBatches(now: now.addingTimeInterval(92 * 86400))
        #expect(later.flatMap(\.events).isEmpty)
        try await store.close()
        let reopened = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        #expect(try await reopened.historySyncBatches(now: now.addingTimeInterval(92 * 86400)) == later)
        try await reopened.close()
    }
}

extension BrowserHistoryStore {
    func rollbackSyncFixture() throws {
        do {
            try database?.transaction {
                try database?.execute("DELETE FROM historySyncBatches")
                throw BrowserSyncError.unavailable
            }
        } catch BrowserSyncError.unavailable {}
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_SYNC_CRASH_PHASE"] != nil))
struct BrowserSyncProcessCrashTests {
    @Test func durableBoundary() async throws {
        let phase = ProcessInfo.processInfo.environment["ORBIT_SYNC_CRASH_PHASE"] ?? ""
        let path = ProcessInfo.processInfo.environment["ORBIT_SYNC_CRASH_ROOT"] ?? ""
        guard path.hasPrefix("/private/tmp/perf-sync-idle-3/crash-") else { throw BrowserSyncError.unavailable }
        let root = URL(fileURLWithPath: path), destination = root.appendingPathComponent("replica.json")
        let expectedFile = root.appendingPathComponent("expected.json"), serverFile = root.appendingPathComponent("server.json")
        let fixture = BrowserSyncTests(), cloud = BrowserSyncMemoryCloud()
        let transport = BrowserSyncMemoryTransport(cloud: cloud, account: "synthetic")
        if phase == "recover" {
            let recovered = try BrowserSyncState.load(destination)
            let expected = try JSONDecoder().decode([String: BrowserSyncRecord].self, from: Data(contentsOf: expectedFile))
            #expect(recovered.replica.records == expected)
            if let server = try? Data(contentsOf: serverFile) {
                _ = try await transport.exchange(JSONDecoder().decode([BrowserSyncRecord].self, from: server))
            }
            let result = try await transport.exchange(Array(recovered.replica.records.values))
            #expect(Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) }) == expected)
            print("CRASH_RECOVERY exact_outbox=true duplicates=0 records=\(result.count)")
        } else {
            let worker = BrowserSyncWorker(state: .init(), destination: destination)
            try await worker.admit("synthetic")
            let records = try await worker.capture(.init(session: fixture.document(nested: true), settings: .init()), now: fixture.date)
            try BrowserSyncReplica.encodeValue(Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })).write(to: expectedFile)
            if phase == "after-send" {
                try BrowserSyncReplica.encodeValue(await transport.exchange(records)).write(to: serverFile)
            }
            try Data(String(getpid()).utf8).write(to: root.appendingPathComponent("ready"))
            // The external synthetic harness sends SIGKILL to this exact test process.
            try await Task.sleep(for: .seconds(45))
            Issue.record("Crash harness did not terminate the test process")
        }
    }
}
