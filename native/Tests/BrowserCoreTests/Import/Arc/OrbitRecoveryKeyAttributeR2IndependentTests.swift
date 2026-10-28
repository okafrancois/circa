import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security
import Testing
@testable import BrowserCore

private final class FalseLikeObject: NSObject {
    @objc var boolValue: Bool { false }
    override var description: String { "invented-false-like-object" }
}

private struct FalseLikeValue { let boolValue = false }

/// All rows and references are invented in memory; the system adapter is never constructed.
private final class AttributeReviewStorage: OrbitRecoverySecItemBoundary {
    private let registration = UUID()
    var row: [String: Any]?
    var reads = 0
    var additions = 0
    var responseValue: Any? = false
    var faultAtRead: Int?

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        reads += 1
        guard var result = row else { return (errSecItemNotFound, nil) }
        if faultAtRead == nil || faultAtRead == reads {
            result[kSecAttrSynchronizable as String] = responseValue
        }
        return (errSecSuccess, [result] as NSArray)
    }

    func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        additions += 1
        guard row == nil else { return (errSecDuplicateItem, nil) }
        var stored = attributes
        stored.removeValue(forKey: kSecReturnPersistentRef as String)
        let reference = Data("invented-r2-review-reference".utf8)
        stored[kSecValuePersistentRef as String] = reference
        row = stored
        return (errSecSuccess, reference)
    }

    func provider() -> OrbitNativeRecoveryKeyProvider {
        OrbitNativeRecoveryKeyProvider(product: .daily, registration: registration, backend: self)
    }
}

private let malformedAttributeShapes = [
    "integer-zero", "double-zero", "decimal-zero", "true", "cf-true", "string", "nsstring",
    "data", "nsdata", "null", "array", "dictionary", "custom-object", "custom-value"
]

private func malformedAttribute(_ shape: String) -> Any {
    switch shape {
    case "integer-zero": return NSNumber(value: 0)
    case "double-zero": return NSNumber(value: 0.0)
    case "decimal-zero": return NSDecimalNumber.zero
    case "true": return true
    case "cf-true": return kCFBooleanTrue!
    case "string": return "false"
    case "nsstring": return NSString(string: "NO")
    case "data": return Data([0])
    case "nsdata": return NSData(data: Data([0]))
    case "null": return NSNull()
    case "array": return [false]
    case "dictionary": return ["boolValue": false]
    case "custom-object": return FalseLikeObject()
    default: return FalseLikeValue()
    }
}

@Suite("Independent R2 synchronization attribute recheck; fake backend only", .serialized)
struct OrbitRecoveryKeyAttributeR2IndependentTests {
    @Test(arguments: ["swift-false", "cf-false", "nsnumber-false", "absent"])
    func genuineFalseAndOmissionSupportAllAdmissionReads(_ shape: String) throws {
        let storage = AttributeReviewStorage()
        switch shape {
        case "cf-false": storage.responseValue = kCFBooleanFalse!
        case "nsnumber-false": storage.responseValue = NSNumber(value: false)
        case "absent": storage.responseValue = nil
        default: storage.responseValue = false
        }
        let provider = storage.provider(); let transaction = UUID()
        try provider.prepareRecoveryKey(transaction: transaction)
        try provider.prepareRecoveryKey(transaction: transaction)
        let key = try provider.loadRecoveryKey(transaction: transaction)
        #expect(key.bitCount == 256)
        try provider.retainRecoveryKeyForEvidence(transaction: transaction)
        #expect(storage.additions == 1)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) {
            try provider.cancelPreparedKey(transaction: transaction)
        }
    }

    @Test(arguments: malformedAttributeShapes)
    func malformedPresentValuesRefusePreparedAndUnpreparedAccess(_ shape: String) throws {
        let storage = AttributeReviewStorage(); let provider = storage.provider(); let transaction = UUID()
        try provider.prepareRecoveryKey(transaction: transaction)
        let original = storage.row as NSDictionary?
        storage.responseValue = malformedAttribute(shape)
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) {
            try provider.prepareRecoveryKey(transaction: transaction)
        }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) {
            _ = try provider.loadRecoveryKey(transaction: transaction)
        }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) {
            try provider.retainRecoveryKeyForEvidence(transaction: transaction)
        }
        let fresh = storage.provider()
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) {
            try fresh.prepareRecoveryKey(transaction: transaction)
        }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) {
            _ = try fresh.loadRecoveryKey(transaction: transaction)
        }
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.lifecycle) {
            try fresh.cancelPreparedKey(transaction: transaction)
        }
        let unchanged = original?.isEqual(to: storage.row ?? [:]) == true
        #expect(unchanged && storage.additions == 1)
        let reads = storage.reads
        try provider.cancelPreparedKey(transaction: transaction)
        #expect(storage.reads == reads)
    }

    @Test(arguments: [2, 3, 4], malformedAttributeShapes)
    func malformedReadbackLoadAndRetainCannotPublishSyntheticIntent(_ stage: Int, _ shape: String) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("orbit-r2-attribute-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent(OrbitAuthenticationRecovery.syntheticMarker)
        try Data("orbit-auth-recovery-synthetic-v1\n".utf8).write(to: marker)
        guard chmod(marker.path, 0o600) == 0 else { throw OrbitRecoveryFailure.io }
        let storage = AttributeReviewStorage(); let provider = storage.provider()
        storage.responseValue = malformedAttribute(shape); storage.faultAtRead = stage
        let lease = try OrbitRecoveryRootLock(root: root)
        let expected: any Error = stage == 3 ? OrbitRecoveryFailure.keyUnavailable : OrbitNativeRecoveryKeyProvider.Failure.invalidItem
        do {
            _ = try OrbitAuthenticationRecovery.beginSyntheticBackup(
                lease: lease, provider: provider,
                profilePath: "Chromium/profile-22222222-2222-2222-2222-222222222222", deadline: 2000)
            Issue.record("Malformed synchronization response unexpectedly reached backup")
        } catch {
            let correctFailure = String(describing: error) == String(describing: expected)
            #expect(correctFailure)
        }
        #expect(storage.reads == stage && storage.additions == 1)
        for path in [OrbitAuthenticationRecovery.marker, OrbitAuthenticationRecovery.marker + ".writing", OrbitAuthenticationRecovery.directory] {
            #expect(try lease.root.info(path) == nil)
        }
        guard let account = storage.row?[kSecAttrAccount as String] as? String,
              let transaction = UUID(uuidString: String(account.suffix(36))) else { throw OrbitRecoveryFailure.invalidEvidence }
        let reads = storage.reads
        try provider.cancelPreparedKey(transaction: transaction)
        let hasRetainedRow = storage.row != nil
        #expect(storage.reads == reads && hasRetainedRow)
    }
}
