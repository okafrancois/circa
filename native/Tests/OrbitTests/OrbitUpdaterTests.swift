import Foundation
import Testing
@testable import Orbit

@Suite("Updater admission without network")
struct OrbitUpdaterTests {
    @Test("Updater starts once after the first window transaction commits")
    @MainActor
    func firstWindowOrdering() {
        let app = OrbitApplication()
        var commit: (@MainActor () -> Void)?
        var events: [String] = []
        app.afterWindowCommit = { commit = $0 }
        app.onUpdaterStart = { events.append("updater") }
        #expect(events.isEmpty)
        app.presentAndScheduleUpdates { events.append("window") }
        #expect(events == ["window"])
        commit?()
        #expect(events == ["window", "updater"])
        commit = nil
        app.presentAndScheduleUpdates { events.append("second-window") }
        #expect(commit == nil)
        #expect(events == ["window", "updater", "second-window"])
    }

    @Test("Nightly opt-in persists and defaults to the stable channel")
    @MainActor
    func nightlyPreference() {
        let suite = "nightly-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = OrbitUpdater(defaults: defaults)
        #expect(updater.allowedUpdateChannels.isEmpty)
        updater.setReceivesNightlyBuilds(true)
        #expect(OrbitUpdater(defaults: defaults).allowedUpdateChannels == ["nightly"])
        updater.setReceivesNightlyBuilds(false)
        #expect(OrbitUpdater(defaults: defaults).allowedUpdateChannels.isEmpty)
    }

    @Test("Opting out and quitting cancel a staged installer only once")
    @MainActor
    func nightlyCancellationOnQuit() async {
        let suite = "nightly-quit-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "OrbitReceiveNightlyBuilds")
        let updater = OrbitUpdater(defaults: defaults)
        updater.fetchLatestVersion = { "2" }
        updater.prepared(version: "2")
        var cancellations = 0
        updater.discardPendingUpdate = {
            cancellations += 1
            try? await Task.sleep(for: .milliseconds(20))
        }
        updater.setReceivesNightlyBuilds(false)
        updater.setReceivesNightlyBuilds(true)
        updater.setReceivesNightlyBuilds(false)
        await updater.prepareForQuit()
        #expect(cancellations == 1)
        #expect(updater.pendingVersion == nil)
        #expect(updater.readyVersion == nil)
        #expect(updater.allowedUpdateChannels.isEmpty)
    }

    private var production: [String: Any] { [
        "SUPublicEDKey": Data(repeating: 42, count: 32).base64EncodedString(),
        "SUFeedURL": "https://github.com/example/browser/releases/download/update-feed/appcast.xml"
    ] }

    @Test("Missing keys and ordinary synthetic bundles never start an updater")
    func disabledTests() {
        #expect(OrbitUpdatePolicy.permits(info: production, synthetic: false, arguments: []) == true)
        #expect(OrbitUpdatePolicy.permits(info: production, synthetic: true, arguments: []) == false)
        var info = production
        for key in ["", "invalid", Data(repeating: 1, count: 31).base64EncodedString()] {
            info["SUPublicEDKey"] = key
            #expect(!OrbitUpdatePolicy.permits(info: info, synthetic: false, arguments: []))
        }
        #expect(!OrbitUpdatePolicy.permits(info: production, synthetic: false, arguments: ["--use-mock-keychain"]))
        #expect(!OrbitUpdatePolicy.permits(info: production, synthetic: false, arguments: ["--ephemeral"]))
    }

    @Test("Only an explicitly isolated updater E2E can use the loopback feed")
    func loopbackException() {
        var info = production
        info.merge(["CFBundleIdentifier": "io.github.okatech.orbit.test.update", "OrbitSyntheticBundle": true,
                    "OrbitUseMockKeychain": true, "OrbitUpdaterLocalTest": true,
                    "SUFeedURL": "http://127.0.0.1:12345/appcast.xml"]) { _, new in new }
        #expect(OrbitUpdatePolicy.permits(info: info, synthetic: true, arguments: []))
        #expect(!OrbitUpdatePolicy.permits(info: info, synthetic: false, arguments: []))
        info["SUFeedURL"] = "https://github.com/appcast.xml"
        #expect(!OrbitUpdatePolicy.permits(info: info, synthetic: true, arguments: []))
        info["SUFeedURL"] = "http://localhost:12345/appcast.xml"
        #expect(!OrbitUpdatePolicy.permits(info: info, synthetic: true, arguments: []))
    }
}
