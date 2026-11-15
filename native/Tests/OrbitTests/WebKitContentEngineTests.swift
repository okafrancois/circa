import BrowserCore
import BrowserEngine
import Foundation
import Testing
import WebKitEngine
@testable import Orbit

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

    @Test("A WebKit document reports connection security the shell's pill and Site Controls read")
    func pageSecurity() throws {
        let secure = try #require(WebKitSurface.securityState(url: URL(string: "https://www.example.test/")!,
                                                              hasOnlySecureContent: true))
        #expect(secure.level == 3 && !secure.certificateError && !secure.displayedMixedContent)
        #expect(BrowserSiteControlsModel.Connection.resolve(url: URL(string: "https://www.example.test/"), security: secure) == .https)
        let mixed = try #require(WebKitSurface.securityState(url: URL(string: "https://www.example.test/")!,
                                                             hasOnlySecureContent: false))
        #expect(BrowserSiteControlsModel.Connection.resolve(url: URL(string: "https://www.example.test/"), security: mixed) == .insecure)
        let plain = try #require(WebKitSurface.securityState(url: URL(string: "http://example.test/")!,
                                                             hasOnlySecureContent: true))
        #expect(BrowserSiteControlsModel.Connection.resolve(url: URL(string: "http://example.test/"), security: plain) == .insecure)
        #expect(WebKitSurface.securityState(url: URL(string: "about:blank")!, hasOnlySecureContent: true) == nil)
        #expect(WebKitSurface.securityState(url: URL(string: "file:///tmp/a.html")!, hasOnlySecureContent: true) == nil)
    }

    @Test("A WebKit tab's address comes from its page services: committed URL and formatted host")
    func addressFromWebKitServices() {
        let url = URL(string: "https://www.netflix.example/browse")!
        let address = BrowserAddressPresentation(url: url, security: BrowserPageSecurityState(level: 3),
                                                 format: { $0.host })
        #expect(address.label == "www.netflix.example")
        #expect(address.value == url.absoluteString)
        #expect(address.connection == .https)
        // Without a formatter (no page services) the label is redacted, which was the reported defect.
        #expect(BrowserAddressPresentation(url: url, security: nil, format: { _ in nil }).label == uiText("Page"))
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
