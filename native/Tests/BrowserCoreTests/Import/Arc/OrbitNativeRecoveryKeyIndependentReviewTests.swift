import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import BrowserCore

/// Independent fault seam. It never constructs or invokes the system adapter.
private final class ReviewRecoveryStorage: OrbitRecoverySecItemBoundary {
    var rows: [[String: Any]] = []
    var reads: [[String: Any]] = []
    var writes: [[String: Any]] = []
    var readFault: ((Int, [[String: Any]]) -> (OSStatus, Any?)?)?
    var addFault: (([String: Any]) -> (OSStatus, Any?)?)?
    var receipt: ((Data) -> Any?)?

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        reads.append(query)
        let matches = rows.filter {
            $0[kSecAttrService as String] as? String == query[kSecAttrService as String] as? String &&
            $0[kSecAttrAccount as String] as? String == query[kSecAttrAccount as String] as? String
        }
        if let fault = readFault?(reads.count, matches) { return fault }
        return matches.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, matches as NSArray)
    }

    func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        writes.append(attributes)
        if let fault = addFault?(attributes) { return fault }
        if rows.contains(where: {
            $0[kSecAttrService as String] as? String == attributes[kSecAttrService as String] as? String &&
            $0[kSecAttrAccount as String] as? String == attributes[kSecAttrAccount as String] as? String
        }) { return (errSecDuplicateItem, nil) }
        let reference = Data(UUID().uuidString.utf8)
        var row = attributes
        row.removeValue(forKey: kSecReturnPersistentRef as String)
        row[kSecValuePersistentRef as String] = reference
        rows.append(row)
        if let receipt { return (errSecSuccess, receipt(reference)) }
        return (errSecSuccess, reference)
    }
}

private final class ReviewRecoveryFixture {
    let root: URL
    let storage = ReviewRecoveryStorage()
    let registration = UUID()
    let profile = "Chromium/profile-22222222-2222-2222-2222-222222222222"

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("orbit-key-independent-synthetic-" + UUID().uuidString)
        for path in ["", "Chromium", profile] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try write("orbit-auth-recovery-synthetic-v1\n", OrbitAuthenticationRecovery.syntheticMarker)
        try write("invented-independent-session", "session.json")
        try write("invented-independent-cookies", profile + "/Cookies")
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func provider(_ product: OrbitNativeRecoveryKeyProvider.Product = .daily) -> OrbitNativeRecoveryKeyProvider {
        OrbitNativeRecoveryKeyProvider(product: product, registration: registration, backend: storage)
    }
    func write(_ value: String, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try Data(value.utf8).write(to: url)
        guard chmod(url.path, 0o600) == 0 else { throw OrbitRecoveryFailure.io }
    }
    func backup(_ lease: OrbitRecoveryRootLock, _ provider: OrbitNativeRecoveryKeyProvider) throws -> OrbitAuthenticationRecovery {
        try OrbitAuthenticationRecovery.beginSyntheticBackup(lease: lease, provider: provider, profilePath: profile, deadline: 2000)
    }
    func storedTransaction() throws -> UUID {
        guard let account = storage.rows.first?[kSecAttrAccount as String] as? String,
              let transaction = UUID(uuidString: String(account.suffix(36))) else { throw OrbitRecoveryFailure.invalidEvidence }
        return transaction
    }
}

@Suite("Independent native recovery key faults; fake storage only", .serialized)
struct OrbitNativeRecoveryKeyIndependentReviewTests {
    @Test(arguments: [OrbitNativeRecoveryKeyProvider.Product.daily, .live])
    func exactReadAndAddKeySetsExcludeImplicitAuthorities(_ product: OrbitNativeRecoveryKeyProvider.Product) throws {
        let f = try ReviewRecoveryFixture(); let p = f.provider(product); let transaction = UUID()
        try p.prepareRecoveryKey(transaction: transaction)
        let namespace = Set([kSecClass, kSecAttrService, kSecAttrAccount, kSecAttrSynchronizable].map { $0 as String })
        let readKeys = namespace.union([kSecMatchLimit, kSecReturnAttributes, kSecReturnData, kSecReturnPersistentRef].map { $0 as String })
        let addKeys = namespace.union([kSecAttrGeneric, kSecValueData, kSecReturnPersistentRef].map { $0 as String })
        let service = product == .daily ? "Orbit Authentication Recovery v1" : "Orbit Live Authentication Recovery v1"
        let account = "v1/\(f.registration.uuidString.lowercased())/\(transaction.uuidString.lowercased())"
        #expect(f.storage.writes.count == 1 && f.storage.reads.count == 2)
        for query in f.storage.reads + f.storage.writes {
            let correctNamespace = query[kSecClass as String] as? String == kSecClassGenericPassword as String &&
                query[kSecAttrService as String] as? String == service &&
                query[kSecAttrAccount as String] as? String == account &&
                query[kSecAttrSynchronizable as String] as? Bool == false
            #expect(correctNamespace)
        }
        for query in f.storage.reads {
            #expect(Set(query.keys) == readKeys)
            let correctReturns = query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String &&
                query[kSecReturnAttributes as String] as? Bool == true &&
                query[kSecReturnData as String] as? Bool == true && query[kSecReturnPersistentRef as String] as? Bool == true
            #expect(correctReturns)
        }
        #expect(Set(f.storage.writes[0].keys) == addKeys)
    }

    @Test(arguments: ["absent", "false"])
    func documentedLocalOnlyShapesAndFoundationBridgingRemainUsable(_ shape: String) throws {
        let f = try ReviewRecoveryFixture(); let transaction = UUID()
        try f.provider().prepareRecoveryKey(transaction: transaction)
        if shape == "absent" { f.storage.rows[0].removeValue(forKey: kSecAttrSynchronizable as String) }
        let p = f.provider(); try p.prepareRecoveryKey(transaction: transaction)
        #expect(try p.loadRecoveryKey(transaction: transaction).bitCount == 256)
        #expect(f.storage.writes.count == 1)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: transaction) }
    }

    @Test(arguments: ["string", "data", "null"])
    func malformedSynchronizableAttributeMustRefuseInsteadOfImplyingLocalOnly(_ shape: String) throws {
        let f = try ReviewRecoveryFixture(); let transaction = UUID()
        try f.provider().prepareRecoveryKey(transaction: transaction)
        switch shape {
        case "string": f.storage.rows[0][kSecAttrSynchronizable as String] = "true"
        case "data": f.storage.rows[0][kSecAttrSynchronizable as String] = Data([1])
        default: f.storage.rows[0][kSecAttrSynchronizable as String] = NSNull()
        }
        let p = f.provider()
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) { _ = try p.loadRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(f.storage.writes.count == 1)
    }

    @Test func malformedReadbackAttributeMustStopBeforePublishingSyntheticIntent() throws {
        let f = try ReviewRecoveryFixture(); let lease = try OrbitRecoveryRootLock(root: f.root)
        f.storage.readFault = { _, matches in
            guard var row = matches.first else { return nil }
            row[kSecAttrSynchronizable as String] = "true"
            return (errSecSuccess, [row])
        }
        #expect(throws: (any Error).self) { _ = try f.backup(lease, f.provider()) }
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) == nil)
        #expect(try lease.root.info(OrbitAuthenticationRecovery.directory) == nil)
    }

    @Test(arguments: [errSecParam, errSecDecode, errSecDuplicateItem])
    func unsuccessfulReadsIgnorePlausiblePayloadAndNeverProvision(_ status: OSStatus) throws {
        let f = try ReviewRecoveryFixture(); let transaction = UUID()
        try f.provider().prepareRecoveryKey(transaction: transaction)
        f.storage.readFault = { _, rows in (status, rows) }
        let p = f.provider()
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.unavailable) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.unavailable) { _ = try p.loadRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: transaction) }
        #expect(f.storage.writes.count == 1)
    }

    @Test(arguments: ["service", "account", "metadata", "value", "reference", "empty-reference", "owner-uppercase", "metadata-value-mismatch", "extra-key-byte", "array-empty", "array-mixed", "dictionary", "nil"])
    func independentMalformedResultsRefuseWithoutWriting(_ shape: String) throws {
        let f = try ReviewRecoveryFixture(); let transaction = UUID()
        try f.provider().prepareRecoveryKey(transaction: transaction)
        f.storage.readFault = { _, matches in
            var row = matches[0]
            switch shape {
            case "service": row[kSecAttrService as String] = Data()
            case "account": row.removeValue(forKey: kSecAttrAccount as String)
            case "metadata": row[kSecAttrGeneric as String] = "invalid"
            case "value": row[kSecValueData as String] = NSNull()
            case "reference": row[kSecValuePersistentRef as String] = "invalid"
            case "empty-reference": row[kSecValuePersistentRef as String] = Data()
            case "owner-uppercase":
                let metadata = row[kSecAttrGeneric as String] as! Data
                let modified = Data(metadata.dropLast(36)) + Data("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA".utf8)
                row[kSecAttrGeneric as String] = modified
                row[kSecValueData as String] = modified + (row[kSecValueData as String] as! Data).suffix(32)
            case "metadata-value-mismatch":
                var value = row[kSecValueData as String] as! Data; value[0] ^= 1; row[kSecValueData as String] = value
            case "extra-key-byte": row[kSecValueData as String] = (row[kSecValueData as String] as! Data) + Data([0])
            case "array-empty": return (errSecSuccess, [] as [Any])
            case "array-mixed": return (errSecSuccess, [row, "invalid"] as [Any])
            case "dictionary": return (errSecSuccess, row)
            default: return (errSecSuccess, nil)
            }
            return (errSecSuccess, [row])
        }
        let p = f.provider()
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) { _ = try p.loadRecoveryKey(transaction: transaction) }
        #expect(f.storage.writes.count == 1)
    }

    @Test(arguments: ["nil", "empty", "dictionary", "array"])
    func invalidSuccessfulAddReceiptRetainsStorageButCannotClaimOwnership(_ shape: String) throws {
        let f = try ReviewRecoveryFixture(); let p = f.provider(); let transaction = UUID()
        f.storage.receipt = { _ in
            switch shape {
            case "nil": return nil
            case "empty": return Data()
            case "dictionary": return ["invalid": "receipt"]
            default: return [Data([1])]
            }
        }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: transaction) }
        #expect(f.storage.rows.count == 1 && f.storage.reads.count == 1)
        f.storage.receipt = nil
        try f.provider().prepareRecoveryKey(transaction: transaction)
        #expect(f.storage.writes.count == 1)
    }

    @Test(arguments: [3, 4])
    func loadOrRetainReadRefusalPrecedesIntentAndAllowsOnlyMemoryCancellation(_ read: Int) throws {
        let f = try ReviewRecoveryFixture(); let p = f.provider(); let lease = try OrbitRecoveryRootLock(root: f.root)
        f.storage.readFault = { count, _ in count == read ? (errSecInteractionNotAllowed, nil) : nil }
        #expect(throws: (any Error).self) { _ = try f.backup(lease, p) }
        let transaction = try f.storedTransaction()
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker) == nil)
        #expect(try lease.root.info(OrbitAuthenticationRecovery.marker + ".writing") == nil)
        #expect(try lease.root.info(OrbitAuthenticationRecovery.directory) == nil)
        let reads = f.storage.reads.count
        try p.cancelPreparedKey(transaction: transaction)
        #expect(f.storage.reads.count == reads && f.storage.rows.count == 1 && f.storage.writes.count == 1)
    }

    @Test func failedStrictReadbackCanOnlyBeAdoptedOnLaterExplicitAdmission() throws {
        let f = try ReviewRecoveryFixture(); let p = f.provider(); let transaction = UUID()
        f.storage.readFault = { count, _ in count == 2 ? (errSecNotAvailable, nil) : nil }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.unavailable) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(f.storage.rows.count == 1 && f.storage.reads.count == 2)
        try p.cancelPreparedKey(transaction: transaction)
        let restarted = f.provider(); try restarted.prepareRecoveryKey(transaction: transaction)
        try restarted.retainRecoveryKeyForEvidence(transaction: transaction)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try restarted.cancelPreparedKey(transaction: transaction) }
        #expect(f.storage.writes.count == 1)
    }

    @Test func duplicateFailureHasNoAdmissionUntilExplicitRetry() throws {
        let f = try ReviewRecoveryFixture(); let transaction = UUID()
        try f.provider().prepareRecoveryKey(transaction: transaction)
        let p = f.provider(); let count = f.storage.reads.count
        f.storage.readFault = { index, _ in index == count + 1 ? (errSecItemNotFound, nil) : nil }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.conflict) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(f.storage.reads.count == count + 1 && f.storage.writes.count == 2)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.retainRecoveryKeyForEvidence(transaction: transaction) }
        try p.prepareRecoveryKey(transaction: transaction)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: transaction) }
        #expect(f.storage.rows.count == 1 && f.storage.writes.count == 2)
    }

    @Test(arguments: ["reference", "key", "owner"])
    func preparedInstancePinsMaterialWhileNewInstanceHasOnlyReadOnlyAdoption(_ field: String) throws {
        let f = try ReviewRecoveryFixture(); let p = f.provider(); let transaction = UUID()
        try p.prepareRecoveryKey(transaction: transaction)
        switch field {
        case "reference": f.storage.rows[0][kSecValuePersistentRef as String] = Data("invented-new-reference".utf8)
        case "key":
            var value = f.storage.rows[0][kSecValueData as String] as! Data
            value[value.count - 1] ^= 1; f.storage.rows[0][kSecValueData as String] = value
        default:
            let metadata = f.storage.rows[0][kSecAttrGeneric as String] as! Data
            let modified = Data(metadata.dropLast(36)) + Data(UUID().uuidString.lowercased().utf8)
            f.storage.rows[0][kSecAttrGeneric as String] = modified
            f.storage.rows[0][kSecValueData as String] = modified + (f.storage.rows[0][kSecValueData as String] as! Data).suffix(32)
        }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.conflict) { try p.prepareRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.conflict) { _ = try p.loadRecoveryKey(transaction: transaction) }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.retainRecoveryKeyForEvidence(transaction: transaction) }
        let restarted = f.provider(); try restarted.prepareRecoveryKey(transaction: transaction)
        #expect(try restarted.loadRecoveryKey(transaction: transaction).bitCount == 256)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try restarted.cancelPreparedKey(transaction: transaction) }
        #expect(f.storage.writes.count == 1)
    }

    @Test func writeCreationFailureRetainsKeyBeforeAnyIntentCallback() throws {
        let f = try ReviewRecoveryFixture(); let p = f.provider()
        try f.write("invented-preexisting-interrupted-intent", OrbitAuthenticationRecovery.marker + ".writing")
        do {
            let lease = try OrbitRecoveryRootLock(root: f.root)
            #expect(throws: (any Error).self) { _ = try f.backup(lease, p) }
        }
        let transaction = try f.storedTransaction()
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try p.cancelPreparedKey(transaction: transaction) }
        #expect(f.storage.rows.count == 1 && f.storage.writes.count == 1)
        let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0
        #expect(throws: OrbitRecoveryFailure.invalidEvidence) {
            try OrbitAuthenticationStartupGate.run(lease: lease, provider: f.provider(), now: 1000) { starts += 1 }
        }
        #expect(starts == 0)
    }

    @Test func newProviderCannotAuthenticateChangedKeyOrResumePendingVerification() throws {
        for pending in [false, true] {
            let f = try ReviewRecoveryFixture()
            do {
                let lease = try OrbitRecoveryRootLock(root: f.root); let recovery = try f.backup(lease, f.provider())
                if pending { try recovery.withSyntheticMutation(now: 1000) {} }
            }
            if !pending {
                var value = f.storage.rows[0][kSecValueData as String] as! Data
                value[value.count - 1] ^= 1; f.storage.rows[0][kSecValueData as String] = value
            }
            let lease = try OrbitRecoveryRootLock(root: f.root); var starts = 0
            #expect(throws: (any Error).self) {
                try OrbitAuthenticationStartupGate.run(lease: lease, provider: f.provider(), now: 1000) { starts += 1 }
            }
            #expect(starts == 0 && f.storage.writes.count == 1)
        }
    }

    @Test func cancellationHasNoCrossInstanceDestructiveAuthorityOrStorageCall() throws {
        let f = try ReviewRecoveryFixture(); let creator = f.provider(); let transaction = UUID()
        try creator.prepareRecoveryKey(transaction: transaction)
        let other = f.provider(); try other.prepareRecoveryKey(transaction: transaction)
        try other.retainRecoveryKeyForEvidence(transaction: transaction)
        let key = try other.loadRecoveryKey(transaction: transaction)
        let sealed = try AES.GCM.seal(Data("invented-independent-payload".utf8), using: key)
        let reads = f.storage.reads.count
        try creator.cancelPreparedKey(transaction: transaction)
        #expect(f.storage.reads.count == reads && f.storage.rows.count == 1 && f.storage.writes.count == 1)
        let reloaded = try other.loadRecoveryKey(transaction: transaction)
        let restored = try AES.GCM.open(sealed, using: reloaded) == Data("invented-independent-payload".utf8)
        #expect(restored)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) { try creator.cancelPreparedKey(transaction: transaction) }
    }

    @Test func diagnosticsAndRecoveryFilesExcludeKeyMetadataAndReference() throws {
        let f = try ReviewRecoveryFixture()
        do { let lease = try OrbitRecoveryRootLock(root: f.root); _ = try f.backup(lease, f.provider()) }
        let row = f.storage.rows[0]
        guard let value = row[kSecValueData as String] as? Data,
              let metadata = row[kSecAttrGeneric as String] as? Data,
              let reference = row[kSecValuePersistentRef as String] as? Data else { throw OrbitRecoveryFailure.invalidEvidence }
        let protected = [Data(value.suffix(32)), value, metadata, reference]
        let diagnostics = [OrbitNativeRecoveryKeyProvider.Failure.unavailable, .invalidItem, .conflict, .lifecycle]
            .map { Data(String(describing: $0).utf8) }
        var outputs = diagnostics
        let enumerator = try #require(FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in enumerator where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            outputs.append(try Data(contentsOf: file))
        }
        let leaked = outputs.contains { output in protected.contains { bytes in
            output.range(of: bytes) != nil || output.range(of: Data(bytes.base64EncodedString().utf8)) != nil
        } }
        #expect(!leaked)
    }
}
