import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import BrowserCore

private final class R2ReviewStorage: OrbitRecoverySecItemBoundary {
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
        var row = attributes
        row[kSecValuePersistentRef as String] = reference
        rows.append(row)
        return (errSecSuccess, reference)
    }
}

private final class R2ReviewRoot {
    let url: URL
    let storage = R2ReviewStorage()
    let profile = "Chromium/profile-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    init() throws {
        url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-r2-independent-" + UUID().uuidString)
        for path in ["", "Chromium", profile] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(path), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try write(Data("orbit-auth-recovery-synthetic-v1\n".utf8), OrbitAuthenticationRecovery.syntheticMarker)
        try write(Data("invented original session".utf8), "session.json")
        try write(Data("invented original cookie".utf8), profile + "/Cookies")
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func write(_ bytes: Data, _ path: String) throws {
        let file = url.appendingPathComponent(path)
        try bytes.write(to: file)
        guard chmod(file.path, 0o600) == 0 else { throw OrbitRecoveryFailure.io }
    }
    func snapshot() throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(url.path.count))] = try Data(contentsOf: file)
            }
        }
        return result
    }
    func registeredBackup(_ lease: OrbitRecoveryRootLock) throws {
        let registration = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily)
        let provider = try registration.syntheticKeyProvider(product: .daily, backend: storage)
        _ = try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider,
                                                              profilePath: profile, deadline: 2000)
    }
    func run(_ lease: OrbitRecoveryRootLock, start: () throws -> Void) throws {
        try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: .daily,
                                                       backend: { self.storage }, now: 1000, runtimeStart: start)
    }
}

@Suite("Independent R2 shared handoff and retained authority", .serialized)
struct OrbitRegistrationLockR2IndependentTests {
    @Test func descriptorLocationRejectsReplacedRootAndNonRootDirectory() throws {
        let fixture = try R2ReviewRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        let location = try lease.root.sessionLocation()
        #expect(location.sessionFile.path == fixture.url.appendingPathComponent("session.json").path)
        let child = try RecoveryDirectory(parent: lease.root, name: "Chromium")
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try child.sessionLocation() }
        let moved = fixture.url.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: fixture.url, to: moved)
        defer {
            try? FileManager.default.removeItem(at: fixture.url)
            try? FileManager.default.moveItem(at: moved, to: fixture.url)
        }
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try lease.root.sessionLocation() }
    }

    // Deterministic states at the post-conversion seam, not a claim to force a
    // kernel scheduling window or a hostile writer while the shared lock is held.
    @Test(arguments: ["registration", "registration-writing", "marker", "marker-writing", "recovery-directory"])
    func newAuthorityAfterConversionRefusesWithoutMutation(_ kind: String) throws {
        let fixture = try R2ReviewRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        let structural = try RecoveryImportLock(root: lease.root)
        let location = try lease.root.sessionLocation()
        try structural.allowSessionReaders()
        let names = ["registration": OrbitRecoveryRootRegistration.fileName,
                     "registration-writing": OrbitRecoveryRootRegistration.fileName + ".writing",
                     "marker": OrbitAuthenticationRecovery.marker,
                     "marker-writing": OrbitAuthenticationRecovery.marker + ".writing"]
        if let name = names[kind] { try fixture.write(Data("invented interrupted authority".utf8), name) }
        else {
            try FileManager.default.createDirectory(at: fixture.url.appendingPathComponent(OrbitAuthenticationRecovery.directory),
                                                    withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let before = try fixture.snapshot()
        #expect(throws: OrbitRecoveryFailure.invalidEvidence) {
            try OrbitAuthenticationStartupGate.validateRegisteredRuntime(lease: lease, product: .daily,
                registration: nil, recovery: nil, location: location, now: 1000)
        }
        let unchanged = try fixture.snapshot() == before
        #expect(unchanged && fixture.storage.reads == 0 && fixture.storage.adds == 0)
        withExtendedLifetime(structural) {}
    }

    @Test(arguments: ["replacement", "mode", "publication"])
    func retainedRegistrationIsRecheckedAfterConversion(_ kind: String) throws {
        let fixture = try R2ReviewRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        let registration = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily)
        let structural = try RecoveryImportLock(root: lease.root)
        let location = try lease.root.sessionLocation()
        try structural.allowSessionReaders()
        let file = fixture.url.appendingPathComponent(OrbitRecoveryRootRegistration.fileName)
        if kind == "replacement" {
            let bytes = try Data(contentsOf: file)
            try FileManager.default.moveItem(at: file, to: fixture.url.appendingPathComponent("saved-registration"))
            try fixture.write(bytes, OrbitRecoveryRootRegistration.fileName)
        } else if kind == "mode" { #expect(chmod(file.path, 0o640) == 0) }
        else { try fixture.write(Data("invented incomplete publication".utf8), OrbitRecoveryRootRegistration.fileName + ".writing") }
        let before = try fixture.snapshot()
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationStartupGate.validateRegisteredRuntime(lease: lease, product: .daily,
                registration: registration, recovery: nil, location: location, now: 1000)
        }
        let unchanged = try fixture.snapshot() == before
        #expect(unchanged && fixture.storage.reads == 0)
        withExtendedLifetime(structural) {}
    }

    @Test(arguments: ["expiry", "journal", "chunk"])
    func authenticatedReadmissionIsReadOnlyAndRejectsInvalidBackup(_ kind: String) throws {
        let fixture = try R2ReviewRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        try fixture.registeredBackup(lease)
        // Registered load and recovery use the same fake-backed namespace as startup.
        let structural = try RecoveryImportLock(root: lease.root)
        let registration = try #require(try OrbitRecoveryRootRegistration.load(lease: lease, product: .daily))
        let provider = try registration.syntheticKeyProvider(product: .daily, backend: fixture.storage)
        let recovery = try #require(try OrbitAuthenticationRecovery.prepareBeforeRuntime(lease: lease, provider: provider,
            now: 1000, heldImportLock: structural))
        let location = try lease.root.sessionLocation()
        try structural.allowSessionReaders()
        let beforeValid = try fixture.snapshot()
        try OrbitAuthenticationStartupGate.validateRegisteredRuntime(lease: lease, product: .daily,
            registration: registration, recovery: recovery, location: location, now: 1000)
        let validUnchanged = try fixture.snapshot() == beforeValid
        #expect(validUnchanged)
        if kind != "expiry" {
            let work = fixture.url.appendingPathComponent(OrbitAuthenticationRecovery.directory)
            let name = kind == "journal" ? "journal" : try #require(FileManager.default.contentsOfDirectory(atPath: work.path)
                .filter { $0.hasPrefix("chunk-") }.sorted().first)
            var bytes = try Data(contentsOf: work.appendingPathComponent(name))
            bytes[bytes.count - 1] ^= 1
            try fixture.write(bytes, OrbitAuthenticationRecovery.directory + "/" + name)
        }
        let beforeInvalid = try fixture.snapshot()
        let reads = fixture.storage.reads
        #expect(throws: kind == "expiry" ? OrbitRecoveryFailure.expired : OrbitRecoveryFailure.invalidEvidence) {
            try OrbitAuthenticationStartupGate.validateRegisteredRuntime(lease: lease, product: .daily,
                registration: registration, recovery: recovery, location: location, now: kind == "expiry" ? 2000 : 1000)
        }
        let invalidUnchanged = try fixture.snapshot() == beforeInvalid
        #expect(invalidUnchanged && fixture.storage.reads == reads && fixture.storage.adds == 1)
        withExtendedLifetime((structural, recovery)) {}
    }

    @Test func authenticatedRuntimeThrowReleasesRecoveryAndRootButRetainsCallerInstance() throws {
        let fixture = try R2ReviewRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        try fixture.registeredBackup(lease)
        let runThrowingRuntime = {
            try fixture.run(lease) {
                let reader = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: false, validatingPath: false)
                defer { reader.release() }
                let directory = try RecoveryDirectory(parent: lease.root, name: OrbitAuthenticationRecovery.directory)
                let lock = try directory.openFile("lock")
                defer { close(lock) }
                #expect(flock(lock, LOCK_EX | LOCK_NB) != 0)
                #expect(throws: OrbitRecoveryFailure.busy) { try OrbitRecoveryRootLock(root: fixture.url) }
                throw OrbitRecoveryFailure.injected
            }
        }
        #expect(throws: OrbitRecoveryFailure.injected) { try runThrowingRuntime() }
        let writer = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: true)
        writer.release()
        let directory = try RecoveryDirectory(parent: lease.root, name: OrbitAuthenticationRecovery.directory)
        let lock = try directory.openFile("lock")
        defer { flock(lock, LOCK_UN); close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: OrbitRecoveryFailure.busy) { try OrbitRecoveryRootLock(root: fixture.url) }
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) != nil)
        #expect(fixture.storage.adds == 1)
    }

    @Test(arguments: [false, true])
    func structuralRestoreWithRetainedAuthenticatedEvidencePrecedesSessionRead(_ corrupt: Bool) throws {
        let fixture = try R2ReviewRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        try fixture.registeredBackup(lease)
        try fixture.run(lease) {}
        let evidence = try fixture.snapshot().filter { $0.key.hasPrefix("/" + OrbitAuthenticationRecovery.directory + "/") }
        let location = try lease.root.sessionLocation()
        let imports = try OrbitSecureDirectory.open(location.importDirectory, create: true)
        let id = "20261026T010000Z-abcdef12"
        let previous = try imports.directory(".restore-\(id)/previous", create: true)
        let staged = try imports.directory(".restore-\(id)/staged", create: true)
        let original = Data("invented parked session".utf8)
        try previous.write(original, to: "session.json")
        try staged.write(Data("invented next session".utf8), to: "session.json")
        try FileManager.default.removeItem(at: location.sessionFile)
        let moves = [ArcImportRestore.Move(from: "session.json", to: "Import/.restore-\(id)/previous/session.json"),
                     ArcImportRestore.Move(from: "Import/.restore-\(id)/staged/session.json", to: "session.json")]
        try imports.write(ArcImportFiles.encoder().encode(ArcImportRestore.Journal(backupID: id, phase: .swapping, moves: moves)),
                          to: ArcImportRestore.journalName)
        if corrupt {
            try imports.write(Data("invented unreadable restore journal".utf8), to: ArcImportRestore.journalName)
            let before = try fixture.snapshot()
            var started = false
            #expect(throws: ArcImportError.restoreJournalUnreadable) { try fixture.run(lease) { started = true } }
            let unchanged = try fixture.snapshot() == before
            #expect(!started && unchanged)
            let writer = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: true)
            writer.release()
            let directory = try RecoveryDirectory(parent: lease.root, name: OrbitAuthenticationRecovery.directory)
            let lock = try directory.openFile("lock")
            defer { flock(lock, LOCK_UN); close(lock) }
            #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
            #expect(throws: OrbitRecoveryFailure.busy) { try OrbitRecoveryRootLock(root: fixture.url) }
            return
        }
        try fixture.run(lease) {
            try ArcImportBackups.recoverInterruptedRestore(at: location)
            let reader = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: false, validatingPath: false)
            defer { reader.release() }
            let restored = try Data(contentsOf: location.sessionFile) == original
            #expect(restored && !ArcImportBackups.hasInterruptedRestore(at: location))
        }
        let evidenceRetained = try fixture.snapshot().filter { $0.key.hasPrefix("/" + OrbitAuthenticationRecovery.directory + "/") } == evidence
        #expect(evidenceRetained && fixture.storage.adds == 1)
    }
}
