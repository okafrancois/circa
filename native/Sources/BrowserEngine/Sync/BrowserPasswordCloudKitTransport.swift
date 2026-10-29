import BrowserCore
import CloudKit
import Foundation
import Security

/// CKContainer is constructed only after inspecting the running signature. The account-bound
/// transport persists CKSyncEngine tokens AND record system fields, including server change tags.
public actor BrowserPasswordCloudKitTransport: BrowserPasswordSyncTransport, CKSyncEngineDelegate {
    private struct State: Codable {
        var engine: CKSyncEngine.State.Serialization?
        var records: [String: BrowserPasswordSyncEntry] = [:]
        var dirty: Set<String> = []
        var systemFields: [String: Data] = [:]
    }
    private let container: CKContainer
    private let cache: BrowserPasswordSyncCache
    private let identity: String
    private let zone = CKRecordZone.ID(zoneName: BrowserPasswordSyncSchema.zone)
    private var state: State
    private var engine: CKSyncEngine?
    private var stopped = false
    private var failure: (any Error)?

    public init(cache: BrowserPasswordSyncCache, identity: String) throws {
        guard BrowserSyncEntitlement.isAvailable() else { throw BrowserSyncError.unavailable }
        container = CKContainer(identifier: BrowserSyncSchema.container)
        self.cache = cache; self.identity = identity
        state = try cache.load(State.self) ?? State()
    }

    public func account() async throws -> String? {
        guard try await container.accountStatus() == .available else { return nil }
        return try await container.userRecordID().recordName
    }

    private func admitted() async throws {
        guard !stopped else { throw BrowserSyncError.unavailable }
        guard let current = try await account() else { throw BrowserSyncError.signedOut }
        guard current == identity else { throw BrowserSyncError.accountChanged }
    }

    public func exchange(_ records: [BrowserPasswordSyncEntry]) async throws -> [BrowserPasswordSyncEntry] {
        try await admitted()
        if let failure { throw failure }
        if engine == nil {
            var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                stateSerialization: state.engine, delegate: self)
            configuration.automaticallySync = true
            engine = CKSyncEngine(configuration)
        }
        guard let engine else { throw BrowserSyncError.unavailable }
        var fetch = CKSyncEngine.FetchChangesOptions()
        fetch.scope = .zoneIDs([zone])
        try await engine.fetchChanges(fetch)
        if let failure { throw failure }
        try await admitted()
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for record in records {
            let old = state.records[record.id.uuidString]
            var merged = old ?? record
            try merged.merge(record)
            if old != merged {
                state.records[record.id.uuidString] = merged
                state.dirty.insert(record.id.uuidString)
            }
            if state.dirty.contains(record.id.uuidString) {
                pending.append(.saveRecord(.init(recordName: record.id.uuidString, zoneID: zone)))
            }
        }
        try persist()
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
        engine.state.add(pendingRecordZoneChanges: pending)
        try await engine.sendChanges()
        if let failure { throw failure }
        try await admitted()
        return Array(state.records.values)
    }

    public func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                        syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs([zone])
        return options
    }

    public func stop() async {
        stopped = true
        await engine?.cancelOperations()
        engine = nil
        state = State()
    }

    private func persist() throws {
        try cache.save(state)
    }

    private func accept(_ record: CKRecord) throws {
        let incoming = try BrowserPasswordSyncEntry.fromCloud(record)
        var merged = state.records[incoming.id.uuidString] ?? incoming
        try merged.merge(incoming)
        state.records[incoming.id.uuidString] = merged
        if merged != incoming { state.dirty.insert(incoming.id.uuidString) }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver); archiver.finishEncoding()
        state.systemFields[incoming.id.uuidString] = archiver.encodedData
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .accountChange(let event):
                if case .signIn(let user) = event.changeType, user.recordName == identity { return }
                // Freeze immediately. A new transport requires the persisted marker's admission.
                stopped = true
                Task { await syncEngine.cancelOperations() }
            case .stateUpdate(let event):
                guard !stopped, failure == nil else { return }
                state.engine = event.stateSerialization
                try persist()
            case .fetchedRecordZoneChanges(let event):
                try await admitted()
                for modification in event.modifications where modification.record.recordID.zoneID == zone { try accept(modification.record) }
                // Logical deletions travel as tombstones. Physical deletions require a full
                // rescan; never interpret them as permission to erase local user data.
                if event.deletions.contains(where: { $0.recordID.zoneID == zone }) { throw BrowserSyncError.invalidRecord }
                try persist()
            case .sentRecordZoneChanges(let event):
                try await admitted()
                for record in event.savedRecords {
                    try accept(record)
                    if let bytes = record.encryptedValues[BrowserPasswordSyncSchema.field] as? Data,
                       let sent = try? JSONDecoder().decode(BrowserPasswordSyncEntry.self, from: bytes),
                       state.records[sent.id.uuidString] == sent { state.dirty.remove(sent.id.uuidString) }
                }
                for failed in event.failedRecordSaves {
                    switch failed.error.code {
                    case .serverRecordChanged:
                        guard let server = failed.error.serverRecord else { throw BrowserSyncError.invalidRecord }
                        try accept(server)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    case .zoneNotFound:
                        // A Keychain reset cannot authorize replacing an unreadable vault.
                        guard (failed.error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? NSNumber)?.boolValue != true else {
                            throw BrowserSyncError.unavailable
                        }
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    default: throw failed.error
                    }
                }
                try persist()
            case .fetchedDatabaseChanges(let event):
                if event.deletions.contains(where: { $0.zoneID == zone }) { throw BrowserSyncError.invalidRecord }
            default: break
            }
        } catch { failure = error }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                         syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard failure == nil else { return nil }
        do { try await admitted() } catch { failure = error; return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            await self?.record(recordID)
        }
    }

    private func record(_ recordID: CKRecord.ID) -> CKRecord? {
        do {
            guard !stopped, recordID.zoneID == zone, let value = state.records[recordID.recordName] else { return nil }
            return try value.cloudRecord(systemFields: state.systemFields[value.id.uuidString])
        } catch { failure = error; return nil }
    }
}

extension BrowserPasswordSyncEntry {
    func cloudRecord(systemFields: Data? = nil) throws -> CKRecord {
        try validate()
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: .init(zoneName: BrowserPasswordSyncSchema.zone))
        let record: CKRecord
        if let systemFields {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: systemFields)
            decoder.requiresSecureCoding = true
            guard let decoded = CKRecord(coder: decoder), decoded.recordID == recordID,
                  decoded.recordType == BrowserPasswordSyncSchema.recordType else { throw BrowserSyncError.invalidRecord }
            decoder.finishDecoding(); record = decoded
        } else { record = CKRecord(recordType: BrowserPasswordSyncSchema.recordType, recordID: recordID) }
        guard Set(record.allKeys()).subtracting(record.encryptedValues.allKeys()).isEmpty else { throw BrowserSyncError.invalidRecord }
        var bytes = try Self.encodeValue(self)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        record.encryptedValues[BrowserPasswordSyncSchema.field] = bytes as CKRecordValue
        return record
    }
    static func fromCloud(_ record: CKRecord) throws -> Self {
        guard record.recordID.zoneID == CKRecordZone.ID(zoneName: BrowserPasswordSyncSchema.zone),
              record.recordType == BrowserPasswordSyncSchema.recordType, Set(record.allKeys()).subtracting(record.encryptedValues.allKeys()).isEmpty,
              var bytes = record.encryptedValues[BrowserPasswordSyncSchema.field] as? Data else { throw BrowserSyncError.invalidRecord }
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        guard value.id.uuidString == record.recordID.recordName else { throw BrowserSyncError.invalidRecord }
        return value
    }
}
