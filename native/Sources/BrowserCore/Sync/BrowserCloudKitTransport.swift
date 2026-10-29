import CloudKit
import Foundation
import Security

public enum BrowserSyncEntitlement {
    /// Inspect this process's verified signature, never a plist assertion or a build flag.
    public static func isAvailable() -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool != true else { return false }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
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
    private let container: CKContainer
    private let destination: URL
    private let identity: String
    private let zone = CKRecordZone.ID(zoneName: BrowserSyncSchema.zone)
    private var state: State
    private var engine: CKSyncEngine?
    private var persistence = BrowserSyncPersistence()
    private var stopped = false
    private var failure: (any Error)?

    public init(destination: URL, identity: String) throws {
        guard BrowserSyncEntitlement.isAvailable() else { throw BrowserSyncError.unavailable }
        container = CKContainer(identifier: BrowserSyncSchema.container)
        self.destination = destination; self.identity = identity
        if let bytes = try BrowserPermissionFile.load(destination, maximumBytes: 64 * 1024 * 1024) {
            state = try JSONDecoder().decode(State.self, from: bytes)
        } else { state = State() }
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

    public func exchange(_ records: [BrowserSyncRecord]) async throws -> [BrowserSyncRecord] {
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
    }

    private func persist() throws {
        try persistence.save(BrowserSyncReplica.encodeValue(state), to: destination, maximumBytes: 64 * 1024 * 1024)
    }

    private func accept(_ record: CKRecord) throws {
        guard record.recordID.zoneID == zone, record.recordType == BrowserSyncSchema.recordType,
              let bytes = record["payload"] as? Data else { throw BrowserSyncError.invalidRecord }
        let incoming = try JSONDecoder().decode(BrowserSyncRecord.self, from: bytes)
        guard incoming.id == record.recordID.recordName else { throw BrowserSyncError.invalidRecord }
        var merged = state.records[incoming.id] ?? incoming
        try merged.merge(incoming)
        state.records[incoming.id] = merged
        if merged != incoming { state.dirty.insert(incoming.id) }
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
                    if let bytes = record["payload"] as? Data,
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
            if let bytes = state.systemFields[value.id] {
                let decoder = try NSKeyedUnarchiver(forReadingFrom: bytes)
                decoder.requiresSecureCoding = true
                guard let decoded = CKRecord(coder: decoder) else { throw BrowserSyncError.invalidRecord }
                decoder.finishDecoding(); record = decoded
            } else { record = CKRecord(recordType: BrowserSyncSchema.recordType, recordID: recordID) }
            record["payload"] = try BrowserSyncReplica.encodeValue(value) as CKRecordValue
            return record
        } catch { failure = error; return nil }
    }
}

public struct BrowserSyncState: Codable, Sendable {
    public var version = BrowserSyncSchema.version
    public var enabled = false
    public var replica = BrowserSyncReplica()
    public var account = BrowserSyncAccountMarker()
    public init() {}
    public static func load(_ destination: URL) throws -> Self {
        guard let bytes = try BrowserPermissionFile.load(destination, maximumBytes: 64 * 1024 * 1024) else { return Self() }
        var value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.version == BrowserSyncSchema.version, value.replica.version == BrowserSyncSchema.version else { throw BrowserSyncError.unsupportedVersion }
        value.replica.tick = max(value.replica.tick, BrowserSyncClockPersistence.loadTick(for: bytes, at: destination) ?? value.replica.tick)
        return value
    }
    public func save(_ destination: URL) throws {
        try BrowserPermissionFile.save(BrowserSyncReplica.encodeValue(self), to: destination, maximumBytes: 64 * 1024 * 1024)
    }
}
