import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Site permission storage")
struct BrowserSitePermissionTests {
    private func temporaryURL() -> URL {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("Orbit-SITE-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("permissions.json")
    }

    @Test("Origins normalize scheme host and default port but retain nondefault ports")
    func canonicalOrigin() throws {
        #expect(BrowserSiteOrigin(requestOrigin: "HTTPS://EXAMPLE.test:443")?.value == "https://example.test")
        #expect(BrowserSiteOrigin(requestOrigin: "http://example.test:80/")?.value == "http://example.test")
        #expect(BrowserSiteOrigin(requestOrigin: "https://example.test:8443")?.value == "https://example.test:8443")
        #expect(BrowserSiteOrigin(requestOrigin: "https://[::1]:443")?.value == "https://[::1]")
        #expect(BrowserSiteOrigin(url: URL(string: "https://example.test/path?private=secret")!)?.value == "https://example.test")
    }

    @Test("Invalid request origins and opaque schemes cannot acquire a stored permission",
          arguments: ["data:text/plain,test", "file:///tmp/test", "about:blank", "https://user:pass@example.test", "https://example.test/path", "https://example.test?query", "https://example.test#fragment", "https://example.test:0"])
    func invalidOrigin(raw: String) {
        #expect(BrowserSiteOrigin(requestOrigin: raw) == nil)
    }

    @Test("Settings persist across reopen with independent profiles schemes hosts ports and permission kinds")
    func roundTripAndIsolation() async throws {
        let destination = temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let first = ProfileID(), second = ProfileID()
        let origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        let store = try BrowserSitePermissionStore(destination: destination)
        try await store.set(.allow, for: [.camera], origin: origin, profileID: first)
        try await store.set(.block, for: [.microphone], origin: origin, profileID: first)
        let reopened = try BrowserSitePermissionStore(destination: destination)
        #expect(await reopened.setting(for: .camera, origin: origin, profileID: first) == .allow)
        #expect(await reopened.setting(for: .microphone, origin: origin, profileID: first) == .block)
        #expect(await reopened.setting(for: .camera, origin: origin, profileID: second) == .ask)
        for value in ["http://example.test", "https://sub.example.test", "https://example.test:8443"] {
            #expect(await reopened.setting(for: .camera, origin: BrowserSiteOrigin(requestOrigin: value)!, profileID: first) == .ask)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let contents = try String(contentsOf: destination, encoding: .utf8)
        #expect(!contents.contains("private=secret"))
    }

    @Test("Reset targets one site and profile clearing leaves other profiles unchanged")
    func resetAndClear() async throws {
        let store = try BrowserSitePermissionStore()
        let first = ProfileID(), second = ProfileID()
        let one = BrowserSiteOrigin(requestOrigin: "https://one.test")!
        let two = BrowserSiteOrigin(requestOrigin: "https://two.test")!
        for profile in [first, second] {
            for origin in [one, two] { try await store.set(.allow, for: [.camera, .microphone], origin: origin, profileID: profile) }
        }
        try await store.reset(origin: one, profileID: first)
        #expect(await store.setting(for: .camera, origin: one, profileID: first) == .ask)
        #expect(await store.setting(for: .camera, origin: two, profileID: first) == .allow)
        try await store.clear(profileID: first)
        #expect(await store.setting(for: .camera, origin: two, profileID: first) == .ask)
        #expect(await store.setting(for: .microphone, origin: one, profileID: second) == .allow)
    }

    @Test("Persistent screen-sharing grants are rejected without partial combined changes")
    func screenSharingRequiresPicker() async throws {
        let store = try BrowserSitePermissionStore()
        let profile = ProfileID(), origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        await #expect(throws: BrowserPermissionStoreError.invalidPersistentGrant) {
            try await store.set(.allow, for: [.camera, .screenSharing], origin: origin, profileID: profile)
        }
        #expect(await store.setting(for: .camera, origin: origin, profileID: profile) == .ask)
    }

    @Test("Failed durable publication preserves prior decisions")
    func failedSave() async throws {
        let destination = temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let store = try BrowserSitePermissionStore(destination: destination)
        let profile = ProfileID(), origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        try await store.set(.block, for: [.camera], origin: origin, profileID: profile)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await store.set(.allow, for: [.camera], origin: origin, profileID: profile)
        }
        #expect(await store.setting(for: .camera, origin: origin, profileID: profile) == .block)
    }

    @Test("Corrupt and future documents are never silently replaced")
    func invalidDocuments() throws {
        let destination = temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        for raw in ["not json", "{\"version\":99,\"entries\":[]}"] {
            try Data(raw.utf8).write(to: destination)
            #expect(throws: (any Error).self) { try BrowserSitePermissionStore(destination: destination) }
            #expect(try String(contentsOf: destination, encoding: .utf8) == raw)
        }
    }

    @Test("Symbolic links are refused for reads and writes")
    func symbolicLinks() async throws {
        let destination = temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = destination.deletingLastPathComponent().appendingPathComponent("target.json")
        try Data("private".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        #expect(throws: (any Error).self) { try BrowserSitePermissionStore(destination: destination) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "private")
    }

    @Test("An unavailable store is read-only and never grants even when a prompt requests always allow")
    func unavailableStore() async throws {
        let store = BrowserSitePermissionStore.unavailable()
        let profile = ProfileID(), origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        let state = await store.state(origin: origin, profileID: profile)
        #expect(!state.isDurable)
        #expect(try await !store.commit(.alwaysAllow, for: [.camera], origin: origin, profileID: profile, expectedRevision: state.revision))
        await #expect(throws: BrowserPermissionStoreError.unavailable) {
            try await store.set(.allow, for: [.camera], origin: origin, profileID: profile)
        }
    }

    @Test("Failed restrictive changes remain effective in memory and invalidate older prompts")
    func volatileRestrictions() async throws {
        let destination = temporaryURL()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let store = try BrowserSitePermissionStore(destination: destination)
        let profile = ProfileID(), origin = BrowserSiteOrigin(requestOrigin: "https://example.test")!
        try await store.set(.allow, for: [.camera], origin: origin, profileID: profile)
        let state = await store.state(origin: origin, profileID: profile)
        try await store.set(.block, for: [.cookies], origin: origin, profileID: profile)
        let oldBytes = try Data(contentsOf: destination)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await store.set(.block, for: [.camera], origin: origin, profileID: profile)
        }
        #expect(await store.setting(for: .camera, origin: origin, profileID: profile) == .block)
        #expect(try await !store.commit(.alwaysAllow, for: [.camera], origin: origin, profileID: profile, expectedRevision: state.revision))
        await #expect(throws: (any Error).self) { try await store.reset(origin: origin, profileID: profile) }
        #expect(await store.setting(for: .camera, origin: origin, profileID: profile) == .block)
        #expect(await store.setting(for: .cookies, origin: origin, profileID: profile) == .block)
        try FileManager.default.removeItem(at: destination)
        try oldBytes.write(to: destination)
        let reopened = try BrowserSitePermissionStore(destination: destination)
        #expect(await reopened.setting(for: .camera, origin: origin, profileID: profile) == .allow)
        try await store.set(.block, for: [.camera], origin: origin, profileID: profile)
        let repaired = try BrowserSitePermissionStore(destination: destination)
        #expect(await repaired.setting(for: .camera, origin: origin, profileID: profile) == .block)
    }

    @Test("An ephemeral store never creates its destination")
    func ephemeral() async throws {
        let store = try BrowserSitePermissionStore()
        #expect(await store.setting(for: .sound, origin: BrowserSiteOrigin(requestOrigin: "https://example.test")!, profileID: ProfileID()) == .allow)
    }
}
