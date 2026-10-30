import AppKit
import BrowserCore
import BrowserEngine
import Darwin
import Foundation
import Testing
@testable import Orbit

@Suite @MainActor
struct ResourceCoordinatorTests {
    private final class Identity {}
    private func state(_ value: BrowserPageLifecycle.State = .running, pid: Int32 = 123) -> BrowserPageLifecycle {
        var state = BrowserPageLifecycle()
        state.state = value; state.rendererPID = pid; state.documentID = 7; state.footprintKB = 1024
        return state
    }

    @Test("Visibility age survives repeated hidden publications and resets on return")
    func visibility() throws {
        let coordinator = BrowserResourceCoordinator(observePressure: false)
        let object = Identity(), window = UUID(), occurrence = TabOccurrenceID(), profile = ProfileID()
        func update(_ visible: Bool, _ now: Double) {
            coordinator.update(identity: ObjectIdentifier(object), window: window, occurrence: occurrence, profile: profile,
                lifecycle: state(), suspended: false, visible: visible, now: now)
        }
        update(true, 10); update(false, 20); update(false, 40)
        #expect(try #require(coordinator.tabs[ObjectIdentifier(object)]).secondsSinceVisible(at: 50) == 30)
        update(true, 60)
        #expect(try #require(coordinator.tabs[ObjectIdentifier(object)]).secondsSinceVisible(at: 80) == 0)
        update(false, 90)
        #expect(try #require(coordinator.tabs[ObjectIdentifier(object)]).secondsSinceVisible(at: 100) == 10)
    }

    @Test("Native and policy discards are event counts, separate from frozen and suspended snapshots")
    func lifecycle() throws {
        let coordinator = BrowserResourceCoordinator(observePressure: false)
        let object = Identity(), key = ObjectIdentifier(object), window = UUID(), occurrence = TabOccurrenceID(), profile = ProfileID()
        func update(_ value: BrowserPageLifecycle?, _ suspended: Bool = false) {
            coordinator.update(identity: key, window: window, occurrence: occurrence, profile: profile,
                lifecycle: value, suspended: suspended, visible: false)
        }
        update(nil)
        #expect(coordinator.tabs[key]?.state == "unknown")
        update(state(.frozen))
        #expect(coordinator.tabs[key]?.state == "frozen")
        coordinator.change(.init(event: .aboutToDiscard, initiator: .nativePolicy, state: state()), identity: key)
        coordinator.change(.init(event: .discarded, initiator: .nativePolicy, state: state(.discarded)), identity: key)
        update(state(.discarded))
        #expect(coordinator.nativeDiscards == 1 && coordinator.policyDiscards == 0)
        #expect(coordinator.tabs[key]?.state == "discarded")
        update(state())
        coordinator.settled(key)
        coordinator.change(.init(event: .discarded, initiator: .embedder, state: state(.discarded)), identity: key)
        update(state(.discarded), true)
        #expect(coordinator.tabs[key]?.state == "suspended")
        #expect(coordinator.tabs[key]?.lastDiscard == .embedder)
        #expect(coordinator.policyDiscards == 1)
        coordinator.change(.init(event: .closed), identity: key)
        #expect(coordinator.tabs.isEmpty)
        #expect(coordinator.nativeDiscards == 1 && coordinator.policyDiscards == 1)
        coordinator.change(.init(event: .discarded, initiator: .nativePolicy), identity: key)
        #expect(coordinator.nativeDiscards == 1)
    }

    @Test("Memory charges shared renderer PIDs once globally, excluding discarded PIDs and retaining read failures")
    func memory() {
        var reads: [Int32] = []
        let coordinator = BrowserResourceCoordinator(observePressure: false) { pid in
            reads.append(pid); return pid == 124 ? nil : 4096
        }
        let objects = (0..<62).map { _ in Identity() }, profiles = [ProfileID(), ProfileID(), ProfileID()]
        for (index, object) in objects.enumerated() {
            coordinator.update(identity: ObjectIdentifier(object), window: UUID(), occurrence: TabOccurrenceID(), profile: profiles[index % 3],
                lifecycle: state(index == 61 ? .discarded : .running, pid: index == 61 ? 125 : index % 2 == 0 ? 123 : 124),
                suspended: false, visible: index == 0)
        }
        coordinator.sampleMemory()
        #expect(Set(reads) == Set([getpid(), 123, 124]))
        #expect(reads.count == 3)
        #expect(coordinator.processes.first { $0.pid == 124 }?.footprint == nil)
        #expect(coordinator.tabs.count == 62)
        coordinator.recordPressure("critical")
        #expect(coordinator.pressureEvents == 1 && coordinator.pressureLevel == "critical")
        #expect(coordinator.memorySampleUptime != nil)
    }

    @Test("Transfers preserve identity and discard history; closing the former window cannot remove the new owner")
    func transfer() {
        let coordinator = BrowserResourceCoordinator(observePressure: false)
        let object = Identity(), key = ObjectIdentifier(object), first = UUID(), second = UUID(), profile = ProfileID()
        coordinator.update(identity: key, window: first, occurrence: TabOccurrenceID(), profile: profile,
            lifecycle: state(), suspended: false, visible: false, now: 1)
        coordinator.change(.init(event: .discarded, initiator: .nativePolicy, state: state(.discarded)), identity: key)
        coordinator.update(identity: key, window: second, occurrence: TabOccurrenceID(), profile: profile,
            lifecycle: state(.discarded), suspended: false, visible: false, now: 2)
        coordinator.retain(window: first, identities: [])
        #expect(coordinator.tabs[key]?.nativeDiscards == 1)
        #expect(coordinator.tabs[key]?.backgroundSince == 1)
        coordinator.retain(window: second, identities: [])
        #expect(coordinator.tabs.isEmpty)
    }

    @Test("Disabling observation performs no reads or state changes; real process footprint uses charged bytes")
    func disabled() {
        var reads = 0
        let coordinator = BrowserResourceCoordinator(observePressure: false) { _ in reads += 1; return 0 }
        let vetoed = Identity()
        coordinator.update(identity: ObjectIdentifier(vetoed), window: UUID(), occurrence: TabOccurrenceID(), profile: ProfileID(),
            lifecycle: state(), suspended: false, visible: false, engineAllowsSuspension: false)
        #expect(coordinator.tabs[ObjectIdentifier(vetoed)]?.protected == true)
        coordinator.change(.init(event: .closed), identity: ObjectIdentifier(vetoed))
        coordinator.enabled = false
        let object = Identity()
        coordinator.update(identity: ObjectIdentifier(object), window: UUID(), occurrence: TabOccurrenceID(), profile: ProfileID(),
            lifecycle: state(), suspended: false, visible: true)
        coordinator.sampleMemory(); coordinator.recordPressure("warning")
        #expect(reads == 0 && coordinator.tabs.isEmpty && coordinator.pressureEvents == 0)
        #expect((BrowserResourceCoordinator.footprint(getpid()) ?? 0) > 0)
        #expect(BrowserResourceCoordinator.footprint(-1) == nil)
    }
}

extension NativeWebKitTests {
@Suite(.serialized) @MainActor
struct WindowResourceObservationTests {
    private final class Performance: BrowserPagePerformance {
        var state = BrowserPageLifecycle()
        var continuation: AsyncStream<BrowserPageLifecycleChange>.Continuation?
        func lifecycle() -> BrowserPageLifecycle? { state }
        func changes() -> AsyncStream<BrowserPageLifecycleChange> {
            AsyncStream { continuation = $0 }
        }
        func capture(_ request: BrowserNativeCaptureRequest) async -> BrowserNativeCapture { .init(status: .unavailable) }
        func activationFrame(activationID: UInt64) async -> BrowserActivationFrame {
            .init(browserID: 0, activationID: activationID, documentID: 0, status: .closed)
        }
    }
    @Test("The window subscribes across selection and reconciles stale queued events against the live engine")
    func observation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        let coordinator = BrowserResourceCoordinator(observePressure: false, memoryReader: { _ in 100 })
        window.resources.close()
        window.resources = BrowserWindowResources(owner: window, coordinator: coordinator)
        defer {
            window.resources.close(); window.tabSuspension.close(); window.session.close()
            window.window?.close(); environment.autoArchive.scheduler.stop()
        }
        window.openTab(url: URL(string: "https://resources.test/one")!)
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let api = Performance()
        api.state.documentID = 1; api.state.rendererPID = 123
        surface.pagePerformance = api
        window.resources.reconcile(now: 100)
        let key = ObjectIdentifier(surface)
        #expect(coordinator.tabs[key]?.selected == true)
        window.openTab(url: URL(string: "https://resources.test/two")!)
        await window.session.waitForPendingCommands()
        window.resources.reconcile(now: 120)
        #expect(coordinator.tabs[key]?.selected == false)
        // Native state is already running again before this older discard is delivered.
        api.continuation?.yield(.init(event: .discarded, initiator: .nativePolicy, state: {
            var state = api.state; state.state = .discarded; return state
        }()))
        for _ in 0..<10 { await Task.yield() }
        #expect(coordinator.nativeDiscards == 1)
        #expect(coordinator.tabs[key]?.lifecycle?.state == .running)
        #expect(coordinator.tabs[key]?.lastDiscard == .nativePolicy)
        window.resources.sweep()
        #expect(coordinator.memorySampleUptime != nil)
        window.resources.close()
        #expect(coordinator.tabs.isEmpty)
        api.continuation?.yield(.init(event: .discarded, initiator: .embedder))
        for _ in 0..<10 { await Task.yield() }
        #expect(coordinator.policyDiscards == 0)
    }
}
}
