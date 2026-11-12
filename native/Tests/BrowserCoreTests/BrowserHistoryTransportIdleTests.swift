import CloudKit
import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite(.serialized)
struct BrowserHistoryTransportIdleTests {
    private func cpu() -> Double {
        var value = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1e9
    }

    @Test func idleTransport() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/history-transport-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("history.json")
        let transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        let now = Date(), profile = ProfileID()
        let events = (0..<200).map { index in
            BrowserHistorySyncEvent(visit: BrowserHistoryVisit(url: URL(string: "https://example.invalid/\(index)")!,
                title: String(repeating: "Synthetic ", count: 11), visitedAt: now), time: now)
        }
        let batches = (0..<200).map { _ in
            BrowserHistorySyncBatch(profileID: profile, cutoff: BrowserHistorySyncSchema.cutoff(now), events: events)
        }
        _ = try await transport.exchange(batches, now: now)
        let before = await (transport.validations, transport.fullStateEncodes, transport.explicitExchanges)
        let writes = await transport.stateWrites
        let bytes = try Data(contentsOf: destination)
        var start = cpu()
        for index in 1...10 {
            // Runtime assembles a fresh outer array from each profile's cached batches.
            let input = batches.map { $0 }
            #expect(try await transport.exchange(input, now: now.addingTimeInterval(Double(index) * 5)).count == 200)
        }
        let newCPU = (cpu() - start) * 1000 / 10
        #expect(await transport.validations == before.0)
        #expect(await transport.fullStateEncodes == before.1)
        #expect(await transport.explicitExchanges == before.2)
        // Exercise the same persistence barrier as stateUpdate with opaque engine tokens.
        for index in 0..<10 { try await transport.persistEngineCheckpoint(Data("token-\(index)".utf8)) }
        #expect(await transport.fullStateEncodes == before.1)
        #expect(try Data(contentsOf: destination.appendingPathExtension("engine")).count < 256)
        #expect(await transport.stateWrites == writes)
        #expect(try Data(contentsOf: destination) == bytes)
        // A safety fetch rechecks immutable identities without revalidating or encoding them.
        _ = try await transport.exchange(batches, now: now.addingTimeInterval(301))
        #expect(await transport.explicitExchanges == before.2 + 1)
        #expect(await transport.validations == before.0)
        #expect(await transport.fullStateEncodes == before.1)
        let remote = BrowserHistorySyncBatch(profileID: profile, cutoff: BrowserHistorySyncSchema.cutoff(now), events: [])
        let record = CKRecord(recordType: BrowserHistorySyncSchema.recordType,
            recordID: .init(recordName: remote.id.uuidString, zoneID: .init(zoneName: BrowserHistorySyncSchema.zone)))
        record["payload"] = try remote.encoded() as CKRecordValue
        try await transport.accept(record)
        #expect(try await transport.exchange(batches, now: now.addingTimeInterval(302)).count == 201)
        #expect(await transport.validations == before.0 + 1)
        #expect(await transport.fullStateEncodes == before.1 + 1)
        let accepted = await transport.validations
        try await transport.accept(record)
        #expect(await transport.validations == accepted)
        let reopened = try BrowserHistoryCloudKitTransport(testDestination: destination)
        _ = try await reopened.exchange(batches, now: now)
        #expect(await reopened.validations == 0)
        #expect(await reopened.fullStateEncodes == 0)
        let conflict = BrowserHistorySyncBatch(id: batches[0].id, profileID: profile,
            cutoff: batches[0].cutoff, events: [])
        await #expect(throws: BrowserSyncError.invalidRecord) { try await reopened.exchange([conflict], now: now) }
        await reopened.stop()
        await #expect(throws: BrowserSyncError.unavailable) { try await reopened.exchange(batches, now: now) }

        // Frozen old hot path: every retained record validated, then full state encoded at
        // exchange and two representative engine events. Network latency is excluded.
        struct LegacyState: Codable {
            var records: [String: BrowserHistorySyncBatch]
            var dirty: Set<String>
            var deleting: Set<String> = []
            var systemFields: [String: Data] = [:]
        }
        let legacy = LegacyState(records: Dictionary(uniqueKeysWithValues: batches.map { ($0.id.uuidString, $0) }),
            dirty: Set(batches.map { $0.id.uuidString }))
        var encodedBytes = 0
        start = cpu()
        for _ in 0..<3 {
            for batch in batches { try batch.validate() }
            for _ in 0..<3 { encodedBytes += try BrowserSyncReplica.encodeValue(legacy).count }
        }
        let oldCPU = (cpu() - start) * 1000 / 3
        #expect(encodedBytes > 0)
        print("HISTORY_TRANSPORT_BENCH batches=200 state_bytes=\(bytes.count) old_cpu_ms=\(oldCPU) new_cpu_ms=\(newCPU) idle_validations=0 idle_full_encodes=0 idle_explicit_exchanges=0")
    }

    @Test func failedWriteRetainsDirtyState() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/history-write-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try BrowserHistoryCloudKitTransport(testDestination: root.appendingPathComponent("state.json"))
        try Data("blocked parent".utf8).write(to: root)
        let now = Date()
        let batch = BrowserHistorySyncBatch(profileID: ProfileID(), cutoff: BrowserHistorySyncSchema.cutoff(now), events: [])
        await #expect(throws: (any Error).self) { try await transport.exchange([batch], now: now) }
        #expect(await transport.stateWrites == 0)
        try FileManager.default.removeItem(at: root)
        #expect(try await transport.exchange([batch], now: now).count == 1)
        #expect(await transport.validations == 1)
        #expect(await transport.fullStateEncodes == 2)
        #expect(await transport.stateWrites == 1)
    }

    @Test func coalescingAndDurableFlush() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/history-coalesce-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID(), now = Date()
        var store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let visit = BrowserHistoryVisit(url: URL(string: "https://example.invalid/light")!, title: "Synthetic", visitedAt: now)
        _ = try await store.record(visit)
        let initial = try await store.historySyncBatches(now: now, forcePacking: false)
        #expect(initial.flatMap(\.events).isEmpty)
        #expect(try await store.historySyncBatches(now: now.addingTimeInterval(5), forcePacking: false) == initial)
        try await store.close()
        store = try BrowserHistoryStore(profileID: profile, policy: .persistent, directory: root)
        let aged = try await store.historySyncBatches(now: now.addingTimeInterval(61), forcePacking: false)
        #expect(aged.flatMap(\.events).contains { $0.visit?.id == visit.id })
        let second = BrowserHistoryVisit(url: URL(string: "https://example.invalid/flush")!, title: "Synthetic", visitedAt: now)
        _ = try await store.record(second)
        let flushed = try await store.historySyncBatches(now: now, forcePacking: true)
        #expect(flushed.flatMap(\.events).contains { $0.visit?.id == second.id })
        try await store.close()
    }
}
