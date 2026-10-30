import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class StoreExtensionProbe: BrowserExtensionHost {
    var supportsActions = false
    var onExtensionsChange: ((ProfileID) -> Void)?
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] { [] }
    func openManagement(on surface: any BrowserEngineSurface) throws {}
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws {}
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws {}
    func remove(extensionID: String, in profileID: ProfileID) throws {}
}

@MainActor
private final class StoreHarness {
    let engine: SiteSyntheticEngine
    let environment: BrowserEnvironment<SiteSyntheticEngine>
    let owner: BrowserWindowController<SiteSyntheticEngine>
    let router: BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>
    let registry: BrowserCommandRegistry<BrowserWindowController<SiteSyntheticEngine>>
    let source: SiteSyntheticSurface
    let tabCount: Int
    let requests: [URL]
    let generation: UInt64

    init() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        engine = SiteSyntheticEngine()
        engine.extensions = StoreExtensionProbe()
        environment = BrowserEnvironment(engine: engine)
        owner = try await environment.makeWindow()
        let controller = owner
        router = BrowserWindowRouter(create: { _ in controller }, present: { _, _ in }, dispose: { _ in })
        registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow(id: owner.id)
        await router.waitForPendingCommands()
        owner.palette.registry = registry
        owner.openTab(url: URL(string: "https://retained.store-fixture.test/form")!)
        await owner.session.waitForPendingCommands()
        source = try #require(owner.session.selectedSurface)
        tabCount = try #require(owner.session.snapshot?.tabs.count)
        requests = source.requestedURLs
        generation = source.documentGeneration
    }

    func settle() async {
        await owner.palette.waitForAcceptance()
        await router.waitForPendingCommands()
        await owner.session.waitForPendingCommands()
    }

    func checkNewStoreTab() throws {
        #expect(owner.session.snapshot?.tabs.count == tabCount + 1)
        #expect(owner.session.selectedSurface !== source)
        #expect(owner.session.selectedSurface?.currentURL?.absoluteString == "https://chromewebstore.google.com/")
        #expect(owner.session.selectedSurface?.profileID == source.profileID)
        #expect(!source.isDisposed)
        #expect(source.currentURL?.absoluteString == "https://retained.store-fixture.test/form")
        #expect(source.requestedURLs == requests)
        #expect(source.documentGeneration == generation)
    }

    func close() async throws {
        environment.autoArchive.scheduler.stop()
        owner.palette.dismiss(returnFocus: false)
        router.shutdown()
        owner.session.close()
        try await environment.finalize()
        owner.window?.close()
    }
}

extension NativeWebKitTests {
@Suite("Extension Store opens a separate tab", .serialized)
@MainActor
struct ExtensionStoreNewTabTests {
    @Test("Queued profile and Space changes revoke Store creation without creating in a new context",
          arguments: [false, true])
    func pendingContextCannotRetarget(returnToOrigin: Bool) async throws {
        let harness = try await StoreHarness()
        let originalSpace = try #require(harness.owner.session.snapshot?.activeSpaceID)
        let profile = await harness.environment.store.createProfile(name: "Queued Store profile")
        let space = try await harness.environment.store.createSpace(name: "Queued Store Space", profileID: profile)
        let before = await harness.environment.store.sessionDocument()
        harness.owner.session.activateSpace(space)
        if returnToOrigin { harness.owner.session.activateSpace(originalSpace) }
        #expect(harness.owner.session.hasPendingCommands)
        #expect(harness.owner.isSitePermissionTarget(harness.source))
        harness.owner.openExtensionStore(from: harness.source)
        await harness.settle()
        let after = await harness.environment.store.sessionDocument()
        #expect(after.tabs == before.tabs)
        let store = URL(string: "https://chromewebstore.google.com/")!
        #expect(harness.engine.surfaces.allSatisfy { !$0.requestedURLs.contains(store) })
        #expect(harness.source.requestedURLs == harness.requests)
        #expect(harness.owner.session.activeProfileID == (returnToOrigin ? harness.source.profileID : profile))
        try await harness.close()
    }

    @Test("Plus menu preserves the original document and creates one selected Store tab")
    func creationMenu() async throws {
        let harness = try await StoreHarness()
        let action = try #require(harness.owner.makeCreationActions().first { $0.command == .addExtension })
        action.perform()
        await harness.settle()
        try harness.checkNewStoreTab()
        try await harness.close()
    }

    @Test("The Extensions menu shares the non-destructive new-tab route")
    func applicationMenu() async throws {
        let harness = try await StoreHarness()
        #expect(harness.registry.dispatch(.addExtension, origin: .menu))
        await harness.settle()
        try harness.checkNewStoreTab()
        try await harness.close()
    }

    @Test("Both palette modes preserve the original document when accepting Add Extension")
    func paletteModes() async throws {
        for mode in [BrowserPaletteMode.newTab, .currentTab] {
            let harness = try await StoreHarness()
            harness.owner.palette.present(mode)
            await harness.owner.palette.waitForResults()
            harness.owner.palette.query("add extension")
            let index = try #require(harness.owner.palette.results.firstIndex { $0.action == .command(.addExtension) })
            harness.owner.palette.move(index - harness.owner.palette.selection.index)
            harness.owner.palette.accept()
            await harness.settle()
            try harness.checkNewStoreTab()
            try await harness.close()
        }
    }

    @Test("Site Controls opens a new Store tab while a revoked row remains inert")
    func siteControls() async throws {
        let harness = try await StoreHarness()
        var rows: [NSView] = []
        var current = true
        harness.owner.siteControls.appendExtensionRows(to: &rows, surface: harness.source, valid: { current })
        let action = try #require(rows.compactMap { $0 as? SiteControlButton }.first {
            $0.accessibilityIdentifier() == "extensions-store"
        })
        current = false
        action.onPress?()
        await harness.settle()
        #expect(harness.owner.session.snapshot?.tabs.count == harness.tabCount)
        #expect(harness.source.requestedURLs == harness.requests)
        current = true
        action.onPress?()
        await harness.settle()
        try harness.checkNewStoreTab()
        try await harness.close()
    }

    @Test("Little Circa opens a separate same-profile target and never replaces its document")
    func quickWindowTarget() async throws {
        let harness = try await StoreHarness()
        let little = try await harness.environment.makeQuickWindow()
        let source = try #require(little.surface)
        source.navigate(to: URL(string: "https://little.store-fixture.test/form")!)
        let requests = source.requestedURLs, generation = source.documentGeneration
        let target = harness.environment.registerQuickWindow(spaceID: little.sourceSpaceID,
            profileID: little.profileID, spaceName: little.sourceSpaceName)
        var child: SiteSyntheticSurface?
        little.onNewTarget = { origin, request, make in
            #expect(origin === source)
            #expect(request.url?.absoluteString == "https://chromewebstore.google.com/")
            #expect(request.disposition == .newForegroundTab)
            child = make()
            #expect(target.adoptNewTarget(child!))
            return child
        }
        little.openExtensionStore(from: source)
        let created = try #require(child)
        #expect(created !== source && created.profileID == source.profileID)
        #expect(created.currentURL?.absoluteString == "https://chromewebstore.google.com/")
        #expect(source.requestedURLs == requests && source.documentGeneration == generation)
        little.onNewTarget = { _, _, _ in source }
        little.openExtensionStore(from: source)
        #expect(source.requestedURLs == requests)
        let mainRequests = harness.source.requestedURLs
        little.onNewTarget = { _, _, _ in harness.source }
        little.openExtensionStore(from: source)
        #expect(harness.source.requestedURLs == mainRequests)
        target.retire()
        little.retire()
        try await harness.close()
    }
}
}
