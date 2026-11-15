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
    private var worker: BrowserSyncWorker?
    private var destination: URL?
    private var transport: (any BrowserSyncTransport)?
    private var passwordTransport: (any BrowserPasswordSyncTransport)?
    private var passwords: BrowserPasswordSync?
    private var historyTransport: (any BrowserHistorySyncTransport)?
    private var task: Task<Void, Never>?
    private var loading: Task<Void, Never>?
    private var isTerminating = false
    /// Failure backoff base, and the minimum spacing between two cycles (the former poll period).
    private var interval = Duration.seconds(5)
    /// Coalesces a burst of local edits or pushes into one cycle.
    private var debounce = Duration.seconds(2)
    /// Slow safety cycle: forces a fetch/send and a full password rescan for missed signals.
    private var safetyInterval = Duration.seconds(600)
    var hasScheduledCycle: Bool { task != nil }
    private var flushHistory: (() async throws -> Void)?
    private var historyRetryAfter = Date.distantPast
    private var historyFailures = 0
    private var cycle: (() async throws -> Void)?
    private var pendingWake = false
    private var refreshRequested = false
    private var lastRefresh: ContinuousClock.Instant?
    private var waiter: CheckedContinuation<Void, Never>?
    private var waitGeneration = 0
    private var admission = BrowserSyncAdmission()
    private var signalsObserved = false

    init() {
        available = BrowserSyncEntitlement.isAvailable()
        showsSettings = available || (Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true
            && ProcessInfo.processInfo.environment["ORBIT_SYNTHETIC_SYNC_SETTINGS"] == "1")
    }

    /// A local-only scheduler seam: tests never construct a CloudKit container.
    init(destination: URL, interval: Duration, debounce: Duration? = nil, safetyInterval: Duration = .seconds(600),
         observesSignals: Bool = false, cycle: @escaping () async throws -> Void) {
        available = true
        showsSettings = true
        self.destination = destination
        worker = BrowserSyncWorker(state: BrowserSyncState(), destination: destination)
        self.interval = interval
        self.debounce = debounce ?? min(interval, .seconds(2))
        self.safetyInterval = safetyInterval
        self.cycle = cycle
        status = .off
        if observesSignals { observeSignals() }
    }

    func skillsChanged() {
        if enabled, case .synced = status { status = .on }
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

    func configure<Engine: BrowserEngine>(_ environment: BrowserEnvironment<Engine>, destination: URL,
                                          onError: @escaping @MainActor (any Error) -> Void) {
        guard available, !environment.isPrivate else { return }
        self.destination = destination
        cycle = { [weak self, weak environment] in
            guard let self, let environment, !environment.isFinalizing, !environment.settingsRemovalIsRunning else { return }
            try await self.synchronize(environment)
        }
        flushHistory = { [weak environment] in
            guard let environment, !environment.isPrivate else { return }
            let session = await environment.store.sessionDocument()
            for profile in session.profiles {
                _ = try await environment.historyRecorder.syncBatches(for: profile.id, forcePacking: true)
            }
        }
        observeSignals()
        // Read, decode and seed the replica off the main actor (one read, one decode).
        loading = Task { [weak self] in
            do {
                let worker = try await Task.detached(priority: .utility) { try BrowserSyncWorker(loading: destination) }.value
                let enabled = await worker.enabled
                guard let self else { return }
                self.worker = worker
                self.enabled = enabled; status = enabled ? .on : .off
                loading = nil
                if enabled { NSApp?.registerForRemoteNotifications() }
                start()
            } catch {
                self?.loading = nil
                onError(error)
            }
        }
    }

    // MARK: Wake sources

    /// A committed local edit (session save, settings, Boosts, skills, passwords).
    func localStateChanged() { wake() }
    /// CloudKit fetched pushed changes, failed, or saw an account change.
    func remoteChangeArrived() { wake() }
    func accountChanged() { admission.reset(); wake(refresh: true) }
    func applicationBecameActive() {
        // Covers a missed push when the user comes back; at most one forced fetch per minute.
        if let lastRefresh, ContinuousClock.now - lastRefresh < .seconds(60) { return }
        wake(refresh: true)
    }

    private func wake(refresh: Bool = false) {
        guard enabled, !isTerminating else { return }
        if refresh { refreshRequested = true }
        pendingWake = true
        resumeWaiter()
    }

    private func observeSignals() {
        guard !signalsObserved else { return }
        signalsObserved = true
        let center = NotificationCenter.default
        _ = center.addObserver(forName: BrowserSyncLocalChanges.notification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.localStateChanged() }
        }
        _ = center.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.accountChanged() }
        }
        _ = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.applicationBecameActive() }
        }
    }

    private func resumeWaiter() {
        waiter?.resume(); waiter = nil
    }

    /// Returns on a wake, after `timeout`, or on cancellation; never polls.
    private func waitForWake(timeout: Duration) async {
        guard !pendingWake, !Task.isCancelled else { return }
        waitGeneration += 1
        let generation = waitGeneration
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil, let self, self.waitGeneration == generation else { return }
            self.resumeWaiter()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resumeWaiter() }
        }
        timer.cancel()
    }

    func setEnabled(_ value: Bool) async throws {
        await loading?.value
        guard available, let worker else { return }
        if !value { task?.cancel() }
        try await worker.setEnabled(value)
        enabled = value
        if !value { task?.cancel(); await transport?.stop(); await historyTransport?.stop(); transport = nil; historyTransport = nil; await stopPasswords(); status = .off }
        else { status = .on; NSApp?.registerForRemoteNotifications(); start() }
    }

    func prepareForTermination() async {
        isTerminating = true
        await loading?.value
        task?.cancel()
        await transport?.stop()
        await historyTransport?.stop()
        await stopPasswords()
        await task?.value
        if enabled { try? await flushHistory?() }
        task = nil; transport = nil; historyTransport = nil
    }

    func resumeAfterCancelledTermination() {
        isTerminating = false
        if enabled { start() }
    }

    private func start() {
        guard enabled, !isTerminating, task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                // An enable may arrive while the cancelled cycle is still unwinding.
                start()
            }
            var failures = 0
            var retryAfter: Duration?
            var lastStart: ContinuousClock.Instant?
            // Launch and enable run one cycle immediately; later cycles wait for a signal.
            var immediate = true
            while enabled && !Task.isCancelled {
                if !immediate {
                    if failures > 0 || retryAfter != nil {
                        // Backoff retries do not need a signal; signals arriving meanwhile are kept.
                        let backoff = min(interval * (1 << failures), .seconds(300))
                        do { try await Task.sleep(for: max(backoff, retryAfter ?? .zero)) } catch { break }
                    } else {
                        var timeout = safetyInterval
                        let history = historyRetryAfter.timeIntervalSinceNow
                        if history > 0, historyRetryAfter != .distantPast {
                            timeout = min(timeout, .milliseconds(Int64(history * 1000) + 1))
                        }
                        await waitForWake(timeout: timeout)
                        guard enabled, !Task.isCancelled else { break }
                        if pendingWake {
                            var delay = debounce
                            if let lastStart { delay = max(delay, interval - (ContinuousClock.now - lastStart)) }
                            do { try await Task.sleep(for: delay) } catch { break }
                        } else if lastRefresh.map({ ContinuousClock.now - $0 >= safetyInterval }) ?? true {
                            refreshRequested = true
                        }
                    }
                }
                immediate = false
                guard enabled, !Task.isCancelled else { break }
                pendingWake = false
                lastStart = .now
                retryAfter = nil
                do { try await cycle?(); failures = 0 }
                catch is CancellationError where Task.isCancelled { break }
                catch BrowserSyncError.signedOut {
                    failures = min(failures + 1, 6)
                    status = .signedOut; await stopPasswords(); await transport?.stop(); transport = nil
                    await historyTransport?.stop(); historyTransport = nil
                }
                catch BrowserSyncError.accountChanged {
                    await stopPasswords()
                    await historyTransport?.stop(); historyTransport = nil
                    status = .accountChanged; needsAccountDecision = true
                    await transport?.stop(); transport = nil
                    // Require an explicit decision; never attach the retained data to a new ID.
                    try? await setEnabled(false)
                    status = .accountChanged
                }
                catch BrowserSyncError.localChange { status = .on; pendingWake = true }
                catch let error where BrowserSyncRetry.isTransient(error) {
                    // Throttling or connectivity: keep the transports (the engines retry their
                    // own pending work) and back off, honoring the server's retry delay.
                    failures = min(failures + 1, 6)
                    retryAfter = BrowserSyncRetry.retryAfter(error)
                    status = .on
                }
                catch { failures = min(failures + 1, 6); status = .unavailable; await stopPasswords(); await transport?.stop(); transport = nil }
            }
        }
    }

    /// The signed-in identity, verified at most once a minute and again after any account
    /// change notification (each check costs two daemon round trips).
    private func verifiedIdentity() async throws -> String? {
        if let cached = admission.identity() { return cached }
        let epoch = BrowserSyncAccountEpoch.current
        let container = CKContainer(identifier: BrowserSyncSchema.container)
        let identity = try await container.accountStatus() == .available ? try await container.userRecordID().recordName : nil
        admission.record(identity, epoch: epoch)
        return identity
    }

    private func synchronize<Engine: BrowserEngine>(_ environment: BrowserEnvironment<Engine>) async throws {
        guard let destination, let worker, enabled else { return }
        // No container is ever initialized in unsigned/synthetic processes.
        guard available else { throw BrowserSyncError.unavailable }
        let identity = try await verifiedIdentity()
        try await worker.admit(identity)
        guard let identity else { throw BrowserSyncError.signedOut }
        let remote: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.remoteChangeArrived() } }
        if transport == nil {
            transport = try await Task.detached(priority: .utility) {
                try BrowserCloudKitTransport(destination: destination.appendingPathExtension("cloudkit"), identity: identity,
                                             onRemoteChange: remote)
            }.value
        }
        guard let transport else { return }
        let refresh = refreshRequested
        refreshRequested = false
        if refresh { lastRefresh = .now; await transport.requestRefresh() }
        status = .syncing
        let session = await environment.store.sessionDocument()
        do {
            if Date() >= historyRetryAfter {
                try await synchronizeHistory(environment, session: session, identity: identity, destination: destination)
                historyFailures = 0; historyRetryAfter = .distantPast
            }
        }
        catch BrowserSyncError.signedOut { throw BrowserSyncError.signedOut }
        catch BrowserSyncError.accountChanged { throw BrowserSyncError.accountChanged }
        catch {
            // A missing Production history type (or corrupt/unsupported history payload) must
            // fail closed for this zone without interrupting organization synchronization.
            await historyTransport?.stop(); historyTransport = nil
            historyFailures = min(historyFailures + 1, 6)
            historyRetryAfter = Date().addingTimeInterval(min(300, 5 * pow(2, Double(historyFailures))))
        }
        var deferred: (any Error)?
        do { try await synchronizePasswords(environment, session: session, identity: identity, destination: destination, refresh: refresh) }
        catch BrowserSyncError.signedOut { throw BrowserSyncError.signedOut }
        catch BrowserSyncError.accountChanged { throw BrowserSyncError.accountChanged }
        catch let error where BrowserSyncRetry.isTransient(error) {
            // Keep the password transport; retry with the runtime backoff after this cycle.
            deferred = error
        }
        catch {
            // Password schema/key/engine failures are isolated from the other sync zones.
            await stopPasswords()
        }
        let settings = await environment.settings.store.snapshot()
        var boostDocuments: [BrowserBoostDocument] = []
        for profile in session.profiles { boostDocuments.append(await (try environment.boosts.store(for: profile.id)).snapshot()) }
        var skillDocuments: [BrowserAISkillDocument] = []
        for profile in session.profiles { skillDocuments.append(await (try environment.skills.store(for: profile.id)).snapshot()) }
        let outgoing = try await worker.capture(.init(session: session, settings: settings, boosts: boostDocuments, skills: skillDocuments))
        guard enabled, !Task.isCancelled else { return }
        let incoming = try await transport.exchange(outgoing)
        guard enabled, !Task.isCancelled, !environment.isFinalizing, !environment.settingsRemovalIsRunning else { return }
        try await worker.merge(incoming, identity: transport.account())
        // Recapture immediately before publication; changes made while offline win by their
        // own stamp instead of being overwritten by a network snapshot.
        let current = await environment.store.sessionDocument()
        let currentSettings = await environment.settings.store.snapshot()
        var currentBoosts: [BrowserBoostDocument] = []
        for profile in current.profiles { currentBoosts.append(await (try environment.boosts.store(for: profile.id)).snapshot()) }
        var currentSkills: [BrowserAISkillDocument] = []
        for profile in current.profiles { currentSkills.append(await (try environment.skills.store(for: profile.id)).snapshot()) }
        let prepared = try await worker.prepare(.init(session: current, settings: currentSettings, boosts: currentBoosts, skills: currentSkills))
        let value = prepared.value
        if !prepared.changed {
            try await worker.acknowledge(prepared.projection)
            status = .synced(Date())
            if let deferred { throw deferred }
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
        for document in value.skills {
            let store = try environment.skills.store(for: document.profileID)
            let expected = currentSkills.first { $0.profileID == document.profileID } ?? BrowserAISkillDocument(profileID: document.profileID)
            try await store.applySync(document, expected: expected)
            await environment.skills.refresh(document.profileID)
        }
        await environment.settings.refresh()
        await environment.refreshSettingsCatalog()
        try await environment.saveNow()
        try await worker.acknowledge(prepared.projection)
        status = .synced(Date())
        if let deferred { throw deferred }
    }

    private func synchronizeHistory<Engine: BrowserEngine>(_ environment: BrowserEnvironment<Engine>,
        session: BrowserSessionDocument, identity: String, destination: URL) async throws {
        guard enabled, !environment.isPrivate else { return }
        if historyTransport == nil {
            historyTransport = try await Task.detached(priority: .utility) {
                try BrowserHistoryCloudKitTransport(destination: destination.appendingPathExtension("history.cloudkit"), identity: identity)
            }.value
        }
        guard let historyTransport else { return }
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

    private func stopPasswords() async {
        await passwords?.stop(); passwords = nil
        await passwordTransport?.stop(); passwordTransport = nil
    }

    private func synchronizePasswords<Engine: BrowserEngine>(_ environment: BrowserEnvironment<Engine>,
        session: BrowserSessionDocument, identity: String, destination: URL, refresh: Bool) async throws {
        guard enabled, !environment.isPrivate, let store = environment.engine.passwordStore else { return }
        if passwords == nil || passwordTransport == nil {
            let key = try await Task.detached(priority: .utility) { try BrowserPasswordSyncCache.systemKey() }.value
            let local: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.localStateChanged() } }
            let remote: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.remoteChangeArrived() } }
            let sync = try BrowserPasswordSync(cache: .init(destination: destination.appendingPathExtension("passwords.sealed"), key: key))
            await sync.setLocalChangeHandler(local)
            passwords = sync
            passwordTransport = try await Task.detached(priority: .utility) {
                try BrowserPasswordCloudKitTransport(
                    cache: .init(destination: destination.appendingPathExtension("passwords.cloudkit.sealed"), key: key), identity: identity,
                    onRemoteChange: remote)
            }.value
        }
        guard let passwords, let passwordTransport else { return }
        if refresh { await passwordTransport.requestRefresh() }
        try await passwords.synchronize(store: store, profiles: session.profiles.map(\.id), transport: passwordTransport) { [weak self, weak environment] in
            guard let self, let environment, enabled, !Task.isCancelled,
                  !environment.isFinalizing, !environment.settingsRemovalIsRunning else { throw BrowserSyncError.unavailable }
            let current = try await verifiedIdentity()
            try await worker?.admit(current)
            guard current == identity else { throw BrowserSyncError.accountChanged }
        }
    }

    deinit { task?.cancel() }
}
