import Foundation
import Testing
@testable import BrowserCore

struct GitHubLiveFolderTests {
    func html(rows: String = "[]", count: Int = 0, actor: Int = 123) -> String {
        """
        <html><head><meta name="user-login" content="fixture"><meta name="octolytics-actor-id" content="\(actor)"></head>
        <body><script type="application/json" data-target="react-app.embeddedData">{"payload":{"pullsDashboardSurfaceContentRoute":{
        "currentPage":1,"totalPages":1,"totalCount":\(count),"results":\(rows)}}}</script></body></html>
        """
    }
    let row = #"[{"globalId":"PR_fixture","title":"Synthetic & change","permalink":"https://github.com/example/repo/pull/1","updatedAt":"2026-10-01T00:00:00Z","state":"REPO_PULL_REQUEST_STATE_OPEN"}]"#

    @Test func explicitQueriesUnionRelationshipsAndValidateRepositoryNames() throws {
        let config = BrowserLiveFolderConfiguration(filters: [.authored, .reviewRequested], excludedRepositories: ["example/repo"])
        #expect(try BrowserGitHubPullRequestsProvider.queries(config, login: "fixture") == [
            "is:pr is:open author:fixture draft:false -repo:example/repo",
            "is:pr is:open review-requested:fixture draft:false -repo:example/repo"])
        #expect(try BrowserGitHubPullRequestsProvider.queries(.init(filters: [.authored, .drafts]), login: "fixture") == ["is:pr is:open author:fixture"])
        #expect(throws: BrowserGitHubProviderError.invalidConfiguration) {
            try BrowserGitHubPullRequestsProvider.queries(.init(excludedRepositories: ["x/y is:closed"]), login: "fixture")
        }
        #expect(throws: BrowserGitHubProviderError.invalidConfiguration) {
            try BrowserGitHubPullRequestsProvider.queries(.init(filters: [.assigned]), login: "fixture")
        }
    }

    @Test func structuredPageAndExplicitEmptyHaveDifferentOutcomesFromUnknownHTML() throws {
        let page = try BrowserGitHubWebPage(html: html(rows: row, count: 1))
        #expect(page.account == .init(id: 123, login: "fixture"))
        #expect(page.items.first?.title == "Synthetic & change")
        #expect(page.items.first?.identity.itemID == "github.com:123:PR_fixture")
        #expect(try BrowserGitHubWebPage(html: html()).items.isEmpty)
        #expect(throws: BrowserGitHubProviderError.invalidResponse) {
            try BrowserGitHubWebPage(html: html().replacingOccurrences(of: "pullsDashboardSurfaceContentRoute", with: "unrecognizedRoute"))
        }
        #expect(throws: BrowserGitHubProviderError.signedOut) { try BrowserGitHubWebPage(html: "<html><body>Sign in</body></html>") }
        #expect(throws: BrowserGitHubProviderError.singleSignOnRequired) {
            try BrowserGitHubWebPage(html: html().replacingOccurrences(of: "<body>", with: "<body><a href='/orgs/fixture/sso'>Continue</a>"))
        }
    }

    @Test func rejectsInvalidDestinationsAndInconsistentEmptyResult() {
        #expect(throws: BrowserGitHubProviderError.invalidResponse) {
            try BrowserGitHubWebPage(html: html(rows: row.replacingOccurrences(of: "github.com/", with: "github.com.attacker.invalid/"), count: 1))
        }
        #expect(throws: BrowserGitHubProviderError.invalidResponse) { try BrowserGitHubWebPage(html: html(count: 1)) }
        #expect(throws: BrowserGitHubProviderError.invalidResponse) { try BrowserGitHubWebPage(html: html(actor: 0)) }
    }

    @Test func profileAuthorityPersistsOutsideSessionAndRejectsCrossProfileRestore() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("local.json")
        let profile = ProfileID()
        var local = BrowserLiveFolderLocalStore(profileID: profile)
        local.acknowledge(.init(itemID: "synthetic"), fingerprint: "revision")
        local.disableAutomaticCreation(for: .githubPullRequests)
        let saved = BrowserLiveFolderProfileFile(local: local, account: .init(id: 123, login: "fixture"))
        try saved.save(to: file)
        #expect(try BrowserLiveFolderProfileFile.load(from: file, profileID: profile) == saved)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(throws: BrowserGitHubProviderError.invalidConfiguration) { try BrowserLiveFolderProfileFile.load(from: file, profileID: ProfileID()) }
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: BrowserGitHubProviderError.invalidConfiguration) { try saved.save(to: link) }
    }

    @Test func disconnectPurgesDisabledFolderAndLeavesOrdinaryConversionIntact() async throws {
        let f = try await OrganizationFixture.make()
        let context = try await f.context()
        let id = try await f.store.createLiveFolder(title: "Pull Requests", configuration: .init(), at: .init(.pinned(f.home)), from: context)
        let generation = await f.store.liveFolderLocalStore(for: f.personal).generation(for: .githubPullRequests)
        let page = try BrowserGitHubWebPage(html: html(rows: row, count: 1))
        #expect(try await f.store.reconcileLiveFolder(id, profileID: f.personal, fetched: .init(generation: generation, coverage: .complete, items: page.items)))
        var disabled = BrowserLiveFolderConfiguration(); disabled.isEnabled = false
        try await f.store.configureLiveFolder(id, configuration: disabled, from: context)
        try await f.store.resetLiveFolderConnection(for: .githubPullRequests, profileID: f.personal)
        #expect(await f.store.sessionDocument().organization.tabs.isEmpty)
        #expect(await f.store.sessionDocument().spaces.count == 3)
        try await f.validate()
    }
    // Opt-in integration check consumes a freshly fetched, unauthenticated public repository
    // page. Only synthetic viewer metadata is inserted; it does not prove authenticated schema.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_PUBLIC_PULLS_HTML"] != nil))
    func publicRepositoryPayloadCompatibility() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ORBIT_PUBLIC_PULLS_HTML"])
        let html = try String(contentsOfFile: path, encoding: .utf8)
        #expect(throws: BrowserGitHubProviderError.signedOut) { try BrowserGitHubWebPage(html: html) }
        let metadata = "<meta name='octolytics-actor-id' content='123'>"
        let viewerHTML = html.replacingOccurrences(of: #"<meta name="user-login" content="">"#, with: #"<meta name="user-login" content="fixture">"#)
        let page = try BrowserGitHubWebPage(html: viewerHTML.replacingOccurrences(of: "</head>", with: metadata + "</head>"))
        #expect(!page.items.isEmpty)
        #expect(page.totalCount >= page.items.count)
        #expect(page.items.allSatisfy { $0.url.host == "github.com" })
    }

}
