import CryptoKit
import Darwin
import Foundation
import Testing
@testable import BrowserCore

/// A separately provisioned, private test key. This provider never creates/falls back to a key
/// when loading and never reads any Arc/Chromium storage. Its file is outside the product root.
private struct PersistedTestRecoveryKey: OrbitRecoveryKeyProvider {
    let location: URL
    func loadRecoveryKey(transaction: UUID) throws -> SymmetricKey {
        let p = try RecoveryDirectory(url: location.deletingLastPathComponent())
        let data = try p.read(location.lastPathComponent, limit: 32)
        guard data.count == 32 else { throw OrbitRecoveryFailure.keyUnavailable }
        return SymmetricKey(data: data)
    }
}

private final class RecoveryFixture {
    let home: URL
    let root: URL
    let keyFile: URL
    let profile = "Chromium/profile-11111111-1111-1111-1111-111111111111"
    let other = "Chromium/profile-22222222-2222-2222-2222-222222222222"
    var provider: PersistedTestRecoveryKey { PersistedTestRecoveryKey(location: keyFile) }
    init() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("orbit-auth-recovery-" + UUID().uuidString)
        root = home.appendingPathComponent("product")
        keyFile = home.appendingPathComponent("independent-test-key")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try directory("Chromium"); try directory(profile); try directory(other); try directory(profile + "/Nested")
        try directory("Import"); try directory("History")
        try write("original-profile", profile + "/Cookies")
        try write(Data(repeating: 71, count: OrbitAuthenticationRecovery.chunkSize * 2 + 13), profile + "/Nested/large")
        try write("other-profile", other + "/Cookies")
        try write("session-original", "session.json")
        try write("ledger-original", "Import/arc-import-ledger.json")
        try write("history-original", "History/history.sqlite")
        try write("wal-original", "History/history.sqlite-wal")
        try write("local-state-original", "Chromium/Local State")
        let file = open(root.appendingPathComponent(profile + "/Cookies").path, O_RDWR)
        defer { close(file) }
        let attribute = Data("invented-xattr".utf8)
        let status = attribute.withUnsafeBytes { fsetxattr(file, "lab.orbit.synthetic", $0.baseAddress, attribute.count, 0, 0) }
        guard status == 0 else { throw OrbitRecoveryFailure.io }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 1337, tv_nsec: 123456789)]
        guard futimens(file, &times) == 0 else { throw OrbitRecoveryFailure.io }
        try write("orbit-auth-recovery-synthetic-v1\n", OrbitAuthenticationRecovery.syntheticMarker)
        let parent = try RecoveryDirectory(url: home)
        try parent.publish(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, as: keyFile.lastPathComponent)
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func directory(_ path: String) throws { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
    func write(_ string: String, _ path: String) throws { try write(Data(string.utf8), path) }
    func write(_ data: Data, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try data.write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw OrbitRecoveryFailure.io }
    }
    func read(_ path: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(path)) }
    func backup(_ lease: OrbitRecoveryRootLock, failpoint: @escaping (OrbitAuthenticationRecovery.Boundary) throws -> Void = { _ in }) throws -> OrbitAuthenticationRecovery {
        try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider, profilePath: profile, deadline: 2000, failpoint: failpoint)
    }
    func mutate() throws {
        try write("changed", profile + "/Cookies"); try write("new", profile + "/added")
        try write("changed", "session.json"); try write("changed", "Import/arc-import-ledger.json")
        try write("changed", "History/history.sqlite"); try write("changed", "History/history.sqlite-wal")
        try write("new-mapping", "profile-mapping.json")
        try write("local-state-changed", "Chromium/Local State")
        let file = open(root.appendingPathComponent(profile + "/Cookies").path, O_RDWR)
        defer { close(file) }
        guard fremovexattr(file, "lab.orbit.synthetic", 0) == 0 else { throw OrbitRecoveryFailure.io }
    }
    func expectOriginal() throws {
        #expect(try read(profile + "/Cookies") == Data("original-profile".utf8))
        #expect(try read(profile + "/Nested/large") == Data(repeating: 71, count: OrbitAuthenticationRecovery.chunkSize * 2 + 13))
        #expect(try read("session.json") == Data("session-original".utf8))
        #expect(try read("Import/arc-import-ledger.json") == Data("ledger-original".utf8))
        #expect(try read("History/history.sqlite") == Data("history-original".utf8))
        #expect(try read("History/history.sqlite-wal") == Data("wal-original".utf8))
        #expect(try read("Chromium/Local State") == Data("local-state-original".utf8))
        let p = try RecoveryDirectory(url: root.appendingPathComponent(profile))
        let file = try p.openFile("Cookies"); defer { close(file) }
        #expect(try RecoveryDirectory.attributes(file)["lab.orbit.synthetic"] == Data("invented-xattr".utf8))
        var stat = Darwin.stat(); #expect(fstat(file, &stat) == 0)
        #expect(stat.st_mode & 0o777 == 0o600)
        #expect(stat.st_mtimespec.tv_sec == 1337 && stat.st_mtimespec.tv_nsec == 123456789)
        #expect(try read(other + "/Cookies") == Data("other-profile".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("profile-mapping.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(profile + "/added").path))
    }
    func crashApplying() throws {
        let lease = try OrbitRecoveryRootLock(root: root)
        let recovery = try backup(lease)
        #expect(throws: OrbitRecoveryFailure.injected) {
            try recovery.withSyntheticMutation(now: 1000) { try mutate(); throw OrbitRecoveryFailure.injected }
        }
    }
    func refuse(provider: (any OrbitRecoveryKeyProvider)?, now: Int64 = 1000) throws {
        let lease = try OrbitRecoveryRootLock(root: root); var calls = 0
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationStartupGate.run(lease: lease, provider: provider, now: now) { calls += 1 }
        }
        #expect(calls == 0)
    }
}

@Suite("Encrypted whole-profile recovery and pre-runtime gate", .serialized)
struct OrbitAuthenticationRecoveryTests {
    @Test func noImportAndRootLockOrdering() throws {
        let f = try RecoveryFixture(); let lease = try OrbitRecoveryRootLock(root: f.root)
        var calls = 0
        try OrbitAuthenticationStartupGate.run(lease: lease) { calls += 1 }
        #expect(calls == 1)
        #expect(throws: OrbitRecoveryFailure.busy) { try OrbitRecoveryRootLock(root: f.root) }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(OrbitAuthenticationRecovery.directory).path))
    }
    @Test func encryptedRestartRollbackWithoutSource() throws {
        let f = try RecoveryFixture()
        try f.crashApplying() // releases all recovery objects, keys and locks
        let lease = try OrbitRecoveryRootLock(root: f.root)
        let rootID = lease.root.inode
        let lockStat = try #require(try lease.root.info(".orbit-instance.lock"))
        let encrypted = try f.read(OrbitAuthenticationRecovery.directory + "/chunk-1-0")
        #expect(encrypted.range(of: Data("original-profile".utf8)) == nil)
        var calls = 0
        // New provider reloads independently persisted key; there is no source snapshot/key.
        try OrbitAuthenticationStartupGate.run(lease: lease, provider: PersistedTestRecoveryKey(location: f.keyFile), now: 1000) { calls += 1 }
        #expect(calls == 1); try f.expectOriginal()
        #expect(lease.root.inode == rootID)
        #expect(try lease.root.info(".orbit-instance.lock")?.st_ino == lockStat.st_ino)
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) != nil)
    }
    @Test func pendingVerificationNeverStartsRuntime() throws {
        let f = try RecoveryFixture()
        do { let lease = try OrbitRecoveryRootLock(root: f.root); let r = try f.backup(lease); try r.withSyntheticMutation(now: 1000) { try f.mutate() } }
        try f.refuse(provider: f.provider)
        try f.refuse(provider: f.provider, now: 2000)
        try f.refuse(provider: nil)
        #expect(try f.read("session.json") == Data("changed".utf8))
    }
    @Test(arguments: ["journal", "manifest", "chunk-1-0", "key", "missing-journal", "missing-marker", "missing-chunk", "unknown-version"])
    func corruptionAndKeyLoss(_ kind: String) throws {
        let f = try RecoveryFixture(); try f.crashApplying()
        let work = OrbitAuthenticationRecovery.directory + "/"
        if kind == "key" { try FileManager.default.removeItem(at: f.keyFile) }
        else if kind == "missing-journal" { try FileManager.default.removeItem(at: f.root.appendingPathComponent(work + "journal")) }
        else if kind == "missing-marker" { try FileManager.default.removeItem(at: f.root.appendingPathComponent(OrbitAuthenticationRecovery.marker)) }
        else if kind == "missing-chunk" { try FileManager.default.removeItem(at: f.root.appendingPathComponent(work + "chunk-1-0")) }
        else if kind == "unknown-version" {
            var intent = try JSONSerialization.jsonObject(with: f.read(OrbitAuthenticationRecovery.marker)) as! [String: Any]
            intent["version"] = 999
            try f.write(JSONSerialization.data(withJSONObject: intent), OrbitAuthenticationRecovery.marker)
        } else {
            var data = try f.read(work + kind); data[data.count / 2] ^= 1
            try f.write(data, work + kind)
        }
        try f.refuse(provider: f.provider)
        #expect(try f.read("session.json") == Data("changed".utf8))
    }
    @Test(arguments: ["profile", "backup", "root", "lock", "symlink", "hardlink", "fifo", "truncate", "swapped-chunks"])
    func identityAndUnsafeInputs(_ kind: String) throws {
        let f = try RecoveryFixture(); try f.crashApplying()
        if kind == "profile" || kind == "backup" {
            let path = kind == "profile" ? f.profile : OrbitAuthenticationRecovery.directory
            let url = f.root.appendingPathComponent(path)
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("retained"))
            try f.directory(path)
        } else if kind == "root" {
            let url = f.root.appendingPathExtension("retained")
            try FileManager.default.moveItem(at: f.root, to: url)
            try FileManager.default.copyItem(at: url, to: f.root)
        } else if kind == "lock" {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            try FileManager.default.moveItem(at: f.root.appendingPathComponent(".orbit-instance.lock"), to: f.root.appendingPathComponent("retained-lock"))
            try f.write("", ".orbit-instance.lock")
            var calls = 0
            #expect(throws: (any Error).self) { try OrbitAuthenticationStartupGate.run(lease: lease, provider: f.provider) { calls += 1 } }
            #expect(calls == 0); return
        } else if kind == "truncate" { try f.write(Data([0]), OrbitAuthenticationRecovery.directory + "/chunk-1-0") }
        else if kind == "swapped-chunks" {
            let a = OrbitAuthenticationRecovery.directory + "/chunk-3-0"
            let b = OrbitAuthenticationRecovery.directory + "/chunk-3-1"
            let bytes = try f.read(a); try f.write(f.read(b), a); try f.write(bytes, b)
        } else {
            let path = f.root.appendingPathComponent(f.profile + "/unsafe").path
            if kind == "symlink" { #expect(symlink("Cookies", path) == 0) }
            if kind == "hardlink" { #expect(link(f.root.appendingPathComponent(f.profile + "/Cookies").path, path) == 0) }
            if kind == "fifo" { #expect(mkfifo(path, 0o600) == 0) }
        }
        try f.refuse(provider: f.provider)
    }
    @Test func sharedImporterExclusionAndDormantQuarantine() throws {
        let f = try RecoveryFixture()
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            let importLock = try OrbitDataDirectoryLock.acquire(f.root, exclusive: false, validatingPath: false)
            defer { importLock.release() }
            #expect(throws: OrbitRecoveryFailure.busy) { try f.backup(lease) }
            #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) == nil)
        }
        try f.directory("Chromium/Auth-33333333-3333-3333-3333-333333333333")
        try f.refuse(provider: nil)
    }
    @Test func wrongKeyInterruptedWriteAndReplacementBeforeApply() throws {
        let f = try RecoveryFixture(); try f.crashApplying()
        try f.refuse(provider: f.provider, now: 2000)
        let parent = try RecoveryDirectory(url: f.home)
        try parent.publish(Data(repeating: 5, count: 32), as: f.keyFile.lastPathComponent, replace: true)
        try f.refuse(provider: f.provider)
        let g = try RecoveryFixture()
        do { let lease = try OrbitRecoveryRootLock(root: g.root); _ = try g.backup(lease) }
        try g.write(Data([1, 2, 3]), OrbitAuthenticationRecovery.directory + "/interrupted.writing")
        try g.refuse(provider: g.provider)
        let h = try RecoveryFixture(); let lease = try OrbitRecoveryRootLock(root: h.root)
        let r = try h.backup(lease)
        let url = h.root.appendingPathComponent(h.profile)
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("retained"))
        try h.directory(h.profile)
        var mutations = 0
        #expect(throws: (any Error).self) { try r.withSyntheticMutation(now: 1000) { mutations += 1 } }
        #expect(mutations == 0)
    }
    @Test func unsafeBackupAndPolicyLimitsAreNotPartialSuccess() throws {
        for kind in ["link", "mode", "large", "subset", "structural-recovery"] {
            let f = try RecoveryFixture(); let lease = try OrbitRecoveryRootLock(root: f.root)
            let path = f.root.appendingPathComponent(f.profile + "/unsafe").path
            if kind == "structural-recovery" { try f.write("incomplete-invented-journal", "Import/arc-import-restore.json") }
            if kind == "link" { #expect(symlink("Cookies", path) == 0) }
            if kind == "mode" { try f.write("unsafe", f.profile + "/unsafe"); #expect(chmod(path, 0o644) == 0) }
            if kind == "large" {
                let file = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600); defer { close(file) }
                #expect(ftruncate(file, off_t(OrbitAuthenticationRecovery.maxFileBytes + 1)) == 0)
            }
            #expect(throws: (any Error).self) {
                if kind == "subset" {
                    _ = try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: f.provider, profilePath: f.profile, statePaths: ["session.json"], deadline: 2000)
                } else { _ = try f.backup(lease) }
            }
            #expect(try f.read("session.json") == Data("session-original".utf8))
        }
    }
    @Test func expiredApplyDoesNotAuthorizeMutation() throws {
        let f = try RecoveryFixture(); let lease = try OrbitRecoveryRootLock(root: f.root)
        let recovery = try f.backup(lease); var writes = 0
        #expect(throws: OrbitRecoveryFailure.expired) { try recovery.withSyntheticMutation(now: 2000) { writes += 1 } }
        #expect(throws: OrbitRecoveryFailure.expired) { try recovery.withSyntheticMutation(now: 0) { writes += 1 } }
        #expect(writes == 0)
        try f.expectOriginal()
    }
    @Test(arguments: ["phase", "version", "profileIdentity", "backupIdentity"])
    func authenticatedUnknownOrMismatchedJournalRefuses(_ field: String) throws {
        let f = try RecoveryFixture(); try f.crashApplying()
        let intent = try f.read(OrbitAuthenticationRecovery.marker)
        let key = try f.provider.loadRecoveryKey(transaction: UUID())
        let aad = intent + Data("\njournal-v1".utf8)
        let sealed = try f.read(OrbitAuthenticationRecovery.directory + "/journal")
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
        var object = try JSONSerialization.jsonObject(with: plain) as! [String: Any]
        if field == "phase" { object["phase"] = "unknown-future-phase" }
        if field == "version" { object["version"] = 999 }
        if field == "profileIdentity" { object["profile"] = ["device": 0, "inode": 0] }
        if field == "backupIdentity" { object["backup"] = ["device": 0, "inode": 0] }
        let bad = try AES.GCM.seal(JSONSerialization.data(withJSONObject: object), using: key, authenticating: aad).combined!
        try f.write(bad, OrbitAuthenticationRecovery.directory + "/journal")
        try f.refuse(provider: f.provider)
        #expect(try f.read("session.json") == Data("changed".utf8))
    }
    @Test(arguments: [OrbitAuthenticationRecovery.Boundary.intent, .journal, .backupChunk, .backupManifest, .backupDurable, .applying, .verificationPending])
    func publicationFailpoints(_ boundary: OrbitAuthenticationRecovery.Boundary) throws {
        let f = try RecoveryFixture()
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            #expect(throws: OrbitRecoveryFailure.injected) {
                let r = try f.backup(lease) { if $0 == boundary { throw OrbitRecoveryFailure.injected } }
                try r.withSyntheticMutation(now: 1000) { try f.mutate() }
            }
        }
        if boundary == .backupDurable || boundary == .applying {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            try OrbitAuthenticationStartupGate.run(lease: lease, provider: f.provider, now: 1000) {}
            try f.expectOriginal()
        } else { try f.refuse(provider: f.provider) }
    }
    @Test(arguments: [OrbitAuthenticationRecovery.Boundary.restoring, .restoreCleared, .restoreChunk, .restoreEntry, .rolledBack])
    func interruptedRestoreRetriesDeterministically(_ boundary: OrbitAuthenticationRecovery.Boundary) throws {
        let f = try RecoveryFixture(); try f.crashApplying()
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root); var calls = 0; var chunkWrites = 0
            #expect(throws: OrbitRecoveryFailure.injected) {
                try OrbitAuthenticationStartupGate.run(lease: lease, provider: f.provider, now: 1000, failpoint: {
                    if $0 == .restoreChunk { chunkWrites += 1 }
                    if $0 == boundary && (boundary != .restoreChunk || chunkWrites == 3) { throw OrbitRecoveryFailure.injected }
                }) { calls += 1 }
            }
            #expect(calls == 0)
            if boundary == .restoreChunk {
                #expect(try f.read(f.profile + "/Nested/large").count == OrbitAuthenticationRecovery.chunkSize * 2)
            }
        }
        let lease = try OrbitRecoveryRootLock(root: f.root)
        try OrbitAuthenticationStartupGate.run(lease: lease, provider: f.provider, now: 1000) {}
        try f.expectOriginal()
    }
}
