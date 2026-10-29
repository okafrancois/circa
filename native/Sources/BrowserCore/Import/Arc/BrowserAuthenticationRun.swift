import CryptoKit
import Darwin
import Foundation

/// One encrypted undo point for a fresh structural profile and all its authentication stores.
/// No existing target credentials/site data are admitted. Call offline methods while CEF is closed.
/// The caller supplies an independent, durably provisioned recovery key (never a source key).
public final class BrowserAuthenticationRun {
    public enum Phase: String, Codable, Sendable { case prepared, applying, passwordsPending, passwordsApplying, verified, restoring, restored }
    public struct Status: Sendable {
        public let profileID: ProfileID
        public let phase: Phase
        public let cookies: Int
        public let passwords: Int
        public let unsupportedPasswords: Int
        public let passwordConflicts: Int
        public let outcome: ArcImportOutcome?
    }
    private struct Document: Codable {
        var version = 1
        var profileID: ProfileID
        var sourceID: String
        var sourceProfile: String
        var phase: Phase
        var backup: [String: Data]
        var absent: [String]
        var files: [String: Data]
        var passwords: [ImportedBrowserPassword]
        var cookies: Int
        var unsupportedPasswords: Int
        var passwordConflicts: Int? = nil
        var totalPasswords: Int? = nil
        var outcome: ArcImportOutcome? = nil
    }
    var checkpoint: (String) throws -> Void = { _ in }
    private let root: OrbitSecureDirectory
    private let directory: OrbitSecureDirectory
    private let key: SymmetricKey
    private let aad: Data
    private var document: Document
    public var status: Status {
        .init(profileID: document.profileID, phase: document.phase, cookies: document.cookies,
              passwords: document.totalPasswords ?? document.passwords.count, unsupportedPasswords: document.unsupportedPasswords,
              passwordConflicts: document.passwordConflicts ?? 0, outcome: document.outcome)
    }
    private static let backupPaths = ["session.json", "Import/arc-import-ledger.json", "Import/space-appearance.json", "Import/arc-import-journal.json", "Chromium/Local State"]
    private var profileName: String { "profile-" + document.profileID.rawValue.uuidString.lowercased() }
    private init(root: OrbitSecureDirectory, directory: OrbitSecureDirectory, key: SymmetricKey, document: Document) throws {
        self.root = root; self.directory = directory; self.key = key; self.document = document
        let identity = try OrbitSecureDirectory.identity(of: root.descriptor)
        aad = Data("orbit-import-auth-v1:\(identity.device):\(identity.inode)".utf8)
    }
    public static func exists(dataRoot: URL) throws -> Bool {
        let root = try OrbitSecureDirectory.open(dataRoot, create: false)
        guard try root.checkedKind("AuthenticationImport") != nil else { return false }
        return try root.directory("AuthenticationImport", create: false).checkedKind("run.sealed") != nil
    }
    public static func open(dataRoot: URL, recoveryKey: SymmetricKey, archiveID: UUID? = nil, checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> BrowserAuthenticationRun {
        let root = try OrbitSecureDirectory.open(dataRoot, create: false)
        let directory = try root.directory(archiveID.map { "AuthenticationImportHistory/" + $0.uuidString } ?? "AuthenticationImport", create: false)
        let identity = try OrbitSecureDirectory.identity(of: root.descriptor)
        guard let bytes = directory.read("run.sealed", limit: 268_435_456) else { throw BrowserAuthenticationImportError.invalidState }
        var plain = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: recoveryKey,
            authenticating: Data("orbit-import-auth-v1:\(identity.device):\(identity.inode)".utf8))
        defer { plain.resetBytes(in: 0..<plain.count) }
        let document = try JSONDecoder().decode(Document.self, from: plain)
        guard document.version == 1, Set(document.backup.keys).union(document.absent) == Set(backupPaths),
              Set(document.backup.keys).isDisjoint(with: document.absent),
              document.files.keys.allSatisfy({ allowedProfilePath($0) }) else { throw BrowserAuthenticationImportError.invalidState }
        let run = try Self(root: root, directory: directory, key: recoveryKey, document: document)
        run.checkpoint = checkpoint
        return run
    }
    private static func allowedProfilePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.allSatisfy { OrbitSecureDirectory.validName($0) && !$0.contains("\0") }
            && (path == "Cookies" || (parts.count > 1 && ["Local Storage", "IndexedDB", "WebStorage"].contains(parts[0])))
    }
    private func save() throws {
        var bytes = try JSONEncoder().encode(document)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard bytes.count < 268_435_400 else { throw BrowserAuthenticationImportError.invalidState }
        try directory.write(AES.GCM.seal(bytes, using: key, authenticating: aad).combined!, to: "run.sealed")
    }
    /// The offline target retains its exclusive directory lock across structural apply and cookie
    /// installation. A new installation registration is required when importing a second copy.
    public static func apply(preparation: BrowserImportPreparation, importer: BrowserImportOrchestrator,
                             target: some BrowserImportTarget, authentication: ChromiumAuthenticationSnapshot,
                             sourcePassword: Data, targetPassword: Data, recoveryKey: SymmetricKey,
                             checkpoint: @escaping (String) throws -> Void = { _ in }) async throws -> BrowserAuthenticationRun {
        guard target.holdsExclusiveAccess, preparation.plan.profiles.count == 1,
              let profile = preparation.plan.profiles.first, !profile.isAdopted,
              preparation.plan.registration?.sourceID == authentication.sourceID,
              profile.sourceDirectory == authentication.sourceProfile,
              preparation.report.target.profilesAdded == 1 else { throw BrowserAuthenticationImportError.targetNotFresh }
        let root = try OrbitSecureDirectory.open(target.location.dataDirectory, create: false)
        let engine = try root.directory("Chromium", create: true)
        let profileName = "profile-" + profile.id.rawValue.uuidString.lowercased()
        guard !engine.exists(profileName), !(try exists(dataRoot: root.url)) else { throw BrowserAuthenticationImportError.targetNotFresh }
        let history = try root.directory("History", create: true)
        guard !history.exists(profile.id.rawValue.uuidString) else { throw BrowserAuthenticationImportError.targetNotFresh }
        var sourceKey = try ArcChromiumCookieCipher.deriveKey(password: sourcePassword)
        defer { sourceKey.resetBytes(in: 0..<sourceKey.count) }
        var targetKey = try ArcChromiumCookieCipher.deriveKey(password: targetPassword)
        defer { targetKey.resetBytes(in: 0..<targetKey.count) }
        var passwords: [ImportedBrowserPassword] = [], unsupported = 0
        for file in authentication.loginFiles {
            let read = try ChromiumPasswordReader.read(snapshotFile: file, sourceKey: sourceKey)
            passwords += read.passwords; unsupported += read.unsupported
        }
        var files: [String: Data] = [:], cookies = 0
        if let source = authentication.cookieFile {
            let converted = authentication.profileDirectory.appendingPathComponent("orbit-converted-cookies")
            cookies = try ChromiumCookieImport.convert(snapshotFile: source, destination: converted, sourceKey: sourceKey, targetKey: targetKey)
            files["Cookies"] = try Data(contentsOf: converted)
        }
        let source = try OrbitSecureDirectory.open(authentication.profileDirectory, create: false)
        var total = files.values.reduce(0) { $0 + $1.count }
        func collect(_ folder: OrbitSecureDirectory, prefix: String) throws {
            for name in try folder.checkedEntries() {
                let path = prefix + "/" + name
                if folder.kind(name) == S_IFDIR { try collect(folder.directory(name, create: false), prefix: path) }
                else {
                    guard let bytes = folder.read(name, limit: 128 * 1024 * 1024), files.count < 10_000 else { throw BrowserAuthenticationImportError.invalidState }
                    total += bytes.count
                    guard total <= 128 * 1024 * 1024 else { throw BrowserAuthenticationImportError.invalidState }
                    files[path] = bytes
                }
            }
        }
        for name in ["Local Storage", "IndexedDB", "WebStorage"] where source.exists(name) { try collect(source.directory(name, create: false), prefix: name) }
        let run = try await applyDecoded(preparation: preparation, importer: importer, target: target,
            sourceID: authentication.sourceID, sourceProfile: authentication.sourceProfile, files: files,
            passwords: passwords, cookies: cookies, unsupported: unsupported, total: total,
            recoveryKey: recoveryKey, checkpoint: checkpoint)
        authentication.discard()
        return run
    }
    /// The official export lane uses the common CSV decoder, with no source or target Safe Storage
    /// query. Credentials are sealed before structural mutation and applied by the normal startup sink.
    public static func applySafariExport(preparation: BrowserImportPreparation, importer: BrowserImportOrchestrator,
                                         target: some BrowserImportTarget, adapter: SafariBrowserImportAdapter,
                                         consent: Bool, recoveryKey: SymmetricKey,
                                         checkpoint: @escaping (String) throws -> Void = { _ in }) async throws -> BrowserAuthenticationRun {
        guard consent else { throw BrowserAuthenticationImportError.consentRequired }
        guard preparation.plan.registration == adapter.registration else { throw BrowserAuthenticationImportError.invalidState }
        let read = try adapter.passwords(snapshot: preparation.snapshot)
        return try await applyDecoded(preparation: preparation, importer: importer, target: target,
            sourceID: adapter.registration.sourceID, sourceProfile: adapter.profile.directory, files: [:],
            passwords: read.passwords, cookies: 0, unsupported: read.unsupported, total: 0,
            recoveryKey: recoveryKey, checkpoint: checkpoint)
    }
    /// Plaintext source cookies are converted under Orbit's key. Optional caller-selected Firefox
    /// CSV bytes use the common decoder; NSS databases are never opened or decrypted.
    public static func applyFirefox(preparation: BrowserImportPreparation, importer: BrowserImportOrchestrator,
                                    target: some BrowserImportTarget, adapter: FirefoxBrowserImportAdapter,
                                    passwordCSV: Data? = nil, consent: Bool, targetPassword: Data, recoveryKey: SymmetricKey,
                                    checkpoint: @escaping (String) throws -> Void = { _ in }) async throws -> BrowserAuthenticationRun {
        guard consent, adapter.authenticationConsent else { throw BrowserAuthenticationImportError.consentRequired }
        guard preparation.plan.registration == adapter.registration else { throw BrowserAuthenticationImportError.invalidState }
        var key = try ArcChromiumCookieCipher.deriveKey(password: targetPassword)
        defer { key.resetBytes(in: 0..<key.count) }
        let root = try OrbitSecureDirectory.open(preparation.snapshot.directory, create: false)
        var files: [String: Data] = [:], cookies = 0
        if root.exists("cookies.sqlite") {
            let converted = root.url.appendingPathComponent("orbit-converted-cookies")
            defer { try? FileManager.default.removeItem(at: converted) }
            cookies = try FirefoxCookieImport.convert(file: root.url.appendingPathComponent("cookies.sqlite"), destination: converted, targetKey: key).0
            files["Cookies"] = try Data(contentsOf: converted)
        }
        let read = try passwordCSV.map(BrowserPasswordCSV.read) ?? ChromiumPasswordReadResult()
        return try await applyDecoded(preparation: preparation, importer: importer, target: target,
            sourceID: adapter.registration.sourceID, sourceProfile: adapter.profile.directory, files: files,
            passwords: read.passwords, cookies: cookies, unsupported: read.unsupported,
            total: files.values.reduce(0) { $0 + $1.count }, recoveryKey: recoveryKey, checkpoint: checkpoint)
    }
    private static func applyDecoded(preparation: BrowserImportPreparation, importer: BrowserImportOrchestrator,
                                     target: some BrowserImportTarget, sourceID: String, sourceProfile: String,
                                     files: [String: Data], passwords: [ImportedBrowserPassword], cookies: Int,
                                     unsupported: Int, total: Int, recoveryKey: SymmetricKey,
                                     checkpoint: @escaping (String) throws -> Void) async throws -> BrowserAuthenticationRun {
        guard target.holdsExclusiveAccess, preparation.plan.profiles.count == 1,
              let profile = preparation.plan.profiles.first, !profile.isAdopted,
              preparation.plan.registration?.sourceID == sourceID,
              profile.sourceDirectory == sourceProfile, preparation.report.target.profilesAdded == 1 else {
            throw BrowserAuthenticationImportError.targetNotFresh
        }
        let root = try OrbitSecureDirectory.open(target.location.dataDirectory, create: false)
        let engine = try root.directory("Chromium", create: true)
        let profileName = "profile-" + profile.id.rawValue.uuidString.lowercased()
        let history = try root.directory("History", create: true)
        guard !engine.exists(profileName), !history.exists(profile.id.rawValue.uuidString),
              !(try exists(dataRoot: root.url)) else { throw BrowserAuthenticationImportError.targetNotFresh }
        var backup: [String: Data] = [:], absent: [String] = []
        for path in backupPaths {
            let url = root.url.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                guard let data = ArcImportFiles.readData(url) else { throw BrowserAuthenticationImportError.invalidState }
                backup[path] = data
            } else { absent.append(path) }
        }
        // The persisted pre-import session must agree with the target actor's state.
        guard backup["session.json"] == (try await target.sessionBackup()) else { throw BrowserAuthenticationImportError.invalidState }
        try OrbitDiskSpace.require(Int64(total * 4 + 64 * 1024 * 1024), at: root.url, probe: importer.diskSpace)
        let directory = try root.directory("AuthenticationImport", create: true)
        let run = try Self(root: root, directory: directory, key: recoveryKey,
            document: Document(profileID: profile.id, sourceID: sourceID, sourceProfile: sourceProfile,
                phase: .prepared, backup: backup, absent: absent, files: files, passwords: passwords, cookies: cookies, unsupportedPasswords: unsupported))
        run.checkpoint = checkpoint
        _ = try BrowserImportRecovery.begin(at: target.location, profiles: [profile.id.rawValue], authentication: true)
        try run.save()
        try checkpoint("auth-prepared")
        run.document.phase = .applying; try run.save()
        try checkpoint("auth-applying")
        // Any error leaves the complete encrypted undo point; the caller closes its target and
        // restores before opening runtime. Interrupted .applying never replays structural apply.
        run.document.outcome = try await importer.apply(preparation, to: target)
        guard !engine.exists(profileName) else { throw BrowserAuthenticationImportError.targetNotFresh }
        let destination = try engine.directory(profileName, create: true)
        for (path, bytes) in files.sorted(by: { $0.key < $1.key }) {
            let components = path.split(separator: "/").map(String.init)
            let parent = components.count == 1 ? destination : try destination.directory(components.dropLast().joined(separator: "/"), create: true)
            try parent.write(bytes, to: components.last!)
            try checkpoint("auth-file:" + path)
        }
        run.document.phase = .passwordsPending; try run.save()
        try BrowserImportRecovery.open(at: root.url)?.runtimeReady()
        try checkpoint("auth-passwords-pending")
        return run
    }
    /// Retain the completed undo point before starting another selected-profile import. Its key
    /// identity moves with it; callers keep the returned UUID for the corresponding Restore action.
    public func archiveCompleted() throws -> UUID {
        guard [.verified, .restored].contains(document.phase), directory.path == root.path + "/AuthenticationImport" else { throw BrowserAuthenticationImportError.invalidState }
        let lock = try OrbitDataDirectoryLock.acquire(root.url, exclusive: true)
        defer { lock.release() }
        _ = try directory.verifiedPath("run.sealed")
        let archive = try root.directory("AuthenticationImportHistory", create: true), id = UUID()
        try checkpoint("auth-before-archive")
        try root.rename("AuthenticationImport", to: archive, id.uuidString)
        try checkpoint("auth-after-archive")
        return id
    }
    public func beginPasswordApplication() throws {
        guard document.phase == .passwordsPending else { throw BrowserAuthenticationImportError.invalidState }
        try BrowserImportRecovery.open(at: root.url)?.runtimeApplying()
        document.phase = .passwordsApplying; try save()
        try checkpoint("auth-passwords-applying")
    }
    public func passwordsForRuntime() throws -> [ImportedBrowserPassword] {
        guard [.passwordsPending, .passwordsApplying].contains(document.phase) else { throw BrowserAuthenticationImportError.invalidState }
        return document.passwords
    }
    /// Call after native password store re-list verification. Offline cookie conversion has already
    /// validated decryption and schema; server-side session validity cannot be promised.
    public func markVerified(passwordConflicts: Int = 0) throws {
        guard [.passwordsPending, .passwordsApplying].contains(document.phase) else { throw BrowserAuthenticationImportError.invalidState }
        document.phase = .verified; document.files = [:]
        document.totalPasswords = document.passwords.count; document.passwords = []
        document.passwordConflicts = passwordConflicts; try save()
        try checkpoint("auth-verified")
        try BrowserImportRecovery.open(at: root.url)?.complete()
    }
    /// Restore always requires explicit warning acceptance: later structural edits and edits to the
    /// imported profile will be removed. The other profiles' engine stores are never visited.
    public func restore(confirmDeletingLaterChanges: Bool, usage: any OrbitTargetUsageProbe, holdingLock: Bool = false) throws {
        guard confirmDeletingLaterChanges else { throw BrowserAuthenticationImportError.restoreConfirmationRequired }
        let lock = holdingLock ? nil : try OrbitDataDirectoryLock.acquire(root.url, exclusive: true)
        defer { lock?.release() }
        guard !usage.isInUse(sessionFile: root.url.appendingPathComponent("session.json")) else { throw ArcImportError.targetInUse }
        if try BrowserImportRecovery.open(at: root.url) == nil {
            _ = try BrowserImportRecovery.begin(at: .init(sessionFile: root.url.appendingPathComponent("session.json")),
                profiles: [document.profileID.rawValue], authentication: true, originalFiles: document.backup)
        }
        document.phase = .restoring; try save()
        try checkpoint("auth-restoring")
        guard let recovery = try BrowserImportRecovery.open(at: root.url) else { throw BrowserAuthenticationImportError.invalidState }
        try recovery.recover(.restore, holdingLock: true, quarantineAuthentication: false) { point in
            try self.checkpoint(point)
            if point.hasPrefix("recovery-profile:Chromium/") {
                try self.checkpoint("auth-restore-engine")
            } else if point.hasPrefix("recovery-profile:History/") {
                try self.checkpoint("auth-restore-history")
            } else if point.hasPrefix("recovery-file:") {
                try self.checkpoint(point.replacingOccurrences(of: "recovery-file:", with: "auth-restore-file:"))
            }
        }
        document.phase = .restored; document.files = [:]; document.passwords = []; try save()
        try checkpoint("auth-restored")
    }
}
