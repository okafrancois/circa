import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import CloudKit
import Combine
import Foundation

@MainActor
final class BrowserSyncRuntime: ObservableObject {
    enum Status { case unavailable, off, on, syncing, synced(Date), signedOut, accountChanged }
    @Published private(set) var enabled = false
    @Published private(set) var status = Status.unavailable
    @Published var needsAccountDecision = false
    let available: Bool
    let showsSettings: Bool
    private var state = BrowserSyncState()
    private var destination: URL?
    private var transport: (any BrowserSyncTransport)?
    private var historyTransport: (any BrowserHistorySyncTransport)?
    private var task: Task<Void, Never>?
    private var cycle: (() async throws -> Void)?

    init() {
        available = BrowserSyncEntitlement.isAvailable()
        showsSettings = available || (Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true
            && ProcessInfo.processInfo.environment["ORBIT_SYNTHETIC_SYNC_SETTINGS"] == "1")
    }

    var statusText: String {
        switch status {
        case .unavailable: uiText("iCloud sync is unavailable in this build.")
        case .off: uiText("iCloud sync is off.")
        case .on: uiText("iCloud sync is on.")
        case .syncing: uiText("Syncing with iCloud…")
        case .synced(let date): uiFormat("Last synced: %@", date.formatted(date: .abbreviated, time: .shortened))
        case .signedOut: uiText("Signed out of iCloud. Your local data is kept.")
        case .accountChanged: uiText("Your iCloud account changed. Sync is paused.")
        }
    }

    func configure<Engine: BrowserEngine>(_ environment: BrowserEnvironment<Engine>, destination: URL) throws {
        guard available, !environment.isPrivate else { return }
        self.destination = destination
        state = try BrowserSyncState.load(destination)
        enabled = state.enabled; status = enabled ? .on : .off
        cycle = { [weak self, weak environment] in
            guard let self, let environment, !environment.isFinalizing, !environment.settingsRemovalIsRunning else { return }
            try await self.synchronize(environment)
        }
        if enabled { NSApp?.registerForRemoteNotifications() }
        start()
    }

    func setEnabled(_ value: Bool) async throws {
        guard available, let destination else { return }
        state.enabled = value
        try state.save(destination)
        enabled = value
        if !value { await transport?.stop(); await historyTransport?.stop(); transport = nil; historyTransport = nil; status = .off }
        else { status = .on; NSApp?.registerForRemoteNotifications(); start() }
    }

    func prepareForTermination() async {
        task?.cancel()
        await transport?.stop()
        await historyTransport?.stop()
        await task?.value
        task = nil; transport = nil; historyTransport = nil
    }

    func resumeAfterCancelledTermination() {
        if enabled { start() }
    }

    private func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if enabled {
                    do { try await cycle?() }
                    catch BrowserSyncError.signedOut {
                        status = .signedOut; await transport?.stop(); transport = nil
                        await historyTransport?.stop(); historyTransport = nil
                    }
                    catch BrowserSyncError.accountChanged {
                        await historyTransport?.stop(); historyTransport = nil
                        status = .accountChanged; needsAccountDecision = true
                        await transport?.stop(); transport = nil
                        // Require an explicit decision; never attach the retained data to a new ID.
                        try? await setEnabled(false)
                        status = .accountChanged
                    }
                    catch BrowserSyncError.localChange { status = .on }
                    catch { status = .unavailable; await transport?.stop(); transport = nil }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func synchronize<Engine: BrowserEngine>(_ environment: BrowserEnvironment<Engine>) async throws {
        guard let destination, enabled else { return }
        // No container is ever initialized in unsigned/synthetic processes.
        guard available else { throw BrowserSyncError.unavailable }
        let container = CKContainer(identifier: BrowserSyncSchema.container)
        let identity = try await container.accountStatus() == .available ? try await container.userRecordID().recordName : nil
        do { try state.account.admit(identity) }
        catch { try state.save(destination); throw error }
        try state.save(destination)
        guard let identity else { throw BrowserSyncError.signedOut }
        if transport == nil {
            transport = try BrowserCloudKitTransport(destination: destination.appendingPathExtension("cloudkit"), identity: identity)
        }
        guard let transport else { return }
        status = .syncing
        do { try await synchronizeHistory(environment, identity: identity, destination: destination) }
        catch BrowserSyncError.signedOut { throw BrowserSyncError.signedOut }
        catch BrowserSyncError.accountChanged { throw BrowserSyncError.accountChanged }
        catch {
            // A missing Production history type (or corrupt/unsupported history payload) must
            // fail closed for this zone without interrupting organization synchronization.
            await historyTransport?.stop(); historyTransport = nil
        }
        let session = await environment.store.sessionDocument()
        let settings = await environment.settings.store.snapshot()
        var boostDocuments: [BrowserBoostDocument] = []
        for profile in session.profiles { boostDocuments.append(await (try environment.boosts.store(for: profile.id)).snapshot()) }
        let projection = try BrowserSyncMapping.project(session: session, settings: settings, boosts: boostDocuments)
        try state.replica.capture(projection)
        try state.save(destination)
        let incoming = try await transport.exchange(Array(state.replica.records.values))
        guard enabled, !Task.isCancelled, !environment.isFinalizing, !environment.settingsRemovalIsRunning else { return }
        try state.account.admit(try await transport.account())
        try state.replica.merge(incoming)
        try state.save(destination)
        // Recapture immediately before publication; changes made while offline win by their
        // own stamp instead of being overwritten by a network snapshot.
        let current = await environment.store.sessionDocument()
        let currentSettings = await environment.settings.store.snapshot()
        var currentBoosts: [BrowserBoostDocument] = []
        for profile in current.profiles { currentBoosts.append(await (try environment.boosts.store(for: profile.id)).snapshot()) }
        try state.replica.capture(BrowserSyncMapping.project(session: current, settings: currentSettings, boosts: currentBoosts))
        let value = try BrowserSyncMapping.materialize(state.replica.visible, local: current, settings: currentSettings, boosts: currentBoosts)
        let shared = BrowserSessionDocument(profiles: value.profiles, spaces: value.spaces, windows: [], tabs: [], organization: value.organization)
        let projected = try BrowserSyncMapping.project(session: shared, settings: value.settings, boosts: value.boosts)
        let currentProjection = try BrowserSyncMapping.project(session: current, settings: currentSettings, boosts: currentBoosts)
        if projected == currentProjection {
            try state.replica.acknowledge(projected)
            try state.save(destination)
            status = .synced(Date())
            return
        }
        guard enabled, !Task.isCancelled, !environment.isFinalizing, !environment.settingsRemovalIsRunning else { return }
        try await environment.store.applySync(value, expected: current)
        try await environment.settings.store.applySync(value.settings, expected: currentSettings)
        for document in value.boosts {
            let store = try environment.boosts.store(for: document.profileID)
            let expected = currentBoosts.first { $0.profileID == document.profileID } ?? BrowserBoostDocument(profileID: document.profileID)
            try await store.applySync(document, expected: expected)
            if environment.engine.capabilities.contains(.boosts) {
                try await environment.boosts.synchronize(profileID: document.profileID,
                    enabled: value.settings.enablesBoostsOnWebsites, engine: environment.engine)
            }
        }
        await environment.settings.refresh()
        await environment.refreshSettingsCatalog()
        try await environment.saveNow()
        try state.replica.acknowledge(projected)
        try state.save(destination)
        status = .synced(Date())
    }

    private func synchronizeHistory<Engine: BrowserEngine>(_ environment: BrowserEnvironment<Engine>,
        identity: String, destination: URL) async throws {
        guard enabled, !environment.isPrivate else { return }
        if historyTransport == nil {
            historyTransport = try BrowserHistoryCloudKitTransport(
                destination: destination.appendingPathExtension("history.cloudkit"), identity: identity)
        }
        guard let historyTransport else { return }
        let session = await environment.store.sessionDocument()
        let now = Date()
        var outgoing: [BrowserHistorySyncBatch] = []
        for profile in session.profiles {
            outgoing += try await environment.historyRecorder.syncBatches(for: profile.id, now: now)
        }
        let incoming = try await historyTransport.exchange(outgoing, now: now)
        guard enabled, !Task.isCancelled, !environment.isFinalizing, !environment.settingsRemovalIsRunning else { return }
        // Organization admission may add a profile this cycle; hold its batches in the transport
        // until that profile is locally persistent, never invent or open an unknown profile here.
        let current = await environment.store.sessionDocument()
        for profile in current.profiles {
            if try await environment.historyRecorder.applySync(incoming, for: profile.id, now: now) {
                for controller in environment.liveControllers where controller.library.history.profileID == profile.id {
                    controller.library.history.reload()
                }
            }
        }
    }

    deinit { task?.cancel() }
}
