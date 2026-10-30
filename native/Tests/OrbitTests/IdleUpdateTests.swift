import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite("Unattended updates and developer routes")
@MainActor
struct IdleUpdateTests {
    private func updater() throws -> OrbitUpdater {
        let defaults = try #require(UserDefaults(suiteName: "orbit.test.idle-update.\(UUID())"))
        return OrbitUpdater(defaults: defaults)
    }

    @Test("Active input and unknown or playing media veto every unattended state")
    func admission() {
        for idle in [0.0, 4, 5, 299, 300, 900] {
            for locked in [false, true] {
                for screensaver in [false, true] {
                    for media in [false, true] {
                        let signals = OrbitIdleUpdateSignals(idleSeconds: idle, screensaver: screensaver, locked: locked, mediaPlaying: media)
                        #expect(signals.permitsInstallation == (idle >= 5 && !media && (idle >= 300 || locked || screensaver)))
                    }
                }
            }
        }
        #expect(!OrbitIdleUpdateSignals(idleSeconds: .nan, locked: true, mediaPlaying: false).permitsInstallation)
        #expect(!OrbitIdleUpdateSignals(idleSeconds: .infinity, locked: true, mediaPlaying: false).permitsInstallation)
        #expect(!OrbitIdleUpdateSignals().permitsInstallation)
    }

    @Test("A fake driver remains queued through activity and media, then retries once idle")
    func rescheduling() async throws {
        let updater = try updater()
        var signals = OrbitIdleUpdateSignals(idleSeconds: 0, mediaPlaying: false)
        var media = false, installs = 0
        updater.idleSignals = { signals }
        updater.mediaPreventsAutomaticInstallation = { media }
        updater.fetchLatestVersion = { "27" }
        updater.installPendingUpdate = { installs += 1 }
        updater.prepared(version: "27")
        await updater.attemptAutomaticInstallation()
        #expect(installs == 0)
        signals.idleSeconds = 600; signals.mediaPlaying = true
        await updater.attemptAutomaticInstallation()
        #expect(installs == 0)
        signals.mediaPlaying = false; media = true
        await updater.attemptAutomaticInstallation()
        #expect(installs == 0)
        media = false
        await updater.attemptAutomaticInstallation()
        #expect(installs == 1 && updater.isRestartingForUpdate && updater.permitsAutomaticTermination)
        await updater.attemptAutomaticInstallation()
        #expect(installs == 1)
        signals.idleSeconds = 0
        #expect(!updater.permitsAutomaticTermination)
        updater.cancelAutomaticRelaunch()
        signals.idleSeconds = 600
        await updater.attemptAutomaticInstallation()
        #expect(installs == 2)
    }

    @Test("Input arriving during asynchronous validation defers installation")
    func activityDuringValidation() async throws {
        let updater = try updater()
        var signals = OrbitIdleUpdateSignals(idleSeconds: 600, mediaPlaying: false)
        var installs = 0
        updater.idleSignals = { signals }
        updater.mediaPreventsAutomaticInstallation = { signals.idleSeconds = 0; return false }
        updater.fetchLatestVersion = { "27" }
        updater.installPendingUpdate = { installs += 1 }
        updater.prepared(version: "27")
        await updater.attemptAutomaticInstallation()
        #expect(installs == 0 && !updater.automaticRelaunchRequested)
    }

    @Test("A disabled preference, missing media provider or unavailable freshness never installs")
    func failClosed() async throws {
        let domain = "orbit.test.idle-update." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let updater = OrbitUpdater(defaults: defaults)
        var installs = 0
        updater.idleSignals = { .init(idleSeconds: 600, mediaPlaying: false) }
        updater.installPendingUpdate = { installs += 1 }
        updater.prepared(version: "27")
        await updater.attemptAutomaticInstallation()
        updater.fetchLatestVersion = { "27" }
        await updater.attemptAutomaticInstallation()
        updater.mediaPreventsAutomaticInstallation = { false }
        updater.setAutomaticallyUpdates(false)
        await updater.attemptAutomaticInstallation()
        #expect(installs == 0)
    }

    @Test("Locked and screensaving sessions use the same fake installer", arguments: [true, false])
    func unattended(locked: Bool) async throws {
        let updater = try updater()
        var installs = 0
        updater.idleSignals = { .init(idleSeconds: 10, screensaver: !locked, locked: locked, mediaPlaying: false) }
        updater.mediaPreventsAutomaticInstallation = { false }
        updater.fetchLatestVersion = { "27" }
        updater.installPendingUpdate = { installs += 1 }
        updater.prepared(version: "27")
        await updater.attemptAutomaticInstallation()
        #expect(installs == 1)
    }

    @Test("What's new matches the existing release command and targets exactly the running version")
    func releaseNotes() throws {
        let row = BrowserPaletteResult(id: "release", title: "Release Notes", detail: "", section: .commands,
            action: .command(.releaseNotes), searchAliases: BrowserDailyCommands.aliases(.releaseNotes))
        for query in ["What's new", "what’s new", "See What’s New"] {
            #expect(BrowserPaletteRanking.commandScore(query, result: row) != nil)
        }
        #expect(OrbitApplication().makeCommandSystem().registry.isImplemented(.releaseNotes))
        #expect(OrbitReleaseNotes.runningVersionURL(info: ["CFBundleShortVersionString": "1.2.3"])?.absoluteString
            == "https://github.com/okafrancois/orbit-browser/releases/tag/v1.2.3")
        for version in ["", "1.2", "1.2.3/other", "fixture.20261030"] {
            #expect(OrbitReleaseNotes.runningVersionURL(info: ["CFBundleShortVersionString": version]) == nil)
        }
    }

    @Test("About version text identifies the packaged Chromium build")
    func versionStrings() {
        #expect(BrowserSettingsAbout.versionDescription(info: ["CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "123", "OrbitChromiumVersion": "156.0.8078.80"])
            == "Version 1.2.3 (123) · Chromium 156.0.8078.80")
        #expect(!BrowserSettingsAbout.versionDescription(info: [:]).contains("Chromium"))
    }

    @Test("Unsupported diagnostic commands stay disabled instead of opening a blocked internal URL")
    func diagnosticRefusal() {
        let registry = OrbitApplication().makeCommandSystem().registry
        for id: BrowserCommandID in [.openTaskManager, .recordTrace] {
            #expect(!registry.isImplemented(id))
            #expect(!registry.isEnabled(id))
        }
        #expect(!BrowserNavigationPolicy.isChromiumSettingsURL(URL(string: "chrome://tracing")!))
        #expect(!BrowserNavigationPolicy.isChromiumSettingsURL(URL(string: "chrome://task-manager")!))
    }

    @Test("Control-D remains the default Developer Mode shortcut and accepts a saved remap")
    func controlD() throws {
        let definition = try #require(OrbitCommandCatalog.definitions.first { $0.id == .toggleDeveloperMode })
        let preferences = BrowserShortcutPreferences()
        #expect(preferences.bindings(for: definition) == [.init(key: "d", modifiers: [.control])])
        let custom = BrowserShortcut(key: "d", modifiers: [.control, .option, .shift])
        try preferences.setShortcut(custom, for: .toggleDeveloperMode, definitions: OrbitCommandCatalog.definitions)
        #expect(preferences.bindings(for: definition) == [custom])
    }
}
