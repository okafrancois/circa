import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class StoreReviewFixture {
    let engine = PeekSyntheticEngine()
    let environment: BrowserEnvironment<PeekSyntheticEngine>
    let owner: BrowserWindowController<PeekSyntheticEngine>
    let router: BrowserWindowRouter<BrowserWindowController<PeekSyntheticEngine>>
    let registry: BrowserCommandRegistry<BrowserWindowController<PeekSyntheticEngine>>
    let source: PeekSyntheticSurface
    let count: Int
    let requests: [URL]
    let generation: UInt64

    init() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        environment = BrowserEnvironment(engine: engine)
        owner = try await environment.makeWindow()
        let window = owner
        router = BrowserWindowRouter(create: { _ in window }, present: { _, _ in }, dispose: { _ in })
        registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow(id: owner.id)
        await router.waitForPendingCommands()
        owner.palette.registry = registry
        owner.openTab(url: URL(string: "https://review.invalid/retained-form")!)
        await owner.session.waitForPendingCommands()
        source = try #require(owner.session.selectedSurface)
        source.documentState = "synthetic unsaved field"
        count = try #require(owner.session.snapshot?.tabs.count)
        requests = source.requestedURLs
        generation = source.documentGeneration
    }

    func settle() async {
        await router.waitForPendingCommands()
        await owner.session.waitForPendingCommands()
    }

    func retained() {
        #expect(!source.isDisposed)
        #expect(source.documentState == "synthetic unsaved field")
        #expect(source.documentGeneration == generation)
        #expect(source.requestedURLs == requests)
        #expect(owner.session.ownedSurfaces.contains { $0 === source })
        #expect(source.delegate === owner)
        #expect(source.documentView.superview === source.hostView)
        if owner.session.selectedSurface === source {
            #expect(source.hostView.window === owner.window)
        } else {
            #expect(source.hostView.window == nil)
        }
    }

    func finish() async throws {
        environment.autoArchive.scheduler.stop()
        environment.retireQuickWindows()
        router.shutdown()
        owner.session.close()
        try await environment.finalize()
        owner.window?.close()
    }
}

extension NativeWebKitTests {
@Suite("Independent Store new-target review", .serialized)
@MainActor
struct ExtensionStoreIndependentReviewTests {
    @Test("Store preserves synthetic form, history, binding and owner; ordinary address input still replaces")
    func formAndAddressSemantics() async throws {
        let f = try await StoreReviewFixture()
        let action = try #require(f.owner.makeCreationActions().first { $0.command == .addExtension })
        action.perform()
        await f.settle()
        f.retained()
        let store = try #require(f.owner.session.selectedSurface)
        #expect(store !== f.source && store.profileID == f.source.profileID)
        #expect(store.currentURL?.absoluteString == "https://chromewebstore.google.com/")
        #expect(f.owner.session.snapshot?.tabs.count == f.count + 1)
        f.owner.submitAddress("https://review.invalid/address-entry")
        await f.settle()
        #expect(f.owner.session.selectedSurface === store)
        #expect(store.currentURL?.path == "/address-entry")
        #expect(f.owner.session.snapshot?.tabs.count == f.count + 1)
        f.retained()
        let original = try #require(f.owner.session.occurrenceID(for: f.source))
        f.owner.session.selectOccurrence(original)
        await f.settle()
        #expect(f.owner.session.selectedSurface === f.source)
        f.retained()
        try await f.finish()
    }

    @Test("A retained plus callback loses authority after a document commit or termination")
    func stalePlus() async throws {
        let f = try await StoreReviewFixture()
        let action = try #require(f.owner.makeCreationActions().first { $0.command == .addExtension })
        f.source.navigate(to: URL(string: "https://review.invalid/new-document")!)
        let requests = f.source.requestedURLs
        action.perform()
        await f.settle()
        #expect(f.owner.session.snapshot?.tabs.count == f.count)
        #expect(f.source.requestedURLs == requests)
        let frozen = try #require(f.owner.makeCreationActions().first { $0.command == .addExtension })
        f.owner.freezeCommandsForTermination()
        frozen.perform()
        await f.settle()
        #expect(f.owner.session.snapshot?.tabs.count == f.count)
        f.owner.cancelTerminationPreparation()
        try await f.finish()
    }

    @Test("Real main host refuses nonselected, foreign-profile and closed sources")
    func hostAuthority() async throws {
        let f = try await StoreReviewFixture()
        f.owner.openTab(url: URL(string: "https://review.invalid/other")!)
        await f.settle()
        let count = f.owner.session.snapshot?.tabs.count
        f.owner.openExtensionStore(from: f.source)
        let profile = await f.environment.store.createProfile(name: "Review isolated profile")
        let space = try await f.environment.store.createSpace(name: "Review isolated Space", profileID: profile)
        let foreign = try await f.environment.makeWindow(spaceID: space)
        foreign.openTab(url: URL(string: "https://review.invalid/foreign")!)
        await foreign.session.waitForPendingCommands()
        let foreignSource = try #require(foreign.session.selectedSurface)
        let foreignRequests = foreignSource.requestedURLs
        f.owner.openExtensionStore(from: foreignSource)
        await f.settle()
        #expect(f.owner.session.snapshot?.tabs.count == count)
        #expect(foreignSource.requestedURLs == foreignRequests)
        f.retained()
        f.owner.session.close()
        let surfaces = f.engine.surfaces.count
        f.owner.openExtensionStore(from: f.source)
        await f.settle()
        #expect(f.engine.surfaces.count == surfaces)
        foreign.session.close(); foreign.window?.close()
        try await f.finish()
    }

    @Test("Accepted Store creation is canceled by session closure before queued work drains")
    func closePending() async throws {
        let f = try await StoreReviewFixture()
        let surfaces = f.engine.surfaces.count
        #expect(f.registry.dispatch(.addExtension, origin: .menu))
        f.owner.session.close()
        await f.settle()
        #expect(f.engine.surfaces.count == surfaces)
        #expect(!f.engine.surfaces.contains { $0.currentURL?.host == "chromewebstore.google.com" })
        try await f.finish()
    }

    @Test("Little Orbit factory is single-use and refuses source, existing, foreign and nil returns with cleanup")
    func littleRefusedTargets() async throws {
        let f = try await StoreReviewFixture()
        let little = try await f.environment.makeQuickWindow(url: URL(string: "https://review.invalid/little")!)
        let source = try #require(little.surface)
        let sourceRequests = source.requestedURLs
        let foreignID = await f.environment.store.createProfile(name: "Review foreign target")
        let foreign = f.engine.makeSurface(profileID: foreignID, delegate: little)
        for offered in [source, f.source, foreign, nil] as [PeekSyntheticSurface?] {
            var created: PeekSyntheticSurface?
            little.onNewTarget = { _, request, make in
                #expect(request.httpMethod == "GET" && request.hasBody == false && request.isUserGesture == true)
                #expect(request.disposition == .newForegroundTab)
                created = make()
                #expect(make() === created)
                return offered
            }
            little.openExtensionStore(from: source)
            let refused = try #require(created)
            #expect(refused.isDisposed && refused.requestedURLs.isEmpty)
            #expect(source.requestedURLs == sourceRequests && !source.isDisposed)
            #expect(!foreign.isDisposed && foreign.requestedURLs.isEmpty)
            f.retained()
        }
        foreign.dispose()
        try await f.finish()
    }

    @Test("Little Orbit uses exact adopted child and preserves source form, placement and delegate")
    func littleAdoptionAndRevocation() async throws {
        let f = try await StoreReviewFixture()
        let little = try await f.environment.makeQuickWindow(url: URL(string: "https://review.invalid/little")!)
        let source = try #require(little.surface)
        source.documentState = "synthetic little form"
        let requests = source.requestedURLs, generation = source.documentGeneration, placement = source.placement
        let child = f.environment.registerQuickWindow(spaceID: little.sourceSpaceID, profileID: little.profileID,
                                                    spaceName: little.sourceSpaceName)
        var calls = 0
        little.onNewTarget = { origin, _, make in
            calls += 1
            #expect(origin === source)
            let created = make()
            #expect(child.adoptNewTarget(created))
            return created
        }
        little.openExtensionStore(from: f.source)
        #expect(calls == 0)
        little.freezeForTermination()
        little.openExtensionStore(from: source)
        #expect(calls == 0)
        little.cancelTerminationPreparation()
        little.openExtensionStore(from: source)
        #expect(calls == 1)
        let target = try #require(child.surface)
        #expect(target !== source && target.delegate === child && child.container.owns(target))
        #expect(target.requestedURLs.map(\.absoluteString) == ["https://chromewebstore.google.com/"])
        #expect(source.documentState == "synthetic little form" && source.requestedURLs == requests)
        #expect(source.documentGeneration == generation && source.placement == placement)
        #expect(source.delegate === little && little.container.owns(source))
        little.retire()
        little.openExtensionStore(from: source)
        #expect(calls == 1)
        try await f.finish()
    }

    @Test("Deferred native readiness queues only the fresh adopted Store navigation")
    func deferredReadiness() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine(readiness: .deferred)
        let environment = BrowserEnvironment(engine: engine)
        let little = try await environment.makeQuickWindow(url: URL(string: "https://review.invalid/deferred")!)
        let source = try #require(little.surface)
        await Task.yield()
        let requests = source.requestedURLs, generation = source.documentGeneration
        let child = environment.registerQuickWindow(spaceID: little.sourceSpaceID, profileID: little.profileID,
                                                  spaceName: little.sourceSpaceName)
        little.onNewTarget = { _, _, make in
            let fresh = make()
            #expect(!fresh.isReady)
            #expect(child.adoptNewTarget(fresh))
            return fresh
        }
        little.openExtensionStore(from: source)
        let target = try #require(child.surface)
        #expect(target.requestedURLs.isEmpty)
        await Task.yield()
        #expect(target.currentURL?.absoluteString == "https://chromewebstore.google.com/")
        #expect(source.requestedURLs == requests && source.documentGeneration == generation)
        environment.autoArchive.scheduler.stop()
        environment.retireQuickWindows()
        try await environment.finalize()
    }

    @Test("Reentrant child retirement during adoption cannot load the disposed target or source")
    func reentrantChildRetirement() async throws {
        let f = try await StoreReviewFixture()
        let little = try await f.environment.makeQuickWindow(url: URL(string: "https://review.invalid/reentrant")!)
        let source = try #require(little.surface)
        let requests = source.requestedURLs, generation = source.documentGeneration
        let child = f.environment.registerQuickWindow(spaceID: little.sourceSpaceID, profileID: little.profileID,
                                                    spaceName: little.sourceSpaceName)
        var created: PeekSyntheticSurface?
        little.onNewTarget = { _, _, make in
            let fresh = make()
            created = fresh
            fresh.onDelegateChange = { child.retire() }
            _ = child.adoptNewTarget(fresh)
            return fresh
        }
        little.openExtensionStore(from: source)
        let retired = try #require(created)
        #expect(child.isClosed && retired.isDisposed && retired.requestedURLs.isEmpty)
        #expect(source.requestedURLs == requests && source.documentGeneration == generation)
        #expect(!source.isDisposed && source.delegate === little && little.container.owns(source))
        f.retained()
        try await f.finish()
    }

    @Test("Store host rejects creation after a queued foreign-profile Space change")
    func pendingForeignProfile() async throws {
        let f = try await StoreReviewFixture()
        let profile = await f.environment.store.createProfile(name: "Review queued foreign profile")
        let space = try await f.environment.store.createSpace(name: "Review queued foreign Space", profileID: profile)
        let before = await f.environment.store.sessionDocument()
        f.owner.session.activateSpace(space)
        #expect(f.owner.session.hasPendingCommands)
        #expect(f.owner.isSitePermissionTarget(f.source))
        f.owner.openExtensionStore(from: f.source)
        await f.settle()
        let after = await f.environment.store.sessionDocument()
        #expect(after.tabs == before.tabs)
        let store = URL(string: "https://chromewebstore.google.com/")!
        #expect(f.engine.surfaces.allSatisfy { !$0.requestedURLs.contains(store) })
        #expect(f.source.requestedURLs == f.requests)
        #expect(f.owner.session.activeProfileID == profile)
        try await f.finish()
    }
}
}
