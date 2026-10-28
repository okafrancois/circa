import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import BrowserShell
import Foundation
import Testing

@MainActor
@Suite("Engine contract")
struct BrowserEngineContractTests {
    @Test("A synthetic engine passes the shared conformance checks without a web engine")
    func syntheticConformance() async {
        let failures = await BrowserEngineConformance.check(SyntheticEngine())
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test("An engine whose native host appears asynchronously passes conformance")
    func deferredReadinessConformance() async {
        let failures = await BrowserEngineConformance.check(SyntheticEngine(readiness: .deferred))
        #expect(failures.isEmpty, "\(failures)")
    }

    @Test("Conformance rejects a shutdown that returns before the native close completes")
    func conformanceRejectsUnawaitedClose() async {
        let failures = await BrowserEngineConformance.check(ImmediateShutdownEngine())
        #expect(failures.contains { $0.contains("isTeardownComplete") }, "\(failures)")
    }

    @Test("Commands sent before readiness are queued in order and never dropped")
    func commandsBeforeReadiness() async throws {
        let engine = SyntheticEngine(readiness: .deferred)
        let delegate = RecordingSurfaceDelegate()
        let surface = engine.makeSurface(profileID: ProfileID(), delegate: delegate)
        #expect(!surface.isReady)
        surface.navigate(to: URL(string: "https://a.test/one")!)
        surface.navigate(to: URL(string: "https://a.test/two")!)
        surface.performZoom(.increase)
        #expect(delegate.events.isEmpty)
        #expect(surface.requestedURLs.isEmpty)
        try await waitUntil { surface.isReady }
        #expect(surface.requestedURLs == [URL(string: "https://a.test/one")!, URL(string: "https://a.test/two")!])
        #expect(surface.navigationState.url == URL(string: "https://a.test/two"))
        #expect(surface.pageZoom > 1)
        surface.dispose()
    }

    @Test("Creation delivers nothing; the first navigation delivers lifecycle events in order")
    func lifecycleOrdering() {
        let engine = SyntheticEngine()
        let delegate = RecordingSurfaceDelegate()
        let surface = engine.makeSurface(profileID: ProfileID(), delegate: delegate)
        #expect(delegate.events.isEmpty)
        surface.navigate(to: URL(string: "https://a.test/one")!)
        #expect(delegate.events == ["start", "commit", "finish"])
        surface.navigate(to: URL(string: "https://a.test/two")!)
        #expect(surface.navigationState.canGoBack)
        #expect(surface.goBack() == URL(string: "https://a.test/one"))
        #expect(surface.navigationState.canGoForward)
        surface.dispose()
        delegate.events.removeAll()
        surface.navigate(to: URL(string: "https://a.test/three")!)
        #expect(delegate.events.isEmpty)
    }

    @Test("A synchronous-only engine applies the fallback to an unanswered question, without replay")
    func unansweredPolicyFallsBack() {
        let engine = SyntheticEngine()
        let delegate = RecordingSurfaceDelegate()
        delegate.answersPolicy = false
        let surface = engine.makeSurface(profileID: ProfileID(), delegate: delegate)
        surface.navigate(to: URL(string: "https://a.test/refused")!)
        #expect(delegate.events == ["fail"])
        #expect(surface.navigationState.committedURL == nil)
        #expect(surface.requestedURLs == [URL(string: "https://a.test/refused")!])
        surface.dispose()
    }

    @Test("Policy decisions resolve once, suspend only where offered, and fall back when abandoned")
    func policyDecisionSemantics() {
        var answers: [BrowserNavigationActionPolicy] = []
        let synchronous = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) {
            answers.append($0)
        }
        #expect(!synchronous.suspend())
        synchronous.decide(.allow)
        synchronous.decide(.download)
        synchronous.endSynchronousTurn()
        #expect(answers == [.allow])

        let unanswered = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) {
            answers.append($0)
        }
        unanswered.endSynchronousTurn()
        #expect(answers == [.allow, .cancel])

        let suspended = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: true, fallback: .cancel) {
            answers.append($0)
        }
        #expect(suspended.suspend())
        suspended.endSynchronousTurn()
        #expect(answers == [.allow, .cancel])
        #expect(!suspended.isResolved)
        suspended.decide(.allow)
        #expect(answers == [.allow, .cancel, .allow])

        let late = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: true, fallback: .cancel) {
            answers.append($0)
        }
        late.endSynchronousTurn()
        #expect(!late.suspend())
        let abandoned = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: true, fallback: .cancel) {
            answers.append($0)
        }
        #expect(abandoned.suspend())
        abandoned.endSynchronousTurn()
        abandoned.abandon()
        abandoned.decide(.allow)
        #expect(answers == [.allow, .cancel, .allow, .cancel, .cancel])
    }

    @Test("A new target inherits the source profile and a refused target is released")
    func newTargets() {
        let engine = SyntheticEngine()
        let delegate = RecordingSurfaceDelegate()
        let profile = ProfileID()
        let source = engine.makeSurface(profileID: profile, delegate: delegate)
        let child = source.openNewTarget(URL(string: "https://b.test/")!)
        #expect(child?.profileID == profile)
        #expect(child?.delegate === delegate)
        #expect(child?.navigationState.committedURL == URL(string: "https://b.test/"))
        #expect(delegate.adopted.count == 1)
        delegate.acceptsNewTargets = false
        #expect(source.openNewTarget(URL(string: "https://c.test/")!) == nil)
        #expect(delegate.adopted.count == 1)
    }

    @Test("Window sessions retire engine surfaces through the contract")
    func sessionRetiresSurfaces() async throws {
        let engine = SyntheticEngine()
        let delegate = RecordingSurfaceDelegate()
        let session = BrowserWindowSession<SyntheticSurface>(
            makeSurface: { profileID, _ in engine.makeSurface(profileID: profileID, delegate: delegate) },
            startSurface: { surface, url in surface.navigate(to: url) })
        session.openTab(url: URL(string: "https://a.test/")!)
        session.openTab(url: URL(string: "https://b.test/")!)
        await session.waitForPendingCommands()
        let selected = try #require(session.selectedSurface)
        let host = NSView()
        host.addSubview(selected.hostView)
        session.closeSelectedTab()
        await session.waitForPendingCommands()
        #expect(selected.isDisposed)
        #expect(selected.hostView.superview == nil)
        #expect(session.ownedSurfaces.count == 1)
        session.close()
        await session.waitForPendingCommands()
        #expect(engine.surfaces.allSatisfy { $0.isDisposed })
        await engine.shutdown()
        #expect(engine.isShutDown)
        #expect(engine.pendingTeardowns == 0)
    }

    @Test("Capabilities are an explicit, combinable contract")
    func capabilities() {
        let webKitLike: BrowserEngineCapabilities = [.snapshots, .liveSurfaceTransfer, .suspendablePolicyDecisions]
        #expect(!webKitLike.contains(.chromeWebStoreExtensions))
        #expect(!webKitLike.contains(.exactFindCount))
        #expect(webKitLike.union(.exactFindCount).contains(.exactFindCount))
        #expect(!SyntheticEngine().capabilities.contains(.suspendablePolicyDecisions))
    }

    @Test("Synchronous events of an initial load reach an owner that already records the surface")
    func initialLoadAfterOwnership() async throws {
        let engine = SyntheticEngine()
        let delegate = RecordingSurfaceDelegate()
        var session: BrowserWindowSession<SyntheticSurface>!
        var commits: [(TabOccurrenceID?, BrowserSurfacePlacement)] = []
        session = BrowserWindowSession<SyntheticSurface>(
            makeSurface: { profileID, _ in engine.makeSurface(profileID: profileID, delegate: delegate) },
            startSurface: { surface, url in surface.navigate(to: url) })
        session.onSurfaceMembershipChange = { surface, membership in
            surface.placement = membership.map { .tab(windowID: $0.windowID, occurrenceID: $0.occurrenceID) } ?? .detached
        }
        delegate.onEvent = { event, surface in
            if event == "commit" { commits.append((session.occurrenceID(for: surface), surface.placement)) }
        }
        session.openTab(url: URL(string: "https://history.test/first-visit")!)
        await session.waitForPendingCommands()
        let surface = try #require(session.selectedSurface)
        let occurrence = try #require(session.occurrenceID(for: surface))
        let windowID = try #require(session.snapshot?.id)
        #expect(commits.count == 1)
        #expect(commits.first?.0 == occurrence)
        #expect(commits.first?.1 == .tab(windowID: windowID, occurrenceID: occurrence))
        #expect(surface.requestedURLs == [URL(string: "https://history.test/first-visit")!])
        session.close()
        await session.waitForPendingCommands()
    }
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for a condition")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Wraps the synthetic engine but returns from `shutdown()` at once, before any native close.
@MainActor
private final class ImmediateShutdownEngine: BrowserEngine {
    let inner = SyntheticEngine(teardown: .delayed(.seconds(1)))
    var kind: BrowserEngineKind { inner.kind }
    var capabilities: BrowserEngineCapabilities { inner.capabilities }
    var extensions: (any BrowserExtensionHost)? { nil }
    var conformanceProbe: (any BrowserEngineConformanceProbe<SyntheticSurface>)? { inner.conformanceProbe }
    func profile(for profileID: ProfileID) -> BrowserEngineProfile { inner.profile(for: profileID) }
    func makeSurface(profileID: ProfileID,
                     delegate: any BrowserEngineSurfaceDelegate<SyntheticSurface>) -> SyntheticSurface {
        inner.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async {}
}
