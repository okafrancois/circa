import BrowserCore
import BrowserEngine
import Foundation
import Testing

@MainActor
struct GitHubLiveFolderRefreshTests {
    final class Session: BrowserGitHubWebSession {
        var status = 200
        var account = 123
        var empty = false
        var calls = 0
        var pages = 1
        var failPage: Int?
        var pause: CheckedContinuation<Void, Never>?
        var shouldPause = false
        func pullRequests(profileID: ProfileID, query: String, page: Int) async throws -> BrowserProfileWebResponse {
            calls += 1
            let account = self.account
            if shouldPause { await withCheckedContinuation { pause = $0 } }
            let rows = empty ? "[]" : #"[{"globalId":"PR_fixture","title":"Synthetic change","permalink":"https://github.com/example/fixture/pull/1","updatedAt":"2026-10-01T00:00:00Z","state":"REPO_PULL_REQUEST_STATE_OPEN"}]"#
            let pageRows = rows.replacingOccurrences(of: "PR_fixture", with: "PR_fixture_\(page)")
                .replacingOccurrences(of: "/pull/1", with: "/pull/\(page)")
            let body = """
            <html><head><meta name="user-login" content="fixture"><meta name="octolytics-actor-id" content="\(account)"></head><body>
            <script type="application/json" data-target="react-app.embeddedData">{"payload":{"pullsDashboardSurfaceContentRoute":{
            "currentPage":\(page),"totalPages":\(pages),"totalCount":\(empty ? 0 : pages),"results":\(pageRows)}}}</script></body></html>
            """
            return .init(status: failPage == page ? 500 : status, url: URL(string: "https://github.com/pulls")!, body: body, retryAfter: status == 429 ? "600" : nil)
        }
    }
    func setup() async throws -> (BrowserStore, BrowserGitHubLiveFolderRefresh, Session, FolderID, BrowserContext) {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let context = try await store.captureContext(in: window)
        let config = BrowserLiveFolderConfiguration(filters: [.authored])
        let id = try await store.createLiveFolder(title: "Requests", configuration: config, at: .init(.pinned(space)), from: context)
        let session = Session()
        let owner = BrowserGitHubLiveFolderRefresh(profileID: profile, session: session, store: store)
        try await owner.connect(account: .init(id: 123, login: "fixture"))
        return (store, owner, session, id, context)
    }
    let config = BrowserLiveFolderConfiguration(filters: [.authored])
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func refreshEmptyAndRateLimitRetainsCacheUntilRetry() async throws {
        let (store, owner, session, id, _) = try await setup()
        await owner.refresh(folderID: id, configuration: config, now: now)
        #expect(owner.state == .ready)
        #expect(await store.sessionDocument().organization.tabs.count == 1)
        session.status = 429
        await owner.refresh(folderID: id, configuration: config, now: now.addingTimeInterval(121))
        #expect(owner.state == .failed(.rateLimited(until: now.addingTimeInterval(721))))
        #expect(await store.sessionDocument().organization.tabs.count == 1)
        let calls = session.calls
        owner.invalidateRefreshDeadline()
        await owner.refresh(folderID: id, configuration: config, now: now.addingTimeInterval(200))
        #expect(session.calls == calls)
        session.status = 200; session.empty = true
        await owner.refresh(folderID: id, configuration: config, now: now.addingTimeInterval(722))
        #expect(owner.state == .empty)
        #expect(await store.sessionDocument().organization.tabs.isEmpty)
    }

    @Test func accountMismatchAndSignOutRevokeGeneratedCache() async throws {
        for status in [200, 401] {
            let (store, owner, session, id, _) = try await setup()
            await owner.refresh(folderID: id, configuration: config, now: now)
            session.account = 456; session.status = status
            await owner.refresh(folderID: id, configuration: config, now: now.addingTimeInterval(121))
            #expect(owner.account == nil)
            #expect(owner.state == .failed(status == 401 ? .signedOut : .accountChanged))
            #expect(await store.sessionDocument().organization.tabs.isEmpty)
        }
    }

    @Test func cancelledOldConnectionCannotRepopulate() async throws {
        let (store, owner, session, id, _) = try await setup()
        session.shouldPause = true
        let refresh = Task { await owner.refresh(folderID: id, configuration: config, now: now) }
        while session.pause == nil { await Task.yield() }
        await owner.disconnect()
        session.pause?.resume(); session.pause = nil
        await refresh.value
        #expect(owner.state == .disconnected)
        #expect(await store.sessionDocument().organization.tabs.isEmpty)
    }

    @Test func staleConfigurationCannotFetchOrApplyWithNewGeneration() async throws {
        let (store, owner, session, id, context) = try await setup()
        let changed = BrowserLiveFolderConfiguration(filters: [.reviewRequested])
        try await store.configureLiveFolder(id, configuration: changed, from: context)
        await owner.refresh(folderID: id, configuration: config, now: now)
        #expect(session.calls == 0)
        await owner.refresh(folderID: id, configuration: changed, now: now)
        #expect(owner.state == .ready)
        #expect(await store.sessionDocument().organization.tabs.count == 1)
    }
    @Test func paginationCompletesButFailedLaterPagePreservesCache() async throws {
        let (store, owner, session, id, _) = try await setup()
        session.pages = 2
        await owner.refresh(folderID: id, configuration: config, now: now)
        #expect(session.calls == 2)
        #expect(await store.sessionDocument().organization.tabs.count == 2)
        let before = await store.sessionDocument().organization
        session.failPage = 2
        await owner.refresh(folderID: id, configuration: config, now: now.addingTimeInterval(121))
        #expect(owner.state == .failed(.server(status: 500)))
        #expect(await store.sessionDocument().organization == before)
    }

    @Test func configurationChangeDuringFetchRejectsResult() async throws {
        let (store, owner, session, id, context) = try await setup()
        session.shouldPause = true
        let refresh = Task { await owner.refresh(folderID: id, configuration: config, now: now) }
        while session.pause == nil { await Task.yield() }
        try await store.configureLiveFolder(id, configuration: .init(filters: [.reviewRequested]), from: context)
        session.pause?.resume(); session.pause = nil
        await refresh.value
        #expect(owner.state == .unavailable)
        #expect(await store.sessionDocument().organization.tabs.isEmpty)
    }

}
