import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// Runtime-free admission, also used by tests that must never create a Sparkle updater.
enum OrbitUpdatePolicy {
    static func permits(info: [String: Any], synthetic: Bool, arguments: [String]) -> Bool {
        guard let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32,
              let text = info["SUFeedURL"] as? String, let feed = URL(string: text) else { return false }
        if synthetic {
            // The release E2E is the only test allowed to contact an updater feed (loopback only).
            return info["OrbitUpdaterLocalTest"] as? Bool == true
                && info["OrbitSyntheticBundle"] as? Bool == true
                && info["OrbitUseMockKeychain"] as? Bool == true
                && info["CFBundleIdentifier"] as? String == "io.github.okatech.orbit.test.update"
                && feed.scheme == "http" && feed.host == "127.0.0.1"
                && feed.port != nil && feed.user == nil && feed.password == nil
        }
        return info["OrbitSyntheticBundle"] as? Bool != true
            && info["OrbitUpdaterLocalTest"] as? Bool != true
            && !arguments.contains("--ephemeral")
            && !arguments.contains(where: { $0.hasPrefix("--use-mock-keychain") })
            && feed.scheme == "https"
    }
}

@MainActor
protocol OrbitAutomaticUpdateTarget: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var updateCheckInterval: TimeInterval { get set }
}

#if canImport(Sparkle)
extension SPUUpdater: OrbitAutomaticUpdateTarget {}
#endif

@MainActor
final class OrbitUpdater: NSObject, ObservableObject {
    private let defaults: UserDefaults
    private var defaultsObservation: AnyCancellable?
    var requiresFreshCheck: Bool { defaults.bool(forKey: "OrbitUpdateNeedsFreshCheck") }
    func markPendingCancellation() { defaults.set(true, forKey: "OrbitUpdateNeedsFreshCheck") }
    static let checkInterval: TimeInterval = 3600
    @Published private(set) var readyVersion: String?
    private(set) var pendingVersion: String?
    private var newestVersion: String?
    private var freshnessTimer: Timer?
    private var isQuitting = false
    private var idleTimer: Timer?
    private var automaticAttemptInProgress = false
    private(set) var automaticRelaunchRequested = false
    var idleSignals: (() -> OrbitIdleUpdateSignals)?
    var mediaPreventsAutomaticInstallation: (() async -> Bool)?

    var permitsAutomaticTermination: Bool {
        !automaticRelaunchRequested || (automaticallyUpdates && idleSignals?().permitsInstallation == true)
    }

    func cancelAutomaticRelaunch() {
        automaticRelaunchRequested = false
        isRestartingForUpdate = false
        #if canImport(Sparkle)
        installing = false
        #endif
    }

    /// Repeated ticks reschedule a blocked update without consuming its installer callback.
    func attemptAutomaticInstallation() async {
        guard !automaticAttemptInProgress, !automaticRelaunchRequested, !isQuitting,
              automaticallyUpdates, pendingVersion != nil, let installPendingUpdate,
              idleSignals?().permitsInstallation == true else { return }
        automaticAttemptInProgress = true
        defer { automaticAttemptInProgress = false }
        let revision = pendingRevision
        guard await validatePendingUpdate(),
              await mediaPreventsAutomaticInstallation?() == false,
              pendingRevision == revision, pendingVersion != nil, !isQuitting,
              automaticallyUpdates, idleSignals?().permitsInstallation == true else { return }
        automaticRelaunchRequested = true
        isRestartingForUpdate = true
        installPendingUpdate()
    }

    private func scheduleIdleInstallation() {
        guard idleTimer == nil else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.attemptAutomaticInstallation() }
        }
    }
    private(set) var isRestartingForUpdate = false
    private var pendingRevision: UInt64 = 0
    private var refreshTask: (revision: UInt64, task: Task<Bool, Never>)?
    // Injected seams exercise the same freshness gate without starting Sparkle.
    var fetchLatestVersion: (() async throws -> String)?
    var discardPendingUpdate: (() async -> Void)?
    var downloadLatestUpdate: (() -> Void)?
    var installPendingUpdate: (() -> Void)?

    func prepared(version: String) {
        // Each installer owns its validation, even when callbacks repeat a version.
        pendingRevision &+= 1
        pendingVersion = version
        readyVersion = nil
        Task { _ = await validatePendingUpdate() }
    }

    @discardableResult
    func validatePendingUpdate(forQuit: Bool = false) async -> Bool {
        guard let pending = pendingVersion else { return true }
        let revision = pendingRevision
        if let refreshTask, refreshTask.revision == revision { return await refreshTask.task.value }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            do {
                guard let fetchLatestVersion else { return false }
                let latest = try await fetchLatestVersion()
                guard pendingRevision == revision, pendingVersion == pending else { return false }
                newestVersion = latest
                if latest.compare(pending, options: .numeric) == .orderedDescending {
                    readyVersion = nil
                    await discardPendingUpdate?()
                    guard pendingRevision == revision, pendingVersion == pending else { return false }
                    pendingVersion = nil
                    record("stale-replaced")
                    record(forQuit || isQuitting ? "deferred-for-quit" : "replacement-requested")
                    if !forQuit && !isQuitting { downloadLatestUpdate?() }
                    return false
                }
                guard latest == pending else { throw URLError(.badServerResponse) }
                readyVersion = pending
                record("ready-verified")
                return true
            } catch {
                guard pendingRevision == revision, pendingVersion == pending else { return false }
                readyVersion = nil
                // Never silently install an unverifiable cached update on quit.
                if forQuit {
                    await discardPendingUpdate?()
                    guard pendingRevision == revision, pendingVersion == pending else { return false }
                    pendingVersion = nil
                }
                record("freshness-unavailable")
                return false
            }
        }
        refreshTask = (revision, task)
        let result = await task.value
        if refreshTask?.revision == revision { refreshTask = nil }
        return result
    }

    func restartToUpdate() {
        Task {
            guard await validatePendingUpdate() else { return }
            installPendingUpdate?()
        }
    }

    func prepareForQuit() async {
        // The restart action just passed the freshness gate before invoking Sparkle.
        guard !isRestartingForUpdate else { return }
        isQuitting = true
        _ = await validatePendingUpdate(forQuit: true)
        // A concurrent card refresh might have failed without cancelling the installer.
        if pendingVersion != nil && readyVersion == nil {
            await discardPendingUpdate?()
            pendingVersion = nil
        }
    }

    static func showsCard(ready: String?, synthetic: Bool, forced: Bool,
                          standalone: Bool, isPrivate: Bool) -> Bool {
        ready != nil && (!synthetic || forced) && !standalone && !isPrivate
    }
    /// Sparkle owns this preference, including changes made in its update alert. Using its key
    /// also keeps the switch persistent in synthetic bundles without constructing an updater.
    @Published private(set) var automaticallyUpdates: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyUpdates = defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true
        super.init()
        defaultsObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadPreference() }
            }
    }

    private func reloadPreference() {
        automaticallyUpdates = defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool ?? true
    }

    func setAutomaticallyUpdates(_ enabled: Bool) {
        defaults.set(enabled, forKey: "SUAutomaticallyUpdate")
        #if canImport(Sparkle)
        if let updater = sparkleUpdater {
            // This switch controls installation, never the availability notifications.
            Self.applyAutomaticallyUpdates(enabled, to: updater)
        }
        #endif
        reloadPreference()
    }

    static func applyAutomaticallyUpdates(_ enabled: Bool, to target: any OrbitAutomaticUpdateTarget) {
        target.updateCheckInterval = checkInterval
        target.automaticallyChecksForUpdates = true
        target.automaticallyDownloadsUpdates = enabled
    }

    #if canImport(Sparkle)
    private var sparkleUpdater: SPUUpdater?
    private var userDriver: OrbitUpdateUserDriver?
    private var discarding = false
    private var installing = false
    private var extractingVersion: String?
    private var replacing = false
    private var replacementRetries = 0
    private var discardCompletion: CheckedContinuation<Void, Never>?
    #endif
    private var isLocalTest = false

    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        sparkleUpdater?.canCheckForUpdates ?? false
        #else
        false
        #endif
    }

    func start(synthetic: Bool) {
        #if canImport(Sparkle)
        guard sparkleUpdater == nil, OrbitUpdatePolicy.permits(info: Bundle.main.infoDictionary ?? [:],
            synthetic: synthetic, arguments: CommandLine.arguments) else { return }
        isLocalTest = Bundle.main.object(forInfoDictionaryKey: "OrbitUpdaterLocalTest") as? Bool == true
        if isLocalTest {
            if CommandLine.arguments.contains("--update-test-light") { NSApp.appearance = NSAppearance(named: .aqua) }
            if CommandLine.arguments.contains("--update-test-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        }
        let driver = OrbitUpdateUserDriver(hostBundle: .main, delegate: nil)
        driver.owner = self
        userDriver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        sparkleUpdater = updater
        updater.httpHeaders = ["Cache-Control": "no-cache"]
        fetchLatestVersion = {
            guard let url = updater.feedURL else { throw URLError(.badURL) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try OrbitUpdateFeed.latestVersion(data: data)
        }
        discardPendingUpdate = { [weak self] in
            guard let self else { return }
            await withCheckedContinuation { continuation in
                discardCompletion = continuation
                discarding = true
                markPendingCancellation()
                updater.checkForUpdates()
            }
        }
        downloadLatestUpdate = { [weak self] in
            self?.replacing = true
            self?.replacementRetries = 0
            // Start after the cancelled installer's completion has unwound. The public
            // user-initiated check also clears Sparkle's superseded-version skip marker.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.record(updater.sessionInProgress ? "replacement-busy" : "replacement-idle")
                updater.checkForUpdates()
            }
        }
        installPendingUpdate = { [weak self] in
            self?.installing = true
            updater.checkForUpdates()
        }
        do {
            Self.applyAutomaticallyUpdates(automaticallyUpdates, to: updater)
            try updater.start()
            if requiresFreshCheck {
                // A previous internal cancellation must not become a permanent user skip.
                // Sparkle clears its skip markers on this public, fresh-check path.
                replacing = automaticallyUpdates
                updater.checkForUpdates()
            } else { updater.checkForUpdatesInBackground() }
            freshnessTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in _ = await self?.validatePendingUpdate() }
            }
            record("started")
        } catch {
            sparkleUpdater = nil
            record("start-failed")
        }
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        guard canCheckForUpdates else { return }
        sparkleUpdater?.checkForUpdates()
        #endif
    }

    private func record(_ event: String) {
        guard isLocalTest else { return }
        // Fixed events only: no feed URLs, navigation, paths or error descriptions.
        print("orbit-updater event=\(event) time=\(Date().timeIntervalSince1970)")
        fflush(stdout)
    }
}

#if canImport(Sparkle)
extension OrbitUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        record("ready-on-quit")
        prepared(version: item.versionString)
        installPendingUpdate = { [weak self] in
            self?.installing = true
            immediateInstallHandler()
        }
        scheduleIdleInstallation()
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        if !discarding {
            readyVersion = nil; pendingVersion = nil
            replacing = false; installing = false; cancelAutomaticRelaunch()
        }
        record("aborted")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        record("cycle-finished")
        if discarding {
            discarding = false
            let completion = discardCompletion
            discardCompletion = nil
            completion?.resume()
            if completion == nil && replacing {
                // Cancellation is asynchronous in Sparkle's installer process. If a new
                // cycle resumed that old installer, skip it again before fetching a feed.
                replacementRetries += 1
                guard replacementRetries <= 20 else { replacing = false; return }
                Task {
                    try? await Task.sleep(for: .milliseconds(100))
                    updater.checkForUpdates()
                }
            }
        }
    }

    fileprivate func found(_ item: SUAppcastItem, state: SPUUserUpdateState,
                           reply: @escaping (SPUUserUpdateChoice) -> Void) -> Bool {
        record(state.stage == .installing ? "found-installing" : "found-update")
        if discarding { reply(.skip); return true }
        if replacing && state.stage == .installing && item.versionString != newestVersion {
            discarding = true
            markPendingCancellation()
            reply(.skip)
            return true
        }
        if installing && state.stage == .installing {
            installing = false
            reply(.install)
            return true
        }
        if state.stage == .installing {
            extractingVersion = item.versionString
            ready(reply: reply)
            return true
        }
        if state.stage == .notDownloaded { defaults.removeObject(forKey: "OrbitUpdateNeedsFreshCheck") }
        if replacing && !item.isInformationOnlyUpdate {
            reply(.install)
            return true
        }
        return false
    }

    fileprivate var suppressesProgress: Bool { replacing || discarding || installing }
    fileprivate func ready(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("ready-to-install")
        replacing = false
        if installing { installing = false; reply(.install); return }
        // Keep Sparkle's installer cancellable through the public user-driver reply.
        installPendingUpdate = { [weak self] in self?.installing = true; reply(.install) }
        discardPendingUpdate = { [weak self] in
            guard let self else { return }
            await withCheckedContinuation { continuation in
                discardCompletion = continuation
                discarding = true
                markPendingCancellation()
                reply(.skip)
            }
        }
        if let extractingVersion { prepared(version: extractingVersion) }
        scheduleIdleInstallation()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isRestartingForUpdate = true
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        extractingVersion = item.versionString
    }
}

@MainActor
private final class OrbitUpdateUserDriver: SPUStandardUserDriver {
    weak var owner: OrbitUpdater?
    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if owner?.found(appcastItem, state: state, reply: reply) == true { return }
        super.showUpdateFound(with: appcastItem, state: state, reply: reply)
    }
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner?.ready(reply: reply)
    }
    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if owner?.suppressesProgress != true { super.showUserInitiatedUpdateCheck(cancellation: cancellation) }
    }
    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if owner?.suppressesProgress != true { super.showDownloadInitiated(cancellation: cancellation) }
    }
}
#endif
