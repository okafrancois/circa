import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import BrowserShell
import ChromiumEngine
import Foundation

// Hidden smoke of the real Orbit composition on Chromium (CHROMIUM-APP). Compiled only into
// <build>/smoke/Orbit.app with the laboratory's HiddenGuard (never into the product). Launched by
// scripts/orbit-chromium-app.py with a synthetic data root inside its run root, the mock Keychain,
// a loopback fixture and the external CGWindowList witness. No window is ever ordered on screen:
// Orbit's windows are created by the real router and controllers with a presenter that does not
// show them, and HiddenGuard blocks and reports any ordering or activation.

@MainActor
func orbitLaunchHooks() -> OrbitLaunchHooks? { OrbitSmokeDriver.shared }

@MainActor
final class OrbitSmokeDriver: OrbitLaunchHooks {
    static let shared = OrbitSmokeDriver()

    enum Phase: String {
        /// Conformance of the hosted engine, then the scenarios on a fresh data root; quits normally.
        case fresh
        /// Restores the session written by the previous phase; quits normally.
        case restore
        /// Records a tab, waits for its session save, then kills itself (SIGKILL) without quitting.
        case crash
        /// The runner replaced the profile directories by files: the bridge refuses them. The
        /// session is still restored, the refused profile's tabs stay unavailable; quits normally.
        case refusedProfile = "refused-profile"
    }

    let arguments = CommandLine.arguments
    private(set) var runRoot: URL!
    private(set) var fixture: URL!
    private var phase = Phase.fresh
    private var extensionLoaded = false
    private var events: FileHandle?
    private var results: [[String: Any]] = []
    private(set) var finished = false
    private var application: OrbitApplication?
    private var configuration: OrbitProductConfiguration!
    private var signalSource: DispatchSourceSignal?
    private let started = ContinuousClock.now

    /// Chrome clones its own bundle with hard links (`CodeSignCloneManager`, feature
    /// `MacAppCodeSignClone`, chrome/browser/mac/code_sign_clone_manager.mm:513) so that an update
    /// replacing the bundle cannot break a running process; the kernel can then report the clone
    /// as the executable path, outside the path the witness attests. The product keeps it (it is
    /// replaced in place by its packager); the hidden smoke turns it off.
    var runtimeSwitches: [String] {
        ["--disable-features=MacAppCodeSignClone"] +
            (arguments.contains("--orbit-smoke-site-data") ? ["--use-fake-device-for-media-stream"] : [])
    }
    private var visibleSmoke: Bool {
        arguments.contains("--orbit-smoke-library-boost") || arguments.contains("--orbit-smoke-password-prompt") || arguments.contains("--orbit-smoke-password-generation") ||
            (arguments.contains("--orbit-smoke-extension-update") && arguments.contains("--orbit-smoke-extension-update-manual"))
            || arguments.contains("--orbit-smoke-passwords")
    }
    var hiddenApplication: Bool { !visibleSmoke }

    // MARK: Launch hooks

    func willStartRuntime(_ configuration: OrbitProductConfiguration) {
        func value(_ prefix: String) -> String? {
            arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        guard configuration.usesMockKeychain, let run = value("--orbit-smoke-run="), run.hasPrefix("/"),
              let origin = value("--orbit-smoke-fixture=").flatMap(URL.init(string:)), origin.host == "127.0.0.1",
              let phase = value("--orbit-smoke-phase=").flatMap(Phase.init(rawValue:)),
              // One marked run directory per smoke: a phase directory each, the data root shared.
              case let parent = URL(fileURLWithPath: run, isDirectory: true).deletingLastPathComponent(),
              OrbitProductConfiguration.isInside(configuration.dataRoot, parent),
              FileManager.default.fileExists(atPath: run + "/.orbit-chromium-lab"),
              FileManager.default.fileExists(atPath: parent.appendingPathComponent(".orbit-chromium-lab").path) else {
            FileHandle.standardError.write(Data("""
                orbit-smoke: requires --use-mock-keychain, --orbit-smoke-run=<marked phase directory>, \
                --orbit-smoke-fixture=<loopback origin>, --orbit-smoke-phase and a data root inside the marked run

                """.utf8))
            exit(64)
        }
        self.configuration = configuration
        runRoot = URL(fileURLWithPath: run, isDirectory: true)
        fixture = origin
        self.phase = phase
        extensionLoaded = arguments.contains { $0.hasPrefix("--load-extension=") }
        if arguments.contains("--orbit-smoke-private-domain"), extensionLoaded {
            FileHandle.standardError.write(Data("private smoke refuses extension activation\n".utf8))
            exit(64)
        }
        let eventsPath = runRoot.appendingPathComponent("events.jsonl").path
        if !FileManager.default.fileExists(atPath: eventsPath) {
            FileManager.default.createFile(atPath: eventsPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        events = FileHandle(forWritingAtPath: eventsPath)
        events?.seekToEndOfFile()
        HiddenGuard.shared.onEvent = { [weak self] name, detail in self?.event(name, detail) }
        HiddenGuard.shared.onViolation = { [weak self] kind, detail in
            self?.record("hidden.violation", "failed", ["kind": kind, "detail": detail.description])
            self?.finish(aborted: true)
        }
        if !visibleSmoke { HiddenGuard.shared.install() }
        // The witness and the runner end a run with SIGTERM: finish through the real termination.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { OrbitSmokeDriver.shared.finish(aborted: true) } }
        source.resume()
        signalSource = source
        event("smoke-start", ["phase": phase.rawValue, "extension": String(extensionLoaded)])
    }

    func runtimeDidBecomeReady(_ configuration: OrbitProductConfiguration) {
        if !visibleSmoke { HiddenGuard.shared.startMonitoring() }
        ChromiumRuntime.shared.trace = { name, fields in
            MainActor.assumeIsolated { OrbitSmokeDriver.shared.event("runtime-" + name, fields) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: nil) { _ in
            MainActor.assumeIsolated { OrbitSmokeDriver.shared.event("will-terminate", [:]) }
        }
        Task { await run() }
    }

    // MARK: Ledger

    func event(_ name: String, _ fields: [String: Any]) {
        var record: [String: Any] = fields
        record["event"] = name
        record["t"] = Double(Int((started.duration(to: .now) / .milliseconds(1)))) / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        events?.write(data + Data("\n".utf8))
    }

    func record(_ id: String, _ status: String, _ evidence: [String: Any] = [:]) {
        results.append(["id": id, "status": status, "evidence": evidence])
        event("result", ["id": id, "status": status])
    }

    func check(_ id: String, _ condition: Bool, _ evidence: [String: Any] = [:]) {
        record(id, condition ? "proven" : "failed", evidence)
    }

    private func writeResults(aborted: Bool) {
        // Hidden-mode audit in the laboratory's vocabulary (scripts/orbit-chromium-lab.py verdict).
        let guardSummary = HiddenGuard.shared
        let visibleWindows = NSApp.windows.filter { $0.isVisible || $0.occlusionState.contains(.visible) }.count
        if visibleSmoke {
            check((arguments.contains("--orbit-smoke-passwords") || arguments.contains("--orbit-smoke-password-prompt")) ? "passwords.visible-window" : arguments.contains("--orbit-smoke-library-boost") ? "library-boost.visible-window" : "update.visible-window", visibleWindows > 0, ["visibleWindows": visibleWindows])
        } else {
            check("hidden.monitor", guardSummary.ticks > 0 && guardSummary.violations.isEmpty,
                  ["ticks": guardSummary.ticks, "violations": guardSummary.violations.count])
            check("hidden.final-audit", visibleWindows == 0 && !NSApp.isActive && NSApp.keyWindow == nil
                  && guardSummary.blockedAttempts.isEmpty,
                  ["visibleWindows": visibleWindows, "blockedAttempts": guardSummary.blockedAttempts.count,
                   "appKitWindows": NSApp.windows.count])
        }
        let document: [String: Any] = [
            "phase": phase.rawValue, "aborted": aborted, "results": results,
            "hidden": HiddenGuard.shared.summary, "extensionLoaded": extensionLoaded,
            "dataRootInsideRun": true, "secureStorage": "mock-keychain"
        ]
        let url = runRoot.appendingPathComponent("results.json")
        if let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    /// Writes the results, tells the runner, then quits through the product termination path
    /// (`terminate:` → `applicationShouldTerminate` → session save, release, engine shutdown →
    /// reply → runtime quit → CefShutdown → exit).
    private func finish(aborted: Bool) {
        guard !finished else { return }
        finished = true
        writeResults(aborted: aborted)
        event("lab-finished", ["aborted": String(aborted)])
        if application == nil {
            ChromiumRuntime.shared.requestQuit()
            return
        }
        NSApp.terminate(nil)
        // A cancelled termination (for example a save error, whose alert HiddenGuard refuses)
        // must not leave the run alive: record it, then quit the runtime without the session.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            OrbitSmokeDriver.shared.event("termination-not-completed", [:])
            ChromiumRuntime.shared.requestQuit()
        }
    }

    // MARK: Helpers

    func page(_ name: String) -> URL { URL(string: "/page?case=\(name)", relativeTo: fixture)!.absoluteURL }

    func until<T>(_ seconds: Double, _ value: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline, !finished {
            if let value = value() { return value }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return value()
    }

    func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        await until(seconds) { condition() ? true : nil } ?? false
    }

    func identity(_ surface: ChromiumSurface?) -> [String: Any] {
        guard let surface, let identity = surface.tabIdentity else { return ["identity": "none"] }
        return ["tabID": Int(identity.tabID), "windowID": Int(identity.windowID), "index": Int(identity.index),
                "active": identity.isActive, "hosted": identity.isHosted,
                "style": surface.runtimeStyle == 2 ? "chrome" : surface.runtimeStyle == 1 ? "alloy" : "none"]
    }

    /// The committed selected document of `window`, once it shows `url`.
    func committed(_ window: OrbitWindowController, _ url: URL, _ seconds: Double = 15) async -> ChromiumSurface? {
        await until(seconds) {
            guard let surface = window.session.selectedSurface, surface.navigationState.committedURL == url,
                  !surface.navigationState.isLoading else { return nil }
            return surface
        }
    }

    /// URLs of the sidebar tabs (Today and Pinned, folders included) of a window's Space.
    /// EXT-OUTCOME-R1 viewport invariant on the actual product: the engine content view fills the
    /// host view exactly and the document's layout viewport (CSS px, zoom 100 %) equals the card
    /// width, initially, with the sidebar hidden and shown, and after a native window resize. A
    /// renderer that never reports a size while the window is unordered is recorded as partial.
    private func viewportGeometry(_ window: OrbitWindowController) async {
        let url = page("geometry")
        window.submitAddress(url.absoluteString)
        guard let tab = await committed(window, url) else {
            record("viewport.geometry", "failed", ["reason": "geometry fixture did not commit"])
            return
        }
        struct Sample { let inner, client, scroll, dpr: Int }
        func sample() -> Sample? {
            let parts = (tab.navigationState.title ?? "").split(separator: " ")
            guard parts.count == 5, parts[0] == "geom" else { return nil }
            let values = parts.dropFirst().compactMap { Int($0) }
            return values.count == 4 ? Sample(inner: values[0], client: values[1], scroll: values[2], dpr: values[3]) : nil
        }
        var stages: [[String: Any]] = []
        var allEqual = true, allReported = true
        func measure(_ stage: String) async {
            window.window?.contentView?.layoutSubtreeIfNeeded()
            let host = tab.hostView.bounds
            let content = tab.hostView.subviews.first?.frame
            let reported = await until(5) { sample().flatMap { $0.inner == Int(host.width.rounded()) ? $0 : nil } }
            let last = reported ?? sample()
            let fills = content == host
            let equal = fills && reported != nil && (reported?.scroll ?? .max) <= (reported?.client ?? 0)
            allEqual = allEqual && equal
            allReported = allReported && last != nil
            stages.append(["stage": stage, "hostWidth": Int(host.width.rounded()), "hostHeight": Int(host.height.rounded()),
                           "contentFillsHost": fills, "innerWidth": last?.inner ?? -1, "clientWidth": last?.client ?? -1,
                           "scrollWidth": last?.scroll ?? -1, "dpr100": last?.dpr ?? -1, "matched": equal])
        }
        await measure("initial")
        window.setSidebarVisible(false, animated: false)
        await measure("sidebar-hidden")
        window.setSidebarVisible(true, animated: false)
        await measure("sidebar-shown")
        if let native = window.window {
            let size = native.contentLayoutRect.size
            native.setContentSize(NSSize(width: max(640, size.width - 160), height: size.height))
            await measure("window-narrowed")
            native.setContentSize(size)
            await measure("window-restored")
        }
        record("viewport.geometry", allEqual ? "proven" : (allReported ? "failed" : "partial"), ["stages": stages])
    }

    private func sidebarURLs(_ window: OrbitWindowController) -> [URL] {
        func urls(_ items: [BrowserOrganizationItem]) -> [URL] {
            items.flatMap { item -> [URL] in
                switch item {
                case .tab(let tab): [tab.url]
                case .folder(let folder): urls(folder.children)
                case .split(let split): split.tabs.map(\.url)
                }
            }
        }
        guard let snapshot = window.session.organization else { return [] }
        return urls(snapshot.pinned) + urls(snapshot.today)
    }

    private func sessionContains(_ needle: String) -> Bool {
        guard let data = try? Data(contentsOf: configuration.sessionFile) else { return false }
        return String(decoding: data, as: UTF8.self).contains(needle)
    }

    // MARK: Run

    private func run() async {
        if arguments.contains("--orbit-smoke-last-tab-race") {
            await OrbitRelaunchScenarios.lastTabRace(fixture: fixture, record: record)
            finish(aborted: false)
            return
        }
        if phase == .fresh && !arguments.contains("--orbit-smoke-password-store") && !arguments.contains(where: { $0.hasPrefix("--orbit-smoke-daily-qa=") }) && !arguments.contains("--orbit-smoke-library-boost") && !arguments.contains("--orbit-smoke-password-prompt") && !arguments.contains("--orbit-smoke-boosts") && !arguments.contains("--orbit-smoke-password-generation") && !arguments.contains("--orbit-smoke-passwords") && !arguments.contains("--orbit-smoke-engine-r5") && !arguments.contains("--orbit-smoke-extension-only")
            && !arguments.contains("--orbit-smoke-relaunch") && !arguments.contains("--orbit-smoke-private-domain")
            && !arguments.contains("--orbit-smoke-profiles") && !arguments.contains("--orbit-smoke-site-data")
            && !arguments.contains("--orbit-smoke-space-profile") && !arguments.contains("--orbit-smoke-archive-auto")
            && !arguments.contains("--orbit-smoke-passwords") {
            if arguments.contains("--orbit-smoke-isolated-application") {
                // Supplemental lane only: the original conformance result remains separate.
                // No application assertion below is omitted or relaxed.
                record("conformance.separate-process", "partial", ["reason": "Run independently before this application lane"])
            } else { await conformance() }
        }
        guard !finished else { return }
        let engine = makeActiveEngine()
        engine.onSurfaceEvent = { name, fields in
            MainActor.assumeIsolated { OrbitSmokeDriver.shared.event("application-surface-" + name, fields) }
        }
        check("engine.hosted-mode", engine.surfaceMode == .hosted,
              ["patchLevel": Int(engine.patchLevel), "mode": "\(engine.surfaceMode)"])
        // CHROMIUM-APP-R3 (review MEDIUM 8): Safe Browsing cannot work without an API key; its
        // preference is off rather than claiming a protection.
        let globalSafeBrowsing = engine.safeBrowsingPreference(for: nil)
        check("safe-browsing.preference-off", globalSafeBrowsing == false && !engine.capabilities.contains(.safeBrowsing),
              ["global": globalSafeBrowsing.map { "\($0)" } ?? "unknown"])
        let environment: OrbitEnvironment
        do {
            environment = try await OrbitEnvironment.open(engine: engine, sessionFile: configuration.sessionFile)
        } catch {
            record("app.environment", "failed", ["error": String(describing: error)])
            finish(aborted: true)
            return
        }
        // The real application object, router and controllers; only the presenter differs from the
        // product start-up (`applicationDidFinishLaunching`), whose windows would be shown.
        let application = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        self.application = application
        // Hidden smoke accepts the warning through the same injectable presenter as the unit tests.
        application.confirmQuit = { .quit }
        // Installed before AppKit finished launching, the delegate would also receive the product
        // start-up (`applicationDidFinishLaunching`): a second environment and engine.
        let launched = await until(10) { OrbitLauncher.hasFinishedLaunching }
        check("app.after-appkit-launch", launched, [:])
        NSApp.delegate = application
        application.installMenus()
        ColdLaunchOpenQueue.shared.deliver(to: application, application: NSApp)
        let restored = environment.restoredWindowIDs
        if restored.isEmpty { application.windows.newWindow() }
        else { for id in restored { application.windows.newWindow(id: id.rawValue) } }
        let expectedWindows = max(1, restored.count)
        guard await until(20, { application.windows.windows.count >= expectedWindows }),
              let first = application.windows.windows.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }).first else {
            record("app.window", "failed", ["windows": application.windows.windows.count])
            finish(aborted: true)
            return
        }
        check("app.window", true, ["windows": application.windows.windows.count, "restored": restored.count])
        if arguments.contains("--orbit-smoke-password-store") {
            await OrbitPasswordStoreScenario.run(engine: engine, record: record)
            finish(aborted: false)
            return
        }
        if let daily = arguments.first(where: { $0.hasPrefix("--orbit-smoke-daily-qa=") }) {
            if daily.hasSuffix("=archive") {
                await OrbitRelaunchScenarios.session(application: application, environment: environment,
                    engine: engine, fixture: fixture, root: runRoot, restored: restored.count, restoring: false,
                    archiveRoundTrip: true, record: record)
            } else {
                await dailyFlowScenario(application, environment, first, engine, downloadsOnly: daily.hasSuffix("=downloads"))
            }
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-password-prompt") {
            await OrbitPasswordPromptScenario.run(window: first, fixture: fixture, root: runRoot, record: record)
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-library-boost") {
            await libraryBoostScenario(environment, first, engine)
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-boosts") {
            await boostScenarios(application, environment, first, engine)
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-passwords") {
            await OrbitPasswordScenario.run(application: application, environment: environment, window: first, fixture: fixture, root: runRoot, record: record)
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-archive-auto") {
            await OrbitArchiveAutoScenario.run(engine: engine, fixture: fixture, root: runRoot, record: record)
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-extension-update") {
            await OrbitExtensionUpdateScenario.run(environment: environment, window: first, fixture: fixture, record: record)
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-site-data") {
            await OrbitSiteDataScenarios.run(environment: environment, window: first, fixture: fixture, record: record)
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-space-profile") {
            await OrbitSpaceProfileScenario.run(environment: environment, window: first, fixture: fixture, record: record)
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-private-domain") {
            await OrbitPrivateDomainProbe.run(application: application, environment: environment, window: first, configuration: configuration,
                fixture: fixture, record: record)
            finish(aborted: false)
            return
        }
        if arguments.contains("--orbit-smoke-profiles"), phase == .fresh || phase == .restore {
            await OrbitProfileScenarios.run(application: application, environment: environment,
                fixture: fixture, restoring: phase == .restore, record: record)
        } else if arguments.contains("--orbit-smoke-relaunch") {
            await OrbitRelaunchScenarios.session(application: application, environment: environment,
                engine: engine, fixture: fixture, root: runRoot, restored: restored.count, restoring: phase == .restore, record: record)
        } else { switch phase {
        case .fresh: await fresh(application, first, engine)
        case .restore: await restore(application, engine, restored: restored.count)
        case .crash: await crash(first)
        case .refusedProfile: await refusedProfile(application, engine, restored: restored.count)
        } }
        finish(aborted: false)
    }

    /// `BrowserEngineConformance` on its own hosted engine instance, before the application starts.
    private func conformance() async {
        let engine = ChromiumBrowserEngine(persistence: .persistent, hostedWhenAvailable: true)
        engine.onSurfaceEvent = { name, fields in
            MainActor.assumeIsolated { OrbitSmokeDriver.shared.event("conformance-" + name, fields) }
        }
        let began = ContinuousClock.now
        let failures = await BrowserEngineConformance.check(engine)
        let seconds = Double(Int(began.duration(to: .now) / .milliseconds(1))) / 1000
        record("conformance.hosted", failures.isEmpty ? "proven" : "failed", [
            "failures": failures, "failureCount": failures.count, "seconds": seconds,
            "mode": "\(engine.surfaceMode)", "holdingWindowTabs": engine.holdingWindowTabCount,
            "shutdown": engine.shutdownOutcome.map { "\($0)" } ?? "none"])
    }

    private func navigationDiagnostic(_ stage: String, _ window: OrbitWindowController, _ engine: ChromiumBrowserEngine) {
        func details(_ surface: ChromiumSurface) -> [String: String] {
            ["object": String(describing: ObjectIdentifier(surface)), "profile": String(describing: surface.profileID),
             "browserID": String(surface.browserID), "hostedWindow": String(surface.hostedWindowToken),
             "ready": String(surface.isReady), "pending": String(surface.isCreationPending),
             "awaitingHosted": String(surface.awaitsHostedCreation), "failed": String(surface.creationFailed),
             "disposed": String(surface.isDisposed), "requestedURL": surface.currentURL?.absoluteString ?? "none",
             "committedURL": surface.navigationState.committedURL?.absoluteString ?? "none",
             "loading": String(surface.navigationState.isLoading)]
        }
        let selected = window.session.selectedSurface
        event("navigation-diagnostic", ["stage": stage, "acceptsCommands": window.acceptsCommands,
            "preparingTermination": window.isPreparingForTermination, "sessionClosed": window.session.isClosed,
            "profile": String(describing: window.session.activeProfileID), "engineShutDown": engine.isShutDown,
            "selectedSurfaceExists": selected != nil, "selected": selected.map(details) ?? [:],
            "owned": window.session.ownedSurfaces.map(details), "nativeTokens": engine.liveNativeTokens.sorted()])
    }

    private func fresh(_ application: OrbitApplication, _ window: OrbitWindowController, _ engine: ChromiumBrowserEngine) async {
        // Navigation from the address field; extension identity while the window holds one tab.
        let a = page(extensionLoaded ? "chrome-native-orbit-app" : "orbit-a")
        navigationDiagnostic("before-dispatch", window, engine)
        window.submitAddress(a.absoluteString)
        navigationDiagnostic("after-dispatch", window, engine)
        let diagnosticTask = Task { @MainActor in
            for index in 0..<30 {
                guard !Task.isCancelled, !self.finished else { return }
                self.navigationDiagnostic("poll-\(index)", window, engine)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { diagnosticTask.cancel() }
        guard let tab = await committed(window, a) else {
            navigationDiagnostic("failed", window, engine)
            record("navigation.address", "failed", ["selected": window.session.selectedSurface?.navigationState.committedURL?.absoluteString ?? "nil"])
            return
        }
        check("navigation.address", true, ["title": tab.navigationState.title ?? ""])
        let firstIdentity = tab.tabIdentity
        check("hosted.tab", firstIdentity?.isHosted == true && tab.runtimeStyle == 2 && engine.holdingWindowTabCount == 0
              && engine.hostedWindowCount == 1, identity(tab).merging(["holdingWindowTabs": engine.holdingWindowTabCount,
                                                                       "hostedWindows": engine.hostedWindowCount]) { $1 })
        if arguments.contains("--orbit-smoke-password-generation") {
            await passwordGenerationScenario(window, tab, engine)
            return
        }
        if arguments.contains("--orbit-smoke-passwords") {
            await passwordScenarios(window, tab, engine)
            return
        }
        if arguments.contains("--orbit-smoke-engine-r5") {
            await suspensionScenarios(window, tab, engine)
            return
        }
        if extensionLoaded { await extensionProbes(tab) }
        if arguments.contains("--orbit-smoke-engine-r4") {
            await runtimeStateScenarios(window, tab, engine)
        }
        // DBG-CH2: isolate worker startup and the normal product quit on a fresh profile.
        if arguments.contains("--orbit-smoke-extension-only") { return }

        guard !finished else { return }
        // History: second document, back, forward, reload.
        let b = page("orbit-b")
        window.submitAddress(b.absoluteString)
        let second = await committed(window, b)
        check("navigation.second-document", second === tab, ["title": tab.navigationState.title ?? ""])
        window.navigateBack()
        let back = await committed(window, a)
        window.navigateForward()
        let forward = await committed(window, b)
        let generation = tab.documentGeneration
        window.reload()
        let reloaded = await until(15) { tab.documentGeneration != generation && !tab.navigationState.isLoading }
        check("navigation.history", back != nil && forward != nil && reloaded,
              ["back": back != nil, "forward": forward != nil, "reload": reloaded, "canGoBack": tab.navigationState.canGoBack])

        // A failed main-frame navigation must display its attempted address, not the previous
        // document's origin. Exercise Chromium's real DNS error and the shell's address field.
        let unavailable = URL(string: "http://orbit-core-ux.invalid/")!
        var dnsFailed = false
        let previousEvents = tab.onEngineEvent
        tab.onEngineEvent = { name, fields in
            previousEvents?(name, fields)
            if name == "load-error", fields["url"] == unavailable.absoluteString { dnsFailed = true }
        }
        window.submitAddress(unavailable.absoluteString)
        let failed = await until(15) { dnsFailed && !tab.navigationState.isLoading }
        check("navigation.dns-visible-address", failed && window.addressField.stringValue == unavailable.absoluteString,
              ["failed": failed, "address": window.addressField.stringValue,
               "navigationURL": tab.navigationState.url?.absoluteString ?? "none"])
        tab.onEngineEvent = previousEvents
        window.submitAddress(b.absoluteString)
        check("navigation.dns-recovery", await committed(window, b) === tab)

        guard !finished else { return }
        // Tabs: a second tab is created in the same logical Browser and becomes the active one; the
        // first becomes active again when it is selected again.
        let c = page("orbit-c")
        window.openTab(url: c)
        let other = await committed(window, c)
        let otherActive = await until(5) { other?.tabIdentity?.isActive == true && tab.tabIdentity?.isActive == false }
        check("tabs.new-tab", other != nil && other !== tab && other?.tabIdentity?.windowID == firstIdentity?.windowID
              && otherActive, ["first": identity(tab), "second": identity(other)])
        if let occurrence = window.session.occurrenceID(for: tab) { window.session.selectOccurrence(occurrence) }
        let reselected = await until(5) { window.session.selectedSurface === tab && tab.tabIdentity?.isActive == true
                                          && other?.tabIdentity?.isActive == false }
        check("tabs.select-activates", reselected, ["first": identity(tab), "second": identity(other)])

        // Sidebar model: both live tabs are listed in the window's Space, with their destinations.
        let listed = sidebarURLs(window)
        check("sidebar.lists-tabs", listed.contains(b) && listed.contains(c), ["rows": listed.count])

        guard !finished else { return }
        await viewportGeometry(window)

        guard !finished else { return }
        // Find on a fixture with three needles.
        let findPage = page("find")
        window.submitAddress(findPage.absoluteString)
        if let found = await committed(window, findPage) {
            window.showFind()
            window.findSession.submit("needle", selectMatch: false)
            let state = await until(10) { window.findSession.state(for: found).flatMap { $0.hasExactCount ? $0 : nil } }
            check("find.count", state?.count == 3, ["count": state?.count ?? -1, "final": state?.isFinal ?? false])
            window.closeFind()
        } else {
            record("find.count", "failed", ["reason": "find fixture did not commit"])
        }

        // Zoom after commit (CONTRACT-R2): the shell's command reaches the committed document.
        window.changePageZoom(.increase)
        let zoomed = await until(5) { tab.pageZoom > 1.01 }
        let zoomFactor = tab.pageZoom
        window.changePageZoom(.reset)
        let reset = await until(5) { abs(tab.pageZoom - 1) < 0.001 }
        check("zoom.after-commit", zoomed && reset, ["zoomed": zoomFactor, "reset": tab.pageZoom])

        guard !finished else { return }
        // Peek: a hosted tab of the same window, dismissed back to the page.
        let peekURL = page("orbit-peek")
        if let peeked = window.openPeek(peekURL) {
            let shown = await until(15) { peeked.navigationState.committedURL == peekURL }
            let peekIdentity = peeked.tabIdentity
            check("peek.hosted-same-window", shown && peekIdentity?.isHosted == true
                  && peekIdentity?.windowID == tab.tabIdentity?.windowID, ["peek": identity(peeked)])
            window.dismissPeek(animated: false)
            let dismissed = await until(5) { !window.peek.isPresented }
            check("peek.dismiss", dismissed, [:])
        } else {
            record("peek.hosted-same-window", "failed", ["reason": "openPeek refused"])
        }

        // Palette over the real registry.
        window.palette.present(.newTab)
        await window.palette.waitForResults()
        let presented = window.palette.isPresented
        window.palette.dismiss()
        check("palette.present", presented && !window.palette.isPresented, ["presented": presented])

        // Page-first keyboard, shell side: a candidate key gets a receipt; with no key window (hidden
        // run) the declined key is dropped, never dispatched to a possibly different target.
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                        windowNumber: window.window?.windowNumber ?? 0, context: nil, characters: "[",
                                        charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33),
           case .page(let receipt?) = window.surface(tab, willSendKeyToPage: event) {
            let dispatched = window.surface(tab, pageDidNotHandleKey: event, receipt: receipt)
            let replay = window.surface(tab, pageDidNotHandleKey: event, receipt: receipt)
            check("keyboard.receipt-shell", !dispatched && !replay && receipt.isConsumed,
                  ["dispatched": dispatched, "secondUse": replay, "keyWindow": window.window?.isKeyWindow ?? false])
        } else {
            record("keyboard.receipt-shell", "failed", ["reason": "no receipt for a selected document"])
        }

        guard !finished else { return }
        // CH-ESSENTIALS: page-initiated surfaces through the real bridge (OrbitSmokeEssentials.swift).
        await essentials(application, window, home: tab, engine)

        guard !finished else { return }
        await favorites(window, selected: tab, background: other)

        guard !finished else { return }
        // A second window: its own logical Browser; live transfer is not offered on ABI 6.
        application.windows.newWindow()
        let opened = await until(20) { application.windows.windows.count >= 2 }
        if opened, let second = application.windows.windows.values.first(where: { $0 !== window }) {
            let d = page("orbit-d")
            second.submitAddress(d.absoluteString)
            let remote = await committed(second, d)
            check("windows.second-window", remote?.tabIdentity?.isHosted == true && engine.hostedWindowCount == 2
                  && remote?.tabIdentity?.windowID != tab.tabIdentity?.windowID,
                  ["first": identity(tab), "second": identity(remote), "hostedWindows": engine.hostedWindowCount])
            let canMove = window.canTransferSurface(tab, to: second)
            if engine.capabilities.contains(.liveSurfaceTransfer) {
                await liveTransfer(window, second, tab, other: other, remote: remote, engine)
            } else {
                record("windows.live-transfer", canMove ? "unexpected" : "not-supported",
                       ["liveSurfaceTransfer": false, "patchLevel": Int(engine.patchLevel),
                        "reason": "patched CEF side API v1 has no move between logical Browsers"])
            }
        } else {
            record("windows.second-window", "failed", ["windows": application.windows.windows.count])
        }

        // The session graph reaches the disk before quitting (the debounced save of the real app).
        let saved = await until(15) { sessionContains("orbit-c") && sessionContains("orbit-d") }
        check("session.saved-before-quit", saved, ["file": "session.json"])
        check("hosted.no-holding-window", engine.holdingWindowTabCount == 0, ["holdingWindowTabs": engine.holdingWindowTabCount])
    }

    // MARK: Live tab moves (CHROMIUM-APP-R2, side API v2 move_tab)

    private func moveEvents() -> [[String: Any]] {
        let report = runRoot.appendingPathComponent("reports/move-events.json")
        guard let data = try? Data(contentsOf: report),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object["events"] as? [[String: Any]] ?? []
    }

    private func liveState(_ surface: ChromiumSurface, _ engine: ChromiumBrowserEngine) async -> String? {
        try? await engine.conformanceProbe?.evaluateScript(
            "[document.getElementById('field').value, window.__orbitLive, performance.timeOrigin, history.length].join('|')",
            in: surface)
    }

    /// A tab moves to the second window's logical Browser and back without reloading: same
    /// surface, WebContents and extension tabId, form input and script state kept, extensions see
    /// tabs.onDetached/onAttached. A refused group move (one member cannot move) rolls the moved
    /// member back. The tab strip follows the sidebar order. A Split group moves as one.
    private func liveTransfer(_ window: OrbitWindowController, _ second: OrbitWindowController, _ tab: ChromiumSurface,
                              other: ChromiumSurface?, remote: ChromiumSurface?, _ engine: ChromiumBrowserEngine) async {
        let profileSafeBrowsing = engine.safeBrowsingPreference(for: tab.profileID)
        check("safe-browsing.profile-off", profileSafeBrowsing == false,
              ["profile": profileSafeBrowsing.map { "\($0)" } ?? "unknown"])
        let marker = "orbit-r2-\(UInt32.random(in: 100_000...999_999))"
        _ = try? await engine.conformanceProbe?.evaluateScript(
            "document.getElementById('field').value = '\(marker)'; window.__orbitLive = '\(marker)'; 1", in: tab)
        guard let before = await liveState(tab, engine), before.hasPrefix(marker + "|" + marker),
              let identity = tab.tabIdentity, let destinationWindow = remote?.tabIdentity?.windowID,
              let sourceWindowID = window.session.snapshot?.id, let destinationID = second.session.snapshot?.id else {
            record("windows.live-transfer", "failed", ["reason": "state or identities unavailable"])
            return
        }
        let url = tab.navigationState.committedURL

        // All or none: a group whose second member cannot move leaves the first where it was.
        let inert = InertSmokeDelegate()
        let refusing = engine.makeSurface(profileID: tab.profileID, delegate: inert)
        refusing.dispose()
        let refused = !engine.shellWillMoveSurfaces([tab, refusing], toWindow: destinationID)
        let unknown = !engine.shellWillMoveSurfaces([tab], toWindow: WindowID())
        let afterRefusal = tab.tabIdentity
        check("move.refused-rolls-back", refused && unknown && afterRefusal?.windowID == identity.windowID
              && afterRefusal?.tabID == identity.tabID && window.session.ownedSurfaces.contains { $0 === tab },
              ["refusedGroup": refused, "unknownWindow": unknown, "before": self.identity(tab)])

        let moved = await window.moveSurface(tab, to: second)?.value
        let after = await liveState(tab, engine)
        let movedIdentity = tab.tabIdentity
        check("move.live-to-second-window", moved != nil && second.session.ownedSurfaces.contains { $0 === tab }
              && movedIdentity?.windowID == destinationWindow && movedIdentity?.tabID == identity.tabID
              && movedIdentity?.isHosted == true && tab.navigationState.committedURL == url,
              ["before": ["tabID": Int(identity.tabID), "windowID": Int(identity.windowID)], "after": self.identity(tab),
               "destinationWindowID": Int(destinationWindow)])
        check("move.state-kept", after == before, ["formAndScriptKept": after?.hasPrefix(marker + "|" + marker) == true,
                                                  "sameDocument": after == before])
        if extensionLoaded {
            let events = await until(10) { () -> [[String: Any]]? in
                let all = self.moveEvents().filter { ($0["tabId"] as? Int) == Int(identity.tabID) }
                let detached = all.contains { $0["kind"] as? String == "detached" && ($0["windowId"] as? Int) == Int(identity.windowID) }
                let attached = all.contains { $0["kind"] as? String == "attached" && ($0["windowId"] as? Int) == Int(destinationWindow) }
                return detached && attached ? all : nil
            }
            check("move.extension-events", events != nil, ["events": events?.count ?? 0,
                  "kinds": events?.compactMap { $0["kind"] as? String } ?? []])
        }

        let back = await second.moveSurface(tab, to: window)?.value
        let returned = await liveState(tab, engine)
        check("move.back-to-first-window", back != nil && tab.tabIdentity?.windowID == identity.windowID
              && tab.tabIdentity?.tabID == identity.tabID && returned == before
              && window.session.ownedSurfaces.contains { $0 === tab }, ["after": self.identity(tab)])

        // Review M2: tab strip indices follow the sidebar order.
        let ordered = await until(5) { () -> [Int32]? in
            let organization = window.session.organization
            let surfaces = (organization?.favorites ?? []) + (organization?.pinned ?? []) + (organization?.today ?? [])
            let indices = surfaces.compactMap { item -> Int32? in
                guard case let .tab(entry) = item, let occurrence = entry.occurrenceID,
                      let surface = window.session.surface(for: occurrence) else { return nil }
                return surface.tabIdentity?.index
            }
            return indices.count >= 2 && indices == indices.sorted() && Set(indices).count == indices.count ? indices : nil
        }
        check("move.tab-order-mirrored", ordered != nil, ["indices": ordered?.map(Int.init) ?? []])

        // A Split group of two Today tabs moves as one, live (Favorites never enter a Split).
        _ = other
        func todayTab(_ name: String) async -> (ChromiumSurface, TabID)? {
            let url = page(name)
            window.openTab(url: url)
            guard let surface = await committed(window, url),
                  let occurrence = window.session.occurrenceID(for: surface),
                  let id = window.session.organization?.allTabs.first(where: { $0.occurrenceID == occurrence })?.id else { return nil }
            return (surface, id)
        }
        guard let left = await todayTab("orbit-split-left"), let right = await todayTab("orbit-split-right"),
              let leftIdentity = left.0.tabIdentity, let rightIdentity = right.0.tabIdentity else {
            record("move.split-group", "failed", ["reason": "two Today tabs unavailable"])
            return
        }
        _ = try? await engine.conformanceProbe?.evaluateScript(
            "document.getElementById('field').value = '\(marker)'; window.__orbitLive = '\(marker)'; 1", in: left.0)
        let leftBefore = await liveState(left.0, engine)
        window.session.selectTab(right.1)
        window.session.createSplit([left.1, right.1])
        guard let group = await until(10, { window.session.activeSplit }), group.tabs.count == 2 else {
            record("move.split-group", "failed", ["reason": "split not created"])
            return
        }
        let splitMoved = await window.moveSplitGroup(group.group, to: second)?.value
        let leftAfter = await liveState(left.0, engine)
        check("move.split-group", splitMoved?.count == 2 && left.0.tabIdentity?.windowID == destinationWindow
              && right.0.tabIdentity?.windowID == destinationWindow && left.0.tabIdentity?.tabID == leftIdentity.tabID
              && right.0.tabIdentity?.tabID == rightIdentity.tabID && leftBefore?.hasPrefix(marker + "|" + marker) == true
              && leftAfter == leftBefore && second.session.activeSplit?.tabs.count == 2,
              ["left": self.identity(left.0), "right": self.identity(right.0), "moved": splitMoved?.count ?? 0,
               "sourceWindow": sourceWindowID.rawValue.uuidString])

        await rollbacks(window, engine)
    }

    /// CHROMIUM-APP-R3 (review HIGH 3). A refused group move restores the moved member at its
    /// original index, and the only tab of a window back into that window's same logical Browser
    /// (held during the transfer, same extension window id); a committed move of a window's only
    /// tab lets its emptied Browser close once the move settled.
    private func rollbacks(_ window: OrbitWindowController, _ engine: ChromiumBrowserEngine) async {
        let inert = InertSmokeDelegate()
        func refusingMember(_ profile: ProfileID) -> ChromiumSurface {
            let surface = engine.makeSurface(profileID: profile, delegate: inert)
            surface.dispose()
            return surface
        }
        let ordered = window.session.ownedSurfaces.filter { $0.isBrowserCreated }
        guard let middle = ordered.first(where: { $0.tabIdentity?.index == 1 }), let identity = middle.tabIdentity,
              let destination = application?.windows.windows.values.first(where: { $0 !== window }),
              let destinationID = destination.session.snapshot?.id else {
            record("rollback.restores-index", "failed", ["reason": "no tab at index 1 or no second window"])
            return
        }
        let refused = !engine.shellWillMoveSurfaces([middle, refusingMember(middle.profileID)], toWindow: destinationID)
        check("rollback.restores-index", refused && middle.tabIdentity?.index == 1
              && middle.tabIdentity?.windowID == identity.windowID && middle.tabIdentity?.tabID == identity.tabID,
              ["before": ["index": Int(identity.index), "windowID": Int(identity.windowID)], "after": self.identity(middle)])

        // A third window holding one tab.
        let known = Set(application?.windows.windows.keys.map { $0 } ?? [])
        application?.windows.newWindow()
        guard await until(20, { (self.application?.windows.windows.count ?? 0) > known.count }),
              let third = application?.windows.windows.first(where: { !known.contains($0.key) })?.value else {
            record("rollback.only-tab-same-browser", "failed", ["reason": "third window not opened"])
            return
        }
        let url = page("orbit-only-tab")
        third.submitAddress(url.absoluteString)
        guard let only = await committed(third, url), let onlyIdentity = only.tabIdentity,
              let thirdID = third.session.snapshot?.id, let firstID = window.session.snapshot?.id else {
            record("rollback.only-tab-same-browser", "failed", ["reason": "only tab not loaded"])
            return
        }
        let onlyRefused = !engine.shellWillMoveSurfaces([only, refusingMember(only.profileID)], toWindow: firstID)
        check("rollback.only-tab-same-browser", onlyRefused && only.tabIdentity?.windowID == onlyIdentity.windowID
              && only.tabIdentity?.index == onlyIdentity.index && engine.logicalBrowserCount(for: thirdID) == 1
              && third.session.ownedSurfaces.contains { $0 === only },
              ["before": ["windowID": Int(onlyIdentity.windowID)], "after": self.identity(only),
               "thirdWindowBrowsers": engine.logicalBrowserCount(for: thirdID)])

        let moved = await third.moveSurface(only, to: window)?.value
        let closed = await until(10) { engine.logicalBrowserCount(for: thirdID) == 0 }
        check("rollback.committed-only-tab-closes-source", moved != nil && only.tabIdentity?.windowID == window.session.selectedSurface?.tabIdentity?.windowID
              && closed, ["after": self.identity(only), "thirdWindowBrowsers": engine.logicalBrowserCount(for: thirdID)])
        // The emptied window is closed, as a user would: later phases restore the other two.
        third.window?.close()
        _ = await until(10) { self.application?.windows.windows.count == known.count }
    }

    /// DAILY-1 P1 (SIGABRT): Add to Favorites on Chromium-backed tabs with a valid loopback PNG.
    /// The selected tab, a background tab, then a Peek opened as a tab; each through the session
    /// operation of the sidebar's "Add to Favorites" command.
    private func favorites(_ window: OrbitWindowController, selected: ChromiumSurface, background: ChromiumSurface?) async {
        func tabID(_ surface: ChromiumSurface?) -> TabID? {
            guard let surface, let occurrence = window.session.occurrenceID(for: surface) else { return nil }
            return window.session.organization?.allTabs.first { $0.occurrenceID == occurrence }?.id
        }
        func add(_ id: String, _ surface: ChromiumSurface?) async {
            guard let surface, let tab = tabID(surface) else {
                record(id, "failed", ["reason": "no tab for the surface"])
                return
            }
            let icon = await until(10) { surface.navigationState.faviconURL }
            window.session.addToFavorites([tab])
            let listed = await until(10) { window.favorites.grid.items.contains { $0.tab.id == tab } }
            // The pipeline resolves asynchronously; its completion is where the conflict was.
            try? await Task.sleep(for: .milliseconds(750))
            window.favorites.render()
            try? await Task.sleep(for: .milliseconds(250))
            check(id, listed && icon != nil && !finished && window.favorites.grid.items.contains { $0.tab.id == tab },
                  ["listed": listed, "faviconScheme": icon?.scheme ?? "none",
                   "favorites": window.favorites.grid.items.count, "identity": identity(surface)])
        }
        await add("favorites.add-selected-tab", selected)
        await add("favorites.add-background-tab", background)
        let peekURL = page("orbit-peek-tab")
        guard let peeked = window.openPeek(peekURL), await until(15, { peeked.navigationState.committedURL == peekURL }),
              let adoption = window.promotePeekToTab(), await adoption.value != nil else {
            record("favorites.add-peek-tab", "failed", ["reason": "Peek did not become a tab"])
            return
        }
        await add("favorites.add-peek-tab", peeked)
        // Leave the original tab selected for the following scenarios.
        if let occurrence = window.session.occurrenceID(for: selected) { window.session.selectOccurrence(occurrence) }
        _ = await until(5) { window.session.selectedSurface === selected }
    }

    /// CHROMIUM-APP-R2 (review of DBG-CH): a profile whose `profile-<uuid>` directory became a file
    /// is refused by the bridge (`CanonicalChild`); launch and restoration go on. The user sees
    /// the restored windows and their sidebar tabs; the refused profile's documents never load
    /// (empty content, navigations reported as failed) instead of a crash at restore.
    private func refusedProfile(_ application: OrbitApplication, _ engine: ChromiumBrowserEngine, restored: Int) async {
        let windows = Array(application.windows.windows.values)
        check("refused.profile-recorded", !engine.refusedProfiles.isEmpty, ["refusedProfiles": engine.refusedProfiles.count])
        check("refused.windows-restored", restored >= 1 && windows.count == restored, ["windows": windows.count, "restored": restored])
        let listed = windows.map { sidebarURLs($0).count }
        check("refused.sidebar-tabs-kept", listed.allSatisfy { $0 > 0 }, ["sidebarTabsPerWindow": listed])
        let unavailable = await until(10) {
            windows.allSatisfy { window in window.session.selectedSurface.map { $0.creationFailed && !$0.isReady } ?? false }
        }
        check("refused.documents-unavailable", unavailable, [
            "selectedCreationFailed": windows.map { $0.session.selectedSurface?.creationFailed ?? false },
            "liveNativeTokens": engine.liveNativeTokens.count])
    }

    private func restore(_ application: OrbitApplication, _ engine: ChromiumBrowserEngine, restored: Int) async {
        let windows = application.windows.windows.values
        let crashMarker = page("orbit-crash")
        var restoredURLs: [String] = []
        for window in windows {
            if let url = await until(15, {
                window.session.selectedSurface.flatMap { surface in
                    surface.navigationState.isLoading ? nil : surface.navigationState.committedURL
                }
            }) { restoredURLs.append(url.absoluteString) }
        }
        check("restore.windows", restored >= 1 && windows.count == restored, ["windows": windows.count, "restored": restored])
        check("restore.selected-documents", restoredURLs.count == windows.count && restoredURLs.allSatisfy { $0.hasPrefix(fixture.absoluteString) },
              ["documents": restoredURLs.count])
        // Registrations follow the asynchronous restoration of each window; wait for them (bounded).
        _ = await until(5) { engine.hostedWindowCount == windows.count }
        let hosted = windows.compactMap(\.session.selectedSurface).allSatisfy { $0.tabIdentity?.isHosted == true }
        let perWindow: [[String: Any]] = windows.map { window in
            let surface = window.session.selectedSurface
            let modelWindow = surface?.placement.windowID
            return ["engineWindows": window.engineWindowIDs.count,
                    "placementWindow": modelWindow?.rawValue.uuidString ?? "none",
                    "announced": window.engineWindowIDs.map(\.rawValue.uuidString),
                    "placementMatchesWindow": modelWindow.map { window.engineWindowIDs.contains($0) } ?? false,
                    "registeredToken": modelWindow.flatMap { engine.hostedWindowToken(for: $0) }.map { Int($0) } ?? -1,
                    "tabWindowToken": Int(surface?.tabIdentity?.windowToken ?? 0),
                    "tabs": window.session.ownedSurfaces.count, "identity": identity(surface)]
        }
        check("restore.hosted", hosted && engine.hostedWindowCount == windows.count && engine.holdingWindowTabCount == 0,
              ["hostedWindows": engine.hostedWindowCount, "holdingWindowTabs": engine.holdingWindowTabCount,
               "registrations": engine.hostedWindowRegistrations,
               "profiles": engine.profileCount, "windows": perWindow])
        // The three favorites of the fresh phase come back; the selected one is a live Chromium
        // tab whose icon goes through the favicon pipeline again.
        let favorites = await until(10) {
            windows.map { $0.favorites.grid.items.count }.max().flatMap { $0 >= 3 ? $0 : nil }
        }
        try? await Task.sleep(for: .milliseconds(750))
        check("restore.favorites", favorites != nil && !finished,
              ["favorites": windows.map { $0.favorites.grid.items.count }])
        if arguments.contains("--orbit-smoke-expect-crash-tab") {
            let found = windows.contains { sidebarURLs($0).contains(crashMarker) }
            check("crash.session-survived", found, ["marker": "orbit-crash"])
        }
    }

    private func crash(_ window: OrbitWindowController) async {
        let marker = page("orbit-crash")
        window.openTab(url: marker)
        let shown = await committed(window, marker) != nil
        let saved = await until(15) { sessionContains("orbit-crash") }
        check("crash.saved-before-kill", shown && saved, [:])
        writeResults(aborted: false)
        event("crash-kill", [:])
        // No termination path: the next phase must restore from what the debounced save wrote.
        kill(getpid(), SIGKILL)
    }

    /// The 19 EngineGate MV3 probes from a hosted tab of the real application window.
    private func extensionProbes(_ tab: ChromiumSurface) async {
        let report = runRoot.appendingPathComponent("reports/chrome-native-orbit-app.json")
        // The runner may allow a larger observation window for an explicitly slowed synthetic
        // probe under resource pressure. It never changes the extension's own API deadlines.
        let prefix = "--orbit-smoke-extension-timeout="
        let requested = arguments.first { $0.hasPrefix(prefix) }.flatMap { Int($0.dropFirst(prefix.count)) }
        let seconds = requested.flatMap { (25...180).contains($0) ? Double($0) : nil } ?? 25
        let arrived = await until(seconds) { FileManager.default.fileExists(atPath: report.path) }
        var evidence: [String: Any] = ["reportArrived": arrived]
        guard arrived, let data = try? Data(contentsOf: report),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let probes = object["results"] as? [[String: Any]] else {
            record("extensions.mv3-probes", "failed", evidence)
            return
        }
        let failed = probes.filter { ($0["passed"] as? Bool) != true }
        let context = object["tabContext"] as? [String: Any]
        let identity = tab.tabIdentity
        let matches = (context?["tabID"] as? NSNumber)?.int32Value == identity?.tabID
            && (context?["windowID"] as? NSNumber)?.int32Value == identity?.windowID
        evidence["passed"] = probes.count - failed.count
        evidence["total"] = probes.count
        evidence["failedProbes"] = failed.map { "\($0["name"] ?? "?")" }
        evidence["identityMatchesBridge"] = matches
        record("extensions.mv3-probes", failed.isEmpty && probes.count == 19 && matches ? "proven" : "failed", evidence)
    }
}

/// Delegate of a surface the smoke creates only to make a group move refuse; it never loads.
@MainActor
final class InertSmokeDelegate: BrowserEngineSurfaceDelegate {
    func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidRequestClose(_ surface: ChromiumSurface) {}
    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.cancel) }
    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
}
