import AppKit
import BrowserCore
import BrowserEngine
import Foundation

/// Nonvisual command authority shared by activation, configuration and refresh entry points.
/// Temporary environments never get a disk destination; private engines get no integration.
@MainActor
final class BrowserLiveFoldersRuntime {
    private let store: BrowserStore
    private let session: (any BrowserGitHubWebSession)?
    private let directory: URL?
    private var connections: [ProfileID: BrowserGitHubLiveFolderRefresh] = [:]
    private var restored: Set<ProfileID> = []
    private var removed: Set<ProfileID> = []
    private var timer: Task<Void, Never>?
    private let writer = BrowserLiveFolderFileWriter()
    private var localObservation: Task<Void, Never>?
    private var stopped = false
    private var activationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    func lastFetched(_ folderID: FolderID) -> Date? {
        connections.values.compactMap { $0.lastSuccessfulFetch[folderID] }.max()
    }
    var onMutation: (() -> Void)?
    var onError: ((any Error) -> Void)?

    init(store: BrowserStore, session: (any BrowserGitHubWebSession)?, directory: URL?) {
        self.store = store; self.session = session; self.directory = directory
    }

    private func file(_ profileID: ProfileID) -> URL? {
        directory?.appendingPathComponent("live-folders-\(profileID.rawValue.uuidString).json")
    }

    func connection(_ profileID: ProfileID) async throws -> BrowserGitHubLiveFolderRefresh {
        guard !removed.contains(profileID) else { throw BrowserStoreError.profileMissing }
        guard let session else { throw BrowserEngineError.unsupportedOperation }
        if let existing = connections[profileID] { return existing }
        let connection = BrowserGitHubLiveFolderRefresh(profileID: profileID, session: session, store: store)
        if !restored.contains(profileID), let file = file(profileID), FileManager.default.fileExists(atPath: file.path) {
            let saved = try await writer.load(from: file, profileID: profileID)
            try await store.restoreLiveFolderLocalStore(saved.local)
            if let account = saved.account { try await connection.restore(account: account) }
        }
        restored.insert(profileID)
        connections[profileID] = connection
        return connection
    }

    /// Always creates a distinct provider folder. Names/imported folders carry no provider
    /// authority, and this command cannot convert an ordinary folder or create a Space.
    func enable(configuration: BrowserLiveFolderConfiguration, context: BrowserContext) async throws -> FolderID {
        guard !removed.contains(context.profileID) else { throw BrowserStoreError.profileMissing }
        guard configuration.isEnabled else { throw BrowserGitHubProviderError.invalidConfiguration }
        guard let session else { throw BrowserEngineError.unsupportedOperation }
        _ = try BrowserGitHubPullRequestsProvider.queries(configuration, login: "validation")
        let response = try await session.pullRequests(profileID: context.profileID, query: "is:pr is:open author:@me", page: 1)
        guard response.status == 200 else {
            if response.status == 401 { throw BrowserGitHubProviderError.signedOut }
            throw BrowserGitHubProviderError.server(status: response.status)
        }
        let page = try BrowserGitHubWebPage(html: response.body)
        let connection = try await connection(context.profileID)
        if let bound = connection.account, bound.id != page.account.id {
            await connection.disconnect()
            throw BrowserGitHubProviderError.accountChanged
        }
        if connection.account == nil { try await connection.connect(account: page.account) }
        _ = try BrowserGitHubPullRequestsProvider.queries(configuration, login: page.account.login)
        let id = try await store.createLiveFolder(title: uiText("Pull Requests"), configuration: configuration,
            at: .init(.pinned(context.spaceID)), from: context)
        await connection.refresh(folderID: id, configuration: configuration)
        try await persist(context.profileID)
        onMutation?()
        start()
        return id
    }

    private func sessionResponse(profileID: ProfileID) async throws -> BrowserProfileWebResponse {
        guard let session else { throw BrowserEngineError.unsupportedOperation }
        let response = try await session.pullRequests(profileID: profileID, query: "is:pr is:open author:@me", page: 1)
        guard response.status == 200 else {
            if response.status == 401 { throw BrowserGitHubProviderError.signedOut }
            throw BrowserGitHubProviderError.server(status: response.status)
        }
        return response
    }

    func configuration(_ folderID: FolderID) async -> BrowserLiveFolderConfiguration? {
        await store.sessionDocument().organization.folders.first { $0.id == folderID }?.liveFolder
    }

    func refresh(_ folderID: FolderID, configuration: BrowserLiveFolderConfiguration, context: BrowserContext) async throws {
        let connection = try await connection(context.profileID)
        if connection.account == nil {
            let response = try await sessionResponse(profileID: context.profileID)
            try await connection.connect(account: BrowserGitHubWebPage(html: response.body).account)
        }
        connection.invalidateRefreshDeadline()
        let revision = connection.mutationRevision
        await connection.refresh(folderID: folderID, configuration: configuration)
        try await persist(context.profileID)
        if revision != connection.mutationRevision { onMutation?() }
        if case let .failed(error) = connection.state { throw error }
    }

    func configure(_ folderID: FolderID, configuration: BrowserLiveFolderConfiguration, context: BrowserContext) async throws {
        _ = try BrowserGitHubPullRequestsProvider.queries(configuration, login: "validation")
        try await store.configureLiveFolder(folderID, configuration: configuration, from: context)
        onMutation?()
        try await refresh(folderID, configuration: configuration, context: context)
    }

    func refresh() async {
        guard !stopped else { return }
        let document = await store.sessionDocument()
        let profiles = Set(document.profiles.map(\.id))
        for profile in Array(connections.keys) where !profiles.contains(profile) {
            connections.removeValue(forKey: profile)?.cancel()
            if let file = file(profile) { try? await writer.remove(file) }
        }
        let folders = Dictionary(uniqueKeysWithValues: document.organization.folders.map { ($0.id, $0) })
        func visit(_ nodes: [BrowserOrganizationNode], profile: ProfileID) async {
            for node in nodes {
                guard case let .folder(id) = node, let folder = folders[id] else { continue }
                if let config = folder.liveFolder, config.isEnabled {
                    do {
                        let connection = try await connection(profile)
                        let revision = connection.mutationRevision
                        await connection.refresh(folderID: id, configuration: config)
                        try await persist(profile)
                        if revision != connection.mutationRevision { onMutation?() }
                    } catch { onError?(error) }
                } else { await visit(folder.children, profile: profile) }
            }
        }
        for section in document.organization.spaces {
            if let profile = document.spaces.first(where: { $0.id == section.spaceID })?.profileID {
                await visit(section.pinned, profile: profile)
            }
        }
    }

    func removeProfile(_ profile: ProfileID) async throws {
        removed.insert(profile)
        await connections.removeValue(forKey: profile)?.stop()
        if let file = file(profile), FileManager.default.fileExists(atPath: file.path) {
            try await writer.remove(file)
        }
    }

    func persistAll() async throws {
        for profile in connections.keys { try await persist(profile) }
    }

    func persist(_ profile: ProfileID) async throws {
        guard !removed.contains(profile) else { return }
        guard let file = file(profile) else { return }
        let local = await store.liveFolderLocalStore(for: profile)
        guard !removed.contains(profile) else { return }
        try await writer.save(BrowserLiveFolderProfileFile(local: local, account: connections[profile]?.boundAccount), to: file)
    }

    func start() {
        guard timer == nil, session != nil else { return }
        stopped = false
        localObservation = Task { [weak self, store] in
            let changes = await store.organizationChanges()
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                do { try await persistAll() } catch { onError?(error) }
            }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                if NSApp.isActive { await self?.refresh() }
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
            }
        }
    }

    func stop() async {
        stopped = true
        localObservation?.cancel(); localObservation = nil
        timer?.cancel(); timer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        activationObserver = nil; wakeObserver = nil
        for (profile, connection) in connections {
            await connection.stop()
            do { try await persist(profile) } catch { onError?(error) }
        }
    }
}
