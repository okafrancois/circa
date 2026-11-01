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
}
