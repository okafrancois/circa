import BrowserCore
import Foundation
import Security

/// Construct only for the explicit Read Selected Data action. No source key creation, fallback,
/// enumeration or ACL changes. The key is held by the caller only for the duration of the import.
struct ChromiumImportKeychain {
    let boundary: any OrbitRecoverySecItemBoundary
    func readSource(sourceID: String, userConsented: Bool) throws -> Data {
        guard userConsented else { throw BrowserAuthenticationImportError.consentRequired }
        guard let identity = BrowserSafeStorageIdentity.verified(sourceID: sourceID) else {
            throw BrowserAuthenticationImportError.unsupportedSource
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identity.service, kSecAttrAccount as String: identity.account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let (status, value) = boundary.copyMatching(query)
        if [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed].contains(status) {
            throw BrowserAuthenticationImportError.keychainDenied
        }
        if status == errSecItemNotFound { throw BrowserAuthenticationImportError.sourceKeyMissing }
        guard status == errSecSuccess, let data = value as? Data, !data.isEmpty else {
            throw BrowserAuthenticationImportError.keychainFailure
        }
        return data
    }
}
