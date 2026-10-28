import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import BrowserCore

/// No native Security implementation is constructed by this suite.
private final class RegistrationStorage: OrbitRecoverySecItemBoundary {
    var rows: [[String: Any]] = []
    var reads = 0
    var adds = 0
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        reads += 1
        let matches = rows.filter {
            $0[kSecAttrService as String] as? String == query[kSecAttrService as String] as? String &&
            $0[kSecAttrAccount as String] as? String == query[kSecAttrAccount as String] as? String
        }
        return matches.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, matches)
    }
    func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        adds += 1
        let reference = Data(UUID().uuidString.utf8)
        var row = attributes; row[kSecValuePersistentRef as String] = reference; rows.append(row)
        return (errSecSuccess, reference)
    }
}
private final class RegistrationFixture {
    let root: URL
    let storage = RegistrationStorage()
    let profile = "Chromium/profile-11111111-1111-1111-1111-111111111111"
    let sibling = "Chromium/profile-22222222-2222-2222-2222-222222222222"
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("orbit-registration-synthetic-" + UUID().uuidString)
        for path in ["", "Chromium", profile, sibling] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try write("orbit-auth-recovery-synthetic-v1\n", OrbitAuthenticationRecovery.syntheticMarker)
        try write("invented-original", profile + "/Cookies")
        try write("invented-sibling", sibling + "/Cookies")
        try write("invented-session", "session.json")
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try Data(text.utf8).write(to: url); guard chmod(url.path, 0o600) == 0 else { throw OrbitRecoveryFailure.io }
    }
    func prepare(_ lease: OrbitRecoveryRootLock) throws -> OrbitRecoveryRootRegistration {
        try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily)
    }
    func backup(_ lease: OrbitRecoveryRootLock) throws -> OrbitAuthenticationRecovery {
        let registration = try prepare(lease)
        let provider = try registration.syntheticKeyProvider(product: .daily, backend: storage)
        return try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider, profilePath: profile, deadline: 2000)
    }
    func run(_ lease: OrbitRecoveryRootLock, product: OrbitNativeRecoveryKeyProvider.Product = .daily, now: Int64 = 1000,
             start: () throws -> Void) throws {
        try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: product, backend: { self.storage }, now: now, runtimeStart: start)
    }
}

@Suite("Durable nonsecret root registration and load-only recovery", .serialized)
struct OrbitRecoveryRootRegistrationTests {
    @Test func stablePublicationReopensWithoutProvisioningAndAuthenticatesRollback() throws {
        let f = try RegistrationFixture()
        var original: Data?
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            _ = try f.backup(lease)
            original = try Data(contentsOf: f.root.appendingPathComponent(OrbitRecoveryRootRegistration.fileName))
            try f.write("changed", f.profile + "/Cookies"); try f.write("changed", "session.json")
        }
        var starts = 0
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            try f.run(lease) { starts += 1 }
        }
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            try f.run(lease) { starts += 1 }
        }
        let registrationPreserved = try Data(contentsOf: f.root.appendingPathComponent(OrbitRecoveryRootRegistration.fileName)) == original
        let profileRestored = try Data(contentsOf: f.root.appendingPathComponent(f.profile + "/Cookies")) == Data("invented-original".utf8)
        let siblingPreserved = try Data(contentsOf: f.root.appendingPathComponent(f.sibling + "/Cookies")) == Data("invented-sibling".utf8)
        #expect(registrationPreserved && profileRestored && siblingPreserved)
        #expect(starts == 2 && f.storage.adds == 1)
    }

    @Test func untouchedAndRegisteredWithoutEvidenceHaveZeroStorageAccesses() throws {
        let f = try RegistrationFixture(); let lease = try OrbitRecoveryRootLock(root: f.root)
        var factories = 0; var starts = 0
        func run() throws {
            try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: .daily, backend: {
                factories += 1; return f.storage
            }) { starts += 1 }
        }
        try run(); _ = try f.prepare(lease); try run()
        #expect(starts == 2 && factories == 0 && f.storage.reads == 0 && f.storage.adds == 0)
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) == nil)
    }

    @Test func creationRequiresExactSyntheticMarkerAndRejectsExistingEvidence() throws {
        let f = try RegistrationFixture(); let lease = try OrbitRecoveryRootLock(root: f.root)
        try f.write("incorrect", OrbitAuthenticationRecovery.syntheticMarker)
        #expect(throws: (any Error).self) { try f.prepare(lease) }
        #expect(try lease.root.info(OrbitRecoveryRootRegistration.fileName) == nil)
        try f.write("orbit-auth-recovery-synthetic-v1\n", OrbitAuthenticationRecovery.syntheticMarker)
        try f.write("incomplete", OrbitAuthenticationRecovery.marker)
        #expect(throws: (any Error).self) { try f.prepare(lease) }
        #expect(f.storage.reads == 0 && f.storage.adds == 0)
    }

    @Test(arguments: ["missing", "wrong", "pending", "expired", "corrupt"])
    func evidenceRefusalNeverCreatesOrMutates(_ kind: String) throws {
        let f = try RegistrationFixture()
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root); let recovery = try f.backup(lease)
            if kind == "pending" { try recovery.withSyntheticMutation(now: 1000) {} }
        }
        if kind == "missing" { f.storage.rows = [] }
        if kind == "wrong" {
            var value = f.storage.rows[0][kSecValueData as String] as! Data
            value[value.count - 1] ^= 1; f.storage.rows[0][kSecValueData as String] = value
        }
        if kind == "corrupt" { try f.write("corrupt", OrbitAuthenticationRecovery.directory + "/journal") }
        try f.write("must-remain", "session.json")
        let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0
        #expect(throws: (any Error).self) { try f.run(lease, now: kind == "expired" ? 3000 : 1000) { starts += 1 } }
        let unchanged = try Data(contentsOf: f.root.appendingPathComponent("session.json")) == Data("must-remain".utf8)
        #expect(starts == 0 && unchanged && f.storage.adds == 1)
    }

    @Test(arguments: ["absent", "malformed", "mode", "special", "symlink", "hardlink", "directory", "fifo", "metadata", "root-metadata", "replacement", "root-mode", "root-special", "channel", "root", "service", "identity", "location"])
    func registrationAdmissionFailsBeforeStorageOrMutation(_ kind: String) throws {
        let f = try RegistrationFixture()
        do { let lease = try OrbitRecoveryRootLock(root: f.root); _ = try f.backup(lease) }
        let url = f.root.appendingPathComponent(OrbitRecoveryRootRegistration.fileName)
        let original = try Data(contentsOf: url)
        switch kind {
        case "absent": try FileManager.default.removeItem(at: url)
        case "malformed": try f.write("invalid", OrbitRecoveryRootRegistration.fileName)
        case "mode": #expect(chmod(url.path, 0o640) == 0)
        case "special": #expect(chmod(url.path, 0o4600) == 0)
        case "symlink":
            let saved = f.root.appendingPathComponent("saved"); try FileManager.default.moveItem(at: url, to: saved)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: saved)
        case "hardlink": #expect(link(url.path, f.root.appendingPathComponent("linked").path) == 0)
        case "directory":
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        case "fifo":
            try FileManager.default.removeItem(at: url); #expect(mkfifo(url.path, 0o600) == 0)
        case "metadata", "root-metadata":
            let path = kind == "metadata" ? url.path : f.root.path
            #expect(setxattr(path, "io.github.okatech.orbit.test.unsupported", "fixture", 7, 0, 0) == 0)
        case "replacement":
            try FileManager.default.moveItem(at: url, to: f.root.appendingPathComponent("saved"))
            try original.write(to: url); #expect(chmod(url.path, 0o600) == 0)
        case "root-mode": #expect(chmod(f.root.path, 0o750) == 0)
        case "root-special": #expect(chmod(f.root.path, 0o1700) == 0)
        case "channel": break
        default:
            var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            switch kind {
            case "root": object["rootInode"] = 1
            case "service": object["service"] = "Orbit Safe Storage"
            case "identity": object["registration"] = UUID().uuidString
            default: object["location"] = Data(repeating: 0, count: 32).base64EncodedString()
            }
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        }
        let reads = f.storage.reads; let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0
        #expect(throws: (any Error).self) { try f.run(lease, product: kind == "channel" ? .live : .daily) { starts += 1 } }
        // Even a canonical registration-ID edit is rejected by the intent binding before
        // consulting any account. No old key can be adopted and no state can be mutated.
        #expect(starts == 0 && f.storage.reads == reads && f.storage.adds == 1)
        let unchanged = try Data(contentsOf: f.root.appendingPathComponent("session.json")) == Data("invented-session".utf8)
        #expect(unchanged)
    }

    @Test(arguments: [OrbitRecoveryRootRegistration.PublicationBoundary.written, .durable, .published])
    func interruptedPublicationNeverInventsANewIdentity(_ boundary: OrbitRecoveryRootRegistration.PublicationBoundary) throws {
        let f = try RegistrationFixture()
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            #expect(throws: OrbitRecoveryFailure.injected) {
                try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily) {
                    if $0 == boundary { throw OrbitRecoveryFailure.injected }
                }
            }
        }
        let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0
        if boundary == .published {
            let bytes = try lease.root.read(OrbitRecoveryRootRegistration.fileName, limit: 4096)
            _ = try f.prepare(lease)
            #expect(try lease.root.read(OrbitRecoveryRootRegistration.fileName, limit: 4096) == bytes)
            try f.run(lease) { starts += 1 }; #expect(starts == 1)
        } else {
            #expect(throws: (any Error).self) { try f.prepare(lease) }
            #expect(throws: (any Error).self) { try f.run(lease) { starts += 1 } }
            let incomplete = try lease.root.info(OrbitRecoveryRootRegistration.fileName + ".writing") != nil
            #expect(starts == 0 && incomplete)
        }
        #expect(f.storage.reads == 0 && f.storage.adds == 0)
    }

    @Test func foreignCopyMovedRootAndAncestorAliasCannotAdoptRegistration() throws {
        let f = try RegistrationFixture(); let other = try RegistrationFixture()
        do { let lease = try OrbitRecoveryRootLock(root: f.root); _ = try f.prepare(lease) }
        let name = OrbitRecoveryRootRegistration.fileName
        try FileManager.default.copyItem(at: f.root.appendingPathComponent(name), to: other.root.appendingPathComponent(name))
        do {
            let lease = try OrbitRecoveryRootLock(root: other.root)
            #expect(throws: (any Error).self) { try other.run(lease) {} }
        }
        let moved = f.root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: f.root, to: moved)
        defer { try? FileManager.default.moveItem(at: moved, to: f.root) }
        do {
            let lease = try OrbitRecoveryRootLock(root: moved)
            #expect(throws: (any Error).self) { try f.run(lease) {} }
        }
        let alias = f.root.appendingPathExtension("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: moved)
        defer { try? FileManager.default.removeItem(at: alias) }
        #expect(throws: (any Error).self) { try OrbitRecoveryRootLock(root: alias) }
        #expect(f.storage.reads == 0 && other.storage.reads == 0)
    }

    @Test func allLocksRemainHeldInsideRuntimeAndReleaseAfterItReturns() throws {
        let f = try RegistrationFixture()
        do { let lease = try OrbitRecoveryRootLock(root: f.root); _ = try f.backup(lease) }
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            try f.run(lease) {
                #expect(throws: OrbitRecoveryFailure.busy) { try OrbitRecoveryRootLock(root: f.root) }
                #expect(throws: OrbitRecoveryFailure.busy) { try RecoveryImportLock(root: lease.root) }
                let directory = try RecoveryDirectory(parent: lease.root, name: OrbitAuthenticationRecovery.directory)
                let file = try directory.openFile("lock"); defer { close(file) }
                #expect(flock(file, LOCK_EX | LOCK_NB) != 0)
            }
            _ = try RecoveryImportLock(root: lease.root)
        }
        _ = try OrbitRecoveryRootLock(root: f.root)
    }

    @Test func publicRegistrationAndIntentEditsCannotForgeAuthenticatedJournal() throws {
        let f = try RegistrationFixture()
        do { let lease = try OrbitRecoveryRootLock(root: f.root); _ = try f.backup(lease) }
        let url = f.root.appendingPathComponent(OrbitRecoveryRootRegistration.fileName)
        let old = try OrbitAuthenticationRecovery.decode(OrbitRecoveryRootRegistration.Record.self, Data(contentsOf: url))
        try FileManager.default.moveItem(at: url, to: f.root.appendingPathComponent("saved"))
        try f.write("", OrbitRecoveryRootRegistration.fileName)
        var info = stat(); #expect(lstat(url.path, &info) == 0)
        let forged = OrbitRecoveryRootRegistration.Record(version: old.version, registration: old.registration,
            product: old.product, service: old.service, owner: old.owner, rootDevice: old.rootDevice,
            rootInode: old.rootInode, location: old.location, fileDevice: UInt64(truncatingIfNeeded: info.st_dev), fileInode: UInt64(info.st_ino))
        let bytes = try OrbitAuthenticationRecovery.encode(forged); try bytes.write(to: url)
        let marker = f.root.appendingPathComponent(OrbitAuthenticationRecovery.marker)
        var intent = try OrbitAuthenticationRecovery.decode(OrbitAuthenticationRecovery.Intent.self, Data(contentsOf: marker))
        intent.registration = Data(SHA256.hash(data: bytes))
        try OrbitAuthenticationRecovery.encode(intent).write(to: marker)
        let reads = f.storage.reads; let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0
        #expect(throws: (any Error).self) { try f.run(lease) { starts += 1 } }
        #expect(starts == 0 && f.storage.reads > reads && f.storage.adds == 1)
        let unchanged = try Data(contentsOf: f.root.appendingPathComponent("session.json")) == Data("invented-session".utf8)
        #expect(unchanged)
    }

    @Test func replacedRootAfterLeaseCannotPrepareOrLoad() throws {
        let f = try RegistrationFixture(); let lease = try OrbitRecoveryRootLock(root: f.root)
        _ = try f.prepare(lease)
        let moved = f.root.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: f.root, to: moved)
        defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.moveItem(at: moved, to: f.root) }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(throws: (any Error).self) { try f.prepare(lease) }
        #expect(throws: (any Error).self) { try f.run(lease) {} }
        #expect(f.storage.reads == 0 && f.storage.adds == 0)
    }

    @Test func registrationReplacementAfterAdmissionRefusesBeforeKeyPreparation() throws {
        let f = try RegistrationFixture(); let lease = try OrbitRecoveryRootLock(root: f.root)
        let registration = try f.prepare(lease)
        let provider = try registration.syntheticKeyProvider(product: .daily, backend: f.storage)
        let url = f.root.appendingPathComponent(OrbitRecoveryRootRegistration.fileName)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.moveItem(at: url, to: f.root.appendingPathComponent("saved"))
        try bytes.write(to: url); #expect(chmod(url.path, 0o600) == 0)
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider, profilePath: f.profile, deadline: 2000)
        }
        #expect(f.storage.reads == 0 && f.storage.adds == 0)
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) == nil)
    }
}
