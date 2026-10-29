import BrowserCore
import Foundation

public actor BrowserSessionPersistence {
    public enum SaveResult: Equatable, Sendable {
        case saved(BrowserSessionFileStore.SaveResult)
        /// A newer request superseded this snapshot before it could be written.
        case superseded
        /// Finalization is in progress or has already completed; no snapshot was taken.
        case stopped
    }

    public enum PersistenceError: Error, Equatable, Sendable, LocalizedError {
        case loadRequired
        case loadInProgress
        case finalizationInProgress

        public var errorDescription: String? {
            switch self {
            case .loadRequired: return BrowserText.string("Session loading must succeed before automatic saving is enabled.")
            case .loadInProgress: return BrowserText.string("Session loading is still in progress.")
            case .finalizationInProgress: return BrowserText.string("The final session save is still in progress.")
            }
        }
    }

    // Internal seams keep ordering and file failures deterministic in non-GUI tests.
    struct FileAccess: Sendable {
        var load: @Sendable (URL, Int) throws -> BrowserSessionDocument = {
            try BrowserSessionFileStore().load(from: $0, maximumBytes: $1)
        }
        var encode: @Sendable (BrowserSessionDocument) throws -> BrowserSessionFileStore.EncodedDocument = {
            try BrowserSessionFileStore.EncodedDocument($0)
        }
        var save: @Sendable (BrowserSessionFileStore.EncodedDocument, URL) throws -> BrowserSessionFileStore.SaveResult = {
            try BrowserSessionFileStore().save($0, to: $1)
        }
    }

    private enum State {
        case requiresLoad, loading, ready, finalizing, finalized
    }

    private let fileIO: SessionFileIO
    private let snapshot: @Sendable (BrowserStore) async -> BrowserSessionDocument
    private var state = State.requiresLoad
    private var generation: UInt64 = 0

    /// The same byte budget admits reads and writes. Saving currently encodes once to check
    /// this budget and passes those validated bytes to the atomic writer, off the UI thread.
    public init(
        destination: URL,
        maximumBytes: Int = BrowserSessionDocument.defaultMaximumInputBytes
    ) {
        fileIO = SessionFileIO(destination: destination, maximumBytes: maximumBytes, access: FileAccess())
        snapshot = { await $0.sessionDocument() }
    }

    init(
        destination: URL,
        maximumBytes: Int = BrowserSessionDocument.defaultMaximumInputBytes,
        snapshot: (@Sendable (BrowserStore) async -> BrowserSessionDocument)? = nil,
        fileAccess: FileAccess = FileAccess()
    ) {
        fileIO = SessionFileIO(destination: destination, maximumBytes: maximumBytes, access: fileAccess)
        self.snapshot = snapshot ?? { await $0.sessionDocument() }
    }

    /// Only a missing file returns nil. Every other error is surfaced and disables saving
    /// until a later load succeeds, after the caller has handled the original input.
    /// Reloading invalidates outstanding snapshots but never reopens a finalized coordinator.
    public func load() async throws -> BrowserSessionDocument? {
        switch state {
        case .loading: throw PersistenceError.loadInProgress
        case .finalizing: throw PersistenceError.finalizationInProgress
        default: break
        }
        let wasFinalized = state == .finalized
        state = .loading
        let request = nextGeneration()
        do {
            let document = try await fileIO.load(generation: request)
            state = wasFinalized ? .finalized : .ready
            return document
        } catch {
            state = wasFinalized ? .finalized : .requiresLoad
            throw error
        }
    }

    /// Assigns order before awaiting the model, so a delayed old snapshot cannot replace
    /// a newer request. Callers must observe errors rather than silently dropping failed saves.
    @discardableResult
    public func saveCurrentState(from store: BrowserStore) async throws -> SaveResult {
        switch state {
        case .requiresLoad: throw PersistenceError.loadRequired
        case .loading: throw PersistenceError.loadInProgress
        case .finalizing, .finalized: return .stopped
        case .ready: break
        }
        let request = nextGeneration()
        let document = await snapshot(store)
        guard request == generation, state == .ready else { return .superseded }
        return try await fileIO.save(document, generation: request)
    }

    /// Await pending model commands first, then await this method before tearing down windows.
    /// Success stops all future saves, preserving the pre-teardown document. Failure leaves
    /// the coordinator usable: the caller must retry or cancel quitting, not delete windows.
    /// A concurrent finalize throws; `.stopped` here means finalization already succeeded.
    @discardableResult
    public func finalize(from store: BrowserStore) async throws -> SaveResult {
        switch state {
        case .requiresLoad: throw PersistenceError.loadRequired
        case .loading: throw PersistenceError.loadInProgress
        case .finalizing: throw PersistenceError.finalizationInProgress
        case .finalized: return .stopped
        case .ready: break
        }
        state = .finalizing
        let request = nextGeneration()
        let document = await snapshot(store)
        do {
            let result = try await fileIO.save(document, generation: request)
            state = .finalized
            return result
        } catch {
            state = .ready
            throw error
        }
    }

    private func nextGeneration() -> UInt64 {
        generation += 1
        return generation
    }
}

/// All mutable fields and synchronous file operations are confined to this queue.
/// The queue also checks generations because actor reentrancy can reorder its submissions.
private final class SessionFileIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Orbit.BrowserSessionPersistence", qos: .utility)
    private let destination: URL
    private let maximumBytes: Int
    private let access: BrowserSessionPersistence.FileAccess
    private var latestGeneration: UInt64 = 0

    init(destination: URL, maximumBytes: Int, access: BrowserSessionPersistence.FileAccess) {
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.access = access
    }

    func load(generation: UInt64) async throws -> BrowserSessionDocument? {
        try await perform { io in
            io.latestGeneration = max(io.latestGeneration, generation)
            do { return try io.access.load(io.destination, io.maximumBytes) }
            catch BrowserSessionFileError.notFound { return nil }
        }
    }

    func save(
        _ document: BrowserSessionDocument, generation: UInt64
    ) async throws -> BrowserSessionPersistence.SaveResult {
        try await perform { io in
            guard generation > io.latestGeneration else { return .superseded }
            // Keep the watermark even on failure: replacement may already have happened.
            io.latestGeneration = generation
            // Reject unreadable output before any directory, temporary file, or rename.
            guard io.maximumBytes >= 0 else { throw BrowserSessionError.limitExceeded }
            let encoded = try io.access.encode(document)
            guard encoded.data.count <= io.maximumBytes else {
                throw BrowserSessionError.limitExceeded
            }
            return .saved(try io.access.save(encoded, io.destination))
        }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (SessionFileIO) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try operation(self)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
