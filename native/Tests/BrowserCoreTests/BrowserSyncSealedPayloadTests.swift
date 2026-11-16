import CloudKit
import Foundation
import Testing
@testable import BrowserCore

/// Sync payloads live in CloudKit encrypted values; plaintext records from earlier builds are
/// still read and rewritten. Fake CKRecords only: no container, engine or account.
@Suite("Sealed sync payloads", .serialized)
struct BrowserSyncSealedPayloadTests {
    private let now = Date()

    private func root() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("sealed-sync-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    private func batch(_ marker: String, profile: ProfileID = ProfileID()) -> BrowserHistorySyncBatch {
        let visit = BrowserHistoryVisit(url: URL(string: "https://sealed.test/\(marker)")!, title: "Title \(marker)",
            visitedAt: now.addingTimeInterval(-60), transition: .link, faviconReference: nil, typedCount: 0)
        return BrowserHistorySyncBatch(profileID: profile, cutoff: BrowserHistorySyncSchema.cutoff(now),
            events: [BrowserHistorySyncEvent(visit: visit, time: now)])
    }

    private func organizationRecord(_ id: String) -> BrowserSyncRecord {
        let stamp = BrowserSyncStamp(time: 1, device: "synthetic")
        return BrowserSyncRecord(id: id, fields: ["title": .init(value: Data("\"Sealed Title\"".utf8), stamp: stamp)],
                                 life: stamp, deleted: false)
    }

    private func legacyRecord(type: String, zone: String, name: String, payload: Data) -> CKRecord {
        let record = CKRecord(recordType: type, recordID: .init(recordName: name, zoneID: .init(zoneName: zone)))
        record[BrowserSyncSealedPayload.legacyField] = payload as CKRecordValue
        return record
    }

    /// The saved record must carry the payload only in encrypted values and delete the
    /// plaintext field on the server (a nil value is a changed key).
    private func expectSealed(_ record: CKRecord?, contains marker: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let record else { Issue.record("No record", sourceLocation: sourceLocation); return }
        let sealed = record.encryptedValues[BrowserSyncSealedPayload.field] as? Data
        #expect(sealed.map { String(decoding: $0, as: UTF8.self).contains(marker) } == true, sourceLocation: sourceLocation)
        #expect(record[BrowserSyncSealedPayload.legacyField] == nil, sourceLocation: sourceLocation)
        #expect(record.changedKeys().contains(BrowserSyncSealedPayload.legacyField), sourceLocation: sourceLocation)
        #expect(Set(record.allKeys()) == [BrowserSyncSealedPayload.field], sourceLocation: sourceLocation)
        #expect(record.encryptedValues.allKeys() == [BrowserSyncSealedPayload.field], sourceLocation: sourceLocation)
    }

    @Test("Payload helper writes sealed only, reads sealed and legacy")
    func helper() {
        let record = CKRecord(recordType: "T", recordID: .init(recordName: "a", zoneID: .init(zoneName: "Z")))
        record[BrowserSyncSealedPayload.legacyField] = Data("old".utf8) as CKRecordValue
        #expect(BrowserSyncSealedPayload.isLegacy(record))
        #expect(BrowserSyncSealedPayload.read(record) == Data("old".utf8))
        BrowserSyncSealedPayload.write(Data("new".utf8), to: record)
        #expect(!BrowserSyncSealedPayload.isLegacy(record))
        #expect(BrowserSyncSealedPayload.read(record) == Data("new".utf8))
        #expect(record[BrowserSyncSealedPayload.legacyField] == nil)
    }

    @Test("History: saves are sealed; legacy records decode; the rewrite runs once per cache")
    func history() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("sync.json.history.cloudkit")
        let own = batch("own-visit")
        var transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        _ = try await transport.exchange([own], now: now)
        #expect(await transport.sealedRewrites == 0)
        expectSealed(await transport.record(.init(recordName: own.id.uuidString, zoneID: .init(zoneName: BrowserHistorySyncSchema.zone))),
                     contains: "own-visit")
        // A record written in plaintext by an older build is still accepted.
        let remote = batch("legacy-visit")
        try await transport.accept(legacyRecord(type: BrowserHistorySyncSchema.recordType, zone: BrowserHistorySyncSchema.zone,
                                                name: remote.id.uuidString, payload: try remote.encoded()))
        #expect(await transport.cachedRecordIDs.contains(remote.id.uuidString))
        expectSealed(await transport.record(.init(recordName: remote.id.uuidString, zoneID: .init(zoneName: BrowserHistorySyncSchema.zone))),
                     contains: "legacy-visit")
        // Marker written: reopening does not queue the rewrite again.
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathExtension("sealed-v1").path))
        transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        _ = try await transport.exchange([own], now: now.addingTimeInterval(1))
        #expect(await transport.sealedRewrites == 0)
        // A cache from a build before sealing (no marker) queues this Mac's cached records once.
        try FileManager.default.removeItem(at: destination.appendingPathExtension("sealed-v1"))
        transport = try BrowserHistoryCloudKitTransport(testDestination: destination)
        _ = try await transport.exchange([own], now: now.addingTimeInterval(2))
        #expect(await transport.sealedRewrites == 1)
        #expect(await transport.dirtyRecordIDs.contains(own.id.uuidString))
        // Other Macs' records are left to their owners (or expire with the history window).
        #expect(await !transport.dirtyRecordIDs.contains(remote.id.uuidString))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathExtension("sealed-v1").path))
        await transport.stop()
    }

    @Test("Organization: saves are sealed; a legacy record is accepted and queued for a sealed save")
    func organization() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("sync.json.cloudkit")
        let local = organizationRecord("space-local")
        var transport = try BrowserCloudKitTransport(testDestination: destination)
        _ = try await transport.exchange([local], now: now)
        expectSealed(await transport.record(.init(recordName: local.id, zoneID: .init(zoneName: BrowserSyncSchema.zone))),
                     contains: "space-local")
        let legacy = organizationRecord("space-legacy")
        try await transport.accept(legacyRecord(type: BrowserSyncSchema.recordType, zone: BrowserSyncSchema.zone,
                                                name: legacy.id, payload: try BrowserSyncReplica.encodeValue(legacy)))
        #expect(await transport.dirtyRecordIDs.contains(legacy.id))
        expectSealed(await transport.record(.init(recordName: legacy.id, zoneID: .init(zoneName: BrowserSyncSchema.zone))),
                     contains: "space-legacy")
        _ = try await transport.exchange([local, legacy], now: now.addingTimeInterval(1))
        // The one-time rewrite covers every record this replica exchanges, then never again.
        try FileManager.default.removeItem(at: destination.appendingPathExtension("sealed-v1"))
        transport = try BrowserCloudKitTransport(testDestination: destination)
        _ = try await transport.exchange([local, legacy], now: now.addingTimeInterval(2))
        #expect(await transport.sealedRewrites == 2)
        transport = try BrowserCloudKitTransport(testDestination: destination)
        _ = try await transport.exchange([local, legacy], now: now.addingTimeInterval(3))
        #expect(await transport.sealedRewrites == 0)
        // A record in neither field is refused.
        let empty = CKRecord(recordType: BrowserSyncSchema.recordType, recordID: .init(recordName: "space/empty", zoneID: .init(zoneName: BrowserSyncSchema.zone)))
        await #expect(throws: BrowserSyncError.invalidRecord) { try await transport.accept(empty) }
        await transport.stop()
    }

    @Test("Password sync choice: off for new setups, kept on for existing syncing users")
    func passwordChoiceDefaults() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("sync.json")
        #expect(BrowserSyncState().syncsPasswords == false)
        var fresh = BrowserSyncState(); fresh.enabled = true
        #expect(fresh.syncsPasswords == false)
        // A state file from an earlier build has no password key.
        for enabled in [true, false] {
            var legacy = BrowserSyncState(); legacy.enabled = enabled; legacy.passwords = nil
            try legacy.save(destination)
            #expect(!String(decoding: try Data(contentsOf: destination), as: UTF8.self).contains("\"passwords\""))
            #expect(try BrowserSyncState.load(destination).syncsPasswords == enabled)
            #expect(try BrowserSyncState.load(destination).passwords == enabled)
        }
        var chosen = BrowserSyncState(); chosen.enabled = true; chosen.passwords = false
        try chosen.save(destination)
        #expect(try BrowserSyncState.load(destination).syncsPasswords == false)
        chosen.passwords = true
        try chosen.save(destination)
        #expect(try BrowserSyncState.load(destination).syncsPasswords == true)
    }
}
