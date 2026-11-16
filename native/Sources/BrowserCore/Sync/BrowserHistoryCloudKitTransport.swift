import CloudKit
import CryptoKit
import Foundation

/// CKContainer is constructed only after inspecting the running signature. The account-bound
/// transport persists CKSyncEngine tokens AND record system fields, including server change tags. History has an independent zone and failure boundary.
/// The cache lives in SQLite rows beside the legacy JSON file (`<destination>.sqlite`): a cycle
/// writes only the records, flags and tokens it changed, in one transaction.
public actor BrowserHistoryCloudKitTransport: BrowserHistorySyncTransport, CKSyncEngineDelegate {
    /// The in-memory cache. Containers remember the keys written since the last barrier.
    private struct State {
        var records = BrowserSyncTrackedMap<BrowserHistorySyncBatch>()
        var dirty = BrowserSyncTrackedSet()
        var deleting = BrowserSyncTrackedSet()
        var systemFields = BrowserSyncTrackedMap<Data>()
        /// Records deleted remotely (by a retraction here or elsewhere), with their natural expiry.
        /// A local store may still list one until it applies the matching tombstone; it is never
        /// uploaded again.
        var retired: [String: Date]?
    }
    /// The single JSON file written by earlier builds, imported once then deleted.
    private struct LegacyState: Codable {
        var engine: CKSyncEngine.State.Serialization?
        var records: [String: BrowserHistorySyncBatch] = [:]
        var dirty: Set<String> = []
        var deleting: Set<String> = []
        var systemFields: [String: Data] = [:]
        var retired: [String: Date]?
    }
    private struct EngineCheckpoint: Codable {
        var stateDigest: Data
        var serialization: Data
    }
    private let container: CKContainer?
    private let destination: URL
    private let identity: String
    private let zone = CKRecordZone.ID(zoneName: BrowserHistorySyncSchema.zone)
    private var state: State { didSet { needsPersist = true } }
    private var needsPersist = false
    private var engineSerialization: CKSyncEngine.State.Serialization?
    private var lastInput: [BrowserHistorySyncBatch]?
    private var lastExchange: Date?
    private var remoteRevision = 0
    private var exchangedRevision = -1
    private(set) var validations = 0
    private(set) var explicitExchanges = 0
    private var engine: CKSyncEngine?
    /// Opened at launch when the file exists, otherwise at the first write.
    private var store: BrowserHistorySyncStateStore?
    private var persistedRetired: [String: Date]
    private var persistedEngine: Data?
    /// Transactions that changed cache rows, and those that only advanced the engine tokens.
    private(set) var stateWrites = 0
    private(set) var engineWrites = 0
    private var stopped = false
    private var failure: (any Error)?

    public init(destination: URL, identity: String) throws {
        guard BrowserSyncEntitlement.isAvailable() else { throw BrowserSyncError.unavailable }
        container = CKContainer(identifier: BrowserSyncSchema.container)
        self.destination = destination; self.identity = identity
        let (store, snapshot) = try Self.open(destination)
        self.store = store
        state = Self.state(snapshot); persistedRetired = snapshot.retired; persistedEngine = snapshot.engine
        engineSerialization = snapshot.engine.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    }

    /// Account-free seam that exercises the production cache and persistence path.
    init(testDestination: URL) throws {
        container = nil; destination = testDestination; identity = "synthetic"
        let (store, snapshot) = try Self.open(testDestination)
        self.store = store
        state = Self.state(snapshot); persistedRetired = snapshot.retired; persistedEngine = snapshot.engine
        engineSerialization = snapshot.engine.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    }

    static func storeURL(_ destination: URL) -> URL { destination.appendingPathExtension("sqlite") }

    /// Loads the row store, importing the legacy JSON file first when one is present. The import
    /// commits with the file's digest; the file is deleted only afterwards. An interrupted import
    /// rolls back and runs again; a file left after a committed import (same digest) is only
    /// deleted. A file with another digest was written by an earlier build since: it replaces
    /// the rows, exactly as that build would have resumed from it.
    private static func open(_ destination: URL) throws -> (BrowserHistorySyncStateStore?, BrowserHistorySyncStateSnapshot) {
        let url = storeURL(destination)
        let sidecar = destination.appendingPathExtension("engine")
        let legacy = try BrowserPermissionFile.load(destination, maximumBytes: 256 * 1024 * 1024)
        var info = stat()
        let exists = lstat(url.path, &info) == 0
        guard legacy != nil || exists else {
            unlink(sidecar.path)
            return (nil, BrowserHistorySyncStateSnapshot())
        }
        let store = try BrowserHistorySyncStateStore(url: url)
        var snapshot: BrowserHistorySyncStateSnapshot?
        if let legacy {
            let digest = Data(SHA256.hash(data: legacy))
            if try store.importedLegacyDigest() != digest {
                let imported = try legacySnapshot(legacy, digest: digest, sidecar: sidecar)
                try store.importLegacy(imported, digest: digest)
                snapshot = imported
            }
            unlink(destination.path)
        }
        unlink(sidecar.path)
        return (store, try snapshot ?? store.load())
    }

    /// The legacy file plus its engine checkpoint, which counts only when it names this file.
    private static func legacySnapshot(_ bytes: Data, digest: Data, sidecar: URL) throws -> BrowserHistorySyncStateSnapshot {
        let legacy = try JSONDecoder().decode(LegacyState.self, from: bytes)
        var engine = try legacy.engine.map { try BrowserSyncReplica.encodeValue($0) }
        if let checkpointBytes = try BrowserPermissionFile.load(sidecar, maximumBytes: 16 * 1024 * 1024),
           let checkpoint = try? JSONDecoder().decode(EngineCheckpoint.self, from: checkpointBytes),
           checkpoint.stateDigest == digest,
           (try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: checkpoint.serialization)) != nil {
            engine = checkpoint.serialization
        }
        return BrowserHistorySyncStateSnapshot(engine: engine, records: legacy.records, dirty: legacy.dirty,
            deleting: legacy.deleting, systemFields: legacy.systemFields, retired: legacy.retired ?? [:])
    }

    private static func state(_ snapshot: BrowserHistorySyncStateSnapshot) -> State {
        State(records: .init(snapshot.records), dirty: .init(snapshot.dirty), deleting: .init(snapshot.deleting),
              systemFields: .init(snapshot.systemFields), retired: snapshot.retired.isEmpty ? nil : snapshot.retired)
    }

    /// The cache as the next launch would load it (tests compare it with the stored rows).
    var snapshot: BrowserHistorySyncStateSnapshot {
        BrowserHistorySyncStateSnapshot(engine: persistedEngine, records: state.records.storage, dirty: state.dirty.storage,
            deleting: state.deleting.storage, systemFields: state.systemFields.storage, retired: state.retired ?? [:])
    }
    var stateStore: BrowserHistorySyncStateStore? { store }

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
        retract(records, cutoff: cutoff, now: now)
        var pending: [CKSyncEngine.PendingRecordZoneChange] = state.deleting.map {
            .deleteRecord(.init(recordName: $0, zoneID: zone))
        }
        for record in records where record.expires >= cutoff {
            let id = record.id.uuidString
            guard state.retired?[id] == nil else { continue }
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

    /// The history store dropped these batches because they carried deleted history: delete the
    /// records remotely and from this cache file, once. Expired retirement entries are forgotten.
    func retract(_ records: [BrowserHistorySyncBatch], cutoff: Date, now: Date) {
        var retired = state.retired ?? [:]
        let before = retired
        retired = retired.filter { $0.value >= cutoff }
        for notice in records where notice.isRetraction {
            let id = notice.id.uuidString
            guard retired[id] == nil else { continue }
            if let record = state.records[id], record.profileID != notice.profileID { continue }
            retired[id] = state.records[id]?.expires ?? now.addingTimeInterval(BrowserHistorySyncSchema.retention)
            state.deleting.insert(id)
            state.records.removeValue(forKey: id); state.dirty.remove(id)
        }
        if retired != before { state.retired = retired }
    }

    /// A record deleted remotely is never uploaded again by this Mac.
    func remoteDeletion(_ id: String) {
        guard let record = state.records.removeValue(forKey: id) else { return }
        remoteRevision += 1
        state.retired = (state.retired ?? [:]).merging([id: record.expires]) { $1 }
    }

    var cachedRecordIDs: Set<String> { Set(state.records.keys) }
    var pendingDeletions: Set<String> { state.deleting.storage }

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

    /// Writes the rows changed since the last barrier, and the engine tokens when given, in one
    /// transaction. On failure every change stays pending for the next barrier.
    private func persist(engine engineBytes: Data? = nil) throws {
        let engineBytes = engineBytes == persistedEngine ? nil : engineBytes
        guard needsPersist || engineBytes != nil else { return }
        var changes = BrowserHistorySyncStateChanges()
        for id in state.records.touched { changes.records.updateValue(state.records[id], forKey: id) }
        for id in state.systemFields.touched { changes.systemFields.updateValue(state.systemFields[id], forKey: id) }
        for id in state.dirty.touched { changes.dirty[id] = state.dirty.contains(id) }
        for id in state.deleting.touched { changes.deleting[id] = state.deleting.contains(id) }
        let retired = state.retired ?? [:]
        if retired != persistedRetired {
            for (id, expires) in retired where persistedRetired[id] != expires { changes.retired.updateValue(expires, forKey: id) }
            for id in persistedRetired.keys where retired[id] == nil { changes.retired.updateValue(nil, forKey: id) }
        }
        let changesState = !changes.isEmpty
        changes.engine = engineBytes
        if !changes.isEmpty {
            if store == nil { store = try BrowserHistorySyncStateStore(url: Self.storeURL(destination)) }
            try store?.apply(changes)
            if changesState { stateWrites += 1 } else { engineWrites += 1 }
        }
        state.records.clearTouched(); state.systemFields.clearTouched()
        state.dirty.clearTouched(); state.deleting.clearTouched()
        persistedRetired = retired
        if let engineBytes { persistedEngine = engineBytes }
        needsPersist = false
    }

    /// The record cache must be durable before a newer engine cursor is published: both commit
    /// in the same transaction.
    func persistEngineCheckpoint(_ bytes: Data) throws {
        try persist(engine: bytes)
    }

    func accept(_ record: CKRecord) throws {
        guard record.recordID.zoneID == zone, record.recordType == BrowserHistorySyncSchema.recordType,
              let bytes = record["payload"] as? Data, bytes.count <= BrowserHistorySyncSchema.maximumBytes else { throw BrowserSyncError.invalidRecord }
        let incoming = try JSONDecoder().decode(BrowserHistorySyncBatch.self, from: bytes)
        // A retracted record fetched again before its deletion lands stays out of the cache.
        guard state.retired?[incoming.id.uuidString] == nil else { return }
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
                    remoteDeletion(id)
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
                    if state.records[id.recordName] != nil { state.records.removeValue(forKey: id.recordName) }
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
