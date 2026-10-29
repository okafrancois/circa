import Foundation

/// Owned by a single serialized writer. A failed durability barrier never updates the cache.
/// In particular, an error after rename still requires the next attempt to synchronize again.
struct BrowserSyncPersistence: Sendable {
    private var persisted: Data?
    private var persistedDestination: URL?
    private(set) var writes = 0
    private(set) var bytesWritten = 0
    mutating func save(_ bytes: Data, to destination: URL, maximumBytes: Int,
                       write: (Data, URL, Int) throws -> Void = { bytes, url, limit in
                           try BrowserPermissionFile.save(bytes, to: url, maximumBytes: limit)
                       }) throws {
        guard bytes != persisted || destination != persistedDestination else { return }
        persisted = nil
        try write(bytes, destination, maximumBytes)
        persisted = bytes
        persistedDestination = destination
        writes += 1
        bytesWritten += bytes.count
    }
}

/// Synchronous actor turns keep replica mutation and its durability barrier indivisible.
/// Network and model publication stay outside the worker; callers must recapture after I/O.
public actor BrowserSyncWorker {
    public struct Snapshot: Equatable, Sendable {
        public let session: BrowserSessionDocument
        public let settings: BrowserSettingsDocument
        public let boosts: [BrowserBoostDocument]
        public init(session: BrowserSessionDocument, settings: BrowserSettingsDocument, boosts: [BrowserBoostDocument] = []) {
            self.session = session; self.settings = settings; self.boosts = boosts
        }
    }
    public struct Prepared: Sendable {
        public let value: BrowserSyncMapping.Materialized
        public let projection: BrowserSyncProjection
        public let changed: Bool
    }
    private var state: BrowserSyncState
    private let destination: URL
    private var persistence = BrowserSyncPersistence()
    private var projectionCache: (Snapshot, BrowserSyncProjection)?
    private var materializationCache: (Snapshot, [String: [String: Data]], Prepared)?

    public init(state: BrowserSyncState, destination: URL) {
        self.state = state; self.destination = destination
    }
    func persistenceCounts() -> (writes: Int, bytes: Int) { (persistence.writes, persistence.bytesWritten) }

    private func persist() throws {
        try persistence.save(BrowserSyncReplica.encodeValue(state), to: destination, maximumBytes: 64 * 1024 * 1024)
    }
    public func setEnabled(_ enabled: Bool) throws {
        state.enabled = enabled
        try persist()
    }
    public func admit(_ identity: String?) throws {
        do { try state.account.admit(identity) }
        catch { try persist(); throw error }
        try persist()
    }
    private func project(_ snapshot: Snapshot) throws -> BrowserSyncProjection {
        if let cache = projectionCache, cache.0 == snapshot { return cache.1 }
        let projection = try BrowserSyncMapping.project(session: snapshot.session, settings: snapshot.settings, boosts: snapshot.boosts)
        projectionCache = (snapshot, projection)
        return projection
    }
    public func capture(_ snapshot: Snapshot, now: Date = Date()) throws -> [BrowserSyncRecord] {
        try state.replica.capture(project(snapshot), now: now)
        try persist()
        return Array(state.replica.records.values)
    }
    public func merge(_ records: [BrowserSyncRecord], identity: String?) throws {
        try state.account.admit(identity)
        try state.replica.merge(records)
        try persist()
    }
    public func prepare(_ snapshot: Snapshot, now: Date = Date()) throws -> Prepared {
        let current = try project(snapshot)
        try state.replica.capture(current, now: now)
        let visible = state.replica.visible
        if let cache = materializationCache, cache.0 == snapshot, cache.1 == visible { return cache.2 }
        let value = try BrowserSyncMapping.materialize(visible, local: snapshot.session, settings: snapshot.settings, boosts: snapshot.boosts)
        let shared = BrowserSessionDocument(profiles: value.profiles, spaces: value.spaces, windows: [], tabs: [], organization: value.organization)
        let projected = try BrowserSyncMapping.project(session: shared, settings: value.settings, boosts: value.boosts)
        let result = Prepared(value: value, projection: projected, changed: projected != current)
        // Missing local tabs acquire Date() during materialization. Do not reuse that
        // ephemeral timestamp if model publication was refused and the tab is still absent.
        let localIDs = Set(snapshot.session.organization.tabs.map(\.id))
        materializationCache = value.organization.tabs.allSatisfy { localIDs.contains($0.id) }
            ? (snapshot, visible, result) : nil
        return result
    }
    public func acknowledge(_ projection: BrowserSyncProjection) throws {
        try state.replica.acknowledge(projection)
        try persist()
    }
}
