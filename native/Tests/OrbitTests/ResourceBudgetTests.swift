import AppKit
import BrowserCore
import BrowserEngine
import Foundation
import Testing
@testable import Orbit

@Suite @MainActor
struct ResourceBudgetTests {
    private final class Identity {}
    private func state(_ value: BrowserPageLifecycle.State = .running, webLock: Bool = false) -> BrowserPageLifecycle {
        var state = BrowserPageLifecycle()
        state.state = value; state.rendererPID = 123; state.documentID = 7; state.webLock = webLock
        return state
    }
    @MainActor private struct Fixture {
        let coordinator: BrowserResourceCoordinator
        var objects: [Identity] = []
        var keys: [ObjectIdentifier] { objects.map(ObjectIdentifier.init) }
        init(_ budget: BrowserLiveTabBudget?) { coordinator = BrowserResourceCoordinator(observePressure: false, budget: budget) }
        /// Shown at `shown`, then backgrounded; observed with the given admission inputs.
        mutating func add(shown: TimeInterval, lifecycle: BrowserPageLifecycle?, allows: Bool? = true,
                          selected: Bool = false, suspended: Bool = false, profile: ProfileID = ProfileID(), window: UUID = UUID()) {
            let object = Identity(), occurrence = TabOccurrenceID()
            objects.append(object)
            coordinator.update(identity: ObjectIdentifier(object), window: window, occurrence: occurrence, profile: profile,
                lifecycle: lifecycle, suspended: false, visible: false, selected: true, engineAllowsSuspension: allows, now: shown)
            coordinator.update(identity: ObjectIdentifier(object), window: window, occurrence: occurrence, profile: profile,
                lifecycle: lifecycle, suspended: suspended, visible: false, selected: selected, engineAllowsSuspension: allows, now: shown)
        }
    }

    @Test("Protected tabs count toward the budget; only the least recently shown unprotected tabs are admitted")
    func protections() throws {
        var fixture = Fixture(.init(limit: 4, minimumBackgroundAge: 0))
        fixture.add(shown: 10, lifecycle: state())                       // 0: oldest candidate
        fixture.add(shown: 20, lifecycle: state(), allows: false)        // 1: shell veto
        fixture.add(shown: 30, lifecycle: state(webLock: true))          // 2: native veto
        fixture.add(shown: 40, lifecycle: nil)                           // 3: unknown lifecycle refuses
        fixture.add(shown: 50, lifecycle: state(.discarded))             // 4: already sleeping, not live
        fixture.add(shown: 60, lifecycle: state(), suspended: true)      // 5: policy-suspended, not live
        fixture.add(shown: 70, lifecycle: state())                       // 6: second candidate
        fixture.add(shown: 80, lifecycle: state())                       // 7: third candidate
        fixture.add(shown: 90, lifecycle: state(), selected: true)       // 8: visible, never counted
        let plan = try #require(fixture.coordinator.budgetPlan(now: 100))
        let keys = fixture.keys
        // Six live background tabs (three protected) against four: two excess.
        #expect(plan.excess[nil] == 2)
        #expect(Set(plan.entries.keys) == Set([keys[0], keys[6], keys[7]]))
        #expect(keys.filter(plan.admits) == [keys[0], keys[6]])
        #expect(plan.entries[keys[7]]?.rank == 2)
    }

    @Test("A refused admission lets the next candidate through; another window's older candidate keeps its rank")
    func refusalAndWindows() throws {
        var fixture = Fixture(.init(limit: 1, minimumBackgroundAge: 0))
        let other = UUID(), mine = UUID()
        fixture.add(shown: 10, lifecycle: state(), window: other)
        fixture.add(shown: 20, lifecycle: state(), window: mine)
        fixture.add(shown: 30, lifecycle: state(), window: mine)
        fixture.add(shown: 40, lifecycle: state(), window: mine)
        var plan = try #require(fixture.coordinator.budgetPlan(now: 100))
        let keys = fixture.keys
        #expect(plan.excess[nil] == 3)
        #expect(keys.filter(plan.admits) == [keys[0], keys[1], keys[2]])
        let surfaces = fixture.objects.reversed() + [Identity()]
        #expect(plan.ordered(surfaces).map(ObjectIdentifier.init) == keys + [ObjectIdentifier(surfaces.last!)])
        #expect(!plan.admits(keys[3]))
        plan.refused(keys[3])
        #expect(!plan.admits(keys[3]))
        plan.refused(keys[1])
        #expect(keys.filter(plan.admits) == keys)
        // Unknown or non-candidate identities never widen the admitted range.
        let stranger = Identity()
        plan.refused(ObjectIdentifier(stranger))
        #expect(!plan.admits(ObjectIdentifier(stranger)))
        #expect(plan.entries.count == 4)
    }

    @Test("Profile scope keeps a separate least-recently-shown budget per profile")
    func profiles() throws {
        var fixture = Fixture(.init(limit: 1, scope: .profile, minimumBackgroundAge: 0))
        let first = ProfileID(), second = ProfileID()
        for (index, profile) in [first, second, first, first, second].enumerated() {
            fixture.add(shown: TimeInterval(10 * (index + 1)), lifecycle: state(), profile: profile)
        }
        let plan = try #require(fixture.coordinator.budgetPlan(now: 100))
        let keys = fixture.keys
        #expect(plan.excess[first] == 2 && plan.excess[second] == 1)
        #expect(keys.filter(plan.admits) == [keys[0], keys[1], keys[2]])
    }

    @Test("Recent tabs stay live; warning halves the limit without the age floor; critical and normal follow")
    func pressure() throws {
        var fixture = Fixture(.init(limit: 2, minimumBackgroundAge: 300))
        for shown in [100.0, 200, 800, 850, 900, 950] { fixture.add(shown: shown, lifecycle: state()) }
        let keys = fixture.keys
        var plan = try #require(fixture.coordinator.budgetPlan(now: 1000))
        // Four excess, but only the two tabs hidden for five minutes are candidates.
        #expect(plan.excess[nil] == 4 && plan.entries.count == 2)
        #expect(keys.filter(plan.admits) == [keys[0], keys[1]])
        fixture.coordinator.recordPressure("warning")
        plan = try #require(fixture.coordinator.budgetPlan(now: 1000))
        #expect(keys.filter(plan.admits) == Array(keys[0..<5]))
        fixture.coordinator.recordPressure("critical")
        plan = try #require(fixture.coordinator.budgetPlan(now: 1000))
        #expect(keys.filter(plan.admits) == keys)
        fixture.coordinator.recordPressure("normal")
        plan = try #require(fixture.coordinator.budgetPlan(now: 1000))
        #expect(keys.filter(plan.admits) == [keys[0], keys[1]])
    }

    @Test("No budget plans nothing; the hidden default enables it only with a positive limit")
    func configuration() throws {
        var fixture = Fixture(nil)
        fixture.add(shown: 0, lifecycle: state())
        #expect(fixture.coordinator.budgetPlan(now: 10_000) == nil)
        let suite = "orbit.tests.live-tab-budget.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BrowserLiveTabBudget.configured(defaults) == nil)
        defaults.set(0, forKey: BrowserLiveTabBudget.limitKey)
        #expect(BrowserLiveTabBudget.configured(defaults) == nil)
        defaults.set(-3, forKey: BrowserLiveTabBudget.limitKey)
        #expect(BrowserLiveTabBudget.configured(defaults) == nil)
        defaults.set(12, forKey: BrowserLiveTabBudget.limitKey)
        #expect(BrowserLiveTabBudget.configured(defaults) == .init(limit: 12))
        defaults.set("profile", forKey: BrowserLiveTabBudget.scopeKey)
        #expect(BrowserLiveTabBudget.configured(defaults) == .init(limit: 12, scope: .profile))
        defaults.set("unknown", forKey: BrowserLiveTabBudget.scopeKey)
        #expect(BrowserLiveTabBudget.configured(defaults)?.scope == .global)
        let observing = BrowserResourceCoordinator(observePressure: false, budget: .init(limit: 1))
        observing.enabled = false
        #expect(observing.budgetPlan(now: 0) == nil)
    }

    @Test("Recency follows selection even while the window is hidden or occluded")
    func recency() throws {
        let coordinator = BrowserResourceCoordinator(observePressure: false, budget: .init(limit: 0, minimumBackgroundAge: 0))
        let object = Identity(), key = ObjectIdentifier(object), window = UUID(), occurrence = TabOccurrenceID(), profile = ProfileID()
        func update(selected: Bool, _ now: TimeInterval) {
            coordinator.update(identity: key, window: window, occurrence: occurrence, profile: profile,
                lifecycle: state(), suspended: false, visible: false, selected: selected, engineAllowsSuspension: true, now: now)
        }
        update(selected: false, 10); update(selected: false, 50)
        #expect(coordinator.tabs[key]?.lastShown == 10)
        update(selected: true, 60); update(selected: true, 70); update(selected: false, 90); update(selected: false, 200)
        #expect(coordinator.tabs[key]?.lastShown == 90)
        #expect(coordinator.tabs[key]?.secondsSinceVisible(at: 200) == 190)
    }
}

extension NativeWebKitTests {
@Suite(.serialized) @MainActor
struct LiveTabBudgetSweepTests {
    private final class Performance: BrowserPagePerformance {
        var state = BrowserPageLifecycle()
        init(_ pid: Int32) { state.documentID = 1; state.rendererPID = pid }
        func lifecycle() -> BrowserPageLifecycle? { state }
        func changes() -> AsyncStream<BrowserPageLifecycleChange> { AsyncStream { _ in } }
        func capture(_ request: BrowserNativeCaptureRequest) async -> BrowserNativeCapture { .init(status: .unavailable) }
        func activationFrame(activationID: UInt64) async -> BrowserActivationFrame {
            .init(browserID: 0, activationID: activationID, documentID: 0, status: .closed)
        }
    }
    private final class Clock { var now: TimeInterval = 1000 }
    @MainActor private struct Session {
        let environment: BrowserEnvironment<SiteSyntheticEngine>
        let window: BrowserWindowController<SiteSyntheticEngine>
        let coordinator: BrowserResourceCoordinator
        let clock: Clock
        var surfaces: [SiteSyntheticSurface] = []
        var tabs: [BrowserTab] = []
        var performances: [Performance] = []
        func close() {
            window.resources.close(); window.tabSuspension.close(); window.session.close()
            window.window?.close(); environment.autoArchive.scheduler.stop()
        }
    }
    /// Opens `count` tabs 100 s apart; each later selection backgrounds the previous one.
    private func session(_ budget: BrowserLiveTabBudget?, count: Int = 6) async throws -> Session {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow(opensInitialTab: false)
        let coordinator = BrowserResourceCoordinator(observePressure: false, budget: budget, memoryReader: { _ in 100 })
        let clock = Clock()
        coordinator.clock = { clock.now }
        window.resources.close()
        window.resources = BrowserWindowResources(owner: window, coordinator: coordinator)
        window.tabSuspension.close()
        window.tabSuspension = BrowserTabSuspensionController(owner: window, store: environment.store)
        window.tabSuspension.clock = { clock.now }
        var result = Session(environment: environment, window: window, coordinator: coordinator, clock: clock)
        for index in 0..<count {
            clock.now = 1000 + 100 * TimeInterval(index)
            window.openTab(url: URL(string: "https://budget.test/tab-\(index)")!)
            await window.session.waitForPendingCommands()
            let surface = try #require(window.session.selectedSurface)
            let performance = Performance(Int32(200 + index))
            surface.pagePerformance = performance
            surface.allowsSuspension = true
            result.surfaces.append(surface); result.performances.append(performance)
            result.tabs.append(try #require(window.session.snapshot?.tabs.first { $0.occurrenceID == window.session.snapshot?.selectedOccurrenceID }))
        }
        window.renderSession()
        return result
    }

    @Test("Budget discards go through the unchanged admission path in least-recently-shown order")
    func lruAndProtections() async throws {
        let fixture = try await session(.init(limit: 2, minimumBackgroundAge: 0))
        defer { fixture.close() }
        // Tab 1 refuses natively and tab 0 fails the asynchronous document check.
        fixture.performances[1].state.webLock = true
        fixture.surfaces[1].allowsSuspension = false
        fixture.surfaces[0].suspensionCapture = { nil }
        fixture.clock.now = 1600
        // Five live background tabs against two: three admissions, all before the one-hour policy.
        #expect(await fixture.window.tabSuspension.sweep() == 3)
        #expect(fixture.surfaces.map(\.suspensionCount) == [0, 0, 1, 1, 1, 0])
        #expect(fixture.coordinator.budgetDiscards == 3)
        #expect(fixture.window.tabSuspension.isPolicySuspended(fixture.tabs[2].occurrenceID))
        #expect(!fixture.window.tabSuspension.isPolicySuspended(fixture.tabs[5].occurrenceID))
        // The budget is met; the refused and protected tabs remain live and are retried later.
        fixture.surfaces[0].suspensionCapture = nil
        #expect(await fixture.window.tabSuspension.sweep() == 0)
    }

    @Test("Visible and Split tabs are neither counted nor discarded")
    func splitExclusion() async throws {
        let fixture = try await session(.init(limit: 0, minimumBackgroundAge: 0), count: 4)
        defer { fixture.close() }
        fixture.window.session.createSplit([fixture.tabs[0].id, fixture.tabs[1].id])
        await fixture.window.session.waitForPendingCommands()
        fixture.window.renderSession()
        #expect(fixture.window.session.visibleOccurrenceIDs.count == 2)
        let split = try #require(fixture.window.session.activeSplit)
        let paneSurfaces = split.tabs.compactMap(\.occurrenceID).compactMap { fixture.window.session.surface(for: $0) }
        #expect(paneSurfaces.count == 2)
        fixture.clock.now = 2000
        let discarded = await fixture.window.tabSuspension.sweep()
        #expect(paneSurfaces.allSatisfy { $0.suspensionCount == 0 })
        #expect(discarded == fixture.window.session.ownedSurfaces.count - 2)
        #expect(fixture.window.session.ownedSurfaces.filter { surface in
            !paneSurfaces.contains { $0 === surface } }.allSatisfy { $0.suspensionCount == 1 })
    }

    @Test("Without a budget the sweep is exactly the time policy")
    func off() async throws {
        let fixture = try await session(nil)
        defer { fixture.close() }
        fixture.clock.now = 1600
        #expect(fixture.coordinator.budgetPlan(now: 1600) == nil)
        #expect(await fixture.window.tabSuspension.sweep() == 0)
        // Tab 0 was backgrounded at 1100; only it has been hidden for one hour.
        fixture.clock.now = 4700
        #expect(await fixture.window.tabSuspension.sweep() == 1)
        #expect(fixture.surfaces.map(\.suspensionCount) == [1, 0, 0, 0, 0, 0])
        #expect(fixture.coordinator.budgetDiscards == 0)
        // The engine refuses an already-discarded document.
        fixture.surfaces[0].allowsSuspension = false
        // Warning pressure has no effect without a budget.
        fixture.coordinator.recordPressure("warning")
        fixture.clock.now = 4800
        #expect(await fixture.window.tabSuspension.sweep() == 1)
        #expect(fixture.surfaces.map(\.suspensionCount) == [1, 1, 0, 0, 0, 0])
    }
}
}
