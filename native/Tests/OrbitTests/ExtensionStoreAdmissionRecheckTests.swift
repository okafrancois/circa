import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Independent shared Store admission recheck", .serialized)
@MainActor
struct ExtensionStoreAdmissionRecheckTests {
    @Test("Shared menu command cannot retarget during queued Space or context ABA", arguments: [false, true])
    func sharedPending(returnToOrigin: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = PeekSyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let owner = try await environment.makeWindow()
        let router = BrowserWindowRouter(create: { _ in owner }, present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow(id: owner.id)
        await router.waitForPendingCommands()
        owner.openTab(url: URL(string: "https://shared-review.invalid/form")!)
        await owner.session.waitForPendingCommands()
        let source = try #require(owner.session.selectedSurface)
        let requests = source.requestedURLs
        let origin = try #require(owner.session.snapshot?.activeSpaceID)
        let profile = await environment.store.createProfile(name: "Synthetic menu B")
        let space = try await environment.store.createSpace(name: "Synthetic menu B Space", profileID: profile)
        let before = await environment.store.sessionDocument()
        owner.session.activateSpace(space)
        if returnToOrigin { owner.session.activateSpace(origin) }
        #expect(registry.dispatch(.addExtension, origin: .menu))
        await router.waitForPendingCommands()
        await owner.session.waitForPendingCommands()
        #expect(await environment.store.sessionDocument().tabs == before.tabs)
        #expect(source.requestedURLs == requests)
        #expect(engine.surfaces.allSatisfy { $0.currentURL?.host != "chromewebstore.google.com" })
        // Freeze blocks new host/menu admission while retaining already accepted queue semantics.
        owner.freezeCommandsForTermination()
        owner.openExtensionStore(from: source)
        #expect(!registry.dispatch(.addExtension, origin: .menu))
        await owner.session.waitForPendingCommands()
        #expect(await environment.store.sessionDocument().tabs == before.tabs)
        environment.autoArchive.scheduler.stop()
        router.shutdown()
        owner.session.close()
        try await environment.finalize()
        owner.window?.close()
    }
}
}
