import CryptoKit
import Foundation
import SQLite3

/// Encrypted write-ahead state for a merge into existing profiles. All mutations run before
/// windows and sync exist. An identical external re-save cannot be distinguished from replay.
public final class ArcPasswordImportJournal: @unchecked Sendable {
    public enum Phase: String, Codable, Sendable { case staged, pending, applying, complete, undoPending, restored, abandoned }
    public enum State: String, Codable, Sendable { case pending, absent, intent, owned, present, conflict, removed, retained }
    public struct Row: Codable, Sendable {
        public var profile: ProfileID
        public var credential: ImportedBrowserPassword
        public var hash: Data
        public var state: State = .pending
    }
    public struct Counts: Codable, Equatable, Sendable {
        public var added = 0, alreadyPresent = 0, kept = 0, skipped = 0, removed = 0, retained = 0
        public init() {}
    }
    private struct Document: Codable {
        var id: UUID
        var phase: Phase = .staged
        var rows: [Row]
        var counts: Counts
        var sourcePassword: Data
        var targetPassword: Data
    }
    private let directory: OrbitSecureDirectory
    private let key: SymmetricKey
    private var document: Document
    public var checkpoint: (String) throws -> Void = { _ in }
    public var id: UUID { document.id }
    public var phase: Phase { document.phase }
    public var rows: [Row] { document.rows }
    public var counts: Counts { document.counts }
    private var filename: String { id.uuidString + ".sealed" }
    private var aad: Data { Data(("Orbit password import v1:" + id.uuidString).utf8) }
    private init(directory: OrbitSecureDirectory, key: SymmetricKey, document: Document) {
        self.directory = directory; self.key = key; self.document = document
    }
    public static func create(root: URL, key: SymmetricKey, groups: [(ProfileID, [ImportedBrowserPassword])],
                              skipped: Int, sourcePassword: Data, targetPassword: Data) throws -> ArcPasswordImportJournal {
        let directory = try OrbitSecureDirectory.open(root, create: false).directory("ArcPasswordImport", create: true)
        var counts = Counts(); counts.skipped = skipped
        let journal = Self(directory: directory, key: key, document: .init(id: UUID(), rows: [], counts: counts,
            sourcePassword: sourcePassword, targetPassword: targetPassword))
        journal.document.rows = groups.flatMap { profile, values in values.map {
            Row(profile: profile, credential: $0, hash: journal.hash($0.password))
        } }
        try journal.save("staged")
        return journal
    }
    public static func open(root: URL, key: SymmetricKey, id: UUID) throws -> ArcPasswordImportJournal {
        let directory = try OrbitSecureDirectory.open(root, create: false).directory("ArcPasswordImport", create: false)
        guard let data = directory.read(id.uuidString + ".sealed", limit: 128 * 1024 * 1024) else { throw BrowserAuthenticationImportError.invalidState }
        var clear = try AES.GCM.open(.init(combined: data), using: key, authenticating: Data(("Orbit password import v1:" + id.uuidString).utf8))
        defer { clear.resetBytes(in: 0..<clear.count) }
        let document = try JSONDecoder().decode(Document.self, from: clear)
        guard document.id == id else { throw BrowserAuthenticationImportError.invalidState }
        return Self(directory: directory, key: key, document: document)
    }
    public static func activeID(root: URL) throws -> UUID? {
        let root = try OrbitSecureDirectory.open(root, create: false)
        guard root.exists("ArcPasswordImport") else { return nil }
        let directory = try root.directory("ArcPasswordImport", create: false)
        guard directory.exists("active.json") else { return nil }
        guard let data = directory.read("active.json", limit: 1024) else { throw BrowserAuthenticationImportError.invalidState }
        return try JSONDecoder().decode(UUID.self, from: data)
    }
    public func activate(restoring: Bool = false) throws {
        if restoring {
            try prepareUndo()
        } else {
            guard phase == .staged || phase == .pending else { throw BrowserAuthenticationImportError.invalidState }
            document.phase = .pending
            try save("pending")
        }
        try Self.requestStartup(root: URL(fileURLWithPath: directory.path).deletingLastPathComponent(), id: id)
        try checkpoint("password-active")
    }
    public static func requestStartup(root: URL, id: UUID) throws {
        try OrbitSecureDirectory.open(root, create: false).directory("ArcPasswordImport", create: false)
            .write(JSONEncoder().encode(id), to: "active.json")
    }
    /// Recovery may undo a partially applied job without scheduling another automatic attempt.
    public func prepareUndo() throws {
        guard phase != .staged else { throw BrowserAuthenticationImportError.invalidState }
        if phase != .restored { document.phase = .undoPending }
        try save("undo-pending")
    }
    public func abandon() throws {
        document.phase = .abandoned
        document.sourcePassword = Data(); document.targetPassword = Data()
        for index in document.rows.indices { document.rows[index].credential.password = "" }
        try save("abandoned")
    }
    /// Requires no decryption key. Persist this before presenting the recovery decision so a
    /// crash while the alert is open cannot replay writes or prompt again on the next launch.
    public static func suspendStartup(root: URL) throws {
        let directory = try OrbitSecureDirectory.open(root, create: false).directory("ArcPasswordImport", create: false)
        if directory.exists("active.json") {
            try directory.rename("active.json", to: directory, "abandoned-" + UUID().uuidString + ".json")
        }
    }
    public static func finishStartup(root: URL) throws {
        try OrbitSecureDirectory.open(root, create: false).directory("ArcPasswordImport", create: false).removeChecked("active.json")
    }
    /// Preserve unreadable records and failed restores; never delete their encrypted evidence.
    public static func quarantine(root: URL, id: UUID?) throws {
        let parent = try OrbitSecureDirectory.open(root, create: false)
        guard parent.exists("ArcPasswordImport") else { return }
        if let id {
            let directory = try parent.directory("ArcPasswordImport", create: false)
            let name = id.uuidString + ".sealed"
            if directory.exists(name) {
                let quarantine = try directory.directory("quarantine", create: true)
                try directory.rename(name, to: quarantine, UUID().uuidString + ".sealed")
            }
        } else {
            try parent.rename("ArcPasswordImport", to: parent, "ArcPasswordImport-quarantine-" + UUID().uuidString)
        }
    }
    public func hash(_ password: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(("password-value-v1:" + password).utf8), using: key))
    }
    public func connectionKeys() throws -> ArcPasswordImportKeys {
        guard !document.sourcePassword.isEmpty, !document.targetPassword.isEmpty else { throw BrowserAuthenticationImportError.invalidState }
        return .init(source: document.sourcePassword, target: document.targetPassword)
    }
    public func clearConnectionKeys() throws {
        document.sourcePassword.resetBytes(in: 0..<document.sourcePassword.count); document.sourcePassword = Data()
        document.targetPassword.resetBytes(in: 0..<document.targetPassword.count); document.targetPassword = Data()
        try save("connections-finished")
    }
    /// Persist the entire baseline before any row can be inserted.
    public func baseline(_ states: [State]) throws {
        guard phase == .pending, states.count == rows.count else { throw BrowserAuthenticationImportError.invalidState }
        for index in states.indices { document.rows[index].state = states[index] }
        document.phase = .applying
        try save("baseline")
    }
    public func set(_ state: State, at index: Int) throws {
        document.rows[index].state = state
        try save(state.rawValue + ":" + String(index))
    }
    public func finish(restoring: Bool = false) throws {
        var counts = document.counts
        if restoring {
            counts.removed = rows.filter { $0.state == .removed }.count
            counts.retained = rows.filter { $0.state == .retained }.count
            document.phase = .restored
        } else {
            counts.added = rows.filter { $0.state == .owned }.count
            counts.alreadyPresent = rows.filter { $0.state == .present }.count
            counts.kept = rows.filter { $0.state == .conflict }.count
            guard rows.allSatisfy({ [.owned, .present, .conflict].contains($0.state) }) else { throw BrowserAuthenticationImportError.verificationFailed }
            document.phase = .complete
        }
        document.sourcePassword = Data(); document.targetPassword = Data()
        document.counts = counts
        for index in document.rows.indices { document.rows[index].credential.password = "" }
        try save(restoring ? "restored" : "complete")
    }
    public func discard() throws { try Self.discard(root: URL(fileURLWithPath: directory.path).deletingLastPathComponent(), id: id) }
    public static func discard(root: URL, id: UUID) throws {
        let directory = try OrbitSecureDirectory.open(root, create: false).directory("ArcPasswordImport", create: false)
        if try activeID(root: root) == id { try directory.removeChecked("active.json") }
        if directory.exists(id.uuidString + ".sealed") { try directory.removeChecked(id.uuidString + ".sealed") }
    }
    private func save(_ point: String) throws {
        var clear = try JSONEncoder().encode(document)
        defer { clear.resetBytes(in: 0..<clear.count) }
        try directory.write(AES.GCM.seal(clear, using: key, authenticating: aad).combined!, to: filename)
        try checkpoint("password-" + point)
    }
}

public struct ArcPasswordImportKeys: ArcSiteSessionKeyProviding, Sendable {
    private let source: Data, target: Data
    public init(source: Data, target: Data) { self.source = source; self.target = target }
    public func sourcePassword() throws -> Data { source }
    public func targetPassword() throws -> Data { target }
}

/// Bounded source-only snapshot, including WAL/hot journals, independent of Local State.
public enum ArcPasswordImportSource {
    public static func read(root: URL, profiles: [ArcSiteSessionProfile], sourcePassword: Data,
                            probe: any ArcRunningProbe) throws -> (groups: [(ProfileID, [ImportedBrowserPassword])], skipped: Int) {
        var manifest: [(relative: String, limit: Int64?, required: Bool)] = []
        for profile in profiles {
            _ = try ArcAuthenticationSourceProfile(registration: UUID(), profile: .directory(profile.sourceDirectory))
            for name in ["Login Data", "Login Data For Account"] {
                for suffix in [""] + ArcSourceSnapshot.historySidecars {
                    manifest.append((profile.sourceDirectory + "/" + name + suffix, 512 * 1024 * 1024, false))
                }
            }
        }
        let snapshot = try ArcSourceSnapshot.captureManifest(source: root, plan: manifest, historyDirectories: [], historyPrefix: "",
            parent: FileManager.default.temporaryDirectory, probe: probe, diskSpace: OrbitSystemDiskSpaceProbe())
        defer { snapshot.remove() }
        var key = try ArcChromiumCookieCipher.deriveKey(password: sourcePassword)
        defer { key.resetBytes(in: 0..<key.count) }
        var groups: [(ProfileID, [ImportedBrowserPassword])] = [], skipped = 0
        for profile in profiles {
            var values: [ImportedBrowserPassword] = []
            for name in ["Login Data", "Login Data For Account"] {
                let file = snapshot.directory.appendingPathComponent(profile.sourceDirectory).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) {
                    let read = try ChromiumPasswordReader.read(snapshotFile: file, sourceKey: key)
                    skipped += read.unsupported
                    for row in read.passwords {
                        if row.password.isEmpty && !row.blocked { skipped += 1 } else { values.append(row) }
                    }
                }
            }
            groups.append((profile.targetID, values))
        }
        return (groups, skipped)
    }
    public static func count(snapshotFile: URL) throws -> Int {
        let database = try AuthenticationSQLite(snapshotFile)
        let query = try database.statement("SELECT COUNT(*) FROM logins")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw BrowserAuthenticationImportError.database }
        return Int(sqlite3_column_int64(query, 0))
    }
}

public enum ArcPasswordImportKey {
    public static func fixture(root: URL, prepare: Bool) throws -> SymmetricKey {
        let directory = try OrbitSecureDirectory.open(root, create: false)
        if prepare, !directory.exists("import-auth-fixture-key") {
            try SymmetricKey(size: .bits256).withUnsafeBytes { try directory.write(Data($0), to: "import-auth-fixture-key") }
        }
        guard let bytes = directory.read("import-auth-fixture-key", limit: 32), bytes.count == 32 else { throw BrowserAuthenticationImportError.invalidState }
        return SymmetricKey(data: bytes)
    }
    private struct Identity: Codable { var registration: UUID; var transaction: UUID }
    public static func key(root: URL, product: OrbitNativeRecoveryKeyProvider.Product,
                           backend: any OrbitRecoverySecItemBoundary, prepare: Bool) throws -> SymmetricKey {
        let directory = try OrbitSecureDirectory.open(root, create: false).directory("ArcPasswordImport", create: prepare)
        let identity: Identity
        if let data = directory.read("key.json", limit: 4096) { identity = try JSONDecoder().decode(Identity.self, from: data) }
        else {
            guard prepare else { throw BrowserAuthenticationImportError.invalidState }
            identity = .init(registration: UUID(), transaction: UUID())
            let provider = OrbitNativeRecoveryKeyProvider(product: product, registration: identity.registration, backend: backend)
            try provider.prepareRecoveryKey(transaction: identity.transaction)
            try provider.retainRecoveryKeyForEvidence(transaction: identity.transaction)
            try directory.write(JSONEncoder().encode(identity), to: "key.json")
        }
        return try OrbitNativeRecoveryKeyProvider(product: product, registration: identity.registration, backend: backend)
            .loadRecoveryKey(transaction: identity.transaction)
    }
}
