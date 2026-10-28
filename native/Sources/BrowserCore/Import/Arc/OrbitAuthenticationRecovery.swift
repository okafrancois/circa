import CryptoKit
import Darwin
import Foundation

/// Independent recovery key authority. Implementations must load an already provisioned key
/// outside the backed-up trees, without consulting Arc's keys. No implicit fallback is supplied;
/// native provisioning is an explicit, separately injected admission capability.
public protocol OrbitRecoveryKeyProvider {
    func loadRecoveryKey(transaction: UUID) throws -> SymmetricKey
}

/// Durable, encrypted offline prerequisite. This does not authorize real authentication import.
/// Only the explicitly marked synthetic lane can create or advance a transaction in this lot.
public final class OrbitAuthenticationRecovery {
    public enum Boundary: String, CaseIterable, Sendable { case intent, journal, backupChunk, backupManifest, backupDurable, applying, verificationPending, restoring, restoreCleared, restoreChunk, restoreEntry, rolledBack }
    enum Phase: String, Codable { case prepared, backupDurable, applying, verificationPending, restoring, rolledBack }
    struct Identity: Codable, Equatable { let device: UInt64; let inode: UInt64
        init(_ directory: RecoveryDirectory) { device = directory.device; inode = directory.inode }
    }
    struct Intent: Codable, Equatable {
        let version: Int; let transaction: UUID; let root: Identity
        // Optional only for the retained pre-registration synthetic fixtures. Registered product
        // composition requires this binding; AES-GCM authenticates the complete intent as AAD.
        var registration: Data? = nil
    }
    struct Entry: Codable, Equatable {
        let path: String
        let kind: String
        let size: Int
        let chunks: Int
        var attributes: [String: Data] = [:]
        var modifiedSeconds: Int64 = 0
        var modifiedNanos: Int64 = 0
    }
    struct Journal: Codable {
        let version: Int
        let intent: Intent
        let backup: Identity
        let profile: Identity
        let profilePath: String
        let statePaths: [String]
        let deadline: Int64
        var phase: Phase
        var manifestHash: Data?
    }
    static let marker = ".orbit-auth-recovery-required"
    static let directory = ".orbit-auth-recovery"
    static let syntheticMarker = ".orbit-auth-recovery-synthetic"
    static let chunkSize = 262_144
    static let maxBytes = 268_435_456
    static let maxFileBytes = 67_108_864
    static let maxEntries = 1024
    private let lease: OrbitRecoveryRootLock
    private let importLock: RecoveryImportLock
    private let provider: any OrbitRecoveryKeyProvider
    private let failpoint: (Boundary) throws -> Void
    private let directory: RecoveryDirectory
    private let lock: Int32
    private let intent: Intent
    private let intentData: Data
    private let key: SymmetricKey
    private var journal: Journal?

    private init(lease: OrbitRecoveryRootLock, provider: any OrbitRecoveryKeyProvider,
                 creating: Bool, heldImportLock: RecoveryImportLock? = nil, failpoint: @escaping (Boundary) throws -> Void) throws {
        self.lease = lease; self.provider = provider; self.failpoint = failpoint
        try lease.validate()
        importLock = try heldImportLock ?? RecoveryImportLock(root: lease.root)
        let root = lease.root
        if creating {
            if try root.info("Import") != nil {
                let structural = try RecoveryDirectory(parent: root, name: "Import")
                guard !(try structural.names()).contains(where: {
                    $0 == "arc-import-journal.json" || $0 == "arc-import-restore.json" || $0.hasPrefix(".restore-")
                }) else { throw OrbitRecoveryFailure.invalidEvidence }
            }
            var s = stat()
            guard fstat(root.fd, &s) == 0, s.st_mode & 0o777 == 0o700,
                  try root.info(Self.marker) == nil, try root.info(Self.directory) == nil,
                  try root.read(Self.syntheticMarker, limit: 64) == Data("orbit-auth-recovery-synthetic-v1\n".utf8)
            else { throw OrbitRecoveryFailure.unsafeFilesystem }
            intent = Intent(version: 1, transaction: UUID(), root: Identity(root),
                            registration: try (provider as? any OrbitRecoveryRegistrationBindingProvider)?.registrationBinding())
            intentData = try Self.encode(intent)
            // Native admission persists and strictly reads back an independent key first.
            // Load-only synthetic providers preserve their preprovisioned-key contract.
            let admission = provider as? any OrbitRecoveryKeyAdmissionProvider
            try admission?.prepareRecoveryKey(transaction: intent.transaction)
            key = try Self.load(provider, id: intent.transaction)
            // Even failed intent publication can leave durable .writing evidence. Never
            // cancel the key after this boundary or implicitly delete it after rollback.
            try admission?.retainRecoveryKeyForEvidence(transaction: intent.transaction)
            try root.publish(intentData, as: Self.marker, beforeRename: { try failpoint(.intent) })
            directory = try RecoveryDirectory(parent: root, name: Self.directory, create: true)
        } else {
            intentData = try root.read(Self.marker, limit: 4096)
            intent = try Self.decode(Intent.self, intentData)
            guard intent.version == 1, intent.root == Identity(root),
                  intent.registration == (try (provider as? any OrbitRecoveryRegistrationBindingProvider)?.registrationBinding()) else { throw OrbitRecoveryFailure.invalidEvidence }
            directory = try RecoveryDirectory(parent: root, name: Self.directory)
            key = try Self.load(provider, id: intent.transaction)
        }
        lock = try directory.openFile("lock", create: creating, exclusive: creating)
        // All stored properties are now initialized: Swift runs deinit on a thrown error.
        // Only deinit owns these closes, including failed flock/publication admission.
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw OrbitRecoveryFailure.busy }
        try directory.sync()
        // No interrupted atomic publication is interpreted as an absent transaction.
        guard !(try root.names()).contains(Self.marker + ".writing"),
              !(try directory.names()).contains(where: { $0.hasSuffix(".writing") }) else { throw OrbitRecoveryFailure.invalidEvidence }
    }
    deinit { flock(lock, LOCK_UN); close(lock) }
    private static func load(_ provider: any OrbitRecoveryKeyProvider, id: UUID) throws -> SymmetricKey {
        do { let key = try provider.loadRecoveryKey(transaction: id)
            guard key.bitCount == 256 else { throw OrbitRecoveryFailure.keyUnavailable }; return key
        } catch { throw OrbitRecoveryFailure.keyUnavailable }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw OrbitRecoveryFailure.invalidEvidence }
    }
    private func aad(_ label: String) -> Data { intentData + Data(("\n" + label).utf8) }
    private func seal(_ data: Data, label: String) throws -> Data {
        do { return try AES.GCM.seal(data, using: key, authenticating: aad(label)).combined! }
        catch { throw OrbitRecoveryFailure.invalidEvidence }
    }
    private func unseal(_ data: Data, label: String) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: aad(label)) }
        catch { throw OrbitRecoveryFailure.invalidEvidence }
    }
    private func validate() throws {
        try lease.validate()
        guard intent.registration == (try (provider as? any OrbitRecoveryRegistrationBindingProvider)?.registrationBinding()) else { throw OrbitRecoveryFailure.invalidEvidence }
        try directory.validate(); try directory.validateFile("lock", fd: lock)
        guard try lease.root.read(Self.marker, limit: 4096) == intentData else { throw OrbitRecoveryFailure.invalidEvidence }
    }
    private func persist(_ next: Journal, boundary: Boundary) throws {
        try validate()
        let (parent, name) = try self.parent(next.profilePath)
        guard next.profile == Identity(try RecoveryDirectory(parent: parent, name: name)) else { throw OrbitRecoveryFailure.invalidEvidence }
        let sealed = try seal(Self.encode(next), label: "journal-v1")
        try directory.publish(sealed, as: "journal", replace: journal != nil, beforeRename: { try self.failpoint(.journal) })
        journal = next
        try failpoint(boundary)
    }
    private func parent(_ path: String) throws -> (RecoveryDirectory, String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 16 else { throw OrbitRecoveryFailure.invalidEvidence }
        var result = lease.root
        for part in parts.dropLast() { result = try RecoveryDirectory(parent: result, name: part) }
        try RecoveryDirectory.component(parts.last!)
        return (result, parts.last!)
    }
    private static func admittedPaths(profile: String, states: [String]) throws {
        let pieces = profile.split(separator: "/").map(String.init)
        guard pieces.joined(separator: "/") == profile, pieces.count == 2, pieces[0] == "Chromium", pieces[1].hasPrefix("profile-"),
              UUID(uuidString: String(pieces[1].dropFirst(8)))?.uuidString.lowercased() == String(pieces[1].dropFirst(8)),
              Set(states) == Set(["session.json", "Import", "History", "profile-mapping.json", "Chromium/Local State"]) else { throw OrbitRecoveryFailure.invalidEvidence }
        let paths = [profile] + states
        // State declarations include complete owned trees, never engine siblings or recovery/lock files.
        for path in states {
            guard ["session.json", "Import", "History", "profile-mapping.json", "Chromium/Local State"].contains(path) else { throw OrbitRecoveryFailure.invalidEvidence }
        }
        guard Set(paths).count == paths.count else { throw OrbitRecoveryFailure.invalidEvidence }
    }
    /// Caller must declare all structural state; the current importer stores ledger/mapping in
    /// Import and history in History. Whole trees include SQLite WAL/journal sidecars verbatim.
    public static func beginSyntheticBackup(lease: OrbitRecoveryRootLock, provider: any OrbitRecoveryKeyProvider,
                                            profilePath: String, statePaths: [String] = ["session.json", "Import", "History", "profile-mapping.json", "Chromium/Local State"],
                                            deadline: Int64, failpoint: @escaping (Boundary) throws -> Void = { _ in }) throws -> OrbitAuthenticationRecovery {
        try admittedPaths(profile: profilePath, states: statePaths)
        guard deadline > 0 else { throw OrbitRecoveryFailure.invalidEvidence }
        let recovery = try Self(lease: lease, provider: provider, creating: true, failpoint: failpoint)
        let (p, n) = try recovery.parent(profilePath)
        let profile = try RecoveryDirectory(parent: p, name: n)
        let next = Journal(version: 1, intent: recovery.intent, backup: Identity(recovery.directory),
                           profile: Identity(profile), profilePath: profilePath, statePaths: statePaths,
                           deadline: deadline, phase: .prepared)
        try recovery.persist(next, boundary: .journal)
        var entries: [Entry] = []; var total = 0
        for path in [profilePath] + statePaths { try recovery.capture(path, entries: &entries, total: &total) }
        guard entries.reduce(0, { $0 + $1.attributes.values.reduce(0, { $0 + $1.count }) }) <= 262_144 else { throw OrbitRecoveryFailure.invalidEvidence }
        let manifestBytes = try Self.encode(entries)
        guard manifestBytes.count <= 1_000_000 else { throw OrbitRecoveryFailure.invalidEvidence }
        let manifest = try recovery.seal(manifestBytes, label: "manifest-v1")
        try recovery.directory.publish(manifest, as: "manifest", beforeRename: { try failpoint(.backupManifest) })
        var durable = next; durable.manifestHash = Data(SHA256.hash(data: manifest)); durable.phase = .backupDurable
        try recovery.persist(durable, boundary: .backupDurable)
        return recovery
    }
    private func capture(_ path: String, entries: inout [Entry], total: inout Int) throws {
        guard entries.reduce(0, { $0 + $1.attributes.values.reduce(0, { $0 + $1.count }) }) <= 262_144,
              entries.count < Self.maxEntries else { throw OrbitRecoveryFailure.invalidEvidence }
        let (p, n) = try parent(path)
        guard let s = try p.info(n) else { entries.append(Entry(path: path, kind: "absent", size: 0, chunks: 0)); return }
        if s.st_mode & S_IFMT == S_IFDIR {
            let d = try RecoveryDirectory(parent: p, name: n)
            guard UInt64(s.st_ino) == d.inode, UInt64(truncatingIfNeeded: s.st_dev) == d.device, s.st_flags == 0 else { throw OrbitRecoveryFailure.unsafeFilesystem }
            var entry = Entry(path: path, kind: "directory", size: 0, chunks: 0)
            entry.attributes = try RecoveryDirectory.attributes(d.fd)
            entry.modifiedSeconds = Int64(s.st_mtimespec.tv_sec); entry.modifiedNanos = Int64(s.st_mtimespec.tv_nsec)
            entries.append(entry)
            for child in try d.names() { try capture(path + "/" + child, entries: &entries, total: &total) }
        } else {
            let f = try p.openFile(n); defer { close(f) }
            guard s.st_size >= 0, s.st_size <= Self.maxFileBytes, total + Int(s.st_size) <= Self.maxBytes else { throw OrbitRecoveryFailure.invalidEvidence }
            total += Int(s.st_size)
            var entry = Entry(path: path, kind: "file", size: Int(s.st_size), chunks: (Int(s.st_size) + Self.chunkSize - 1) / Self.chunkSize)
            entry.attributes = try RecoveryDirectory.attributes(f)
            entry.modifiedSeconds = Int64(s.st_mtimespec.tv_sec); entry.modifiedNanos = Int64(s.st_mtimespec.tv_nsec)
            let index = entries.count; entries.append(entry)
            for chunk in 0..<entry.chunks {
                let bytes = try RecoveryDirectory.read(f, count: min(Self.chunkSize, entry.size - chunk * Self.chunkSize))
                let sealed = try seal(bytes, label: try chunkLabel(entry, index, chunk))
                try directory.publish(sealed, as: chunkName(index, chunk), beforeRename: { try self.failpoint(.backupChunk) })
            }
            var after = stat(); var byte: UInt8 = 0
            guard fstat(f, &after) == 0, after.st_ino == s.st_ino, after.st_dev == s.st_dev, after.st_size == s.st_size, after.st_mtimespec.tv_sec == s.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == s.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == s.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == s.st_ctimespec.tv_nsec, Darwin.read(f, &byte, 1) == 0 else { throw OrbitRecoveryFailure.unsafeFilesystem }
            try p.validateFile(n, fd: f)
        }
    }
    private func chunkName(_ entry: Int, _ chunk: Int) -> String { "chunk-\(entry)-\(chunk)" }
    private func chunkLabel(_ entry: Entry, _ index: Int, _ chunk: Int) throws -> String {
        "chunk-v1:\(index):\(chunk):" + (try Self.encode(entry).base64EncodedString())
    }
    private func readChunk(_ entry: Entry, _ index: Int, _ chunk: Int) throws -> Data {
        let sealed = try directory.read(chunkName(index, chunk), limit: Self.chunkSize + 64)
        let plain = try unseal(sealed, label: chunkLabel(entry, index, chunk))
        guard plain.count == min(Self.chunkSize, entry.size - chunk * Self.chunkSize) else { throw OrbitRecoveryFailure.invalidEvidence }
        return plain
    }
    private func loadJournal() throws -> Journal {
        try validate()
        let bytes = try unseal(directory.read("journal", limit: 65_536), label: "journal-v1")
        let j = try Self.decode(Journal.self, bytes)
        guard j.version == 1, j.intent == intent, j.backup == Identity(directory), j.deadline > 0 else { throw OrbitRecoveryFailure.invalidEvidence }
        try Self.admittedPaths(profile: j.profilePath, states: j.statePaths)
        let (p, n) = try parent(j.profilePath)
        guard j.profile == Identity(try RecoveryDirectory(parent: p, name: n)) else { throw OrbitRecoveryFailure.invalidEvidence }
        journal = j; return j
    }
    /// Authenticates every byte and the entire tree grammar before any target mutation.
    private func authenticatedBackup(_ j: Journal) throws -> [Entry] {
        let manifest = try directory.read("manifest", limit: 1_048_576)
        guard j.manifestHash == Data(SHA256.hash(data: manifest)) else { throw OrbitRecoveryFailure.invalidEvidence }
        let entries = try Self.decode([Entry].self, unseal(manifest, label: "manifest-v1"))
        guard entries.count <= Self.maxEntries else { throw OrbitRecoveryFailure.invalidEvidence }
        let tops = [j.profilePath] + j.statePaths
        var known: [String: String] = [:]; var total = 0; var expected = Set(["lock", "journal", "manifest"])
        for (i, e) in entries.enumerated() {
            guard known[e.path] == nil, e.path.split(separator: "/").count <= 16,
                  tops.contains(e.path) || known[String(e.path.split(separator: "/").dropLast().joined(separator: "/"))] == "directory",
                  tops.contains(where: { e.path == $0 || e.path.hasPrefix($0 + "/") }),
                  ["file", "directory", "absent"].contains(e.kind), e.size >= 0, e.size <= Self.maxFileBytes,
                  e.chunks == (e.kind == "file" ? (e.size + Self.chunkSize - 1) / Self.chunkSize : 0),
                  e.kind == "file" || e.size == 0,
                  e.modifiedNanos >= 0, e.modifiedNanos < 1_000_000_000,
                  e.attributes.count <= 16, e.attributes.values.reduce(0, { $0 + $1.count }) <= 65_536,
                  e.attributes.keys.allSatisfy({ !$0.isEmpty && !$0.contains("\0") && $0.utf8.count <= 255 }),
                  e.kind != "absent" || tops.contains(e.path) else { throw OrbitRecoveryFailure.invalidEvidence }
            for part in e.path.split(separator: "/", omittingEmptySubsequences: false) { try RecoveryDirectory.component(String(part)) }
            total += e.size; guard total <= Self.maxBytes else { throw OrbitRecoveryFailure.invalidEvidence }
            known[e.path] = e.kind
            for chunk in 0..<e.chunks { _ = try readChunk(e, i, chunk); expected.insert(chunkName(i, chunk)) }
        }
        guard entries.reduce(0, { $0 + $1.attributes.values.reduce(0, { $0 + $1.count }) }) <= 262_144,
              tops.allSatisfy({ known[$0] != nil }), known[j.profilePath] == "directory",
              Set(try directory.names()) == expected else { throw OrbitRecoveryFailure.invalidEvidence }
        return entries
    }
    /// Synthetic mutation seam only. Durable applying precedes the first authorized test write.
    public func withSyntheticMutation(now: Int64 = Int64(Date().timeIntervalSince1970), _ body: () throws -> Void) throws {
        guard try lease.root.read(Self.syntheticMarker, limit: 64) == Data("orbit-auth-recovery-synthetic-v1\n".utf8),
              journal != nil else { throw OrbitRecoveryFailure.invalidEvidence }
        var next = try loadJournal()
        guard next.phase == .backupDurable else { throw OrbitRecoveryFailure.invalidEvidence }
        guard now > 0, now < next.deadline else { throw OrbitRecoveryFailure.expired }
        _ = try authenticatedBackup(next)
        next.phase = .applying; try persist(next, boundary: .applying)
        try body()
        next.phase = .verificationPending; try persist(next, boundary: .verificationPending)
    }
    private func preflightTree(_ path: String, count: inout Int) throws {
        count += 1; guard count <= Self.maxEntries else { throw OrbitRecoveryFailure.invalidEvidence }
        let (p, n) = try parent(path)
        guard let s = try p.info(n) else { return }
        if s.st_mode & S_IFMT == S_IFDIR {
            let d = try RecoveryDirectory(parent: p, name: n)
            for child in try d.names() { try preflightTree(path + "/" + child, count: &count) }
        } else { let f = try p.openFile(n); close(f) }
    }
    private func rollback(_ j: Journal) throws {
        let entries = try authenticatedBackup(j)
        var count = 0
        for top in [j.profilePath] + j.statePaths { try preflightTree(top, count: &count) }
        var restoring = j; restoring.phase = .restoring; try persist(restoring, boundary: .restoring)
        // Keep the owned profile inode and all parent/root/lock inodes. Only declared contents
        // are removed. Replay after interruption clears the partial restore and repeats it.
        for top in [j.profilePath] + j.statePaths {
            let (p, n) = try parent(top)
            if top == j.profilePath {
                let d = try RecoveryDirectory(parent: p, name: n)
                for name in try d.names() { try d.removeTreeEntry(name) }
            } else { try p.removeTreeEntry(n) }
            try failpoint(.restoreCleared)
        }
        for (i, e) in entries.enumerated() {
            try validate()
            if e.path == j.profilePath || e.kind == "absent" { continue }
            let (p, n) = try parent(e.path)
            if e.kind == "directory" { _ = try RecoveryDirectory(parent: p, name: n, create: true) }
            else {
                let f = try p.openFile(n, create: true, exclusive: true)
                defer { close(f) }
                for chunk in 0..<e.chunks {
                    try RecoveryDirectory.write(readChunk(e, i, chunk), fd: f)
                    try failpoint(.restoreChunk)
                }
                guard fsync(f) == 0, fcntl(f, F_FULLFSYNC) == 0 else { throw OrbitRecoveryFailure.io }
                try p.validateFile(n, fd: f); try p.sync()
            }
            try failpoint(.restoreEntry)
        }
        // Restore attributes/times last and in reverse order so creating children cannot change
        // the backed-up directory modification times. All metadata is authenticated above.
        for e in entries.reversed() where e.kind != "absent" {
            let (p, n) = try parent(e.path)
            let d = e.kind == "directory" ? try RecoveryDirectory(parent: p, name: n) : nil
            let file = try d?.fd ?? p.openFile(n)
            defer { if d == nil { close(file) } }
            try RecoveryDirectory.restoreAttributes(e.attributes, file: file)
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: Int(e.modifiedSeconds), tv_nsec: Int(e.modifiedNanos))]
            guard futimens(file, &times) == 0, fsync(file) == 0 else { throw OrbitRecoveryFailure.io }
        }
        restoring.phase = .rolledBack; try persist(restoring, boundary: .rolledBack)
    }
    /// The caller supplies a load-only provider. Pending verification has an
    /// explicit refusal, so no ordinary windows, URLs, extensions or workers can resume.
    public static func beforeRuntime(lease: OrbitRecoveryRootLock, provider: (any OrbitRecoveryKeyProvider)? = nil,
                                     now: Int64 = Int64(Date().timeIntervalSince1970),
                                     failpoint: @escaping (Boundary) throws -> Void = { _ in }) throws {
        _ = try prepareBeforeRuntime(lease: lease, provider: provider, now: now, failpoint: failpoint)
    }
    /// Read-only admission after the root lock converts to shared session ownership.
    func validateRuntimeAdmission(now: Int64) throws {
        let current = try loadJournal()
        guard current.phase == .rolledBack else { throw OrbitRecoveryFailure.invalidEvidence }
        guard now > 0, now < current.deadline else { throw OrbitRecoveryFailure.expired }
        _ = try authenticatedBackup(current)
    }

    /// The registered launcher retains this object/lock until its runtime returns.
    static func prepareBeforeRuntime(lease: OrbitRecoveryRootLock, provider: (any OrbitRecoveryKeyProvider)?,
                                     now: Int64, heldImportLock: RecoveryImportLock? = nil,
                                     failpoint: @escaping (Boundary) throws -> Void = { _ in }) throws -> OrbitAuthenticationRecovery? {
        try lease.validate()
        if try lease.root.info("Chromium") != nil {
            let engine = try RecoveryDirectory(parent: lease.root, name: "Chromium")
            if try engine.names().contains(where: { $0.hasPrefix("Auth-") || $0 == ".orbit-auth-synthetic" }) {
                throw OrbitRecoveryFailure.restrictedVerification
            }
        }
        let marker = try lease.root.info(Self.marker)
        let work = try lease.root.info(Self.directory)
        guard try lease.root.info(Self.marker + ".writing") == nil else { throw OrbitRecoveryFailure.invalidEvidence }
        if marker == nil && work == nil { return nil }
        guard marker != nil, work != nil else { throw OrbitRecoveryFailure.invalidEvidence }
        guard let provider else { throw OrbitRecoveryFailure.keyUnavailable }
        let recovery = try Self(lease: lease, provider: provider, creating: false, heldImportLock: heldImportLock, failpoint: failpoint)
        let j = try recovery.loadJournal()
        guard now > 0, now < j.deadline else { throw OrbitRecoveryFailure.expired }
        switch j.phase {
        case .prepared: throw OrbitRecoveryFailure.invalidEvidence
        case .backupDurable, .applying, .restoring: try recovery.rollback(j)
        case .verificationPending:
            guard now > 0, now < j.deadline else { throw OrbitRecoveryFailure.expired }
            throw OrbitRecoveryFailure.restrictedVerification
        case .rolledBack: _ = try recovery.authenticatedBackup(j)
        }
        return recovery
    }
}

/// The product launcher calls this seam after root-lock preparation. The closure includes all
/// hooks and runtime entry points. Failure is first-failure halt; evidence is never deleted.
public enum OrbitAuthenticationStartupGate {
    public static func run<T>(lease: OrbitRecoveryRootLock, provider: (any OrbitRecoveryKeyProvider)? = nil,
                              now: Int64 = Int64(Date().timeIntervalSince1970),
                              failpoint: @escaping (OrbitAuthenticationRecovery.Boundary) throws -> Void = { _ in },
                              runtimeStart: () throws -> T) throws -> T {
        try OrbitAuthenticationRecovery.beforeRuntime(lease: lease, provider: provider, now: now, failpoint: failpoint)
        return try runtimeStart()
    }
}
