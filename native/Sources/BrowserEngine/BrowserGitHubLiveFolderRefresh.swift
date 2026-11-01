import BrowserCore
import Foundation

/// One owner per profile. A caller invokes refresh after activation/configuration, focus or its
/// timer. Concurrent callers coalesce; a disconnect invalidates results before cancellation.
@MainActor
public final class BrowserGitHubLiveFolderRefresh {
    public enum State: Equatable, Sendable {
        case disconnected, refreshing, ready, empty, failed(BrowserGitHubProviderError), unavailable
    }
    public let profileID: ProfileID
    public private(set) var account: BrowserGitHubAccount?
    public private(set) var state: State = .disconnected
    public private(set) var refreshNotBefore = Date.distantPast
    private var epoch: UInt64 = 0
    private var task: Task<Void, Never>?
    private var activeFolder: FolderID?
    private var operationID = UUID()
    private var folderDeadlines: [FolderID: Date] = [:]
    private let session: any BrowserGitHubWebSession
    private let store: BrowserStore

    public init(profileID: ProfileID, session: any BrowserGitHubWebSession, store: BrowserStore) {
        self.profileID = profileID; self.session = session; self.store = store
    }

    /// Binding is explicit. A different web account never silently adopts a configured folder.
    public func connect(account: BrowserGitHubAccount) async throws {
        await disconnect()
        self.account = account
        state = .ready
    }

    public func restore(account: BrowserGitHubAccount) async throws {
        guard self.account == nil else { throw BrowserGitHubProviderError.invalidConfiguration }
        self.account = account
        state = .ready
    }

    public func invalidateRefreshDeadline() { folderDeadlines = [:] }

    public func stop() async {
        let pending = task
        cancel()
        await pending?.value
    }

    public func cancel() {
        epoch &+= 1
        task?.cancel(); task = nil
        state = .unavailable
    }

    public func disconnect() async {
        epoch &+= 1
        task?.cancel(); task = nil
        account = nil; state = .disconnected; refreshNotBefore = .distantPast; folderDeadlines = [:]
        try? await store.resetLiveFolderConnection(for: .githubPullRequests, profileID: profileID)
    }

    public func refresh(folderID: FolderID, configuration: BrowserLiveFolderConfiguration, now: Date = Date()) async {
        if let task {
            let sameFolder = activeFolder == folderID
            await task.value
            if sameFolder { return }
        }
        guard let account, now >= refreshNotBefore, now >= (folderDeadlines[folderID] ?? .distantPast) else { return }
        activeFolder = folderID
        let epoch = self.epoch
        let operation = UUID()
        operationID = operation
        state = .refreshing
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let generation = await store.liveFolderRefreshGeneration(folderID, profileID: profileID, configuration: configuration) else {
                    state = .unavailable
                    return
                }
                let queries = try BrowserGitHubPullRequestsProvider.queries(configuration, login: account.login)
                var items: [BrowserLiveFolderFetchedItem] = []
                var identities: Set<BrowserLiveFolderItemID> = []
                var complete = true
                for query in queries {
                    var received = 0
                    var queryIDs: Set<BrowserLiveFolderItemID> = []
                    var expectedCount: Int?
                    for number in 1...40 {
                        let response = try await session.pullRequests(profileID: profileID, query: query, page: number)
                        try Task.checkCancellation()
                        guard self.epoch == epoch else { return }
                        if response.status == 401 { throw BrowserGitHubProviderError.signedOut }
                        if response.status == 429 || response.status == 403 && response.retryAfter != nil {
                            let seconds = response.retryAfter.flatMap(Double.init) ?? 60
                            throw BrowserGitHubProviderError.rateLimited(until: now.addingTimeInterval(seconds.isFinite ? max(60, seconds) : 60))
                        }
                        if response.status == 403 { throw BrowserGitHubProviderError.accessDenied }
                        guard response.status == 200 else { throw BrowserGitHubProviderError.server(status: response.status) }
                        let page = try BrowserGitHubWebPage(html: response.body)
                        guard page.account.id == account.id else { throw BrowserGitHubProviderError.accountChanged }
                        guard page.currentPage == number else { throw BrowserGitHubProviderError.invalidResponse }
                        if let expectedCount, expectedCount != page.totalCount { complete = false }
                        expectedCount = page.totalCount
                        received += page.items.count
                        for item in page.items where !queryIDs.insert(item.identity).inserted { complete = false }
                        for item in page.items where identities.insert(item.identity).inserted { items.append(item) }
                        if number >= page.totalPages {
                            if received != page.totalCount { complete = false }
                            break
                        }
                        if number == 40 { complete = false }
                    }
                }
                try Task.checkCancellation()
                guard self.epoch == epoch else { return }
                let accepted = try await store.reconcileLiveFolder(folderID, profileID: profileID,
                    fetched: .init(generation: generation, coverage: complete ? .complete : .partial, items: items))
                guard self.epoch == epoch else { return }
                if accepted { state = items.isEmpty ? .empty : .ready }
                else { state = .unavailable }
                folderDeadlines[folderID] = now.addingTimeInterval(120)
            } catch is CancellationError {
                if self.epoch == epoch { state = .unavailable }
            } catch let error as BrowserGitHubProviderError {
                guard self.epoch == epoch else { return }
                if error == .signedOut || error == .accountChanged {
                    await disconnect()
                    state = .failed(error)
                } else {
                    state = .failed(error)
                    if case let .rateLimited(until) = error { refreshNotBefore = until }
                    else { refreshNotBefore = now.addingTimeInterval(60) }
                }
            } catch {
                if self.epoch == epoch { state = .unavailable; refreshNotBefore = now.addingTimeInterval(60) }
            }
        }
        self.task = task
        await task.value
        if self.epoch == epoch && operationID == operation { self.task = nil }
    }
}
