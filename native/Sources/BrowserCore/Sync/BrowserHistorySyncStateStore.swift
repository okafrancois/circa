import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Everything the history transport keeps between launches.
struct BrowserHistorySyncStateSnapshot: Equatable {
    var engine: Data?
    var records: [String: BrowserHistorySyncBatch] = [:]
    var dirty: Set<String> = []
    var deleting: Set<String> = []
    var systemFields: [String: Data] = [:]
    var retired: [String: Date] = [:]
}

/// The row changes of one persistence barrier. A `nil` value deletes the row.
struct BrowserHistorySyncStateChanges {
    var records: [String: BrowserHistorySyncBatch?] = [:]
    var dirty: [String: Bool] = [:]
    var deleting: [String: Bool] = [:]
    var systemFields: [String: Data?] = [:]
    var retired: [String: Date?] = [:]
    var engine: Data?

    var isEmpty: Bool {
        records.isEmpty && dirty.isEmpty && deleting.isEmpty && systemFields.isEmpty && retired.isEmpty && engine == nil
    }
    var rowCount: Int {
        records.count + dirty.count + deleting.count + systemFields.count + retired.count + (engine == nil ? 0 : 1)
    }
}

/// Dictionary that remembers which keys were written since the last persistence barrier.
struct BrowserSyncTrackedMap<Value>: Sequence {
    private(set) var storage: [String: Value]
    private(set) var touched: Set<String> = []

    init(_ storage: [String: Value] = [:]) { self.storage = storage }

    subscript(key: String) -> Value? {
        get { storage[key] }
        set { storage[key] = newValue; touched.insert(key) }
    }

    @discardableResult
    mutating func removeValue(forKey key: String) -> Value? {
        guard let value = storage.removeValue(forKey: key) else { return nil }
        touched.insert(key)
        return value
    }

    var keys: Dictionary<String, Value>.Keys { storage.keys }
    var values: Dictionary<String, Value>.Values { storage.values }
    var count: Int { storage.count }
    func makeIterator() -> Dictionary<String, Value>.Iterator { storage.makeIterator() }
    mutating func clearTouched() { touched.removeAll(keepingCapacity: true) }
}

/// Set that remembers which members were inserted or removed since the last persistence barrier.
struct BrowserSyncTrackedSet: Sequence {
    private(set) var storage: Set<String>
    private(set) var touched: Set<String> = []

    init(_ storage: Set<String> = []) { self.storage = storage }

    @discardableResult
    mutating func insert(_ member: String) -> (inserted: Bool, memberAfterInsert: String) {
        let result = storage.insert(member)
        if result.inserted { touched.insert(member) }
        return result
    }

    @discardableResult
    mutating func remove(_ member: String) -> String? {
        guard let removed = storage.remove(member) else { return nil }
        touched.insert(member)
        return removed
    }

    func contains(_ member: String) -> Bool { storage.contains(member) }
    var isEmpty: Bool { storage.isEmpty }
    func makeIterator() -> Set<String>.Iterator { storage.makeIterator() }
    mutating func clearTouched() { touched.removeAll(keepingCapacity: true) }
}

/// SQLite rows of the history transport cache, one file per account-bound transport. A cycle
/// writes only the rows it changed, in one transaction. Deleted rows are zeroed
/// (`secure_delete`) and a cycle that deleted a record payload truncates the write-ahead log, so
/// retracted history leaves no URL or title on disk. Confined to the owning transport actor.
final class BrowserHistorySyncStateStore: @unchecked Sendable {
    static let version = 1
    private var handle: OpaquePointer?
    let url: URL
    /// Committed transactions and the rows they wrote (tests and measurements).
    private(set) var commits = 0
    private(set) var rowsWritten = 0
    private(set) var checkpoints = 0
    private(set) var applyTime = Duration.zero

    /// Opens the store, creating the file (mode 0600) and its parent directory when needed.
    init(url: URL) throws {
        self.url = url
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let created = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if created >= 0 { Darwin.close(created) } else if errno != EEXIST { throw BrowserHistoryError.storageFailure(SQLITE_CANTOPEN) }
        let (result, opened) = OrbitSQLiteGuard.open(url.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        handle = opened
        guard result == SQLITE_OK else { sqlite3_close(handle); handle = nil; throw BrowserHistoryError.storageFailure(result) }
        sqlite3_busy_timeout(handle, 2000)
        do {
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA temp_store=MEMORY")
            if try scalarText("PRAGMA journal_mode").lowercased() != "wal" { try execute("PRAGMA journal_mode=WAL") }
            try execute("PRAGMA journal_size_limit=4194304")
            let version = try scalarInt("PRAGMA user_version")
            switch version {
            case 0:
                guard try scalarInt("SELECT COUNT(*) FROM sqlite_master") == 0 else { throw BrowserSyncError.unsupportedVersion }
                try transaction {
                    try execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID")
                    try execute("CREATE TABLE records(id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
                    try execute("CREATE TABLE systemFields(id TEXT PRIMARY KEY, data BLOB NOT NULL)")
                    try execute("CREATE TABLE dirty(id TEXT PRIMARY KEY) WITHOUT ROWID")
                    try execute("CREATE TABLE deleting(id TEXT PRIMARY KEY) WITHOUT ROWID")
                    try execute("CREATE TABLE retired(id TEXT PRIMARY KEY, expires REAL NOT NULL) WITHOUT ROWID")
                    try execute("PRAGMA user_version=\(Self.version)")
                }
            case Self.version: break
            default: throw BrowserSyncError.unsupportedVersion
            }
        } catch { sqlite3_close(handle); handle = nil; throw error }
    }

    deinit { sqlite3_close(handle) }

    func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else { throw BrowserHistoryError.storageFailure(result) }
        self.handle = nil
    }

    // MARK: State

    func load() throws -> BrowserHistorySyncStateSnapshot {
        var snapshot = BrowserHistorySyncStateSnapshot()
        let decoder = JSONDecoder()
        snapshot.engine = try blob("SELECT value FROM meta WHERE key='engine'")
        try rows("SELECT id,payload FROM records") { statement in
            snapshot.records[text(statement, 0)] = try decoder.decode(BrowserHistorySyncBatch.self, from: data(statement, 1))
        }
        try rows("SELECT id,data FROM systemFields") { snapshot.systemFields[text($0, 0)] = data($0, 1) }
        try rows("SELECT id FROM dirty") { snapshot.dirty.insert(text($0, 0)) }
        try rows("SELECT id FROM deleting") { snapshot.deleting.insert(text($0, 0)) }
        try rows("SELECT id,expires FROM retired") {
            snapshot.retired[text($0, 0)] = Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 1))
        }
        return snapshot
    }

    /// Applies one barrier's changes atomically. Returns without writing when nothing changed.
    func apply(_ changes: BrowserHistorySyncStateChanges) throws {
        guard !changes.isEmpty else { return }
        let started = ContinuousClock.now
        defer { applyTime += ContinuousClock.now - started }
        var deletedPayload = false
        try transaction {
            for (id, value) in changes.records {
                if let value {
                    try execute("INSERT OR REPLACE INTO records(id,payload) VALUES(?,?)",
                                [.text(id), .blob(BrowserSyncReplica.encodeValue(value))])
                } else {
                    try execute("DELETE FROM records WHERE id=?", [.text(id)])
                    deletedPayload = deletedPayload || sqlite3_changes(handle) > 0
                }
            }
            for (id, value) in changes.systemFields {
                if let value { try execute("INSERT OR REPLACE INTO systemFields(id,data) VALUES(?,?)", [.text(id), .blob(value)]) }
                else { try execute("DELETE FROM systemFields WHERE id=?", [.text(id)]) }
            }
            for (id, member) in changes.dirty {
                try execute(member ? "INSERT OR IGNORE INTO dirty(id) VALUES(?)" : "DELETE FROM dirty WHERE id=?", [.text(id)])
            }
            for (id, member) in changes.deleting {
                try execute(member ? "INSERT OR IGNORE INTO deleting(id) VALUES(?)" : "DELETE FROM deleting WHERE id=?", [.text(id)])
            }
            for (id, expires) in changes.retired {
                if let expires {
                    try execute("INSERT OR REPLACE INTO retired(id,expires) VALUES(?,?)",
                                [.text(id), .real(expires.timeIntervalSinceReferenceDate)])
                } else { try execute("DELETE FROM retired WHERE id=?", [.text(id)]) }
            }
            if let engine = changes.engine {
                try execute("INSERT OR REPLACE INTO meta(key,value) VALUES('engine',?)", [.blob(engine)])
            }
        }
        commits += 1
        rowsWritten += changes.rowCount
        // Retracted history must not survive in old write-ahead log frames.
        if deletedPayload { try checkpoint() }
    }

    /// Replaces the whole state with `snapshot` and records `digest` as the imported legacy file,
    /// in one transaction that reads the rows back and fails unless they match.
    func importLegacy(_ snapshot: BrowserHistorySyncStateSnapshot, digest: Data) throws {
        try transaction {
            for table in ["records", "systemFields", "dirty", "deleting", "retired", "meta"] { try execute("DELETE FROM \(table)") }
            var changes = BrowserHistorySyncStateChanges()
            for (id, value) in snapshot.records { changes.records[id] = value }
            for (id, value) in snapshot.systemFields { changes.systemFields[id] = value }
            for id in snapshot.dirty { changes.dirty[id] = true }
            for id in snapshot.deleting { changes.deleting[id] = true }
            for (id, expires) in snapshot.retired { changes.retired[id] = expires }
            changes.engine = snapshot.engine
            try apply(changes)
            guard try load() == snapshot else { throw BrowserSyncError.invalidRecord }
            try execute("INSERT OR REPLACE INTO meta(key,value) VALUES('legacyDigest',?)", [.blob(digest)])
        }
        try checkpoint()
    }

    /// The digest of the legacy JSON file this store last imported, if any.
    func importedLegacyDigest() throws -> Data? { try blob("SELECT value FROM meta WHERE key='legacyDigest'") }

    func checkpoint() throws {
        let result = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        guard result == SQLITE_OK else { throw BrowserHistoryError.storageFailure(result) }
        checkpoints += 1
    }

    // MARK: SQLite

    private enum Value { case text(String), blob(Data), real(Double) }

    private func transaction(_ operation: () throws -> Void) throws {
        if sqlite3_get_autocommit(handle) == 0 { return try operation() }
        try execute("BEGIN IMMEDIATE")
        do { try operation(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw BrowserHistoryError.closed }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw BrowserHistoryError.storageFailure(result) }
        return statement
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, position, text, -1, transient)
            case .real(let number): result = sqlite3_bind_double(statement, position, number)
            case .blob(let bytes):
                result = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32($0.count), transient) }
            }
            guard result == SQLITE_OK else { throw BrowserHistoryError.storageFailure(result) }
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw BrowserHistoryError.storageFailure(result) }
    }

    private func rows(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            guard result == SQLITE_ROW else { throw BrowserHistoryError.storageFailure(result) }
            try body(statement)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var value = 0
        try rows(sql) { value = Int(sqlite3_column_int64($0, 0)) }
        return value
    }

    private func scalarText(_ sql: String) throws -> String {
        var value = ""
        try rows(sql) { value = text($0, 0) }
        return value
    }

    private func blob(_ sql: String) throws -> Data? {
        var value: Data?
        try rows(sql) { value = data($0, 0) }
        return value
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }

    private func data(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
