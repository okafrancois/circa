import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct QuickWindowLifecycleTests {
    @Test("Two external URLs own separate windows and a normalized repeat resurfaces the original document")
    func externalReuse() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        var presented: [WindowID] = []
        app.quickWindowPresenter = { presented.append($0.id) }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        let a = URL(string: "https://SYNTHETIC.test:443")!, b = URL(string: "https://synthetic.test/second")!
        app.application(NSApp, open: [a, b, URL(string: "https://synthetic.test/")!])
        await app.waitForQuickWindowCommands()
        #expect(environment.quickWindows.count == 2 && presented.count == 3)
        #expect(presented.first == presented.last && presented[0] != presented[1])
        let first = try #require(environment.quickWindows[presented[0]])
        let surface = try #require(first.surface)
        surface.navigate(to: URL(string: "https://synthetic.test/redirected")!)
        app.application(NSApp, open: [a])
        await app.waitForQuickWindowCommands()
        #expect(environment.quickWindows.count == 2 && first.surface === surface)
        #expect(surface.currentURL?.path == "/redirected")
        first.window?.close()
        app.application(NSApp, open: [a])
        await app.waitForQuickWindowCommands()
        #expect(environment.quickWindows.count == 2 && presented.last != first.id)
    }

    @Test("Injected time expires only old Little windows at the six-hour boundary")
    func autoArchiveTiming() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        environment.quickWindowClock = { now }
        defer { environment.retireQuickWindows() }
        let (_, profile) = try await environment.initialContext.value
        environment.engine.persistentProfiles.insert(profile)
        let old = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.test/old")!)
        now.addTimeInterval(3600)
        let young = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.test/young")!)
        now.addTimeInterval(5 * 3600 - 1)
        await environment.sweepQuickWindowArchives()
        #expect(!old.isClosed && !young.isClosed)
        now.addTimeInterval(1)
        await environment.sweepQuickWindowArchives()
        #expect(old.isClosed && !young.isClosed)
        let record = try #require(await environment.store.sessionDocument().organization.archive.first)
        #expect(record.id == old.archiveID && record.isLittleWindow && record.reason == .automatic && record.archivedAt == now)
        #expect(record.tab.createdAt == now.addingTimeInterval(-6 * 3600))
        await environment.sweepQuickWindowArchives()
        #expect(await environment.store.sessionDocument().organization.archive.count == 1)
        try await environment.settings.setQuickWindowArchiveThreshold(.oneHour)
        await environment.sweepQuickWindowArchives()
        #expect(young.isClosed && environment.quickWindowArchiveTimer == nil)
    }

    @Test("Promotion preparation and termination prevent timeout from taking a live document")
    func protectedTransitions() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        environment.quickWindowClock = { now }
        defer { environment.retireQuickWindows() }
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.test/transition")!)
        now.addTimeInterval(6 * 3600)
        #expect(little.beginPromotionPreparation())
        await environment.sweepQuickWindowArchives()
        #expect(!little.isClosed)
        little.endPromotionPreparation()
        await environment.sweepQuickWindowArchives()
        #expect(little.isClosed)
    }

    @Test("A failed session write leaves an expired document open and retries its archive once")
    func archiveWriteFailure() async throws {
        let canonical = try #require(realpath(NSTemporaryDirectory(), nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical)).appendingPathComponent("little-archive-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json")
        let engine = PeekSyntheticEngine()
        let environment = try await BrowserEnvironment.open(engine: engine, sessionFile: file)
        let (_, profile) = try await environment.initialContext.value
        engine.persistentProfiles.insert(profile)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        environment.quickWindowClock = { now }
        var failures = 0
        environment.onPersistenceError = { _ in failures += 1 }
        defer { environment.retireQuickWindows() }
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.test/retry")!)
        // The synthetic destination becomes a directory; the writer must refuse it.
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        now.addTimeInterval(6 * 3600)
        await environment.sweepQuickWindowArchives()
        #expect(!little.isClosed && little.acceptsCommands && failures > 0)
        try FileManager.default.removeItem(at: file)
        await environment.sweepQuickWindowArchives()
        #expect(little.isClosed)
        let saved = try BrowserSessionFileStore().load(from: file)
        #expect(saved.organization.archive.filter { $0.id == little.archiveID }.count == 1)
        try await environment.historyRecorder.close()
    }

    @Test("The timeout setting publishes all three supported choices independently of Today policy")
    func intervalSetting() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let (_, profile) = try await environment.initialContext.value
        #expect(BrowserQuickWindowArchiveSettings.choices.map(BrowserQuickWindowArchiveSettings.title) == ["1 hour", "6 hours", "12 hours"])
        for value in BrowserQuickWindowArchiveSettings.choices {
            try await environment.settings.setQuickWindowArchiveThreshold(value)
            #expect(environment.settings.document.quickWindowArchiveThreshold == value)
        }
        #expect(await environment.store.archivePolicy().threshold(for: profile) == .twelveHours)
    }

    @Test("Remembered profiles preselect later external links on that host and stale profiles fall back")
    func profilePreselection() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let (home, original) = try await environment.initialContext.value
        defer { environment.retireQuickWindows() }
        let other = await environment.store.createProfile(name: "Synthetic Other")
        let space = try await environment.store.createSpace(name: "Synthetic Other", profileID: other)
        try await environment.settings.store.rememberQuickWindowProfile(for: URL(string: "https://synthetic.test/first")!, profileID: other)
        await environment.settings.refresh()
        let little = try await environment.makeExternalQuickWindow(url: URL(string: "https://synthetic.test/second")!, spaceID: home, profileID: original)
        #expect(little.profileID == other && little.sourceSpaceID == space)
        let unrelated = try await environment.makeExternalQuickWindow(url: URL(string: "https://sub.synthetic.test/second")!, spaceID: home, profileID: original)
        #expect(unrelated.profileID == original)
        let missing = ProfileID()
        try await environment.settings.store.rememberQuickWindowProfile(for: URL(string: "https://synthetic.test/")!, profileID: missing)
        await environment.settings.refresh()
        let fallback = try await environment.makeExternalQuickWindow(url: URL(string: "https://synthetic.test/third")!, spaceID: home, profileID: original)
        #expect(fallback.profileID == original)
    }
}
}
