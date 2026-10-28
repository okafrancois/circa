import BrowserCore
import Foundation
import Security

/// Uses native Keychain authorization. An absent source item never creates an Arc key.
struct ArcSiteSessionKeychain: ArcSiteSessionKeyProviding {
    let targetService: String
    let targetAccount: String

    func sourcePassword() throws -> Data { try password(service: "Arc Safe Storage", account: "Arc", create: false) }
    func targetPassword() throws -> Data { try password(service: targetService, account: targetAccount, create: true) }

    private func password(service: String, account: String, create: Bool) throws -> Data {
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service, kSecAttrAccount as String: account]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, !data.isEmpty { return data }
        guard status == errSecItemNotFound, create else { throw ArcAuthenticationError.sourceKeyUnavailable }
        // Matches Chromium's KeychainPassword: 128 random bits encoded as base64.
        var random = Data(count: 16)
        guard random.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
            throw ArcAuthenticationError.sourceKeyUnavailable
        }
        defer { random.resetBytes(in: 0..<random.count) }
        let password = random.base64EncodedData()
        var item = identity
        item[kSecValueData as String] = password
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return try self.password(service: service, account: account, create: false) }
        guard added == errSecSuccess else { throw ArcAuthenticationError.sourceKeyUnavailable }
        return password
    }
}

/// Chromium source: components/os_crypt/async/browser/keychain_key_provider.mm and
/// crypto/apple/fake_keychain_v2.mm. Only constructed for a confined mock-Keychain launch.
struct ArcSiteSessionFixtureKeys: ArcSiteSessionKeyProviding {
    let dataRoot: URL
    func sourcePassword() throws -> Data {
        try Data(contentsOf: dataRoot.appendingPathComponent("arc-session-source-password"))
    }
    func targetPassword() throws -> Data { Data("mock_password".utf8) }
}
