import CryptoKit
import Foundation

/// Separate recovery authority for the fresh-profile import lane. These UUIDs identify one exact
/// non-synchronizing recovery item, independently of source and destination Safe Storage.
public enum BrowserAuthenticationRunKey {
    private struct Identity: Codable { let registration: UUID; let transaction: UUID }
    public static func prepare(dataRoot: URL, product: OrbitNativeRecoveryKeyProvider.Product,
                               backend: any OrbitRecoverySecItemBoundary, userConsented: Bool) throws -> SymmetricKey {
        guard userConsented else { throw BrowserAuthenticationImportError.consentRequired }
        let directory = try OrbitSecureDirectory.open(dataRoot, create: false).directory("AuthenticationImport", create: true)
        guard !directory.exists("run.sealed"), !directory.exists("key.json") else { throw BrowserAuthenticationImportError.invalidState }
        let identity = Identity(registration: UUID(), transaction: UUID())
        let provider = OrbitNativeRecoveryKeyProvider(product: product, registration: identity.registration, backend: backend)
        try provider.prepareRecoveryKey(transaction: identity.transaction)
        try provider.retainRecoveryKeyForEvidence(transaction: identity.transaction)
        try directory.write(JSONEncoder().encode(identity), to: "key.json")
        return try provider.loadRecoveryKey(transaction: identity.transaction)
    }
    public static func load(dataRoot: URL, product: OrbitNativeRecoveryKeyProvider.Product,
                            backend: any OrbitRecoverySecItemBoundary, archiveID: UUID? = nil) throws -> SymmetricKey {
        let directory = try OrbitSecureDirectory.open(dataRoot, create: false).directory(archiveID.map { "AuthenticationImportHistory/" + $0.uuidString } ?? "AuthenticationImport", create: false)
        guard let bytes = directory.read("key.json", limit: 4096) else { throw BrowserAuthenticationImportError.invalidState }
        let identity = try JSONDecoder().decode(Identity.self, from: bytes)
        return try OrbitNativeRecoveryKeyProvider(product: product, registration: identity.registration, backend: backend)
            .loadRecoveryKey(transaction: identity.transaction)
    }
}
