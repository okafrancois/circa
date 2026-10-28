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
}

#if canImport(Sparkle)
extension SPUUpdater: OrbitAutomaticUpdateTarget {}
#endif

@MainActor
final class OrbitUpdater: NSObject, ObservableObject {
    private let defaults: UserDefaults
    private var defaultsObservation: AnyCancellable?
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
        #if canImport(Sparkle)
        if let updater = controller?.updater {
            // This switch controls installation, never the availability notifications.
            Self.applyAutomaticallyUpdates(enabled, to: updater)
        } else { defaults.set(enabled, forKey: "SUAutomaticallyUpdate") }
        #else
        defaults.set(enabled, forKey: "SUAutomaticallyUpdate")
        #endif
        reloadPreference()
    }

    static func applyAutomaticallyUpdates(_ enabled: Bool, to target: any OrbitAutomaticUpdateTarget) {
        target.automaticallyChecksForUpdates = true
        target.automaticallyDownloadsUpdates = enabled
    }

    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    #endif
    private var isLocalTest = false

    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        controller?.updater.canCheckForUpdates ?? false
        #else
        false
        #endif
    }

    func start(synthetic: Bool) {
        #if canImport(Sparkle)
        guard controller == nil, OrbitUpdatePolicy.permits(info: Bundle.main.infoDictionary ?? [:],
            synthetic: synthetic, arguments: CommandLine.arguments) else { return }
        isLocalTest = Bundle.main.object(forInfoDictionaryKey: "OrbitUpdaterLocalTest") as? Bool == true
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do {
            try controller.updater.start()
            if controller.updater.automaticallyChecksForUpdates {
                controller.updater.checkForUpdatesInBackground()
            }
            record("started")
        } catch {
            self.controller = nil
            record("start-failed")
        }
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
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
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        record("aborted")
    }
}
#endif
