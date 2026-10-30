import BrowserCore
import Darwin
import Foundation
import Testing
@testable import Orbit

@Suite("Safe Browsing opt-in")
struct SafeBrowsingTests {
    @Test("Safe Browsing defaults off, including older settings")
    func defaults() throws {
        let document = BrowserSettingsDocument()
        #expect(!document.safeBrowsingEnabled)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        json.removeValue(forKey: "safeBrowsingEnabled")
        let restored = try JSONDecoder().decode(BrowserSettingsDocument.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!restored.safeBrowsingEnabled)
    }

    @Test("Only the app-wide opt-in is serialized")
    func persistence() async throws {
        let store = try BrowserSettingsStore()
        try await store.setSafeBrowsingEnabled(true)
        let document = await store.snapshot()
        #expect(document.safeBrowsingEnabled)
        let encoded = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(BrowserSettingsDocument.self, from: encoded).safeBrowsingEnabled)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.localizedCaseInsensitiveContains("apiKey"))
        #expect(!text.localizedCaseInsensitiveContains("credential"))
        try await store.setSafeBrowsingEnabled(false)
        #expect(await !store.snapshot().safeBrowsingEnabled)
    }

    @Test("Read-only startup uses durable settings and rejects future schemas")
    func startupSettings() async throws {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("safe-browsing-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("settings.json")
        #expect(try !BrowserSettingsStore.safeBrowsingEnabledAtLaunch(destination: file))
        let store = try BrowserSettingsStore(destination: file)
        try await store.setSafeBrowsingEnabled(true)
        #expect(try BrowserSettingsStore.safeBrowsingEnabledAtLaunch(destination: file))
        try await store.setSafeBrowsingEnabled(false)
        #expect(try !BrowserSettingsStore.safeBrowsingEnabledAtLaunch(destination: file))
        try Data(#"{"version":999,"safeBrowsingEnabled":true}"#.utf8).write(to: file)
        #expect(throws: BrowserSettingsError.self) { try BrowserSettingsStore.safeBrowsingEnabledAtLaunch(destination: file) }
    }

    @MainActor @Test("Saving and removing credentials use the mock Keychain only")
    func storage() throws {
        let storage = BrowserSafeBrowsingMockKeychain()
        let browsing = BrowserSafeBrowsing(storage: storage)
        #expect(try storage.read() == nil)
        try browsing.saveKey("  synthetic-test-credential  \n")
        #expect(browsing.hasKey)
        #expect(try storage.read() == "synthetic-test-credential")
        try browsing.removeKey()
        #expect(!browsing.hasKey)
        #expect(try storage.read() == nil)
    }

    @Test("Launch requires both opt-in and a nonempty key")
    func launchComposition() throws {
        let storage = BrowserSafeBrowsingMockKeychain()
        for enabled in [false, true] {
            let launch = try BrowserSafeBrowsingLaunch(enabled: enabled, storage: storage)
            #expect(!launch.enabled)
            var calls = 0
            launch.applyEnvironment { name, value in
                #expect(name == "GOOGLE_API_KEY")
                #expect(value == nil)
                calls += 1
            }
            #expect(calls == 1)
        }
        try storage.write("synthetic-test-credential")
        #expect(try !BrowserSafeBrowsingLaunch(enabled: false, storage: storage).enabled)
        let launch = try BrowserSafeBrowsingLaunch(enabled: true, storage: storage)
        #expect(launch.enabled)
        launch.applyEnvironment { name, value in
            #expect(name == "GOOGLE_API_KEY")
            #expect(value == "synthetic-test-credential")
        }
    }

    @Test("Disabled startup never accesses secure storage")
    func disabledStorage() throws {
        final class Refused: BrowserSafeBrowsingKeyStorage {
            func read() throws -> String? { throw BrowserSafeBrowsingError.storageUnavailable }
            func write(_ key: String?) throws { throw BrowserSafeBrowsingError.storageUnavailable }
        }
        #expect(try !BrowserSafeBrowsingLaunch(enabled: false, storage: Refused()).enabled)
        #expect(throws: BrowserSafeBrowsingError.self) { try BrowserSafeBrowsingLaunch(enabled: true, storage: Refused()) }
    }

    @MainActor @Test("Edits cannot change the launch snapshot before restart")
    func restart() throws {
        let storage = BrowserSafeBrowsingMockKeychain()
        let browsing = BrowserSafeBrowsing(storage: storage)
        let initial = try browsing.prepare(enabled: false)
        try browsing.saveKey("synthetic-test-credential")
        #expect(!initial.enabled && !browsing.enabledAtLaunch)
        let next = try browsing.prepare(enabled: true)
        #expect(next.enabled && browsing.enabledAtLaunch)
        try browsing.removeKey()
        #expect(next.enabled && browsing.enabledAtLaunch)
        #expect(try !browsing.prepare(enabled: true).enabled)
    }

    @MainActor @Test("Copy explains ownership, missing key, scope and restart without claiming validity")
    func copy() {
        #expect(BrowserSafeBrowsing.requirement.contains("your own Google API key"))
        #expect(BrowserSafeBrowsing.requirement.contains("all profiles"))
        #expect(BrowserSafeBrowsing.requirement.contains("Restart"))
        #expect(BrowserSafeBrowsing.state(enabled: true, hasKey: false).contains("No API key set"))
        #expect(BrowserSafeBrowsing.state(enabled: true, hasKey: true).contains("valid key"))
        #expect(BrowserSafeBrowsing.state(enabled: false, hasKey: true).hasPrefix("Off."))
        #expect(BrowserSafeBrowsing.state(enabled: false, hasKey: true, configuredAtLaunch: true).contains("still configured"))
        #expect(BrowserSafeBrowsing.state(enabled: true, hasKey: false, configuredAtLaunch: true).contains("No API key set"))
    }

    @Test("Diagnostic representations and settings never include credentials")
    func redaction() throws {
        let storage = BrowserSafeBrowsingMockKeychain()
        let key = "synthetic-test-credential"
        try storage.write(key)
        let launch = try BrowserSafeBrowsingLaunch(enabled: true, storage: storage)
        #expect(!String(describing: launch).contains(key))
        #expect(!String(reflecting: launch).contains(key))
        #expect(!String(decoding: try JSONEncoder().encode(BrowserSettingsDocument()), as: UTF8.self).contains(key))
    }

    @MainActor @Test("Invalid input never replaces a saved credential")
    func invalidKey() throws {
        let storage = BrowserSafeBrowsingMockKeychain()
        let browsing = BrowserSafeBrowsing(storage: storage)
        try browsing.saveKey("synthetic-test-credential")
        for invalid in ["", "  ", "two words", "a\u{0}b", String(repeating: "a", count: 513)] {
            #expect(throws: BrowserSafeBrowsingError.self) { try browsing.saveKey(invalid) }
        }
        #expect(try storage.read() == "synthetic-test-credential")
    }
}
