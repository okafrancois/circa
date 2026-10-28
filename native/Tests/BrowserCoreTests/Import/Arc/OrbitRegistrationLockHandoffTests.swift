import Darwin
import Foundation
import Security
import Testing
@testable import BrowserCore

private final class LockHandoffStorage: OrbitRecoverySecItemBoundary {
    var calls = 0
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        calls += 1; return (errSecItemNotFound, nil)
    }
    func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        calls += 1; return (errSecNotAvailable, nil)
    }
}

private final class LockHandoffRoot {
    let url: URL
    let storage = LockHandoffStorage()
    init() throws {
        url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("orbit-lock-handoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try write(Data("orbit-auth-recovery-synthetic-v1\n".utf8), to: url.appendingPathComponent(OrbitAuthenticationRecovery.syntheticMarker))
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func write(_ data: Data, to file: URL) throws {
        try data.write(to: file)
        guard chmod(file.path, 0o600) == 0 else { throw OrbitRecoveryFailure.io }
    }
    func run(_ lease: OrbitRecoveryRootLock, start: () throws -> Void) throws {
        try OrbitAuthenticationStartupGate.runRegistered(lease: lease, product: .daily,
                                                        backend: { self.storage }, runtimeStart: start)
    }
}

@Suite("Recovery lock handoff to normal persistent sessions", .serialized)
struct OrbitRegistrationLockHandoffTests {
    @Test(arguments: [false, true])
    func readersShareWhileOfflineWritersAndAnotherInstanceRemainExcluded(_ registered: Bool) throws {
        let fixture = try LockHandoffRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        if registered { _ = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily) }
        try fixture.run(lease) {
            let first = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: false, validatingPath: false)
            defer { first.release() }
            let second = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: false, validatingPath: false)
            defer { second.release() }
            #expect(throws: ArcImportError.targetInUse) { try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: true) }
            #expect(throws: OrbitRecoveryFailure.busy) { try OrbitRecoveryRootLock(root: fixture.url) }
            #expect(throws: OrbitRecoveryFailure.busy) { try RecoveryImportLock(root: lease.root) }
        }
        let writer = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: true)
        writer.release()
        #expect(fixture.storage.calls == 0)
    }

    @Test(arguments: [false, true])
    func interruptedStructuralRestoreFinishesBeforeSharedSessionAdmission(_ registered: Bool) throws {
        let fixture = try LockHandoffRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        if registered { _ = try OrbitRecoveryRootRegistration.prepareSynthetic(lease: lease, product: .daily) }
        let location = ArcImportDataLocation(sessionFile: fixture.url.appendingPathComponent("session.json"))
        let imports = try OrbitSecureDirectory.open(location.importDirectory, create: true)
        let id = "20261026T000000Z-12345678"
        let previous = try imports.directory(".restore-\(id)/previous", create: true)
        let staged = try imports.directory(".restore-\(id)/staged", create: true)
        let original = Data("invented pre-restore session".utf8)
        try previous.write(original, to: "session.json")
        try staged.write(Data("invented replacement".utf8), to: "session.json")
        let moves = [ArcImportRestore.Move(from: "session.json", to: "Import/.restore-\(id)/previous/session.json"),
                     ArcImportRestore.Move(from: "Import/.restore-\(id)/staged/session.json", to: "session.json")]
        try imports.write(ArcImportFiles.encoder().encode(ArcImportRestore.Journal(
            backupID: id, phase: .swapping, moves: moves)), to: ArcImportRestore.journalName)
        try fixture.run(lease) {
            #expect(!ArcImportBackups.hasInterruptedRestore(at: location))
            #expect(try Data(contentsOf: location.sessionFile) == original)
            // This is the same first restoration call and shared acquisition as the environment.
            try ArcImportBackups.recoverInterruptedRestore(at: location)
            let reader = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: false, validatingPath: false)
            reader.release()
        }
        #expect(!FileManager.default.fileExists(atPath: location.importDirectory.appendingPathComponent(".restore-" + id).path))
        #expect(fixture.storage.calls == 0)
    }

    @Test func corruptStructuralRestoreStopsBeforeRuntimeAndRetainsEvidence() throws {
        let fixture = try LockHandoffRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        let imports = try OrbitSecureDirectory.open(fixture.url.appendingPathComponent("Import"), create: true)
        let bytes = Data("invented invalid restore evidence".utf8)
        try imports.write(bytes, to: ArcImportRestore.journalName)
        var started = false
        #expect(throws: ArcImportError.restoreJournalUnreadable) { try fixture.run(lease) { started = true } }
        #expect(!started && fixture.storage.calls == 0)
        #expect(imports.read(ArcImportRestore.journalName) == bytes)
        let writer = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: true)
        writer.release()
    }

    @Test func readonlyHandoffCheckRefusesEvidenceIntroducedDuringConversion() throws {
        let fixture = try LockHandoffRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        let structural = try RecoveryImportLock(root: lease.root)
        try structural.allowSessionReaders()
        let location = try lease.root.sessionLocation()
        let imports = try OrbitSecureDirectory.open(location.importDirectory, create: true)
        let bytes = Data("invented new restore evidence".utf8)
        try imports.write(bytes, to: ArcImportRestore.journalName)
        #expect(throws: ArcImportError.restoreInterrupted) {
            try OrbitAuthenticationStartupGate.validateRegisteredRuntime(lease: lease, product: .daily,
                registration: nil, recovery: nil, location: location, now: 1000)
        }
        #expect(imports.read(ArcImportRestore.journalName) == bytes)
        #expect(fixture.storage.calls == 0)
        withExtendedLifetime(structural) {}
    }

    @Test func thrownRuntimeReleasesSharedOwnershipWithoutReleasingItsInstanceLease() throws {
        let fixture = try LockHandoffRoot()
        let lease = try OrbitRecoveryRootLock(root: fixture.url)
        #expect(throws: OrbitRecoveryFailure.injected) {
            try fixture.run(lease) { throw OrbitRecoveryFailure.injected }
        }
        let writer = try OrbitDataDirectoryLock.acquire(fixture.url, exclusive: true)
        writer.release()
        #expect(throws: OrbitRecoveryFailure.busy) { try OrbitRecoveryRootLock(root: fixture.url) }
        #expect(fixture.storage.calls == 0)
    }
}
