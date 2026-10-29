import CryptoKit
import Foundation
import Security
import LocalAuthentication

/// An independent local wrapping key; never Chromium Safe Storage or a cloud credential.
/// Tests inject a random in-memory key and never construct a system Keychain adapter.
public struct BrowserPasswordSyncCache: Sendable {
    public let destination: URL
    private let key: SymmetricKey
    private let aad: Data
    public init(destination: URL, key: SymmetricKey) {
        self.destination = destination; self.key = key
        aad = Data(("OrbitPasswords-cache-v1:" + destination.path).utf8)
    }

    public static func systemKey() throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.okatech.orbit.password-sync-cache",
            kSecAttrAccount as String: "local-wrapping-key-v1", kSecAttrSynchronizable as String: false]
        var lookup = query
        lookup[kSecReturnData as String] = true
        let context = LAContext(); context.interactionNotAllowed = true
        lookup[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, var data = result as? Data, data.count == 32 {
            defer { data.resetBytes(in: 0..<data.count) }
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw BrowserSyncError.unavailable }
        let key = SymmetricKey(size: .bits256)
        var data = key.withUnsafeBytes { Data($0) }
        defer { data.resetBytes(in: 0..<data.count) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BrowserSyncError.unavailable }
        return key
    }
    public func load<T: Decodable>(_ type: T.Type) throws -> T? {
        guard let sealed = try BrowserPermissionFile.load(destination, maximumBytes: 64 * 1024 * 1024) else { return nil }
        var bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return try JSONDecoder().decode(type, from: bytes)
    }
    public func save<T: Encodable>(_ value: T) throws {
        var bytes = try JSONEncoder().encode(value)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard let sealed = try AES.GCM.seal(bytes, using: key, authenticating: aad).combined else { throw BrowserSyncError.unavailable }
        try BrowserPermissionFile.save(sealed, to: destination, maximumBytes: 64 * 1024 * 1024)
    }
}
