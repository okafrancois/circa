import Foundation
import SQLite3

/// A separate read-only WAL connection for suggestions and index snapshots. Reads never queue
/// behind the writer actor, and writes never wait for a suggestion. Each request owns a ticket:
/// cancelling its Swift task interrupts only that request, never a sibling window or profile.
final class HistoryReadConnection: @unchecked Sendable {
    /// Every field below is guarded by `lock`; `database` is used on `queue` only, except for
    /// `sqlite3_interrupt`, which is issued under `lock` while the connection is known to be open.
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.orbit.history.reader", qos: .userInitiated)
    private let database: HistoryDatabase
    private var closed = false
    private var active: Ticket?

    final class Ticket: @unchecked Sendable {
        fileprivate var cancelled = false
    }

    init(url: URL) throws {
        database = try HistoryDatabase(readOnlyURL: url)
    }

    func perform<T: Sendable>(_ body: @escaping @Sendable (HistoryDatabase) throws -> T) async throws -> T {
        let ticket = Ticket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async { [self] in
                    lock.lock()
                    if closed { lock.unlock(); continuation.resume(throwing: BrowserHistoryError.closed); return }
                    // Superseded requests are dropped before touching SQLite.
                    if ticket.cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                    active = ticket
                    lock.unlock()
                    // Interrupt alone is lost if cancellation precedes the first sqlite3_step.
                    // A progress handler also observes this request's receipt during execution.
                    let progress = Progress(owner: self, ticket: ticket)
                    let result = withExtendedLifetime(progress) {
                        database.withHandle { sqlite3_progress_handler($0, 1000, { pointer in
                            guard let pointer else { return 0 }
                            let state = Unmanaged<Progress>.fromOpaque(pointer).takeUnretainedValue()
                            return state.owner.isCancelled(state.ticket) ? 1 : 0
                        }, Unmanaged.passUnretained(progress).toOpaque()) }
                        defer { database.withHandle { sqlite3_progress_handler($0, 0, nil, nil) } }
                        return Result { try body(database) }
                    }
                    lock.lock()
                    active = nil
                    let cancelled = ticket.cancelled, wasClosed = closed
                    lock.unlock()
                    switch result {
                    case .success(let value) where !cancelled: continuation.resume(returning: value)
                    case .success: continuation.resume(throwing: CancellationError())
                    case .failure(let error):
                        if cancelled { continuation.resume(throwing: CancellationError()) }
                        else if wasClosed { continuation.resume(throwing: BrowserHistoryError.closed) }
                        else { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: {
            cancel(ticket)
        }
    }

    private final class Progress {
        let owner: HistoryReadConnection
        let ticket: Ticket
        init(owner: HistoryReadConnection, ticket: Ticket) { self.owner = owner; self.ticket = ticket }
    }

    private func isCancelled(_ ticket: Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed || ticket.cancelled
    }

    /// SQLite clears a pending interrupt when the next statement starts with no statement active,
    /// and every request finalizes its statements, so an interrupt never leaks into the next one.
    private func cancel(_ ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        ticket.cancelled = true
        if active === ticket { database.interrupt() }
    }

    /// Interrupts the running request, waits for queued work to observe closure, then closes.
    /// Must not be called from `queue`.
    func close() throws {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        if active != nil { database.interrupt() }
        lock.unlock()
        guard !alreadyClosed else { return }
        queue.sync {}
        try database.close()
    }
}

extension HistoryDatabase {
    /// Read-only companion connection. Never migrates or creates files; the writer owns the schema.
    convenience init(readOnlyURL url: URL) throws {
        try self.init(openingURL: url, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
        do {
            try execute("PRAGMA query_only=1")
            try execute("PRAGMA temp_store=MEMORY")
            try registerMatchingFunctions()
        } catch { try? close(); throw error }
    }

    /// `orbit_word_start(text, term)` and `orbit_host_start(searchURL, term)` reuse the exact
    /// matcher of the in-memory index.
    func registerMatchingFunctions() throws {
        try createFunction("orbit_word_start") { text, term in BrowserHistoryMatching.hasWordStart(text, term) }
        try createFunction("orbit_host_start") { url, term in
            BrowserHistoryMatching.hasWordStart(UnsafeBufferPointer(rebasing: url[0..<BrowserHistoryMatching.hostEnd(url)]), term)
        }
    }

    private func createFunction(_ name: String, _ predicate: @escaping (UnsafeBufferPointer<UInt8>, [UInt8]) -> Bool) throws {
        let box = Unmanaged.passRetained(MatchingFunction(predicate)).toOpaque()
        let result = withHandle { handle in
            sqlite3_create_function_v2(handle, name, 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, box, { context, _, arguments in
                guard let context, let arguments,
                      let function = sqlite3_user_data(context).map({ Unmanaged<MatchingFunction>.fromOpaque($0).takeUnretainedValue() }) else { return }
                let text = sqlite3_value_text(arguments[0])
                let textCount = Int(sqlite3_value_bytes(arguments[0]))
                let term = sqlite3_value_text(arguments[1])
                let termCount = Int(sqlite3_value_bytes(arguments[1]))
                guard let text, let term, termCount > 0 else { sqlite3_result_int(context, 0); return }
                let needle = Array(UnsafeBufferPointer(start: term, count: termCount))
                sqlite3_result_int(context, function.predicate(UnsafeBufferPointer(start: text, count: textCount), needle) ? 1 : 0)
            }, nil, nil, { box in box.map { Unmanaged<MatchingFunction>.fromOpaque($0).release() } })
        }
        guard result == SQLITE_OK else { throw BrowserHistoryError.storageFailure(result) }
    }
}

private final class MatchingFunction {
    let predicate: (UnsafeBufferPointer<UInt8>, [UInt8]) -> Bool
    init(_ predicate: @escaping (UnsafeBufferPointer<UInt8>, [UInt8]) -> Bool) { self.predicate = predicate }
}
