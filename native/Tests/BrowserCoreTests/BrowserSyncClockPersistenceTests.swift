import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite(.serialized)
struct BrowserSyncClockPersistenceTests {
    func root() -> URL { URL(fileURLWithPath: "/private/tmp/sync-clock-\(UUID())") }
    func projection(_ title: String = "Synthetic") -> BrowserSyncProjection {
        var value = BrowserSyncProjection()
        value.entries["item"] = ["title": Data(title.utf8)]
        return value
    }
    let now = Date(timeIntervalSince1970: 1)

    @Test func migrationCorruptionAndStaleRecords() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("replica.json"), clock = BrowserSyncClockPersistence.clockURL(url)
        var state = BrowserSyncState()
        try state.replica.capture(projection(), now: now)
        try state.save(url)
        let legacy = try Data(contentsOf: url)
        #expect(try BrowserSyncState.load(url).replica.tick == state.replica.tick)
        var writer = BrowserSyncClockPersistence(state: state, destination: url)
        for _ in 0..<8 { try state.replica.capture(projection(), now: now); try writer.save(state, to: url) }
        let validClock = try Data(contentsOf: clock)
        #expect(validClock.count == 72)
        #expect(writer.replicaWrites == 0)
        #expect(try Data(contentsOf: url) == legacy)
        #expect(try BrowserSyncState.load(url).replica.tick == state.replica.tick)
        let embedded = try JSONDecoder().decode(BrowserSyncState.self, from: legacy)
        // Missing/truncated/bit-flipped records fall back to the legacy embedded tick.
        try FileManager.default.removeItem(at: clock)
        #expect(try BrowserSyncState.load(url).replica.tick == embedded.replica.tick)
        for corrupt in [Data(), validClock.prefix(40), Data(validClock.map { $0 ^ 1 })] {
            try corrupt.write(to: clock)
            #expect(try BrowserSyncState.load(url).replica.tick == embedded.replica.tick)
        }
        try validClock.write(to: clock)
        try state.replica.capture(projection("Changed"), now: now)
        let before = writer.writes
        try writer.save(state, to: url)
        #expect(writer.writes == before + 1)
        #expect(writer.replicaWrites == 1)
        #expect(try BrowserSyncState.load(url).replica.tick == state.replica.tick)
        // An older reader can still decode the complete updated replica.
        let older = try JSONDecoder().decode(BrowserSyncState.self, from: Data(contentsOf: url))
        #expect(try BrowserSyncReplica.encodeValue(older) == BrowserSyncReplica.encodeValue(state))
        // A valid but unrelated higher clock must never contaminate a reset device.
        var reset = BrowserSyncState(); reset.replica = .init(device: "reset")
        try reset.save(url)
        #expect(try BrowserSyncState.load(url).replica.tick == 0)
    }

    @Test func workerChangeWritesReplicaOnce() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("replica.json"), fixture = BrowserSyncTests()
        let worker = BrowserSyncWorker(state: .init(), destination: url)
        let transport = BrowserSyncMemoryTransport(cloud: BrowserSyncMemoryCloud(), account: "synthetic")
        func cycle(_ session: BrowserSessionDocument) async throws {
            let snapshot = BrowserSyncWorker.Snapshot(session: session, settings: .init())
            try await worker.admit("synthetic")
            let outgoing = try await worker.capture(snapshot, now: fixture.date)
            try await worker.merge(await transport.exchange(outgoing), identity: "synthetic")
            let prepared = try await worker.prepare(snapshot, now: fixture.date)
            try await worker.acknowledge(prepared.projection)
        }
        try await cycle(fixture.document())
        let before = await worker.persistenceCounts()
        try await cycle(fixture.document(title: "Changed"))
        let after = await worker.persistenceCounts()
        #expect(after.replicaWrites - before.replicaWrites == 1)
        #expect(after.writes - before.writes == 2) // one replica, one subsequent eager clock
    }

    @Test func restartAndFailedBarriers() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("replica.json")
        var state = BrowserSyncState()
        try state.replica.capture(projection(), now: now)
        try state.save(url)
        for _ in 0..<8 {
            state = try BrowserSyncState.load(url)
            var writer = BrowserSyncClockPersistence(state: state, destination: url)
            try writer.save(state, to: url)
            #expect(writer.writes == 1 && writer.replicaWrites == 0 && writer.bytesWritten == 72)
            try state.replica.capture(projection(), now: now)
            try writer.save(state, to: url)
            #expect(writer.writes == 2 && writer.replicaWrites == 0 && writer.bytesWritten == 144)
        }
        for boundary in BrowserPermissionFile.WriteBarrier.allCases {
            let prior = state
            var writer = BrowserSyncClockPersistence(state: state, destination: url)
            try state.replica.capture(projection(), now: now)
            #expect(throws: BrowserPermissionFile.Failure.io) {
                try writer.save(state, to: url) { bytes, target, limit in
                    try BrowserPermissionFile.save(bytes, to: target, maximumBytes: limit, barrier: {
                        if $0 == boundary { throw BrowserPermissionFile.Failure.io }
                    })
                }
            }
            // Retry the pending state even if rename succeeded before the failure.
            try writer.save(state, to: url)
            #expect(writer.writes == 1)
            #expect(try BrowserSyncReplica.encodeValue(BrowserSyncState.load(url)) == BrowserSyncReplica.encodeValue(state))
            #expect(state.replica.tick > prior.replica.tick)
        }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_SYNC_CLOCK_CRASH_PHASE"] != nil))
struct BrowserSyncClockProcessCrashTests {
    @Test func barrier() async throws {
        let env = ProcessInfo.processInfo.environment
        let phase = env["ORBIT_SYNC_CLOCK_CRASH_PHASE"] ?? ""
        let path = env["ORBIT_SYNC_CLOCK_CRASH_ROOT"] ?? ""
        guard path.hasPrefix("/private/tmp/perf-sync-idle-3/clock-crash-") else { throw BrowserSyncError.unavailable }
        let root = URL(fileURLWithPath: path), url = root.appendingPathComponent("replica.json")
        let fixture = BrowserSyncClockPersistenceTests()
        if phase == "recover" {
            let actual = try BrowserSyncState.load(url)
            let expected = try JSONDecoder().decode(BrowserSyncState.self, from: Data(contentsOf: root.appendingPathComponent("expected.json")))
            #expect(try BrowserSyncReplica.encodeValue(actual) == BrowserSyncReplica.encodeValue(expected))
            let allStamps = actual.replica.records.values.flatMap { [$0.life.time] + $0.fields.values.map(\.stamp.time) }
            #expect(actual.replica.tick >= (allStamps.max() ?? 0))
            // Continue after the kill with three fake devices, rollback time, edits,
            // tombstones, revivals, idle captures, offline turns and disk reloads.
            var originals = [expected, BrowserSyncState(), BrowserSyncState()]
            originals[1].replica = .init(device: "peer-1"); originals[2].replica = .init(device: "peer-2")
            var resumed = BrowserSyncClockPersistence(state: actual, destination: url)
            try resumed.save(actual, to: url)
            #expect(resumed.writes == 1 && resumed.replicaWrites == 0)
            #expect(try BrowserSyncReplica.encodeValue(BrowserSyncState.load(url)) == BrowserSyncReplica.encodeValue(expected))
            var recovered = originals; recovered[0] = actual
            let oldCloud = BrowserSyncMemoryCloud(), newCloud = BrowserSyncMemoryCloud()
            let oldTransport = BrowserSyncMemoryTransport(cloud: oldCloud, account: "synthetic")
            let newTransport = BrowserSyncMemoryTransport(cloud: newCloud, account: "synthetic")
            for turn in 0..<45 {
                let index = turn % 3, target = root.appendingPathComponent("future-\(index).json")
                let projection = turn % 7 == 0 ? BrowserSyncProjection() : fixture.projection("Title \(turn / 6)")
                let now = Date(timeIntervalSince1970: Double(turn % 2))
                var writer = BrowserSyncClockPersistence(state: recovered[index], destination: target)
                try originals[index].replica.capture(projection, now: now)
                try recovered[index].replica.capture(projection, now: now)
                if turn % 5 != 0 {
                    try originals[index].replica.merge(await oldTransport.exchange(Array(originals[index].replica.records.values)))
                    try recovered[index].replica.merge(await newTransport.exchange(Array(recovered[index].replica.records.values)))
                }
                try writer.save(recovered[index], to: target)
                recovered[index] = try BrowserSyncState.load(target)
                #expect(try BrowserSyncReplica.encodeValue(recovered[index]) == BrowserSyncReplica.encodeValue(originals[index]))
            }
            print("CLOCK_CRASH_RECOVERY exact_state=true future_turns=45 devices=3")
            return
        }
        var state = BrowserSyncState(); state.replica = .init(device: "synthetic-clock")
        try state.replica.capture(fixture.projection(), now: fixture.now)
        try state.save(url)
        var writer = BrowserSyncClockPersistence(state: state, destination: url)
        // Start with an existing clock record so content replacements must supersede it.
        if env["ORBIT_SYNC_CLOCK_CRASH_FIRST"] != "1" {
            for _ in 0..<3 { try state.replica.capture(fixture.projection(), now: fixture.now); try writer.save(state, to: url) }
        }
        let previous = state
        let contentChange = env["ORBIT_SYNC_CLOCK_CRASH_CONTENT"] == "1"
        if env["ORBIT_SYNC_CLOCK_CRASH_RESUME"] == "1" {
            writer = BrowserSyncClockPersistence(state: try BrowserSyncState.load(url), destination: url)
        } else {
            try state.replica.capture(fixture.projection(contentChange ? "Changed" : "Synthetic"), now: fixture.now)
        }
        let committed = ["replaced", "directorySynced", "completed"].contains(phase)
        try BrowserSyncReplica.encodeValue(committed ? state : previous).write(to: root.appendingPathComponent("expected.json"))
        func terminate(_ point: String) {
            if phase == point {
                try! Data(String(getpid()).utf8).write(to: root.appendingPathComponent("ready"))
                // The external harness kills this exact synthetic test PID.
                raise(SIGSTOP)
            }
        }
        terminate("before")
        try writer.save(state, to: url) { bytes, target, limit in
            #expect(target == (contentChange ? url : BrowserSyncClockPersistence.clockURL(url)))
            try BrowserPermissionFile.save(bytes, to: target, maximumBytes: limit,
                beforeReplace: { terminate("beforeReplace") }, barrier: { terminate($0.rawValue) })
        }
        terminate("completed")
        Issue.record("Requested crash boundary was not reached")
    }
}
