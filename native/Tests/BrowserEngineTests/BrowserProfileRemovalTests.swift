import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import Testing

@MainActor
@Suite("Profile removal contract", .serialized)
struct BrowserProfileRemovalTests {
    @Test("The profile-removal acceptance probe verifies reset isolation and idempotence")
    func syntheticProfileRemoval() async {
        let engine = SyntheticEngine(teardown: .delayed(.milliseconds(10)))
        #expect(await BrowserEngineConformance.checkProfileRemoval(engine).isEmpty)
        await engine.shutdown()
    }

    @Test("A no-op removal cannot claim conformance merely by accepting the command")
    func rejectsNoopRemoval() async {
        let engine = NoopProfileRemovalEngine()
        let failures = await BrowserEngineConformance.checkProfileRemoval(engine)
        #expect(failures.contains("removed profile data survived reopening"))
        await engine.shutdown()
    }
}

@MainActor
private final class NoopProfileRemovalEngine: BrowserEngine {
    let inner = SyntheticEngine()
    var kind: BrowserEngineKind { inner.kind }
    var capabilities: BrowserEngineCapabilities { inner.capabilities }
    var extensions: (any BrowserExtensionHost)? { nil }
    var conformanceProbe: (any BrowserEngineConformanceProbe<SyntheticSurface>)? { inner.conformanceProbe }
    func profile(for profileID: ProfileID) -> BrowserEngineProfile { inner.profile(for: profileID) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<SyntheticSurface>) -> SyntheticSurface {
        inner.makeSurface(profileID: profileID, delegate: delegate)
    }
    func removeProfile(_ id: ProfileID) async throws {
        guard !inner.surfaces.contains(where: { $0.profileID == id && !$0.isDisposed }) else { throw BrowserEngineError.profileInUse }
    }
    func shutdown() async { await inner.shutdown() }
}
