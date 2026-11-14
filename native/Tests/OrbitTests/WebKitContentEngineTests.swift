import BrowserCore
import BrowserEngine
import Foundation
import Testing
import WebKitEngine

@Suite("WebKit content engine")
@MainActor
struct WebKitContentEngineTests {
    @Test("Safari-compatible user agent suffix follows the installed Safari, with a safe fallback")
    func safariApplicationName() throws {
        let root = URL(fileURLWithPath: "/private/tmp/webkit-ua-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = root.appendingPathComponent("Info.plist")
        try (["CFBundleShortVersionString": "26.3"] as NSDictionary).write(to: info)
        #expect(WebKitBrowserEngine.safariApplicationName(safariInfo: info) == "Version/26.3 Safari/605.1.15")
        try (["CFBundleShortVersionString": "26.3 (beta) <x>"] as NSDictionary).write(to: info)
        #expect(WebKitBrowserEngine.safariApplicationName(safariInfo: info) == "Version/26.0 Safari/605.1.15")
        #expect(WebKitBrowserEngine.safariApplicationName(safariInfo: root.appendingPathComponent("missing.plist"))
            == "Version/26.0 Safari/605.1.15")
    }

    @Test("Persistence is declared by the engine and memory-only stays the default")
    func persistence() {
        let preview = WebKitBrowserEngine()
        #expect(preview.persistence == .ephemeral)
        #expect(!preview.capabilities.contains(.persistentProfiles))
        let profile = ProfileID()
        #expect(preview.websiteDataStore(for: profile).isPersistent == false)
        #expect(preview.profile(for: profile).persistence == .ephemeral)
        // Declared only: creating a persistent store here would write into the test host's container.
        let product = WebKitBrowserEngine(persistence: .persistent)
        #expect(product.capabilities.contains(.persistentProfiles))
        #expect(product.applicationNameForUserAgent == nil)
    }
}
