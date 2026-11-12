import CloudKit
import CryptoKit
import Foundation

/// CKContainer is constructed only after inspecting the running signature. The account-bound
/// transport persists CKSyncEngine tokens AND record system fields, including server change tags. History has an independent zone and failure boundary.
public actor BrowserHistoryCloudKitTransport: BrowserHistorySyncTransport, CKSyncEngineDelegate {
    private struct State: Codable {
        var engine: CKSyncEngine.State.Serialization?
        var records: [String: BrowserHistorySyncBatch] = [:]
        var dirty: Set<String> = []
        var deleting: Set<String> = []
        var systemFields: [String: Data] = [:]
    }
    private struct EngineCheckpoint: Codable {
        var stateDigest: Data
        var serialization: Data
    }
    private var stateDigest: Data?
    private let container: CKContainer?
    private let destination: URL
    private let identity: String
    private let zone = CKRecordZone.ID(zoneName: BrowserHistorySyncSchema.zone)
    private var state: State { didSet { needsPersist = true } }
    private var needsPersist = false
    private var engineSerialization: CKSyncEngine.State.Serialization?
    private var enginePersistence = BrowserSyncPersistence()
    private var lastInput: [BrowserHistorySyncBatch]?
    private var lastExchange: Date?
    private var remoteRevision = 0
    private var exchangedRevision = -1
    private(set) var validations = 0
    private(set) var fullStateEncodes = 0
    private(set) var explicitExchanges = 0
    private var engine: CKSyncEngine?
    private var persistence = BrowserSyncPersistence()
    var stateWrites: Int { persistence.writes }
    private var stopped = false
    private var failure: (any Error)?

    public init(destination: URL, identity: String) throws {
        guard BrowserSyncEntitlement.isAvailable() else { throw BrowserSyncError.unavailable }
        container = CKContainer(identifier: BrowserSyncSchema.container)
        self.destination = destination; self.identity = identity
        if let bytes = try BrowserPermissionFile.load(destination, maximumBytes: 256 * 1024 * 1024) {
            state = try JSONDecoder().decode(State.self, from: bytes)
            stateDigest = Data(SHA256.hash(data: bytes))
        } else { state = State() }
        engineSerialization = state.engine
        if let bytes = try BrowserPermissionFile.load(destination.appendingPathExtension("engine"), maximumBytes: 16 * 1024 * 1024) {
            if let checkpoint = try? JSONDecoder().decode(EngineCheckpoint.self, from: bytes),
               checkpoint.stateDigest == stateDigest {
                if let decoded = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: checkpoint.serialization) {
                    engineSerialization = decoded
                }
            }
        }
    }

    /// Account-free seam that exercises the production cache and persistence path.
    init(testDestination: URL) throws {
        container = nil; destination = testDestination; identity = "synthetic"
        if let bytes = try BrowserPermissionFile.load(testDestination, maximumBytes: 256 * 1024 * 1024) {
            state = try JSONDecoder().decode(State.self, from: bytes)
            stateDigest = Data(SHA256.hash(data: bytes))
        } else { state = State() }
        engineSerialization = state.engine
    }

    public func account() async throws -> String? {
        guard let container else { return identity }
        guard try await container.accountStatus() == .available else { return nil }
        return try await container.userRecordID().recordName
    }

    private func admitted() async throws {
        guard !stopped else { throw BrowserSyncError.unavailable }
        guard let current = try await account() else { throw BrowserSyncError.signedOut }
        guard current == identity else { throw BrowserSyncError.accountChanged }
    }

    public func exchange(_ records: [BrowserHistorySyncBatch], now: Date = Date()) async throws -> [BrowserHistorySyncBatch] {
        try await admitted()
        if let failure { throw failure }
        if let lastExchange, now.timeIntervalSince(lastExchange) >= 0,
           now.timeIntervalSince(lastExchange) < 300,
           BrowserHistorySyncSchema.cutoff(lastExchange) == BrowserHistorySyncSchema.cutoff(now), exchangedRevision == remoteRevision,
           let lastInput, lastInput == records {
            return Array(state.records.values)
        }
        explicitExchanges += 1
        if engine == nil, let container {
            var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                stateSerialization: engineSerialization, delegate: self)
            configuration.automaticallySync = true
            engine = CKSyncEngine(configuration)
        }
        var fetch = CKSyncEngine.FetchChangesOptions()
        fetch.scope = .zoneIDs([zone])
        try await engine?.fetchChanges(fetch)
        if let failure { throw failure }
        try await admitted()
        let cutoff = BrowserHistorySyncSchema.cutoff(now)
        for (id, value) in state.records where value.expires < cutoff {
            state.deleting.insert(id)
            state.records.removeValue(forKey: id); state.dirty.remove(id)
        }
        var pending: [CKSyncEngine.PendingRecordZoneChange] = state.deleting.map {
            .deleteRecord(.init(recordName: $0, zoneID: zone))
        }
        for record in records where record.expires >= cutoff {
            let id = record.id.uuidString
            if let old = state.records[id] {
                guard old == record else { throw BrowserSyncError.invalidRecord }
            } else {
                validations += 1
                try record.validate()
                state.records[id] = record; state.dirty.insert(id)
            }
            if state.dirty.contains(id) { pending.append(.saveRecord(.init(recordName: id, zoneID: zone))) }
        }
        try persist()
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
        engine?.state.add(pendingRecordZoneChanges: pending)
        try await engine?.sendChanges()
        if let failure { throw failure }
        try await admitted()
        lastInput = records; lastExchange = now; exchangedRevision = remoteRevision
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
    }

    private func persist() throws {
        guard needsPersist else { return }
        state.engine = engineSerialization
        fullStateEncodes += 1
        let bytes = try BrowserSyncReplica.encodeValue(state)
        try persistence.save(bytes, to: destination, maximumBytes: 256 * 1024 * 1024)
        stateDigest = Data(SHA256.hash(data: bytes))
        needsPersist = false
    }

    /// The record cache must be durable before a newer engine cursor is published.
    func persistEngineCheckpoint(_ bytes: Data) throws {
        try persist()
        if stateDigest == nil { needsPersist = true; try persist() }
        guard let stateDigest else { throw BrowserSyncError.invalidRecord }
        let checkpoint = EngineCheckpoint(stateDigest: stateDigest, serialization: bytes)
        try enginePersistence.save(BrowserSyncReplica.encodeValue(checkpoint),
            to: destination.appendingPathExtension("engine"), maximumBytes: 16 * 1024 * 1024)
    }

    func accept(_ record: CKRecord) throws {
        guard record.recordID.zoneID == zone, record.recordType == BrowserHistorySyncSchema.recordType,
              let bytes = record["payload"] as? Data, bytes.count <= BrowserHistorySyncSchema.maximumBytes else { throw BrowserSyncError.invalidRecord }
        let incoming = try JSONDecoder().decode(BrowserHistorySyncBatch.self, from: bytes)
        if state.records[incoming.id.uuidString] != incoming {
            validations += 1
            try incoming.validate(encodedSize: bytes.count)
        }
        let id = incoming.id.uuidString
        guard id == record.recordID.recordName,
              state.records[id].map({ $0 == incoming }) ?? true else { throw BrowserSyncError.invalidRecord }
        if state.records[id] == nil { state.records[id] = incoming; remoteRevision += 1 }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver); archiver.finishEncoding()
        if state.systemFields[id] != archiver.encodedData { state.systemFields[id] = archiver.encodedData }
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
                try persistEngineCheckpoint(BrowserSyncReplica.encodeValue(event.stateSerialization))
                engineSerialization = event.stateSerialization
            case .fetchedRecordZoneChanges(let event):
                try await admitted()
                for modification in event.modifications where modification.record.recordID.zoneID == zone { try accept(modification.record) }
                // Physical pruning removes expired transport cache only, never local visits.
                for deletion in event.deletions where deletion.recordID.zoneID == zone {
                    let id = deletion.recordID.recordName
                    if state.records[id] != nil { state.records.removeValue(forKey: id); remoteRevision += 1 }
                    if state.systemFields[id] != nil { state.systemFields.removeValue(forKey: id) }
                }
                try persist()
            case .sentRecordZoneChanges(let event):
                try await admitted()
                for record in event.savedRecords {
                    try accept(record)
                    if let bytes = record["payload"] as? Data,
                       let sent = try? JSONDecoder().decode(BrowserHistorySyncBatch.self, from: bytes),
                       state.records[sent.id.uuidString] == sent, state.dirty.contains(sent.id.uuidString) {
                        state.dirty.remove(sent.id.uuidString)
                    }
                }
                for id in event.deletedRecordIDs {
                    if state.deleting.contains(id.recordName) { state.deleting.remove(id.recordName) }
                    if state.systemFields[id.recordName] != nil { state.systemFields.removeValue(forKey: id.recordName) }
                }
                for failed in event.failedRecordDeletes.values where failed.code != .unknownItem { throw failed }
                for failed in event.failedRecordSaves {
                    switch failed.error.code {
                    case .serverRecordChanged:
                        guard let server = failed.error.serverRecord else { throw BrowserSyncError.invalidRecord }
                        try accept(server)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    case .zoneNotFound:
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
            let record: CKRecord
            if let bytes = state.systemFields[value.id.uuidString] {
                let decoder = try NSKeyedUnarchiver(forReadingFrom: bytes)
                decoder.requiresSecureCoding = true
                guard let decoded = CKRecord(coder: decoder) else { throw BrowserSyncError.invalidRecord }
                decoder.finishDecoding(); record = decoded
            } else { record = CKRecord(recordType: BrowserHistorySyncSchema.recordType, recordID: recordID) }
            record["payload"] = try BrowserSyncReplica.encodeValue(value) as CKRecordValue
            return record
        } catch { failure = error; return nil }
    }
}
