import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

private final class ArchiveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

extension NativeWebKitTests {
@Suite("Native archive integration", .serialized)
@MainActor
struct NativeArchiveTests {
    @Test("Registry reopen restores original identity exactly once and consumes the archive")
    func duplicateFreeReopen() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { environment.autoArchive.scheduler.stop(); router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow()
        await router.waitForPendingCommands()
        let controller = try #require(router.selectedWindowID.flatMap { router.windows[$0] })
        controller.session.openTab(url: URL(string: "https://archive.test/reopen")!)
        await controller.session.waitForPendingCommands()
        let id = try #require(controller.session.organization?.selectedTab?.id)
        #expect(environment.autoArchive.scheduler.isRunning)
        #expect(registry.dispatch(.archiveTab, origin: .keyboard))
        await controller.session.waitForPendingCommands()
        #expect(controller.session.organization?.archivedTabCount == 1)
        #expect(await controller.session.archivedTabs().value.map(\.id) == [id])
        #expect(registry.dispatch(.restoreLastClosedTab, origin: .keyboard))
        await controller.session.waitForPendingCommands()
        #expect(controller.session.organization?.selectedTab?.id == id)
        #expect(controller.session.organization?.archivedTabCount == 0)
        #expect(await controller.session.archivedTabs().value.isEmpty)
        #expect(!registry.dispatch(.restoreLastClosedTab, origin: .keyboard))
        #expect(controller.session.snapshot?.tabs.filter { $0.id == id }.count == 1)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Archive restores to its source Space with its title and rejects another profile")
    func restorationDestinationAndIsolation() async throws {
        let store = BrowserStore()
        let personal = await store.createProfile(name: "Synthetic A")
        let work = await store.createProfile(name: "Synthetic B")
        let home = try await store.createSpace(name: "Home", profileID: personal)
        let second = try await store.createSpace(name: "Second", profileID: personal)
        let office = try await store.createSpace(name: "Office", profileID: work)
        let window = try await store.createWindow(activeSpaceID: home)
        let occurrence = try await store.openTab(url: URL(string: "https://archive.test/title")!, from: store.captureContext(in: window), activate: true)
        let id = try #require(await store.sessionDocument().tabs.first { $0.occurrenceID == occurrence }?.id)
        _ = try await store.renameTab(id, to: "Synthetic title", from: store.captureContext(in: window))
        _ = try await store.archiveTabs([id], from: store.captureContext(in: window))
        try await store.activateSpace(office, in: window)
        #expect(try await store.archivedTabs(from: store.captureContext(in: window)).isEmpty)
        do {
            _ = try await store.restoreArchivedTab(id, activate: true, from: store.captureContext(in: window))
            Issue.record("Cross-profile restore was accepted")
        } catch BrowserOrganizationError.notVisibleInContext {}
        try await store.activateSpace(second, in: window)
        #expect(try await store.archivedTabs(from: store.captureContext(in: window), matching: "TITLE").map(\.id) == [id])
        let state = try await store.restoreArchivedTab(id, activate: true, from: store.captureContext(in: window))
        #expect(state.snapshot.activeSpaceID == home)
        #expect(state.organization.selectedTab?.id == id)
        #expect(state.organization.selectedTab?.customTitle == "Synthetic title")
    }

    @Test("Wired clock protects audible and unknown media in inactive Spaces, plus the visible tab")
    func scheduledProtection() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let clock = ArchiveClock()
        let store = BrowserStore(clock: { clock.now })
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Home", profileID: profile)
        let engine = SiteSyntheticEngine()
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: space, engine: engine,
            onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        controller.session.openTab(url: URL(string: "https://archive.test/idle")!)
        controller.session.openTab(url: URL(string: "https://archive.test/audible")!)
        controller.session.openTab(url: URL(string: "https://archive.test/visible")!)
        await controller.session.waitForPendingCommands()
        try #require(engine.surfaces.first { $0.currentURL?.path == "/idle" }).media = .init(playback: .paused, isAudible: false)
        let idle = try #require(controller.session.snapshot?.tabs.first { $0.url.path == "/idle" }?.id)
        try #require(engine.surfaces.first { $0.currentURL?.path == "/visible" }).media = .init()
        let otherSpace = try await store.createSpace(name: "Second", profileID: profile)
        controller.session.refreshCatalog()
        controller.session.activateSpace(otherSpace)
        controller.session.openTab(url: URL(string: "https://archive.test/second-visible")!)
        await controller.session.waitForPendingCommands()
        try #require(engine.surfaces.first { $0.currentURL?.path == "/second-visible" }).media = .init(playback: .paused, isAudible: false)
        let runtime = BrowserArchiveRuntime<SiteSyntheticSurface>(store: store, launchGrace: 0,
            uptime: { clock.now.timeIntervalSinceReferenceDate }, wallClock: { clock.now })
        runtime.register(controller.session)
        clock.advance(12 * 3600 - 1)
        #expect(await runtime.scheduler.sweep().isEmpty)
        clock.advance(1)
        #expect(await runtime.scheduler.sweep().map(\.id) == [idle])
        controller.session.synchronizeOrganization()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.tabs.count == 1)
        #expect(await store.sessionDocument().tabs.count == 4)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Delayed settings and destructive confirmation cannot migrate to another profile")
    func capturedProfileActions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.session.close(); controller.window?.close() }
        let original = try #require(controller.session.activeProfileID)
        controller.session.setAutoArchiveThreshold(.sevenDays, inProfile: original)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.organization?.autoArchiveThreshold == .sevenDays)
        let other = await environment.store.createProfile(name: "Synthetic other")
        let space = try await environment.store.createSpace(name: "Other", profileID: other)
        controller.session.refreshCatalog()
        controller.session.activateSpace(space)
        controller.session.setAutoArchiveThreshold(.thirtyDays, inProfile: original)
        controller.session.clearArchive(inProfile: original)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.activeProfileID == other)
        #expect(controller.session.organization?.autoArchiveThreshold == .twelveHours)
        controller.session.activateSpace(try #require(controller.session.catalog?.spaces.first { $0.profileID == original }?.id))
        await controller.session.waitForPendingCommands()
        #expect(controller.session.organization?.autoArchiveThreshold == .sevenDays)
        let restored = try BrowserStore(restoring: await environment.store.sessionDocument())
        let policy = await restored.sessionDocument().organization.archivePolicy
        #expect(policy.threshold(for: original) == .sevenDays)
    }

    @Test("Embedded archive searches records and clears old rows immediately on profile changes")
    func embeddedArchiveSearchAndProfileChange() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let controller = try await environment.makeWindow()
        defer { environment.autoArchive.scheduler.stop(); controller.session.close(); controller.window?.close() }
        controller.session.openTab(url: URL(string: "https://archive.test/needle")!)
        await controller.session.waitForPendingCommands()
        controller.session.closeSelectedTab()
        controller.showArchive()
        await controller.session.waitForPendingCommands()
        await controller.archive.task?.value
        #expect(controller.archive.view.rows.count == 2)
        #expect(!controller.contentCard.isHidden)
        controller.archive.view.searchField.stringValue = "absent"
        controller.renderArchive()
        await controller.archive.task?.value
        #expect(controller.archive.view.rows.isEmpty)
        controller.archive.view.searchField.stringValue = "NEEDLE"
        controller.renderArchive()
        await controller.archive.task?.value
        #expect(controller.archive.view.rows.count == 2)
        let other = await environment.store.createProfile(name: "Synthetic other")
        let space = try await environment.store.createSpace(name: "Other", profileID: other)
        controller.session.refreshCatalog()
        controller.session.activateSpace(space)
        await controller.session.waitForPendingCommands()
        await controller.archive.task?.value
        #expect(controller.archive.displayedProfile == other)
        #expect(controller.archive.view.rows.isEmpty)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Archive day groups are newest first and rows preserve record identity")
    func groupsByDay() {
        let profile = ProfileID(), space = SpaceID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func record(_ date: Date) -> BrowserArchivedTab {
            BrowserArchivedTab(tab: BrowserOrganizedTab(id: TabID(), url: URL(string: "https://archive.test")!, createdAt: date, lastActiveAt: date),
                profileID: profile, spaceID: space, origin: .today, reason: .closed, archivedAt: date)
        }
        let old = record(now.addingTimeInterval(-86400)), recent = record(now)
        let rows = BrowserArchiveView.grouped([old, recent])
        #expect(rows.count == 4)
        #expect(rows[1] == .tab(recent))
        #expect(rows[3] == .tab(old))
    }
}

}
