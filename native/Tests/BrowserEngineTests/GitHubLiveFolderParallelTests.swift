import BrowserCore
import BrowserEngine
import Foundation
import Testing

@MainActor
@Suite("GitHub live folder parallel queries", .serialized)
struct GitHubLiveFolderParallelTests {
    final class Session: BrowserGitHubWebSession {
        var latency: Duration = .milliseconds(100)
        var pages = 2
        var inFlight = 0
        var maxInFlight = 0
        var calls: [(String, Int)] = []
        var statusForQuery: (String) -> Int = { _ in 200 }
        func pullRequests(profileID: ProfileID, query: String, page: Int) async throws -> BrowserProfileWebResponse {
            calls.append((query, page))
            inFlight += 1; maxInFlight = max(maxInFlight, inFlight)
            defer { inFlight -= 1 }
            try await Task.sleep(for: latency)
            let tag = query.contains("review-requested") ? "review" : "authored"
            let rows = (0..<2).map { row in
                #"{"globalId":"PR_\#(tag)_\#(page)_\#(row)","title":"Synthetic \#(tag)","permalink":"https://github.com/example/fixture/pull/\#(tag == "review" ? 500 : 100)\#(page)\#(row)","updatedAt":"2026-10-01T00:00:00Z","state":"REPO_PULL_REQUEST_STATE_OPEN"}"#
            }.joined(separator: ",")
            let body = """
            <html><head><meta name="user-login" content="fixture"><meta name="octolytics-actor-id" content="123"></head><body>
            <script type="application/json" data-target="react-app.embeddedData">{"payload":{"pullsDashboardSurfaceContentRoute":{
            "currentPage":\(page),"totalPages":\(pages),"totalCount":\(pages * 2),"results":[\(rows)]}}}</script></body></html>
            """
            let status = statusForQuery(query)
            return .init(status: status, url: URL(string: "https://github.com/pulls")!, body: body, retryAfter: status == 429 ? "600" : nil)
        }
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let config = BrowserLiveFolderConfiguration(filters: [.authored, .reviewRequested])

    func setup() async throws -> (BrowserStore, BrowserGitHubLiveFolderRefresh, Session, FolderID) {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let context = try await store.captureContext(in: window)
        let id = try await store.createLiveFolder(title: "Requests", configuration: config, at: .init(.pinned(space)), from: context)
        let session = Session()
        let owner = BrowserGitHubLiveFolderRefresh(profileID: profile, session: session, store: store)
        try await owner.connect(account: .init(id: 123, login: "fixture"))
        return (store, owner, session, id)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test("Both relationship queries run together and every page is kept")
    func parallelRefresh() async throws {
        let (store, owner, session, id) = try await setup()
        let start = ContinuousClock.now
        await owner.refresh(folderID: id, configuration: config, now: now)
        let parallel = milliseconds(ContinuousClock.now - start)
        #expect(owner.state == .ready)
        #expect(session.maxInFlight == 2)
        #expect(session.calls.count == 4)
        #expect(await store.sessionDocument().organization.tabs.count == 8)

        // The previous refresh awaited each page of each query in turn: replay that order on the same fake.
        let sequential = Session()
        let queries = try BrowserGitHubPullRequestsProvider.queries(config, login: "fixture")
        let sequentialStart = ContinuousClock.now
        for query in queries { for page in 1...2 { _ = try await sequential.pullRequests(profileID: ProfileID(), query: query, page: page) } }
        let before = milliseconds(ContinuousClock.now - sequentialStart)
        #expect(parallel < before * 0.75)
        print(String(format: "PERF-SHELL-B GitHub live folder refresh (2 queries x 2 pages, 100 ms per page) before=%.0fms after=%.0fms", before, parallel))
    }

    @Test("A rate-limited query fails the refresh and keeps the retry deadline")
    func rateLimitInOneQuery() async throws {
        let (store, owner, session, id) = try await setup()
        await owner.refresh(folderID: id, configuration: config, now: now)
        #expect(await store.sessionDocument().organization.tabs.count == 8)
        session.statusForQuery = { $0.contains("review-requested") ? 429 : 200 }
        await owner.refresh(folderID: id, configuration: config, now: now.addingTimeInterval(121))
        #expect(owner.state == .failed(.rateLimited(until: now.addingTimeInterval(721))))
        #expect(owner.refreshNotBefore == now.addingTimeInterval(721))
        #expect(await store.sessionDocument().organization.tabs.count == 8)
        session.statusForQuery = { $0.contains("author:") ? 500 : 200 }
        owner.invalidateRefreshDeadline()
        await owner.refresh(folderID: id, configuration: config, now: now.addingTimeInterval(722))
        #expect(owner.state == .failed(.server(status: 500)))
    }
}
