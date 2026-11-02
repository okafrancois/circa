import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

@MainActor
struct LiveFoldersRuntimeTests {
    final class NoNetworkSession: BrowserGitHubWebSession {
        func pullRequests(profileID: ProfileID, query: String, page: Int) async throws -> BrowserProfileWebResponse {
            Issue.record("Persistence commands must not start provider requests")
            throw BrowserGitHubProviderError.invalidResponse
        }
    }

    @Test func localAccountRestoresAndProfileRemovalCannotRecreateItsFile() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let file = directory.appendingPathComponent("live-folders-\(profile.rawValue.uuidString).json")
        var local = BrowserLiveFolderLocalStore(profileID: profile)
        local.acknowledge(.init(itemID: "synthetic"), fingerprint: "seen")
        let account = BrowserGitHubAccount(id: 123, login: "fixture")
        try BrowserLiveFolderProfileFile(local: local, account: account).save(to: file)
        let runtime = BrowserLiveFoldersRuntime(store: store, session: NoNetworkSession(), directory: directory)
        let connection = try await runtime.connection(profile)
        #expect(connection.account == account)
        #expect(await store.liveFolderLocalStore(for: profile).lastSeenFingerprint(for: .init(itemID: "synthetic")) == "seen")
        try await runtime.removeProfile(profile)
        try await runtime.persist(profile)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await #expect(throws: BrowserStoreError.profileMissing) { try await runtime.connection(profile) }
        await runtime.stop()
    }
    final class FixtureSession: BrowserGitHubWebSession {
        var actor = 123
        func pullRequests(profileID: ProfileID, query: String, page: Int) async throws -> BrowserProfileWebResponse {
            let body = """
            <html><head><meta name="user-login" content="fixture"><meta name="octolytics-actor-id" content="\(actor)"></head><body>
            <script type="application/json" data-target="react-app.embeddedData">{"payload":{"pullsDashboardSurfaceContentRoute":{
            "currentPage":1,"totalPages":0,"totalCount":0,"results":[]}}}</script></body></html>
            """
            return .init(status: 200, url: URL(string: "https://github.com/pulls")!, body: body)
        }
    }

    @Test func activationCannotReplaceExistingAccountOrCreateSpace() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let context = try await store.captureContext(in: window)
        let fixture = FixtureSession()
        let runtime = BrowserLiveFoldersRuntime(store: store, session: fixture, directory: nil)
        let before = await store.sessionDocument()
        let id = try await runtime.enable(configuration: .init(), context: context)
        #expect(await store.sessionDocument().spaces == before.spaces)
        fixture.actor = 456
        await #expect(throws: BrowserGitHubProviderError.accountChanged) {
            try await runtime.enable(configuration: .init(), context: context)
        }
        let connection = try await runtime.connection(profile)
        #expect(connection.account == nil)
        #expect(connection.boundAccount?.id == 123)
        await #expect(throws: BrowserGitHubProviderError.accountChanged) {
            try await runtime.refresh(id, configuration: .init(), context: context)
        }
        fixture.actor = 123
        try await runtime.refresh(id, configuration: .init(), context: context)
        #expect(connection.state == .empty)
        #expect(runtime.lastFetched(id) != nil)
        await runtime.stop()
    }

}
