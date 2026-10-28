import CryptoKit
import Darwin
import Foundation
import Testing
@testable import BrowserCore

private struct ModeReviewKey: OrbitRecoveryKeyProvider {
    let key = SymmetricKey(size: .bits256)
    func loadRecoveryKey(transaction: UUID) throws -> SymmetricKey { key }
}

private final class ModeReviewFixture {
    let home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("orbit-mode-exact-review-" + UUID().uuidString)
    let profile = "Chromium/profile-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    let provider = ModeReviewKey()
    var root: URL { home.appendingPathComponent("root") }
    func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for path in ["", "Chromium", profile, profile + "/Nested", "History", "Import"] {
            try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try put(Data("orbit-auth-recovery-synthetic-v1\n".utf8), OrbitAuthenticationRecovery.syntheticMarker)
        for path in [profile + "/Nested/data", "session.json", "History/db", "Import/map", "Chromium/Local State"] {
            try put(Data(("original:" + path).utf8), path)
        }
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func put(_ bytes: Data, _ path: String) throws {
        try bytes.write(to: url(path))
        #expect(chmod(url(path).path, 0o600) == 0)
    }
    func bytes(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
    func mode(_ path: String) throws -> mode_t {
        var value = stat()
        #expect(lstat(url(path).path, &value) == 0)
        return value.st_mode & 0o7777
    }
    func backup(_ lease: OrbitRecoveryRootLock) throws -> OrbitAuthenticationRecovery {
        try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider, profilePath: profile, deadline: 4000)
    }
    func interrupt() throws {
        let lease = try OrbitRecoveryRootLock(root: root)
        let recovery = try backup(lease)
        #expect(throws: OrbitRecoveryFailure.injected) {
            try recovery.withSyntheticMutation(now: 1000) {
                try put(Data("current-data".utf8), profile + "/Nested/data")
                try put(Data("current-session".utf8), "session.json")
                throw OrbitRecoveryFailure.injected
            }
        }
    }
}

@Suite("Exact special-mode policy independent re-check", .serialized)
struct OrbitAuthenticationRecoveryModesExactReviewTests {
    @Test(arguments: [0o1000, 0o2000, 0o3000, 0o4000, 0o5000, 0o6000, 0o7000])
    func everySpecialBitCombinationRefusesBackupWithoutChmod(_ special: Int) throws {
        for isDirectory in [false, true] {
            let f = try ModeReviewFixture()
            let path = f.profile + (isDirectory ? "/Nested" : "/Nested/data")
            let mode = mode_t(special | (isDirectory ? 0o700 : 0o600))
            #expect(chmod(f.url(path).path, mode) == 0)
            #expect(try f.mode(path) == mode)
            let lease = try OrbitRecoveryRootLock(root: f.root)
            #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try f.backup(lease) }
            #expect(try f.mode(path) == mode)
            #expect(try f.bytes(f.profile + "/Nested/data") == Data(("original:" + f.profile + "/Nested/data").utf8))
        }
    }

    @Test(arguments: [0o1000, 0o2000, 0o3000, 0o4000, 0o5000, 0o6000, 0o7000])
    func alreadyOpenedDescriptorsRevalidateFullMode(_ special: Int) throws {
        let f = try ModeReviewFixture()
        let root = try RecoveryDirectory(url: f.root)
        let chromium = try RecoveryDirectory(parent: root, name: "Chromium")
        let profileName = String(f.profile.split(separator: "/").last!)
        let profile = try RecoveryDirectory(parent: chromium, name: profileName)
        let nested = try RecoveryDirectory(parent: profile, name: "Nested")
        let file = try nested.openFile("data")
        defer { close(file) }
        let fileMode = mode_t(special | 0o600)
        #expect(fchmod(file, fileMode) == 0)
        #expect(try f.mode(f.profile + "/Nested/data") == fileMode)
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try nested.validateFile("data", fd: file) }
        #expect(try f.mode(f.profile + "/Nested/data") == fileMode)
        let directoryMode = mode_t(special | 0o700)
        #expect(fchmod(nested.fd, directoryMode) == 0)
        #expect(try f.mode(f.profile + "/Nested") == directoryMode)
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try nested.validate() }
        #expect(try f.mode(f.profile + "/Nested") == directoryMode)
    }

    @Test(arguments: [0o1000, 0o2000, 0o3000, 0o4000, 0o5000, 0o6000, 0o7000])
    func retainedProfileAndLateTargetsRefuseBeforeAnyMutation(_ special: Int) throws {
        for target in ["profile", "nested-file", "last-state"] {
            let f = try ModeReviewFixture()
            try f.interrupt()
            let path = target == "profile" ? f.profile : target == "nested-file" ? f.profile + "/Nested/data" : "Chromium/Local State"
            let mode = mode_t(special | (target == "profile" ? 0o700 : 0o600))
            #expect(chmod(f.url(path).path, mode) == 0)
            #expect(try f.mode(path) == mode)
            let evidencePaths = [OrbitAuthenticationRecovery.marker, OrbitAuthenticationRecovery.directory + "/journal", OrbitAuthenticationRecovery.directory + "/manifest"]
            let evidence = try evidencePaths.map { try f.bytes($0) }
            var profileStat = stat()
            #expect(lstat(f.url(f.profile).path, &profileStat) == 0)
            let lease = try OrbitRecoveryRootLock(root: f.root)
            var boundaries = 0
            var starts = 0
            #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) {
                try OrbitAuthenticationStartupGate.run(lease: lease, provider: f.provider, now: 1000,
                    failpoint: { _ in boundaries += 1 }, runtimeStart: { starts += 1 })
            }
            #expect(boundaries == 0 && starts == 0)
            #expect(try f.mode(path) == mode)
            #expect(try f.bytes(f.profile + "/Nested/data") == Data("current-data".utf8))
            #expect(try f.bytes("session.json") == Data("current-session".utf8))
            #expect(try evidencePaths.map { try f.bytes($0) } == evidence)
            var retainedStat = stat()
            #expect(lstat(f.url(f.profile).path, &retainedStat) == 0)
            #expect(retainedStat.st_dev == profileStat.st_dev && retainedStat.st_ino == profileStat.st_ino)
        }
    }

    @Test func rootKeepsItsDistinctNonWritablePolicyAndOrdinaryPrivateModesWork() throws {
        let f = try ModeReviewFixture()
        #expect(chmod(f.root.path, 0o1700) == 0)
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            let recovery = try f.backup(lease)
            #expect(try f.mode(f.profile) == 0o700)
            #expect(try f.mode(f.profile + "/Nested/data") == 0o600)
            #expect(throws: OrbitRecoveryFailure.injected) {
                try recovery.withSyntheticMutation(now: 1000) { throw OrbitRecoveryFailure.injected }
            }
        }
        let lease = try OrbitRecoveryRootLock(root: f.root)
        var starts = 0
        try OrbitAuthenticationStartupGate.run(lease: lease, provider: f.provider, now: 1000) { starts += 1 }
        #expect(starts == 1)
        var s = stat()
        #expect(lstat(f.root.path, &s) == 0 && s.st_mode & 0o7777 == 0o1700)
        #expect(chmod(f.root.path, 0o1722) == 0)
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try lease.validate() }
    }
}
