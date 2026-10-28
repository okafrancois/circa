import CryptoKit
import Foundation
import Security
import Testing
@testable import BrowserCore

/// A disposable SecItem response; no system backend or persistent storage is constructed.
private final class BooleanShapeStorage: OrbitRecoverySecItemBoundary {
    private var row: [String: Any]?
    var responseAttribute: Any? = false

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        guard var row else { return (errSecItemNotFound, nil) }
        row[kSecAttrSynchronizable as String] = responseAttribute
        return (errSecSuccess, [row] as NSArray)
    }

    func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        guard row == nil else { return (errSecDuplicateItem, nil) }
        var stored = attributes
        stored.removeValue(forKey: kSecReturnPersistentRef as String)
        stored[kSecValuePersistentRef as String] = Data([1])
        row = stored
        return (errSecSuccess, Data([1]))
    }
}

@Suite("Recovery key Boolean attribute shape", .serialized)
struct OrbitRecoveryKeyBooleanShapeTests {
    @Test("Numeric zero is not a Boolean false storage attribute")
    func numericAliasesRefuse() throws {
        let storage = BooleanShapeStorage()
        let provider = OrbitNativeRecoveryKeyProvider(product: .daily, registration: UUID(), backend: storage)
        let transaction = UUID()
        try provider.prepareRecoveryKey(transaction: transaction)
        let malformed: [Any] = [NSNumber(value: 0), NSNumber(value: 0.0), NSNumber(value: 1),
                                NSNumber(value: -1), "false", Data(), NSNull()]
        for value in malformed {
            storage.responseAttribute = value
            #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) {
                _ = try provider.loadRecoveryKey(transaction: transaction)
            }
            #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) {
                try provider.prepareRecoveryKey(transaction: transaction)
            }
        }
        storage.responseAttribute = true
        #expect(throws: OrbitNativeRecoveryKeyProvider.Failure.invalidItem) {
            _ = try provider.loadRecoveryKey(transaction: transaction)
        }
        for value: Any? in [false, NSNumber(value: false), nil] {
            storage.responseAttribute = value
            let hasExpectedSize = try provider.loadRecoveryKey(transaction: transaction).bitCount == 256
            #expect(hasExpectedSize)
        }
    }
}
