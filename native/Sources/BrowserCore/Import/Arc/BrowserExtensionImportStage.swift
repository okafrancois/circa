import Darwin
import Foundation

/// A narrow registration payload consumed through Chromium's preference service before normal
/// startup. The service computes its own target integrity data; no source hashes or keys migrate.
public struct BrowserExtensionImportStage: Sendable {
    public let profileID: ProfileID
    public let json: String
    private let file: URL
    private let dataRoot: URL
    public static func registrationFailed(dataRoot: URL) throws {
        try BrowserImportRecovery.open(at: dataRoot)?.runtimeApplying()
    }
    public static func pending(dataRoot: URL) throws -> [Self] {
        let root = try OrbitSecureDirectory.open(dataRoot, create: false)
        guard root.exists("Chromium") else { return [] }
        let engine = try root.directory("Chromium", create: false)
        return try engine.checkedEntries().sorted().compactMap { name in
            guard name.hasPrefix("profile-"), let id = UUID(uuidString: String(name.dropFirst(8))),
                  engine.kind(name) == S_IFDIR else { return nil }
            let profile = try engine.directory(name, create: false)
            guard profile.exists("OrbitExtensionImport.json") else { return nil }
            guard let bytes = profile.read("OrbitExtensionImport.json", limit: 64 * 1024 * 1024),
                  let json = String(data: bytes, encoding: .utf8) else { throw ArcImportError.backupInvalid }
            return Self(profileID: ProfileID(id), json: json, file: profile.url.appendingPathComponent("OrbitExtensionImport.json"), dataRoot: dataRoot)
        }
    }
    /// Preference writes are asynchronous. Do not shut Chromium down while its initial
    /// integrity records are still being calculated and published by the preference service.
    public func isPersisted() -> Bool { persistedPreferences() != nil }
    private func persistedPreferences() -> Data? {
        guard let data = try? Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent("Secure Preferences")),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requested = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let wanted = (requested["extensions"] as? [String: Any])?["settings"] as? [String: Any],
              let actual = (document["extensions"] as? [String: Any])?["settings"] as? [String: Any],
              let macs = (document["protection"] as? [String: Any])?["macs"] as? [String: Any],
              let hashes = (macs["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { return nil }
        return wanted.keys.allSatisfy { actual[$0] != nil && hashes[$0] != nil } ? data : nil
    }
    public func retainRegistration() throws {
        guard let data = persistedPreferences() else { throw ArcImportError.backupInvalid }
        let profile = try OrbitSecureDirectory.open(file.deletingLastPathComponent(), create: false)
        try profile.write(data, to: "OrbitExtensionRegisteredPreferences.json")
    }
    /// Called only after CefShutdown has flushed target preference integrity records.
    public func complete() throws {
        let profile = try OrbitSecureDirectory.open(file.deletingLastPathComponent(), create: false)
        guard let registered = profile.read("OrbitExtensionRegisteredPreferences.json", limit: 64 * 1024 * 1024) else { throw ArcImportError.backupInvalid }
        try profile.write(registered, to: "Secure Preferences")
        // Publish the final undo state before removing the last retry marker. A crash between
        // these operations can replay registration; it cannot strand a runtime-ready journal.
        if try Self.pending(dataRoot: dataRoot).count == 1, let recovery = try BrowserImportRecovery.open(at: dataRoot), !recovery.isAuthentication {
            try recovery.complete()
        }
        try profile.removeChecked("OrbitExtensionRegisteredPreferences.json")
        try profile.removeChecked("OrbitExtensionImport.json")
    }
}
