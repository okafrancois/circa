import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import BrowserCore

/// All persistence in this suite is disposable memory. No system SecItem adapter is created.
private final class FakeRecoverySecItems: OrbitRecoverySecItemBoundary {
    var rows: [[String: Any]] = []
    var queries: [[String: Any]] = []
    var additions = 0
    var deletions = 0
    var readStatus: OSStatus?
    var addStatus: OSStatus?
    var afterAdd: (() -> Void)?
    var addResultTransform: ((Data) -> Any?)?
    var readTransform: (([[String: Any]]) -> Any)?
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        queries.append(query)
        if let readStatus { return (readStatus, nil) }
        let found = rows.filter { row in
            row[kSecAttrService as String] as? String == query[kSecAttrService as String] as? String &&
            row[kSecAttrAccount as String] as? String == query[kSecAttrAccount as String] as? String
        }
        return found.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, readTransform?(found) ?? found)
    }
    func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        additions += 1
        if let addStatus { return (addStatus, nil) }
        let reference = Data(UUID().uuidString.utf8)
        var row = attributes
        row[kSecValuePersistentRef as String] = reference
        rows.append(row)
        afterAdd?()
        return (errSecSuccess, addResultTransform?(reference) ?? reference)
    }
}

private final class NativeKeyRecoveryFixture {
    let root: URL
    let backend = FakeRecoverySecItems()
    let registration = UUID()
    let profile = "Chromium/profile-11111111-1111-1111-1111-111111111111"
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("orbit-native-key-synthetic-" + UUID().uuidString)
        for path in ["", "Chromium", profile] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try write("orbit-auth-recovery-synthetic-v1\n", OrbitAuthenticationRecovery.syntheticMarker)
        try write("invented-cookie-store", profile + "/Cookies")
        try write("invented-original-session", "session.json")
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func provider(registration: UUID? = nil, product: OrbitNativeRecoveryKeyProvider.Product = .daily) -> OrbitNativeRecoveryKeyProvider {
        OrbitNativeRecoveryKeyProvider(product: product, registration: registration ?? self.registration, backend: backend)
    }
    func write(_ text: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try Data(text.utf8).write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw OrbitRecoveryFailure.io }
    }
    func backup(_ lease: OrbitRecoveryRootLock, _ provider: OrbitNativeRecoveryKeyProvider,
                failpoint: @escaping (OrbitAuthenticationRecovery.Boundary) throws -> Void = { _ in }) throws -> OrbitAuthenticationRecovery {
        try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider, profilePath: profile,
                                                           deadline: 2000, failpoint: failpoint)
    }
    func transaction() throws -> UUID {
        let data = try Data(contentsOf: root.appendingPathComponent(OrbitAuthenticationRecovery.marker))
        return try JSONDecoder().decode(OrbitAuthenticationRecovery.Intent.self, from: data).transaction
    }
}

@Suite("Native independent recovery key admission with disposable SecItem storage", .serialized)
struct OrbitNativeRecoveryKeyProviderTests {
    @Test func missingLoadAndCleanStartupNeverProvisionOrQueryStorage() throws {
        let f = try NativeKeyRecoveryFixture(); let p = f.provider()
        let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0
        try OrbitAuthenticationStartupGate.run(lease: lease, provider: p, now: 1000) { starts += 1 }
        #expect(starts == 1 && f.backend.queries.isEmpty && f.backend.additions == 0)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.unavailable) { try p.loadRecoveryKey(transaction: UUID()) }
        #expect(f.backend.additions == 0 && f.backend.deletions == 0)
    }

    @Test func invalidAddReceiptCannotOwnOrDeleteAnItem() throws {
        let f = try NativeKeyRecoveryFixture(); let p = f.provider(); let transaction = UUID()
        f.backend.addResultTransform = { _ in "invalid-receipt" }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: transaction) }
        #expect(f.backend.rows.count == 1 && f.backend.deletions == 0)
    }

    @Test func releaseHasNoImplicitCleanupAndRetentionRechecksPersistedMaterial() throws {
        let f = try NativeKeyRecoveryFixture(); let transaction = UUID()
        do { let p = f.provider(); try p.prepareRecoveryKey(transaction: transaction) }
        #expect(f.backend.rows.count == 1 && f.backend.deletions == 0)
        let p = f.provider(); try p.prepareRecoveryKey(transaction: transaction)
        var bytes = f.backend.rows[0][kSecValueData as String] as! Data
        bytes[bytes.count - 1] ^= 1; f.backend.rows[0][kSecValueData as String] = bytes
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.retainRecoveryKeyForEvidence(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.conflict) { try p.loadRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.conflict) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(f.backend.additions == 1 && f.backend.deletions == 0)
    }

    @Test func restartLoadsIndependentKeyWithoutSourceAuthority() throws {
        let f = try NativeKeyRecoveryFixture(); let transaction = UUID()
        var source: SymmetricKey? = SymmetricKey(size: .bits256)
        var provider: OrbitNativeRecoveryKeyProvider? = f.provider()
        try provider!.prepareRecoveryKey(transaction: transaction)
        let recovery = try provider!.loadRecoveryKey(transaction: transaction)
        let independent = source!.withUnsafeBytes { sourceBytes in recovery.withUnsafeBytes { Data($0) != Data(sourceBytes) } }
        #expect(independent)
        let ciphertext = try AES.GCM.seal(Data("invented-state".utf8), using: recovery)
        source = nil; provider = nil
        let restarted = f.provider()
        let reloaded = try restarted.loadRecoveryKey(transaction: transaction)
        let restored = try AES.GCM.open(ciphertext, using: reloaded) == Data("invented-state".utf8)
        #expect(restored); #expect(f.backend.additions == 1)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try restarted.cancelPreparedKey(transaction: transaction) }
    }

    @Test func exactNamespaceQueriesNeverConsultSafeStorageOrAlterAccess() throws {
        let f = try NativeKeyRecoveryFixture(); let p = f.provider(); let transaction = UUID()
        try p.prepareRecoveryKey(transaction: transaction)
        _ = try p.loadRecoveryKey(transaction: transaction)
        for query in f.backend.queries {
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "Orbit Authentication Recovery v1")
            #expect(query[kSecAttrAccount as String] as? String == "v1/\(f.registration.uuidString.lowercased())/\(transaction.uuidString.lowercased())")
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecAttrAccess as String] == nil)
            #expect(query[kSecAttrAccessGroup as String] == nil)
            #expect(query[kSecUseAuthenticationUI as String] == nil)
            #expect(query[kSecValueData as String] == nil)
        }
        #expect(f.backend.deletions == 0)
    }

    @Test(arguments: [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable])
    func permissionAndReadRefusalsNeverCreate(_ status: OSStatus) throws {
        let f = try NativeKeyRecoveryFixture(); f.backend.readStatus = status
        let p = f.provider(); let transaction = UUID()
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.unavailable) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.unavailable) { try p.loadRecoveryKey(transaction: transaction) }
        #expect(f.backend.rows.isEmpty && f.backend.additions == 0 && f.backend.deletions == 0)
    }

    @Test(arguments: [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable])
    func writeRefusalStopsBeforeIntent(_ status: OSStatus) throws {
        let f = try NativeKeyRecoveryFixture(); f.backend.addStatus = status
        let lease = try OrbitRecoveryRootLock(root: f.root)
        #expect(throws: (any Error).self) { try f.backup(lease, f.provider()) }
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) == nil)
        #expect(try lease.root.info(OrbitAuthenticationRecovery.directory) == nil)
        #expect(f.backend.rows.isEmpty && f.backend.deletions == 0)
    }

    @Test(arguments: ["refusal", "missing", "value", "reference", "metadata", "ambiguous"])
    func failedReadbackRetainsOnlyOwnedCandidateAndPublishesNothing(_ kind: String) throws {
        let f = try NativeKeyRecoveryFixture(); let p = f.provider()
        f.backend.afterAdd = {
            switch kind {
            case "refusal": f.backend.readStatus = errSecUserCanceled
            case "missing": f.backend.readStatus = errSecItemNotFound
            case "value":
                var bytes = f.backend.rows[0][kSecValueData as String] as! Data
                bytes[bytes.count - 1] ^= 1; f.backend.rows[0][kSecValueData as String] = bytes
            case "reference": f.backend.rows[0][kSecValuePersistentRef as String] = Data("different-reference".utf8)
            case "metadata": f.backend.rows[0][kSecAttrGeneric as String] = Data()
            default: f.backend.rows.append(f.backend.rows[0])
            }
        }
        let lease = try OrbitRecoveryRootLock(root: f.root)
        #expect(throws: (any Error).self) { try f.backup(lease, p) }
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) == nil)
        #expect(try lease.root.info(OrbitAuthenticationRecovery.directory) == nil)
        #expect(f.backend.deletions == 0)
    }

    @Test func duplicateRaceDoesNotReplaceOrAdoptWinnerSilently() throws {
        let f = try NativeKeyRecoveryFixture(); let transaction = UUID()
        let winner = f.provider(); try winner.prepareRecoveryKey(transaction: transaction)
        let original = f.backend.rows[0][kSecValueData as String] as! Data
        // A read racing before the winner became visible, followed by duplicate-on-add.
        f.backend.readStatus = errSecItemNotFound; f.backend.addStatus = errSecDuplicateItem
        let loser = f.provider()
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.conflict) { try loser.prepareRecoveryKey(transaction: transaction) }
        f.backend.readStatus = nil; f.backend.addStatus = nil
        let unchanged = f.backend.rows[0][kSecValueData as String] as? Data == original
        #expect(unchanged); #expect(f.backend.rows.count == 1)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try loser.cancelPreparedKey(transaction: transaction) }
        try loser.prepareRecoveryKey(transaction: transaction) // explicit retry, existing item is read-only/adopted
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try loser.cancelPreparedKey(transaction: transaction) }
        #expect(f.backend.deletions == 0)
    }

    @Test func existingItemAndRepeatedPrepareNeverRotateKey() throws {
        let f = try NativeKeyRecoveryFixture(); let p = f.provider(); let transaction = UUID()
        try p.prepareRecoveryKey(transaction: transaction)
        let original = try p.loadRecoveryKey(transaction: transaction)
        try p.prepareRecoveryKey(transaction: transaction); try f.provider().prepareRecoveryKey(transaction: transaction)
        let current = try p.loadRecoveryKey(transaction: transaction)
        let same = original.withUnsafeBytes { a in current.withUnsafeBytes { Data($0) == Data(a) } }
        #expect(same); #expect(f.backend.additions == 1)
    }

    @Test(arguments: ["service", "account", "registration", "transaction", "owner", "length", "extra", "sync", "shape"])
    func malformedOrWrongIdentityItemsFailClosed(_ kind: String) throws {
        let f = try NativeKeyRecoveryFixture(); let transaction = UUID(); let p = f.provider()
        try p.prepareRecoveryKey(transaction: transaction)
        f.backend.readTransform = { rows in
            var row = rows[0]
            switch kind {
            case "service": row[kSecAttrService as String] = "Orbit Safe Storage"
            case "account": row[kSecAttrAccount as String] = "Orbit"
            case "registration", "transaction", "owner":
                var metadata = row[kSecAttrGeneric as String] as! Data
                let index = kind == "owner" ? metadata.count - 1 : (kind == "registration" ? 28 : 66)
                metadata[index] = 33; row[kSecAttrGeneric as String] = metadata
            case "length": row[kSecValueData as String] = Data(repeating: 0, count: 31)
            case "extra": row[kSecValueData as String] = (row[kSecValueData as String] as! Data) + Data([0])
            case "sync": row[kSecAttrSynchronizable as String] = true
            default: return row
            }
            return [row]
        }
        #expect(throws: (any Error).self) { try f.provider().loadRecoveryKey(transaction: transaction) }
        #expect(throws: (any Error).self) { try f.provider().prepareRecoveryKey(transaction: transaction) }
        #expect(f.backend.additions == 1 && f.backend.deletions == 0)
    }

    @Test func dailyLiveRegistrationAndTransactionAreSeparate() throws {
        let f = try NativeKeyRecoveryFixture(); let transaction = UUID()
        try f.provider().prepareRecoveryKey(transaction: transaction)
        for provider in [f.provider(product: .live), f.provider(registration: UUID())] {
            #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.unavailable) { try provider.loadRecoveryKey(transaction: transaction) }
        }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.unavailable) { try f.provider().loadRecoveryKey(transaction: UUID()) }
        #expect(f.backend.additions == 1)
    }

    @Test func cancellationReleasesOnlyExplicitlyOwnedPreIntentAdmissionAndRetainsStorage() throws {
        let f = try NativeKeyRecoveryFixture(); let p = f.provider(); let transaction = UUID(); let other = UUID()
        try p.prepareRecoveryKey(transaction: transaction); try p.prepareRecoveryKey(transaction: other)
        let unrelated: [String: Any] = [kSecAttrService as String: "unrelated", kSecAttrAccount as String: "unrelated"]
        f.backend.rows.append(unrelated)
        try p.cancelPreparedKey(transaction: transaction)
        #expect(f.backend.rows.count == 3 && f.backend.deletions == 0)
        #expect(try p.loadRecoveryKey(transaction: transaction).bitCount == 256)
        #expect(try p.loadRecoveryKey(transaction: other).bitCount == 256)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: transaction) }
    }

    @Test func anotherProviderCanRetainKeyWhileCreatorCancelsWithoutDestroyingIt() throws {
        let f = try NativeKeyRecoveryFixture(); let p = f.provider(); let transaction = UUID()
        try p.prepareRecoveryKey(transaction: transaction)
        let other = f.provider()
        try other.prepareRecoveryKey(transaction: transaction)
        try other.retainRecoveryKeyForEvidence(transaction: transaction)
        try p.cancelPreparedKey(transaction: transaction)
        #expect(try other.loadRecoveryKey(transaction: transaction).bitCount == 256)
        #expect(f.backend.rows.count == 1 && f.backend.deletions == 0)
    }

    @Test func failedReadbackCancellationReleasesMemoryWithoutStorageAccessOrDeletion() throws {
        let f = try NativeKeyRecoveryFixture(); let p = f.provider(); let transaction = UUID()
        f.backend.afterAdd = { f.backend.readStatus = errSecUserCanceled }
        #expect(throws: (any Error).self) { try p.prepareRecoveryKey(transaction: transaction) }
        let reads = f.backend.queries.count
        try p.cancelPreparedKey(transaction: transaction)
        #expect(f.backend.queries.count == reads)
        #expect(f.backend.deletions == 0)
        f.backend.readStatus = nil
        #expect(try f.provider().loadRecoveryKey(transaction: transaction).bitCount == 256)
        #expect(f.backend.rows.count == 1)
    }

    @Test func intentPublicationFailureRetainsKeyAndBlocksRuntime() throws {
        let f = try NativeKeyRecoveryFixture(); let p = f.provider()
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            #expect(throws: OrbitRecoveryFailure.injected) {
                try f.backup(lease, p) { if $0 == .intent { throw OrbitRecoveryFailure.injected } }
            }
        }
        let account = try #require(f.backend.rows.first?[kSecAttrAccount as String] as? String)
        let transaction = try #require(UUID(uuidString: String(account.suffix(36))))
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: transaction) }
        let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationStartupGate.run(lease: lease, provider: f.provider(), now: 1000) { starts += 1 }
        }
        #expect(starts == 0 && f.backend.rows.count == 1 && f.backend.deletions == 0)
    }

    @Test func actualRecoveryRestartAndRollbackRetainEvidenceKey() throws {
        let f = try NativeKeyRecoveryFixture(); var sourceKey: SymmetricKey? = SymmetricKey(size: .bits256)
        #expect(sourceKey != nil)
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root); let p = f.provider(); let recovery = try f.backup(lease, p)
            #expect(throws: OrbitRecoveryFailure.injected) {
                try recovery.withSyntheticMutation(now: 1000) { try f.write("changed", "session.json"); throw OrbitRecoveryFailure.injected }
            }
            #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: f.transaction()) }
        }
        sourceKey = nil
        let lease = try OrbitRecoveryRootLock(root: f.root); let p = f.provider(); var starts = 0
        try OrbitAuthenticationStartupGate.run(lease: lease, provider: p, now: 1000) { starts += 1 }
        #expect(starts == 1)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("session.json")) == Data("invented-original-session".utf8))
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: f.transaction()) }
        #expect(f.backend.rows.count == 1 && f.backend.deletions == 0)
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) != nil)
    }

    @Test(arguments: ["missing", "wrong-key", "namespace", "pending", "no-provider"])
    func startupFailuresCannotReachRuntime(_ kind: String) throws {
        let f = try NativeKeyRecoveryFixture()
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root); let recovery = try f.backup(lease, f.provider())
            if kind == "pending" { try recovery.withSyntheticMutation(now: 1000) {} }
        }
        if kind == "missing" { f.backend.rows.removeAll() }
        if kind == "wrong-key" {
            var value = f.backend.rows[0][kSecValueData as String] as! Data
            value[value.count - 1] ^= 1; f.backend.rows[0][kSecValueData as String] = value
        }
        let p: (any OrbitRecoveryKeyProvider)? = kind == "no-provider" ? nil : f.provider(registration: kind == "namespace" ? UUID() : nil)
        let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0
        #expect(throws: (any Error).self) {
            try OrbitAuthenticationStartupGate.run(lease: lease, provider: p, now: 1000) { starts += 1 }
        }
        #expect(starts == 0 && f.backend.additions == 1 && f.backend.deletions == 0)
    }

    @Test func secretBytesAreAbsentFromRecoveryFilesAndDiagnostics() throws {
        let f = try NativeKeyRecoveryFixture()
        do { let lease = try OrbitRecoveryRootLock(root: f.root); _ = try f.backup(lease, f.provider()) }
        let value = try #require(f.backend.rows[0][kSecValueData as String] as? Data)
        let raw = Data(value.suffix(32))
        let enumerator = try #require(FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let bytes = try Data(contentsOf: url)
            let leaked = bytes.range(of: raw) != nil || bytes.range(of: Data(raw.base64EncodedString().utf8)) != nil
            #expect(!leaked)
        }
        for failure in [OrbitNativeRecoveryKeyProvider.Failure.unavailable, .invalidItem, .conflict, .lifecycle] {
            let diagnostic = String(describing: failure)
            let leaked = Data(diagnostic.utf8).range(of: raw) != nil || diagnostic.contains(raw.base64EncodedString())
            #expect(!leaked)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("key").path))
    }
}
