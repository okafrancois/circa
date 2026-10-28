import AppKit
import Darwin
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Local sharing and notification permissions")
@MainActor
struct ShareNotificationTests {
    @Test("Copy Link supplies plain text for text editors and a URL for native services")
    func linkPasteboard() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let url = URL(string: "https://example.test/page?value=1#section")!
        #expect(BrowserLinkPasteboard.write(url, to: board))
        #expect(board.string(forType: .string) == url.absoluteString)
        #expect(board.string(forType: .URL) == url.absoluteString)
    }
    @Test("Notification decisions survive a store reload and stay scoped to profile and origin")
    func persistedNotifications() async throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let directory = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("permissions.json")
        let origin = BrowserSiteOrigin(requestOrigin: "http://127.0.0.1:48731")!
        let profile = ProfileID()
        let request = BrowserPermissionRequest(kind: .notifications, origin: origin.value, isMainFrame: true)
        let policy = BrowserSitePermissionPolicy(store: try BrowserSitePermissionStore(destination: file))
        #expect(await policy.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in .block } == .deny)
        let restored = BrowserSitePermissionPolicy(store: try BrowserSitePermissionStore(destination: file))
        var prompts = 0
        #expect(await restored.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in prompts += 1; return .alwaysAllow } == .deny)
        #expect(prompts == 0)
        #expect(await restored.resolve(request, profileID: ProfileID(), isCurrent: { true }) { _, _ in prompts += 1; return .alwaysAllow } == .grant)
        #expect(prompts == 1)
        let other = BrowserPermissionRequest(kind: .notifications, origin: "http://localhost:48731", isMainFrame: true)
        #expect(await restored.resolve(other, profileID: profile, isCurrent: { true }) { _, _ in prompts += 1; return .dismiss } == .deny)
        #expect(prompts == 2)
        try await restored.store.reset(origin: origin, profileID: profile)
        #expect(await restored.resolve(request, profileID: profile, isCurrent: { true }) { _, _ in .alwaysAllow } == .grant)
        let granted = try BrowserSitePermissionStore(destination: file)
        #expect(await granted.setting(for: .notifications, origin: origin, profileID: profile) == .allow)
    }

    @Test("Page sharing appears only for a document menu")
    func pageSharing() {
        let request = BrowserContextMenuRequest(location: .zero, pageURL: URL(string: "https://example.test"), documentGeneration: 1)
        let groups = BrowserPageContextMenuModel.groups(for: request, context: .init())
        #expect(groups.flatMap { $0 }.contains { $0.command == .pageShare })
    }
}
}
