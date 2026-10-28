import Foundation

/// Destination of imported visits. The app's implementation brackets the whole profile import in
/// one bulk mutation of its in-memory palette index; offline tools write to the stores directly.
public protocol ArcHistoryImportSink: Sendable {
    /// False for profiles whose history is not persisted (ephemeral engine profiles, private).
    func acceptsHistory(for profileID: ProfileID) async -> Bool
    func beginBulkImport(for profileID: ProfileID) async
    /// One transaction per chunk: other readers and writers interleave between chunks.
    func importChunk(_ document: BrowserHistoryDocument) async throws -> Int
    func endBulkImport(for profileID: ProfileID) async
}

/// Opens `BrowserHistoryStore`s under the data root's `History` directory (offline import, tests).
public actor ArcDirectHistorySink: ArcHistoryImportSink {
    private let directory: URL
    private var stores: [ProfileID: BrowserHistoryStore] = [:]

    public init(directory: URL) { self.directory = directory }

    public func acceptsHistory(for profileID: ProfileID) -> Bool { true }
    public func beginBulkImport(for profileID: ProfileID) {}
    public func endBulkImport(for profileID: ProfileID) {}

    public func importChunk(_ document: BrowserHistoryDocument) async throws -> Int {
        try await store(for: document.profileID).importDocument(document)
    }

    public func close() async {
        for store in stores.values { try? await store.close() }
        stores.removeAll()
    }

    private func store(for profileID: ProfileID) throws -> BrowserHistoryStore {
        if let store = stores[profileID] { return store }
        let store = try BrowserHistoryStore(profileID: profileID, policy: .persistent, directory: directory)
        stores[profileID] = store
        return store
    }
}
