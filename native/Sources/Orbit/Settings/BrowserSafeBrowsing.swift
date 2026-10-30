import BrowserCore
import BrowserShell
import Combine
import Foundation
import Security

/// API credentials are device-local, independent of profile preferences and sync.
protocol BrowserSafeBrowsingKeyStorage: AnyObject {
    func read() throws -> String?
    func write(_ key: String?) throws
}

enum BrowserSafeBrowsingError: Error { case storageUnavailable, invalidKey }

final class BrowserSafeBrowsingMockKeychain: BrowserSafeBrowsingKeyStorage {
    private var key: String?
    func read() throws -> String? { key }
    func write(_ key: String?) throws { self.key = key }
}

final class BrowserSafeBrowsingKeychain: BrowserSafeBrowsingKeyStorage {
    private let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Circa Safe Browsing", kSecAttrAccount as String: "Google API key"]
    func read() throws -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw BrowserSafeBrowsingError.storageUnavailable }
        return key
    }
    func write(_ key: String?) throws {
        guard let key else {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw BrowserSafeBrowsingError.storageUnavailable }
            return
        }
        let value = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(identity as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity.merging(value) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BrowserSafeBrowsingError.storageUnavailable }
    }
}

/// Deliberately has no Codable or debug representation containing the credential.
struct BrowserSafeBrowsingLaunch: CustomStringConvertible, CustomDebugStringConvertible {
    private let key: String?
    var enabled: Bool { key != nil }
    var description: String { enabled ? "Safe Browsing configured" : "Safe Browsing disabled" }
    var debugDescription: String { description }
    init(enabled: Bool, storage: any BrowserSafeBrowsingKeyStorage) throws {
        key = enabled ? Self.normalized(try storage.read()) : nil
    }
    static func normalized(_ key: String?) -> String? {
        guard let value = key?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.utf8.count <= 512, value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else { return nil }
        return value
    }
    /// Always removes an inherited key. Only the user's explicit opt-in may configure Chromium.
    func applyEnvironment(set: (String, String?) -> Void = { name, value in
        if let value { setenv(name, value, 1) } else { unsetenv(name) }
    }) {
        set("GOOGLE_API_KEY", key)
    }
}

@MainActor
final class BrowserSafeBrowsing: ObservableObject {
    /// Tests and preview builds start with memory-only storage. Product admission replaces it.
    static var shared = BrowserSafeBrowsing(storage: BrowserSafeBrowsingMockKeychain())
    let storage: any BrowserSafeBrowsingKeyStorage
    @Published private(set) var hasKey = false
    @Published private(set) var keyChanged = false
    private(set) var enabledAtLaunch = false
    init(storage: any BrowserSafeBrowsingKeyStorage) { self.storage = storage }
    func prepare(enabled: Bool) throws -> BrowserSafeBrowsingLaunch {
        let launch = try BrowserSafeBrowsingLaunch(enabled: enabled, storage: storage)
        enabledAtLaunch = launch.enabled
        return launch
    }
    func refreshKeyState() throws { hasKey = BrowserSafeBrowsingLaunch.normalized(try storage.read()) != nil }
    func saveKey(_ text: String) throws {
        guard let key = BrowserSafeBrowsingLaunch.normalized(text) else { throw BrowserSafeBrowsingError.invalidKey }
        try storage.write(key)
        hasKey = true
        keyChanged = true
    }
    func removeKey() throws {
        try storage.write(nil)
        hasKey = false
        keyChanged = true
    }
    static var requirement: String { uiText("Requires your own Google API key. Google receives Safe Browsing requests. Stored in Keychain on this Mac. Applies to all profiles. Restart Circa to apply changes.") }
    static func state(enabled: Bool, hasKey: Bool, configuredAtLaunch: Bool = false) -> String {
        if configuredAtLaunch && !enabled { return uiText("Restart Circa to turn Safe Browsing off. It is still configured for this session.") }
        if configuredAtLaunch && !hasKey { return uiText("No API key set. Restart Circa to turn Safe Browsing off for the next session.") }
        if !enabled { return uiText("Off. Circa does not warn about dangerous sites or downloads.") }
        return hasKey ? uiText("Key saved. Restart Circa to apply. Protection requires a valid key with Safe Browsing access.")
            : uiText("No API key set. Protection stays off until you save a key and restart Circa.")
    }
}
