import CryptoKit
import Darwin
import Foundation
import Testing
@testable import BrowserCore

// Independent synthetic fixtures. The randomly provisioned key is outside every backed-up tree.
private struct ReviewRecoveryKey: OrbitRecoveryKeyProvider {
    let file: URL
    func loadRecoveryKey(transaction: UUID) throws -> SymmetricKey {
        let data = try Data(contentsOf: file)
        guard data.count == 32 else { throw OrbitRecoveryFailure.keyUnavailable }
        return SymmetricKey(data: data)
    }
}

private final class ReviewRecoveryFixture {
    let home: URL
    let root: URL
    let profile = "Chromium/profile-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    let other = "Chromium/profile-bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    let provider: ReviewRecoveryKey
    init() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("orbit-independent-recovery-" + UUID().uuidString)
        root = home.appendingPathComponent("root")
        provider = ReviewRecoveryKey(file: home.appendingPathComponent("provisioned-key"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for path in ["", "Chromium", profile, profile + "/Nested", other, "History", "Import"] {
            try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try SymmetricKey(size: .bits256).withUnsafeBytes { try Data($0).write(to: provider.file) }
        #expect(chmod(provider.file.path, 0o600) == 0)
        try put(Data("orbit-auth-recovery-synthetic-v1\n".utf8), OrbitAuthenticationRecovery.syntheticMarker)
        try put(Data("original-cookie-fixture".utf8), profile + "/Cookies")
        try put(Data(repeating: 19, count: OrbitAuthenticationRecovery.chunkSize + 17), profile + "/Nested/payload")
        try put(Data("unrelated-original".utf8), other + "/Cookies")
        for path in ["session.json", "Import/mapping", "History/history.sqlite", "History/history.sqlite-wal", "Chromium/Local State"] {
            try put(Data(("original:" + path).utf8), path)
        }
    }
    deinit { try? FileManager.default.removeItem(at: home) }
    func url(_ path: String) -> URL { path.isEmpty ? root : root.appendingPathComponent(path) }
    func put(_ data: Data, _ path: String) throws {
        try data.write(to: url(path)); #expect(chmod(url(path).path, 0o600) == 0)
    }
    func bytes(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
    func backup(_ lease: OrbitRecoveryRootLock) throws -> OrbitAuthenticationRecovery {
        try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider, profilePath: profile, deadline: 4000)
    }
    func interruptApply(_ mutation: () throws -> Void = {}) throws {
        let lease = try OrbitRecoveryRootLock(root: root)
        let transaction = try backup(lease)
        #expect(throws: OrbitRecoveryFailure.injected) {
            try transaction.withSyntheticMutation(now: 1000) {
                try put(Data("current-cookie-fixture".utf8), profile + "/Cookies")
                try put(Data("current-session-fixture".utf8), "session.json")
                try mutation()
                throw OrbitRecoveryFailure.injected
            }
        }
    }
    func gate(_ lease: OrbitRecoveryRootLock, failpoint: @escaping (OrbitAuthenticationRecovery.Boundary) throws -> Void = { _ in }, start: () -> Void = {}) throws {
        try OrbitAuthenticationStartupGate.run(lease: lease, provider: provider, now: 1000, failpoint: failpoint, runtimeStart: start)
    }
    // Reauthenticate malformed records with the independently provisioned fixture key. This
    // distinguishes format/preflight checks from a test that merely breaks an AEAD tag.
    func editManifest(_ edit: (inout [[String: Any]]) -> Void) throws {
        let intent = try bytes(OrbitAuthenticationRecovery.marker)
        let key = try provider.loadRecoveryKey(transaction: UUID())
        func open(_ name: String, _ domain: String) throws -> Data {
            try AES.GCM.open(AES.GCM.SealedBox(combined: bytes(OrbitAuthenticationRecovery.directory + "/" + name)), using: key,
                             authenticating: intent + Data(("\n" + domain).utf8))
        }
        func seal(_ value: Data, _ domain: String) throws -> Data {
            try AES.GCM.seal(value, using: key, authenticating: intent + Data(("\n" + domain).utf8)).combined!
        }
        var entries = try JSONSerialization.jsonObject(with: open("manifest", "manifest-v1")) as! [[String: Any]]
        edit(&entries)
        let manifest = try seal(JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]), "manifest-v1")
        try put(manifest, OrbitAuthenticationRecovery.directory + "/manifest")
        var journal = try JSONSerialization.jsonObject(with: open("journal", "journal-v1")) as! [String: Any]
        journal["manifestHash"] = Data(SHA256.hash(data: manifest)).base64EncodedString()
        try put(seal(JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]), "journal-v1"), OrbitAuthenticationRecovery.directory + "/journal")
    }
}

@Suite("Independent recovery falsification", .serialized)
struct OrbitAuthenticationRecoveryIndependentReviewTests {
    @Test(arguments: ["duplicate", "missing-required", "unsafe-path", "parent-is-file", "size-binding", "metadata-binding", "unknown-kind"])
    func authenticatedMalformedManifestCannotClearTargets(_ variant: String) throws {
        let f = try ReviewRecoveryFixture(); try f.interruptApply()
        try f.editManifest { entries in
            let file = entries.firstIndex { $0["path"] as? String == f.profile + "/Cookies" }!
            switch variant {
            case "duplicate": entries.append(entries[file])
            case "missing-required": entries.removeAll { $0["path"] as? String == "session.json" }
            case "unsafe-path": entries[file]["path"] = f.profile + "/../outside"
            case "parent-is-file": entries[file]["path"] = f.profile + "/Cookies/descendant"
            case "size-binding": entries[file]["size"] = 2
            case "metadata-binding": entries[file]["modifiedNanos"] = 999
            default: entries[file]["kind"] = "future-kind"
            }
        }
        let lease = try OrbitRecoveryRootLock(root: f.root); var mutations = 0; var starts = 0
        #expect(throws: (any Error).self) { try f.gate(lease, failpoint: { _ in mutations += 1 }, start: { starts += 1 }) }
        #expect(starts == 0 && mutations == 0)
        #expect(try f.bytes(f.profile + "/Cookies") == Data("current-cookie-fixture".utf8))
        #expect(try f.bytes("session.json") == Data("current-session-fixture".utf8))
    }

    @Test(arguments: ["late-chunk", "last-current-type", "wrong-key", "unavailable-key", "extra-evidence"])
    func completePreflightBeforeFirstMutation(_ variant: String) throws {
        let f = try ReviewRecoveryFixture(); try f.interruptApply()
        switch variant {
        case "late-chunk":
            let work = f.url(OrbitAuthenticationRecovery.directory)
            let chunk = try FileManager.default.contentsOfDirectory(atPath: work.path).filter { $0.hasPrefix("chunk-") }.sorted().last!
            var bytes = try f.bytes(OrbitAuthenticationRecovery.directory + "/" + chunk); bytes[bytes.count - 1] ^= 1
            try f.put(bytes, OrbitAuthenticationRecovery.directory + "/" + chunk)
        case "last-current-type":
            try FileManager.default.removeItem(at: f.url("Chromium/Local State"))
            #expect(symlink("../session.json", f.url("Chromium/Local State").path) == 0)
        case "wrong-key": try Data(repeating: 7, count: 32).write(to: f.provider.file)
        case "unavailable-key": try FileManager.default.removeItem(at: f.provider.file)
        default: try f.put(Data("unexpected".utf8), OrbitAuthenticationRecovery.directory + "/extra")
        }
        let lease = try OrbitRecoveryRootLock(root: f.root); var boundaries = 0; var starts = 0
        #expect(throws: (any Error).self) { try f.gate(lease, failpoint: { _ in boundaries += 1 }, start: { starts += 1 }) }
        #expect(boundaries == 0 && starts == 0)
        #expect(try f.bytes(f.profile + "/Cookies") == Data("current-cookie-fixture".utf8))
        #expect(try f.bytes("session.json") == Data("current-session-fixture".utf8))
    }

    @Test(arguments: ["cross-transaction-chunk", "journal-as-manifest", "manifest-as-journal"])
    func authenticatedDomainsAndTransactionsAreNotInterchangeable(_ variant: String) throws {
        let f = try ReviewRecoveryFixture()
        let g = try ReviewRecoveryFixture()
        // Independent authority may provision one key for multiple transactions. Copying it
        // outside both backed-up roots isolates intent/domain binding from wrong-key refusal.
        try Data(contentsOf: f.provider.file).write(to: g.provider.file)
        try f.interruptApply(); try g.interruptApply()
        let work = OrbitAuthenticationRecovery.directory + "/"
        if variant == "cross-transaction-chunk" {
            let name = try FileManager.default.contentsOfDirectory(atPath: f.url(OrbitAuthenticationRecovery.directory).path)
                .filter { $0.hasPrefix("chunk-") }.sorted().first!
            try g.put(f.bytes(work + name), work + name)
        } else if variant == "journal-as-manifest" {
            try g.put(g.bytes(work + "journal"), work + "manifest")
        } else { try g.put(g.bytes(work + "manifest"), work + "journal") }
        let lease = try OrbitRecoveryRootLock(root: g.root); var boundaries = 0; var starts = 0
        #expect(throws: (any Error).self) { try g.gate(lease, failpoint: { _ in boundaries += 1 }, start: { starts += 1 }) }
        #expect(boundaries == 0 && starts == 0)
        #expect(try g.bytes("session.json") == Data("current-session-fixture".utf8))
    }

    @Test func replayPreservesAllOwnershipInodesAndUnrelatedProfile() throws {
        let f = try ReviewRecoveryFixture(); try f.interruptApply {
            try f.put(Data("unrelated-after-backup".utf8), f.other + "/Cookies")
            try f.put(Data("created-after-backup".utf8), "profile-mapping.json")
        }
        let lease = try OrbitRecoveryRootLock(root: f.root)
        let paths = ["", "Chromium", f.profile, ".orbit-instance.lock", OrbitAuthenticationRecovery.directory, OrbitAuthenticationRecovery.directory + "/lock"]
        func identities() throws -> [UInt64] {
            try paths.map { path in var s = stat(); guard lstat(f.url(path).path, &s) == 0 else { throw OrbitRecoveryFailure.io }; return UInt64(s.st_ino) }
        }
        let originalIDs = try identities(); var starts = 0; var writes = 0
        #expect(throws: OrbitRecoveryFailure.injected) {
            try f.gate(lease, failpoint: { boundary in
                if boundary == .restoreChunk { writes += 1; if writes == 2 { throw OrbitRecoveryFailure.injected } }
            }, start: { starts += 1 })
        }
        #expect(starts == 0 && writes == 2)
        try f.gate(lease, start: { starts += 1 })
        #expect(starts == 1)
        #expect(try identities() == originalIDs)
        #expect(try f.bytes(f.profile + "/Cookies") == Data("original-cookie-fixture".utf8))
        #expect(try f.bytes(f.other + "/Cookies") == Data("unrelated-after-backup".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.url("profile-mapping.json").path))
        #expect(throws: OrbitRecoveryFailure.busy) { try OrbitRecoveryRootLock(root: f.root) }
        // The structural lease ends before ordinary runtime, while the instance lease stays live.
        let structural = try OrbitDataDirectoryLock.acquire(f.root, exclusive: true, validatingPath: false)
        structural.release()
        #expect(FileManager.default.fileExists(atPath: f.url(OrbitAuthenticationRecovery.marker).path))
    }

    @Test func physicalComponentsRejectArbitraryAliasButAdmitSystemVar() throws {
        let f = try ReviewRecoveryFixture()
        let alias = f.home.appendingPathComponent("alias")
        #expect(symlink(f.root.path, alias.path) == 0)
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try OrbitRecoveryRootLock(root: alias) }
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try OrbitRecoveryRootLock(root: alias.appendingPathComponent("Chromium")) }
        if f.root.path.hasPrefix("/private/var/") {
            let systemAlias = URL(fileURLWithPath: String(f.root.path.dropFirst("/private".count)))
            let lease = try OrbitRecoveryRootLock(root: systemAlias)
            try OrbitAuthenticationStartupGate.run(lease: lease) {}
        }
    }

    // These are correctness assertions, deliberately left red for PM repair of the reviewed
    // source. Do not weaken them into acceptance of the reproduced behavior.
    @Test(arguments: ["file-setuid", "directory-sticky"])
    func unsupportedSpecialModeBitsMustRefuseBackup(_ variant: String) throws {
        let f = try ReviewRecoveryFixture()
        let path = variant == "file-setuid" ? f.profile + "/Cookies" : f.profile + "/Nested"
        let mode: mode_t = variant == "file-setuid" ? 0o4600 : 0o1700
        #expect(chmod(f.url(path).path, mode) == 0)
        var s = stat(); #expect(lstat(f.url(path).path, &s) == 0 && s.st_mode & 0o7777 == mode)
        let lease = try OrbitRecoveryRootLock(root: f.root)
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try f.backup(lease) }
    }

    @Test func stableProfileModeMustBeRestoredOrRefusedBeforeMutation() throws {
        let f = try ReviewRecoveryFixture(); try f.interruptApply { #expect(chmod(f.url(f.profile).path, 0o1700) == 0) }
        let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0; var clears = 0
        do {
            try f.gate(lease, failpoint: { if $0 == .restoreCleared { clears += 1 } }, start: { starts += 1 })
            #expect(starts == 1)
            var s = stat(); #expect(lstat(f.url(f.profile).path, &s) == 0)
            #expect(s.st_mode & 0o7777 == 0o700)
        } catch OrbitRecoveryFailure.unsafeFilesystem {
            #expect(starts == 0 && clears == 0)
            #expect(try f.bytes(f.profile + "/Cookies") == Data("current-cookie-fixture".utf8))
        }
    }

    @Test func supportedStableProfileMetadataIsRestoredExactly() throws {
        let f = try ReviewRecoveryFixture()
        let original = Data("original-directory-attribute".utf8)
        #expect(original.withUnsafeBytes { setxattr(f.url(f.profile).path, "lab.orbit.review", $0.baseAddress, original.count, 0, 0) } == 0)
        let anchor = try RecoveryDirectory(url: f.url(f.profile))
        let originalAttributes = try RecoveryDirectory.attributes(anchor.fd)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 2468, tv_nsec: 987654321)]
        #expect(utimensat(AT_FDCWD, f.url(f.profile).path, &times, AT_SYMLINK_NOFOLLOW) == 0)
        try f.interruptApply {
            #expect(removexattr(f.url(f.profile).path, "lab.orbit.review", 0) == 0)
            let extra = Data("extra-directory-attribute".utf8)
            #expect(extra.withUnsafeBytes { setxattr(f.url(f.profile).path, "lab.orbit.review.extra", $0.baseAddress, extra.count, 0, 0) } == 0)
        }
        let lease = try OrbitRecoveryRootLock(root: f.root)
        try f.gate(lease)
        let directory = try RecoveryDirectory(url: f.url(f.profile))
        #expect(try RecoveryDirectory.attributes(directory.fd) == originalAttributes)
        var s = stat(); #expect(fstat(directory.fd, &s) == 0)
        #expect(s.st_mtimespec.tv_sec == 2468 && s.st_mtimespec.tv_nsec == 987654321)
    }

    // Current metadata outside the documented size policy is a retained failure, not an
    // accepted exact restore. Characterize it separately from the mode-admission defect.
    @Test func unsupportedStableProfileMetadataRetainsEvidenceAndRefusesRuntime() throws {
        let f = try ReviewRecoveryFixture(); try f.interruptApply {
            let value = Data(repeating: 5, count: 65_537)
            let status = value.withUnsafeBytes { setxattr(f.url(f.profile).path, "lab.orbit.review.oversized", $0.baseAddress, value.count, 0, 0) }
            #expect(status == 0)
        }
        let lease = try OrbitRecoveryRootLock(root: f.root); var clears = 0; var starts = 0
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) {
            try f.gate(lease, failpoint: { if $0 == .restoreCleared { clears += 1 } }, start: { starts += 1 })
        }
        #expect(starts == 0 && clears == 6)
        #expect(try f.bytes(f.profile + "/Cookies") == Data("original-cookie-fixture".utf8))
        #expect(try f.bytes("session.json") == Data("original:session.json".utf8))
        #expect(FileManager.default.fileExists(atPath: f.url(OrbitAuthenticationRecovery.marker).path))
        #expect(FileManager.default.fileExists(atPath: f.url(OrbitAuthenticationRecovery.directory + "/manifest").path))
        #expect(throws: OrbitRecoveryFailure.unsafeFilesystem) { try f.gate(lease, start: { starts += 1 }) }
        #expect(starts == 0)
    }
}
