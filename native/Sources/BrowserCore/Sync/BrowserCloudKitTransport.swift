import CloudKit
import Foundation
import Security

public enum BrowserSyncEntitlement {
    /// Inspect this process's verified signature, never a plist assertion or a build flag.
    public static func isAvailable() -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool != true,
              let values = BrowserSignedEntitlements.current() else { return false }
        return matches(values)
    }

    public static func matches(_ values: [String: Any]) -> Bool {
        (values["com.apple.developer.icloud-container-identifiers"] as? [String])?.contains(BrowserSyncSchema.container) == true
            && (values["com.apple.developer.icloud-services"] as? [String])?.contains("CloudKit") == true
            && values["com.apple.developer.icloud-container-environment"] as? String == "Production"
    }
}

/// CKContainer is constructed only after inspecting the running signature. The account-bound
/// transport persists CKSyncEngine tokens AND record system fields, including server change tags.
public actor BrowserCloudKitTransport: BrowserSyncTransport, CKSyncEngineDelegate {
    private struct State: Codable {
        var engine: CKSyncEngine.State.Serialization?
        var records: [String: BrowserSyncRecord] = [:]
        var dirty: Set<String> = []
        var systemFields: [String: Data] = [:]
    }
    private let container: CKContainer?
    private let destination: URL
    private let identity: String
    private let zone = CKRecordZone.ID(zoneName: BrowserSyncSchema.zone)
    private var state: State
    private var engine: CKSyncEngine?
    private var persistence = BrowserSyncPersistence()
    private var stopped = false
    private var failure: (any Error)?
    private var admission = BrowserSyncAdmission()
    private var gate = BrowserSyncExchangeGate()
    private var remoteRevision = 0
    private var exchanging = false
    private var zoneQueued = false
    private let onRemoteChange: @Sendable () -> Void
    private var sealedRewrite: BrowserSyncSealedRewrite
    /// Records queued by the one-time sealed rewrite (observable by tests).
    private(set) var sealedRewrites = 0
    private(set) var explicitExchanges = 0
    private(set) var accountQueries = 0

    /// `onRemoteChange` fires when the engine fetched, failed or saw an account change outside
    /// an explicit exchange (push-driven automatic sync). It must only schedule a cycle.
    public init(destination: URL, identity: String, onRemoteChange: @escaping @Sendable () -> Void = {}) throws {
        guard BrowserSyncEntitlement.isAvailable() else { throw BrowserSyncError.unavailable }
        container = CKContainer(identifier: BrowserSyncSchema.container)
        self.destination = destination; self.identity = identity; self.onRemoteChange = onRemoteChange
        sealedRewrite = BrowserSyncSealedRewrite(cache: destination)
        if let bytes = try BrowserPermissionFile.load(destination, maximumBytes: 64 * 1024 * 1024) {
            state = try JSONDecoder().decode(State.self, from: bytes)
        } else { state = State() }
    }

    /// Local-only seam: no container, engine or daemon. Admission uses the fixed identity.
    init(testDestination: URL, identity: String = "synthetic") throws {
        container = nil
        destination = testDestination; self.identity = identity; onRemoteChange = {}
        sealedRewrite = BrowserSyncSealedRewrite(cache: testDestination)
        if let bytes = try BrowserPermissionFile.load(testDestination, maximumBytes: 64 * 1024 * 1024) {
            state = try JSONDecoder().decode(State.self, from: bytes)
        } else { state = State() }
    }

    func persistenceWrites() -> Int { persistence.writes }
    var dirtyRecordIDs: Set<String> { state.dirty }

    public func account() async throws -> String? {
        if let cached = admission.identity() { return cached }
        let epoch = BrowserSyncAccountEpoch.current
        accountQueries += 1
        let current: String?
        if let container {
            current = try await container.accountStatus() == .available ? try await container.userRecordID().recordName : nil
        } else { current = identity }
        if current == identity { admission.record(current, epoch: epoch) } else { admission.reset() }
        return current
    }

    private func admitted() async throws {
        guard !stopped else { throw BrowserSyncError.unavailable }
        guard let current = try await account() else { throw BrowserSyncError.signedOut }
        guard current == identity else { throw BrowserSyncError.accountChanged }
    }

    public func requestRefresh() async { gate.invalidate() }

    /// A latched failure always needs a fresh transport: the engine token after the failed
    /// event was not persisted, so a new transport refetches it. Even a transient cause is
    /// therefore reported as unavailable (teardown), unlike a direct throttling error.
    private func throwLatchedFailure() throws {
        guard let failure else { return }
        if BrowserSyncRetry.isTransient(failure) { throw BrowserSyncError.unavailable }
        throw failure
    }

    public func exchange(_ records: [BrowserSyncRecord]) async throws -> [BrowserSyncRecord] {
        try await exchange(records, now: Date())
    }

    func exchange(_ records: [BrowserSyncRecord], now: Date) async throws -> [BrowserSyncRecord] {
        try await admitted()
        try throwLatchedFailure()
        if !sealedRewrite.isDone {
            // Records cached before the sealed format may still be plaintext on the server:
            // save each once more so `record(_:)` replaces the plaintext field.
            for record in records where state.records[record.id] != nil { sealedRewrites += 1; state.dirty.insert(record.id) }
        }
        let unchanged = try records.allSatisfy { record in
            guard let old = state.records[record.id] else { return false }
            var merged = old
            try merged.merge(record)
            return merged == old
        }
        if gate.canSkip(now: now, remoteRevision: remoteRevision, inputsUnchanged: unchanged, pendingSends: !state.dirty.isEmpty) {
            return Array(state.records.values)
        }
        explicitExchanges += 1
        exchanging = true
        defer { exchanging = false }
        if engine == nil, let container {
            var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                stateSerialization: state.engine, delegate: self)
            configuration.automaticallySync = true
            engine = CKSyncEngine(configuration)
        }
        // Automatic sync fetches on push; this explicit fetch only runs on a non-idle exchange
        // (local edit, remote change, refresh request or the periodic forced exchange).
        var fetch = CKSyncEngine.FetchChangesOptions()
        fetch.scope = .zoneIDs([zone])
        try await engine?.fetchChanges(fetch)
        try throwLatchedFailure()
        try await admitted()
        var pending: [CKSyncEngine.PendingRecordZoneChange] = []
        for record in records {
            let old = state.records[record.id]
            var merged = old ?? record
            try merged.merge(record)
            if old != merged {
                state.records[record.id] = merged
                state.dirty.insert(record.id)
            }
            if state.dirty.contains(record.id) {
                pending.append(.saveRecord(.init(recordName: record.id, zoneID: zone)))
            }
        }
        try persist()
        if let engine {
            // Once per transport; `.zoneNotFound` re-queues it.
            if !zoneQueued { engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))]); zoneQueued = true }
            engine.state.add(pendingRecordZoneChanges: pending)
            try await engine.sendChanges()
        } else if container == nil {
            // Test seam: no server, so every queued save is acknowledged immediately.
            state.dirty.removeAll()
        }
        try throwLatchedFailure()
        try await admitted()
        if !sealedRewrite.isDone { try persist(); try sealedRewrite.markDone() }
        gate.exchanged(at: now, remoteRevision: remoteRevision)
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
        try persistence.save(BrowserSyncReplica.encodeValue(state), to: destination, maximumBytes: 64 * 1024 * 1024)
    }

    func accept(_ record: CKRecord) throws {
        guard record.recordID.zoneID == zone, record.recordType == BrowserSyncSchema.recordType,
              let bytes = BrowserSyncSealedPayload.read(record) else { throw BrowserSyncError.invalidRecord }
        let incoming = try JSONDecoder().decode(BrowserSyncRecord.self, from: bytes)
        guard incoming.id == record.recordID.recordName else { throw BrowserSyncError.invalidRecord }
        let old = state.records[incoming.id]
        var merged = old ?? incoming
        try merged.merge(incoming)
        if merged != old { remoteRevision += 1 }
        state.records[incoming.id] = merged
        // A plaintext record written by an older build is saved again in sealed form.
        if merged != incoming || BrowserSyncSealedPayload.isLegacy(record) { state.dirty.insert(incoming.id) }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver); archiver.finishEncoding()
        state.systemFields[incoming.id] = archiver.encodedData
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        do {
            switch event {
            case .accountChange(let event):
                if case .signIn(let user) = event.changeType, user.recordName == identity { return }
                // Freeze immediately. A new transport requires the persisted marker's admission.
                stopped = true
                admission.reset()
                Task { await syncEngine.cancelOperations() }
                onRemoteChange()
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
                    if let bytes = BrowserSyncSealedPayload.read(record), !BrowserSyncSealedPayload.isLegacy(record),
                       let sent = try? JSONDecoder().decode(BrowserSyncRecord.self, from: bytes),
                       state.records[sent.id] == sent { state.dirty.remove(sent.id) }
                }
                for failed in event.failedRecordSaves {
                    switch failed.error.code {
                    case .serverRecordChanged:
                        guard let server = failed.error.serverRecord else { throw BrowserSyncError.invalidRecord }
                        try accept(server)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    case .zoneNotFound:
                        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failed.record.recordID)])
                    case _ where BrowserSyncRetry.isTransient(failed.error):
                        // Throttling and connectivity: the engine keeps and retries the pending
                        // save; the record stays dirty so the next exchange re-queues it.
                        break
                    default: throw failed.error
                    }
                }
                try persist()
            case .fetchedDatabaseChanges(let event):
                if event.deletions.contains(where: { $0.zoneID == zone }) { throw BrowserSyncError.invalidRecord }
            case .didFetchChanges:
                // Push-driven fetches (any zone of the private database, including history)
                // wake the runtime; fetches inside an explicit exchange are already consumed.
                if !exchanging { onRemoteChange() }
            default: break
            }
        } catch {
            failure = error
            if !exchanging { onRemoteChange() }
        }
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

    func record(_ recordID: CKRecord.ID) -> CKRecord? {
        do {
            guard !stopped, recordID.zoneID == zone, let value = state.records[recordID.recordName] else { return nil }
            let record: CKRecord
            if let bytes = state.systemFields[value.id] {
                let decoder = try NSKeyedUnarchiver(forReadingFrom: bytes)
                decoder.requiresSecureCoding = true
                guard let decoded = CKRecord(coder: decoder) else { throw BrowserSyncError.invalidRecord }
                decoder.finishDecoding(); record = decoded
            } else { record = CKRecord(recordType: BrowserSyncSchema.recordType, recordID: recordID) }
            BrowserSyncSealedPayload.write(try BrowserSyncReplica.encodeValue(value), to: record)
            return record
        } catch { failure = error; return nil }
    }
}

public struct BrowserSyncState: Codable, Sendable {
    public var version = BrowserSyncSchema.version
    public var enabled = false
    /// Password sync is a separate, disclosed choice: off for a new setup. A state written by
    /// an earlier build has no value and keeps what that build did (passwords followed `enabled`).
    public var passwords: Bool?
    public var replica = BrowserSyncReplica()
    public var account = BrowserSyncAccountMarker()
    public init() { passwords = false }
    public var syncsPasswords: Bool { passwords ?? enabled }
    public static func load(_ destination: URL) throws -> Self {
        try loadWithBytes(destination).state
    }
    /// One read and one decode; the bytes seed the clock writer without re-reading the file.
    public static func loadWithBytes(_ destination: URL) throws -> (state: Self, bytes: Data?) {
        guard let bytes = try BrowserPermissionFile.load(destination, maximumBytes: 64 * 1024 * 1024) else { return (Self(), nil) }
        var value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.version == BrowserSyncSchema.version, value.replica.version == BrowserSyncSchema.version else { throw BrowserSyncError.unsupportedVersion }
        if value.passwords == nil { value.passwords = value.enabled }
        value.replica.tick = max(value.replica.tick, BrowserSyncClockPersistence.loadTick(for: bytes, at: destination) ?? value.replica.tick)
        return (value, bytes)
    }
    public func save(_ destination: URL) throws {
        try BrowserPermissionFile.save(BrowserSyncReplica.encodeValue(self), to: destination, maximumBytes: 64 * 1024 * 1024)
    }
}
