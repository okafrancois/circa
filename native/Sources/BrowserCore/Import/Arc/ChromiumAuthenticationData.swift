import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Source identities are explicit, never generated from a display label or probed by enumeration.
public struct BrowserSafeStorageIdentity: Sendable, Equatable {
    public let service: String
    public let account: String
    public static func verified(sourceID: String) -> Self? {
        let identities: [String: Self] = [
            "chrome": .init(service: "Chrome Safe Storage", account: "Chrome"),
            "chromium": .init(service: "Chromium Safe Storage", account: "Chromium"),
            "brave": .init(service: "Brave Safe Storage", account: "Brave"),
            "edge": .init(service: "Microsoft Edge Safe Storage", account: "Microsoft Edge"),
            "vivaldi": .init(service: "Vivaldi Safe Storage", account: "Vivaldi"),
            "opera": .init(service: "Opera Safe Storage", account: "Opera"),
            "dia": .init(service: "Dia Safe Storage", account: "Dia")
        ]
        return identities[sourceID]
    }
}

public enum BrowserAuthenticationImportError: Error, Equatable {
    case consentRequired, unsupportedSource, schema, database, invalidRecord, invalidCSV
    case keychainDenied, sourceKeyMissing, keychainFailure
    case targetNotFresh, verificationFailed, restoreConfirmationRequired, invalidState
}

/// In-memory transfer only. Never include this value in diagnostics.
public struct ImportedBrowserPassword: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var realm: String
    public var origin: String
    public var action: String
    public var usernameElement: String
    public var username: String
    public var passwordElement: String
    public var password: String
    public var created: Int64
    public var lastUsed: Int64
    public var modified: Int64
    public var blocked: Bool
    public var scheme: Int32
    public var description: String { "ImportedBrowserPassword(<redacted>)" }
    public var debugDescription: String { description }
}

/// Operates only on a private snapshot, opened read/write to recover copied WAL/hot journals.
/// Source files are never opened by SQLite.
final class AuthenticationSQLite {
    let db: OpaquePointer
    private let directory: OrbitSecureDirectory
    private let name: String
    init(_ url: URL) throws {
        directory = try OrbitSecureDirectory.open(url.deletingLastPathComponent(), create: false)
        name = url.lastPathComponent
        let opened = OrbitSQLiteGuard.open(try directory.verifiedPath(name), flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard opened.0 == SQLITE_OK, let handle = opened.1 else {
            sqlite3_close(opened.1); throw BrowserAuthenticationImportError.database
        }
        db = handle
        sqlite3_busy_timeout(db, 2000)
    }
    deinit { sqlite3_close(db) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw BrowserAuthenticationImportError.database }
        _ = try directory.verifiedPath(name)
    }
    func statement(_ sql: String) throws -> OpaquePointer {
        var row: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &row, nil) == SQLITE_OK, let row else { throw BrowserAuthenticationImportError.schema }
        return row
    }
    func version(maximum: Int, minimum: Int) throws -> Int {
        let row = try statement("SELECT key,value FROM meta WHERE key IN ('version','last_compatible_version')")
        defer { sqlite3_finalize(row) }
        var values: [String: Int] = [:]
        while sqlite3_step(row) == SQLITE_ROW { values[try Self.text(row, 0)] = Int(sqlite3_column_int64(row, 1)) }
        guard let version = values["version"], let compatible = values["last_compatible_version"],
              (minimum...maximum).contains(version), compatible > 0, compatible <= version else {
            throw BrowserAuthenticationImportError.schema
        }
        return version
    }
    func columns(_ table: String) throws -> Set<String> {
        let row = try statement("PRAGMA table_info(" + table + ")")
        defer { sqlite3_finalize(row) }
        var result = Set<String>()
        while sqlite3_step(row) == SQLITE_ROW { result.insert(try Self.text(row, 1)) }
        return result
    }
    static func bytes(_ row: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(row, column))
        guard count > 0, let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
    static func text(_ row: OpaquePointer, _ column: Int32) throws -> String {
        guard let value = String(data: bytes(row, column), encoding: .utf8) else { throw BrowserAuthenticationImportError.invalidRecord }
        return value
    }
    static func bind(_ bytes: Data, to row: OpaquePointer, at column: Int32) throws {
        let status = bytes.withUnsafeBytes { sqlite3_bind_blob(row, column, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard status == SQLITE_OK else { throw BrowserAuthenticationImportError.database }
    }
}

public struct ChromiumPasswordReadResult: Sendable {
    public var passwords: [ImportedBrowserPassword] = []
    public var unsupported = 0
    public var unrepresentedNotes = 0
}

public enum ChromiumPasswordReader {
    public static let unsupportedCategories = ["passkeys", "passwordNotes", "passwordSharing", "otp"]
    /// Schema 40–43 uses the same supported form fields. Unsupported federation and schemes
    /// are counted, never flattened into ordinary HTML credentials.
    public static func read(snapshotFile: URL, sourceKey: Data) throws -> ChromiumPasswordReadResult {
        let database = try AuthenticationSQLite(snapshotFile)
        _ = try database.version(maximum: 43, minimum: 40)
        let columns = ["signon_realm", "origin_url", "action_url", "username_element", "username_value",
                       "password_element", "password_value", "date_created", "date_last_used", "date_password_modified",
                       "blacklisted_by_user", "scheme", "federation_url"]
        guard Set(columns).isSubset(of: try database.columns("logins")) else { throw BrowserAuthenticationImportError.schema }
        let row = try database.statement("SELECT " + columns.joined(separator: ",") + " FROM logins ORDER BY id")
        defer { sqlite3_finalize(row) }
        var result = ChromiumPasswordReadResult()
        var step = sqlite3_step(row)
        while step == SQLITE_ROW {
            guard result.passwords.count + result.unsupported < 100_000 else { throw BrowserAuthenticationImportError.invalidRecord }
            let scheme = sqlite3_column_int(row, 11)
            if try !(0...2).contains(scheme) || !AuthenticationSQLite.text(row, 12).isEmpty {
                result.unsupported += 1; step = sqlite3_step(row); continue
            }
            let origin = try AuthenticationSQLite.text(row, 1)
            let realm = try AuthenticationSQLite.text(row, 0)
            guard validWebURL(origin), validWebURL(realm) else {
                result.unsupported += 1; step = sqlite3_step(row); continue
            }
            let blocked = sqlite3_column_int(row, 10) != 0
            var clear = blocked ? Data() : try ArcChromiumCookieCipher.decrypt(AuthenticationSQLite.bytes(row, 6), key: sourceKey)
            defer { clear.resetBytes(in: 0..<clear.count) }
            guard let password = String(data: clear, encoding: .utf8) else { throw BrowserAuthenticationImportError.invalidRecord }
            result.passwords.append(try .init(realm: realm, origin: origin, action: AuthenticationSQLite.text(row, 2),
                usernameElement: AuthenticationSQLite.text(row, 3), username: AuthenticationSQLite.text(row, 4),
                passwordElement: AuthenticationSQLite.text(row, 5), password: password,
                created: sqlite3_column_int64(row, 7), lastUsed: sqlite3_column_int64(row, 8), modified: sqlite3_column_int64(row, 9),
                blocked: blocked, scheme: scheme))
            step = sqlite3_step(row)
        }
        guard step == SQLITE_DONE else { throw BrowserAuthenticationImportError.database }
        return result
    }
    static func validWebURL(_ text: String) -> Bool {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }
}
