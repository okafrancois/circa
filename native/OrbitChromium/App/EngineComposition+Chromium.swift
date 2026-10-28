import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Darwin
import Foundation

// Composition root of the Chromium product build of Orbit (CHROMIUM-APP): replaces
// `App/EngineComposition.swift`. See docs/native-port/chromium-app-2026-10-25.md.

typealias ActiveEngine = ChromiumBrowserEngine
typealias OrbitEnvironment = BrowserEnvironment<ActiveEngine>
typealias OrbitWindowController = BrowserWindowController<ActiveEngine>

/// Hosted Chrome-style tabs (D-chrome) on the patched CEF; Alloy on the stock SDK.
@MainActor
func makeActiveEngine() -> ActiveEngine {
    ChromiumBrowserEngine(persistence: .persistent, hostedWhenAvailable: true)
}

/// A separate engine instance uses the already-running runtime; it never starts or stops CEF.
@MainActor
func makePrivateEngine() -> ActiveEngine {
    ChromiumBrowserEngine(persistence: .ephemeral, hostedWhenAvailable: true)
}

/// Written once by `OrbitLauncher.run()` before the runtime and AppKit start, then only read.
nonisolated(unsafe) private var launchedConfiguration: OrbitProductConfiguration?

func activeSiteSessionConfiguration() -> OrbitProductConfiguration? { launchedConfiguration }

/// Session file used without `--session-file` or `--ephemeral`: `<data root>/session.json`.
func activeDefaultSessionFile() -> URL {
    if let launchedConfiguration { return launchedConfiguration.sessionFile }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return OrbitProductConfiguration.personalDataRoot(applicationSupport: support).appendingPathComponent("session.json")
}

/// A synthetic (mock Keychain) run keeps every session file inside its synthetic data root.
func activeSyntheticDataGuard() -> SyntheticDataGuard? { launchedConfiguration?.syntheticGuard }

/// The stable signing certificate's SHA-1, built in by CMake (`ORBIT_STABLE_SIGNING_ROOT`, from the
/// local identity's public `identity.json`); empty when the build had none: product mode refuses.
func activeDeveloperSigningTeam() -> String? { OrbitStableSigning.developerTeamID }

func activeStableSigningRoot() -> String? { OrbitStableSigning.rootSHA1.isEmpty ? nil : OrbitStableSigning.rootSHA1 }

/// Optional replacement of the product start-up (the hidden smoke build supplies one; the product
/// build's `ProductLaunchHooks.swift` returns nil).
@MainActor
protocol OrbitLaunchHooks: AnyObject {
    var runtimeSwitches: [String] { get }
    /// Prohibited activation policy, no Dock icon (hidden runs only).
    var hiddenApplication: Bool { get }
    /// Before CEF creates anything.
    func willStartRuntime(_ configuration: OrbitProductConfiguration)
    /// Replaces the product start-up once the runtime is ready.
    func runtimeDidBecomeReady(_ configuration: OrbitProductConfiguration)
}

/// CEF owns the message loop: the runtime starts before `NSApplication.shared` exists, then the
/// ready callback installs Orbit.
/// - Configuration: `OrbitProductConfiguration` from the arguments and Info.plist. Without either,
///   the personal data root and the real Keychain item `Orbit Safe Storage`.
/// - Cold launch: `ColdLaunchOpenQueue` owns the `GURL`/`odoc` handlers from before CEF starts and
///   hands queued requests to `application(_:open:)` once the delegate exists.
/// - Termination: the bridge's `ACRApplication terminate:` asks `applicationShouldTerminate` (session
///   save, surface release, `await engine.shutdown()`), quits the runtime only after the positive
///   reply, then `CefShutdown` runs and this process exits with the runtime status.
@MainActor
enum OrbitLauncher {
    private static var delegate: OrbitApplication?
    private static var finishedLaunching = false
    /// AppKit posted `didFinishLaunching`. The runtime can become ready before or after it; a
    /// delegate installed before it receives `applicationDidFinishLaunching` from AppKit.
    static var hasFinishedLaunching: Bool { finishedLaunching }

    /// Held for the life of the process: one running Orbit per data root.
    private static var dataRootLock: OrbitDataRootLock?

    static var siteSessionResult: ArcSiteSessionResult?
    static var siteSessionFailed = false

    static func run() {
        // A relaunch may exec faster than the parent releases its recovery/session locks.
        // Wait outside CEF and before opening the root, preserving the normal quit sequence.
        if let option = CommandLine.arguments.first(where: { $0.hasPrefix("--orbit-relaunch-parent=") }),
           let parent = Int32(option.dropFirst("--orbit-relaunch-parent=".count)), parent > 1, parent != getpid() {
            let deadline = Date().addingTimeInterval(30)
            while kill(parent, 0) == 0 {
                guard Date() < deadline else { exit(75) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        let configuration: OrbitProductConfiguration
        do {
            // Product admission first (nothing is created for a refused build), then the
            // directories, the exclusive data root lock and the synthetic session confinement.
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let prepared = try OrbitProductLaunch.prepare(arguments: CommandLine.arguments,
                                                         infoDictionary: Bundle.main.infoDictionary ?? [:],
                                                         applicationSupport: support, build: .current())
            configuration = prepared.0
            dataRootLock = prepared.1
            launchedConfiguration = configuration
        } catch is OrbitRecoveryFailure {
            FileHandle.standardError.write(Data("orbit: authentication recovery refused before runtime\n".utf8))
            exit(65)
        } catch {
            FileHandle.standardError.write(Data("orbit: \(error)\n".utf8))
            exit(64)
        }
        OrbitPerformanceProbe.pauseBeforeRuntime(configuration)
        do {
            guard let lock = dataRootLock else { throw OrbitRecoveryFailure.unsafeFilesystem }
            // Load-only root registration admission precedes every hook, CEF and restore.
            // Mock runs have no system storage fallback; untouched roots do not access it.
            try OrbitAuthenticationStartup.run(configuration: configuration, lock: lock) {
                processSiteSessionImport(configuration)
                startRuntime(configuration)
            }
        } catch {
            FileHandle.standardError.write(Data("orbit: authentication recovery refused before runtime\n".utf8))
            exit(65)
        }
    }

    private static func processSiteSessionImport(_ configuration: OrbitProductConfiguration) {
        let importer = ArcSiteSessionImport(dataRoot: configuration.dataRoot)
        do {
            if let data = try? Data(contentsOf: importer.pendingFile),
               let request = try? JSONDecoder().decode(ArcSiteSessionRequest.self, from: data),
               request.action == .importSessions,
               request.sourceRoot.standardizedFileURL == ArcSourceSnapshot.defaultSourceRoot.appendingPathComponent("User Data").standardizedFileURL,
               !NSRunningApplication.runningApplications(withBundleIdentifier: "company.thebrowser.Browser").isEmpty {
                throw ArcImportError.arcIsRunning
            }
            let keys: any ArcSiteSessionKeyProviding
            switch configuration.secureStorage {
            case .mockKeychain:
                // Synthetic source paths must stay outside personal Library locations too.
                if let data = try? Data(contentsOf: importer.pendingFile),
                   let request = try? JSONDecoder().decode(ArcSiteSessionRequest.self, from: data),
                   request.action == .importSessions {
                    try SyntheticDataGuard(syntheticRoot: request.sourceRoot, personalLocations: configuration.personalLocations).checkRoot()
                }
                keys = ArcSiteSessionFixtureKeys(dataRoot: configuration.dataRoot)
            case .keychain(let service, let account):
                keys = ArcSiteSessionKeychain(targetService: service, targetAccount: account)
            }
            siteSessionResult = try importer.consumePending(keys: keys)
        } catch {
            // Recovery must succeed before CEF opens the profile, even after an import error.
            do { try importer.recoverInterruptedImport(); try importer.cancelPending() }
            catch {
                FileHandle.standardError.write(Data("orbit: session backup restoration failed; files retained\n".utf8))
                exit(65)
            }
            siteSessionFailed = true
        }
    }

    private static func startRuntime(_ configuration: OrbitProductConfiguration) {
        ColdLaunchOpenQueue.shared.install()
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { OrbitLauncher.finishedLaunching = true } }
        let hooks = orbitLaunchHooks()
        hooks?.willStartRuntime(configuration)
        let options = productRuntimeOptions(configuration, extraSwitches: hooks?.runtimeSwitches ?? [],
                                            hiddenApplication: hooks?.hiddenApplication ?? false)
        let status = ChromiumRuntime.shared.run(options: options) {
            if let hooks {
                hooks.runtimeDidBecomeReady(configuration)
                return
            }
            let application = OrbitApplication()
            delegate = application
            OrbitPerformanceProbe.start(application: application, configuration: configuration)
            NSApplication.shared.delegate = application
            NSApplication.shared.setActivationPolicy(.regular)
            ColdLaunchOpenQueue.shared.deliver(to: application, application: NSApplication.shared)
            // AppKit calls it itself when it finishes launching after the runtime is ready.
            if finishedLaunching {
                application.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
            }
        }
        NotificationCenter.default.removeObserver(observer)
        // This flag is set only after both the session save and pending request succeed.
        // A bounded CEF shutdown can return a nonzero status after that durable save.
        if delegate?.wantsSiteSessionRelaunch == true {
            dataRootLock?.release()
            relaunchForSiteSessionImport()
        }
        withExtendedLifetime(hooks) { exit(status) }
    }

    private static func relaunchForSiteSessionImport() {
        let parent = getpid()
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let workspace = NSWorkspace.shared
        let existingProcesses = Set(workspace.runningApplications.map(\.processIdentifier))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--orbit-relaunch-parent=") }
            + ["--orbit-relaunch-parent=\(parent)"]
        let completed = DispatchSemaphore(value: 0)
        // LaunchServices owns the replacement independently of the terminating application.
        // Its completion runs on a concurrent queue, so it can signal after CEF's loop exits.
        workspace.openApplication(at: bundleURL, configuration: configuration) { application, error in
            if error != nil || application == nil || application?.processIdentifier == parent {
                FileHandle.standardError.write(Data("orbit: relaunch failed; import will run on next launch\n".utf8))
            }
            completed.signal()
        }
        // LaunchServices may defer its completion until the replacement finishes launching.
        // That process must first wait for this PID, so also accept its registered, live PID
        // as launch confirmation. Pump AppKit's loop so its running-app list stays current.
        let deadline = ContinuousClock.now + .seconds(10)
        while completed.wait(timeout: .now()) == .timedOut {
            if workspace.runningApplications.contains(where: {
                !existingProcesses.contains($0.processIdentifier) && $0.processIdentifier > 1 && !$0.isTerminated
                    && $0.bundleURL?.standardizedFileURL == bundleURL
            }) { return }
            guard ContinuousClock.now < deadline else {
                // Neither failure nor timeout consumes pending.json; manual launch can retry.
                FileHandle.standardError.write(Data("orbit: relaunch confirmation timed out; import remains scheduled\n".utf8))
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
