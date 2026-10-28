import CoreFoundation
import CryptoKit
import Foundation
import Security

/// Optional lifecycle boundary. Existing preprovisioned providers remain load-only.
public protocol OrbitRecoveryKeyAdmissionProvider: OrbitRecoveryKeyProvider {
    func prepareRecoveryKey(transaction: UUID) throws
    /// Called before attempting the first durable intent. Failure thereafter retains the key.
    func retainRecoveryKeyForEvidence(transaction: UUID) throws
}

/// SecItem-shaped seam: constructing the native adapter performs no Keychain operation.
/// Automated tests must inject a disposable fake, never this system implementation.
public protocol OrbitRecoverySecItemBoundary {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> (OSStatus, Any?)
}

public struct OrbitSystemRecoverySecItems: OrbitRecoverySecItemBoundary {
    public init() {}
    public func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    public func add(_ attributes: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemAdd(attributes as CFDictionary, &result)
        return (status, result)
    }
}

/// Independent of both Arc source decryption and Chromium Safe Storage. The registration is
/// an opaque, stable key identity supplied by the root-registration authority; it is not
/// derived from a profile, source key, path or secret.
public final class OrbitNativeRecoveryKeyProvider: OrbitRecoveryKeyAdmissionProvider {
    public enum Product: String, Sendable { case daily, live }
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unavailable, invalidItem, conflict, lifecycle
        public var description: String { "Recovery key unavailable (\(self.code))" }
        private var code: String {
            switch self {
            case .unavailable: "storage"
            case .invalidItem: "identity"
            case .conflict: "conflict"
            case .lifecycle: "lifecycle"
            }
        }
    }
    private struct Item {
        let metadata: Data
        let value: Data
        let reference: Data
    }
    private struct Admission {
        let item: Item
        let owned: Bool
        var retained: Bool
    }
    private let product: Product
    private let registration: UUID
    private let backend: any OrbitRecoverySecItemBoundary
    private let mutex = NSLock()
    private var admissions: [UUID: Admission] = [:]

    /// Explicit injection prevents mock-mode composition from accidentally querying Keychain.
    public init(product: Product, registration: UUID, backend: any OrbitRecoverySecItemBoundary) {
        self.product = product; self.registration = registration; self.backend = backend
    }
    private var service: String {
        product.recoveryService
    }
    private func account(_ transaction: UUID) -> String {
        "v1/\(registration.uuidString.lowercased())/\(transaction.uuidString.lowercased())"
    }
    private func binding(_ transaction: UUID) -> Data {
        Data("orbit-recovery-key-v1/\(product.rawValue)/\(account(transaction))/".utf8)
    }
    private func query(_ transaction: UUID) -> [String: Any] {
        // Exact generic-password namespace only. No access-group, ACL, prompt override,
        // search-list change, synchronizable-any search, update or Safe Storage lookup.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account(transaction),
         kSecAttrSynchronizable as String: false]
    }
    private func read(_ transaction: UUID) throws -> Item? {
        var attributes = query(transaction)
        // All matches within this exact service/account let ambiguity fail closed, including
        // identical names in multiple user keychains. Never enumerate unrelated items.
        attributes[kSecMatchLimit as String] = kSecMatchLimitAll
        attributes[kSecReturnAttributes as String] = true
        attributes[kSecReturnData as String] = true
        attributes[kSecReturnPersistentRef as String] = true
        let (status, result) = backend.copyMatching(attributes)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.unavailable }
        guard let matches = result as? [[String: Any]], matches.count == 1 else { throw Failure.invalidItem }
        let row = matches[0]
        // An omitted attribute is compatible with the explicit local-only query. A present
        // attribute must be an actual false CFBoolean, never an optional-cast failure.
        if let synchronizable = row[kSecAttrSynchronizable as String] {
            guard let boolean = synchronizable as? NSNumber,
                  CFGetTypeID(boolean) == CFBooleanGetTypeID(),
                  !boolean.boolValue else { throw Failure.invalidItem }
        }
        let prefix = binding(transaction)
        guard row[kSecAttrService as String] as? String == service,
              row[kSecAttrAccount as String] as? String == account(transaction),
              let metadata = row[kSecAttrGeneric as String] as? Data,
              metadata.count == prefix.count + 36, metadata.starts(with: prefix),
              let owner = String(data: metadata.suffix(36), encoding: .utf8),
              UUID(uuidString: owner)?.uuidString.lowercased() == owner,
              let value = row[kSecValueData as String] as? Data,
              value.count == metadata.count + 32, value.starts(with: metadata),
              let reference = row[kSecValuePersistentRef as String] as? Data, !reference.isEmpty
        else { throw Failure.invalidItem }
        return Item(metadata: metadata, value: value, reference: reference)
    }
    private func matches(_ lhs: Item, _ rhs: Item) -> Bool {
        // This comparison remains in native memory and is never a public credential digest.
        lhs.metadata == rhs.metadata && lhs.value == rhs.value && lhs.reference == rhs.reference
    }
    public func prepareRecoveryKey(transaction: UUID) throws {
        mutex.lock(); defer { mutex.unlock() }
        if let previous = admissions[transaction] {
            guard let current = try read(transaction), matches(previous.item, current) else { throw Failure.conflict }
            return
        }
        if let existing = try read(transaction) {
            admissions[transaction] = Admission(item: existing, owned: false, retained: true)
            return
        }
        let metadata = binding(transaction) + Data(UUID().uuidString.lowercased().utf8)
        // CryptoKit uses system cryptographic randomness; never a source-key-derived value.
        let value = metadata + SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var attributes = query(transaction)
        attributes[kSecAttrGeneric as String] = metadata
        attributes[kSecValueData as String] = value
        attributes[kSecReturnPersistentRef as String] = true
        let (status, result) = backend.add(attributes)
        // A racing creator owns the transaction key. Do not replace it or silently admit
        // a different candidate. A later explicit prepare can load the established item.
        guard status != errSecDuplicateItem else { throw Failure.conflict }
        guard status == errSecSuccess else { throw Failure.unavailable }
        guard let reference = result as? Data, !reference.isEmpty else { throw Failure.invalidItem }
        let expected = Item(metadata: metadata, value: value, reference: reference)
        // Track explicit add ownership for pre-intent cancellation of this in-memory
        // admission only. No cancellation may delete persistent key material.
        admissions[transaction] = Admission(item: expected, owned: true, retained: false)
        guard let persisted = try read(transaction), matches(expected, persisted) else { throw Failure.conflict }
    }
    public func loadRecoveryKey(transaction: UUID) throws -> SymmetricKey {
        mutex.lock(); defer { mutex.unlock() }
        guard let current = try read(transaction) else { throw Failure.unavailable }
        if let previous = admissions[transaction], !matches(previous.item, current) { throw Failure.conflict }
        return SymmetricKey(data: current.value.suffix(32))
    }
    public func retainRecoveryKeyForEvidence(transaction: UUID) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard var admission = admissions[transaction],
              let current = try read(transaction), matches(admission.item, current) else { throw Failure.lifecycle }
        admission.retained = true; admissions[transaction] = admission
    }
    /// Only pre-intent cancellation of an admission explicitly added by this instance is allowed.
    /// After a publish attempt, restart, or adoption, retain indefinitely: authenticated
    /// rolledBack still keeps its encrypted evidence, and no terminal disposal policy exists.
    /// This releases memory only. Another process/provider may already have admitted the
    /// same item. The storage boundary deliberately exposes no update/delete operation;
    /// an authenticated terminal evidence-disposal authority must precede such an API.
    /// Deinit never deletes; no completion/rollback caller can implicitly release a key.
    public func cancelPreparedKey(transaction: UUID) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard let admission = admissions[transaction], admission.owned, !admission.retained else { throw Failure.lifecycle }
        admissions.removeValue(forKey: transaction)
    }
}
