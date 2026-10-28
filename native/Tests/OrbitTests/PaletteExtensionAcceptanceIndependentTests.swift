import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import BrowserShell
@testable import Orbit

@MainActor
private final class AcceptanceReviewManager: BrowserExtensionHost {
    var supportsActions = false
    var onExtensionsChange: ((ProfileID) -> Void)?
    var deliveries: [ObjectIdentifier] = []
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] { [] }
    func openManagement(on surface: any BrowserEngineSurface) throws { deliveries.append(ObjectIdentifier(surface)) }
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws {}
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws {}
    func remove(extensionID: String, in profileID: ProfileID) throws {}
}

@MainActor
private final class AcceptanceReviewState {
    var beforeReturningState: ((BrowserWindowController<SiteSyntheticEngine>) -> Void)?
}

@MainActor
private final class AcceptanceReviewHarness {
    let manager = AcceptanceReviewManager()
    let state = AcceptanceReviewState()
    let environment: BrowserEnvironment<SiteSyntheticEngine>
    let owner: BrowserWindowController<SiteSyntheticEngine>
    let router: BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>
    let registry: BrowserCommandRegistry<BrowserWindowController<SiteSyntheticEngine>>

    init() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        engine.extensions = manager
        environment = BrowserEnvironment(engine: engine)
        owner = try await environment.makeWindow()
        let controller = owner, state = state
        router = BrowserWindowRouter(create: { _ in controller }, present: { _, _ in }, dispose: { _ in })
        registry = try BrowserCommandRegistry(router: router, state: { window in
            // Deterministic injection between preflight's snapshot and delivery's fresh read.
            // The controller, registry, router and command handlers are production code.
            let snapshot = window?.commandState ?? .init()
            if let window { state.beforeReturningState?(window) }
            return snapshot
        })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow(id: owner.id)
        await router.waitForPendingCommands()
        owner.palette.registry = registry
        owner.openTab(url: URL(string: "https://acceptance-review.invalid/form")!)
        await owner.session.waitForPendingCommands()
    }

    func choose(_ command: BrowserCommandID) throws {
        owner.palette.query(command == .manageExtensions ? "manage extensions" : "add extension")
        let index = try #require(owner.palette.results.firstIndex { $0.action == .command(command) })
        owner.palette.move(index - owner.palette.selection.index)
    }

    func show(_ command: BrowserCommandID) async throws {
        owner.palette.present(.newTab)
        await owner.palette.waitForResults()
        try choose(command)
    }

    func settle() async {
        await owner.palette.waitForAcceptance()
        await router.waitForPendingCommands()
        await owner.session.waitForPendingCommands()
    }

    func expectDelivery(_ command: BrowserCommandID, source: SiteSyntheticSurface?, count: Int) {
        if command == .manageExtensions {
            #expect(manager.deliveries == source.map { [ObjectIdentifier($0)] } ?? [])
            #expect(owner.session.snapshot?.tabs.count == count)
        } else {
            #expect(manager.deliveries.isEmpty)
            #expect(owner.session.snapshot?.tabs.count == count + 1)
            #expect(owner.session.selectedSurface !== source)
            #expect(owner.session.selectedSurface?.currentURL?.absoluteString == "https://chromewebstore.google.com/")
        }
        #expect(!owner.palette.isPresented)
    }

    /// Controlled same-occurrence engine replacement, without a model revision or selection
    /// change. Shell internals are used only to inject this fault and preserve ownership cleanup.
    func replaceSelectedSurface() throws -> SiteSyntheticSurface {
        let session = try #require(owner.session)
        let occurrence = try #require(session.snapshot?.selectedOccurrenceID)
        let source = try #require(session.selectedSurface)
        let replacement = environment.engine.makeSurface(profileID: source.profileID, delegate: owner)
        #expect(BrowserSurfaceProvenance.registerFactorySurface(replacement, for: session))
        let order = session.surfaceOrder.firstIndex(of: occurrence)
        let authority = session.authorities[occurrence]
        session.surfaces.removeValue(forKey: occurrence)
        session.surfaceOrder.removeAll { $0 == occurrence }
        session.occurrencesBySurface.removeValue(forKey: ObjectIdentifier(source))
        session.disposeSurface(source)
        session.record(replacement, as: occurrence, authority: authority, at: order)
        replacement.navigate(to: try #require(source.currentURL))
        #expect(replacement.documentGeneration == source.documentGeneration)
        return replacement
    }

    func close() async throws {
        state.beforeReturningState = nil
        environment.autoArchive.scheduler.stop()
        owner.palette.dismiss(returnFocus: false)
        router.shutdown()
        owner.session.close()
        try await environment.finalize()
        #expect(owner.window?.isVisible == false)
        owner.window?.close()
    }
}

extension NativeWebKitTests {
@Suite("Independent extension palette acceptance review", .serialized)
@MainActor
struct PaletteExtensionAcceptanceIndependentTests {
    @Test("Same-occurrence surface replacement before presentation completion revokes acceptance",
          arguments: [BrowserCommandID.manageExtensions, .addExtension])
    func presentationSurfaceReplacement(command: BrowserCommandID) async throws {
        let h = try await AcceptanceReviewHarness()
        let source = try #require(h.owner.session.selectedSurface)
        let revision = h.owner.session.snapshot?.revision
        let occurrence = h.owner.session.snapshot?.selectedOccurrenceID
        let count = try #require(h.owner.session.snapshot?.tabs.count)
        h.owner.palette.present(.newTab)
        try h.choose(command)
        h.owner.palette.accept()
        let replacement = try h.replaceSelectedSurface()
        await h.settle()
        #expect(h.owner.session.snapshot?.revision == revision)
        #expect(h.owner.session.snapshot?.selectedOccurrenceID == occurrence)
        #expect(h.owner.session.selectedSurface === replacement && replacement !== source)
        #expect(h.manager.deliveries.isEmpty && h.owner.session.snapshot?.tabs.count == count)
        #expect(h.owner.palette.isPresented)
        h.owner.palette.accept()
        await h.settle()
        h.expectDelivery(command, source: replacement, count: count)
        try await h.close()
    }

    @Test("Selection A to B to A still revokes the original revision",
          arguments: [BrowserCommandID.manageExtensions, .addExtension])
    func selectionABA(command: BrowserCommandID) async throws {
        let h = try await AcceptanceReviewHarness()
        let source = try #require(h.owner.session.selectedSurface)
        let origin = try #require(h.owner.session.snapshot?.selectedOccurrenceID)
        h.owner.openTab(url: URL(string: "https://acceptance-review.invalid/other")!)
        await h.owner.session.waitForPendingCommands()
        let other = try #require(h.owner.session.snapshot?.selectedOccurrenceID)
        h.owner.session.selectOccurrence(origin)
        await h.owner.session.waitForPendingCommands()
        try await h.show(command)
        let revision = try #require(h.owner.session.snapshot?.revision)
        let count = try #require(h.owner.session.snapshot?.tabs.count)
        h.owner.palette.accept()
        h.owner.session.selectOccurrence(other)
        h.owner.session.selectOccurrence(origin)
        await h.settle()
        #expect(h.owner.session.selectedSurface === source)
        #expect((h.owner.session.snapshot?.revision ?? 0) > revision)
        #expect(h.manager.deliveries.isEmpty && h.owner.session.snapshot?.tabs.count == count)
        #expect(h.owner.palette.isPresented)
        h.owner.palette.accept()
        await h.settle()
        h.expectDelivery(command, source: source, count: count)
        try await h.close()
    }

    @Test("A preflight document or surface replacement cannot acquire a fresh retry receipt",
          arguments: [BrowserCommandID.manageExtensions, .addExtension], [false, true])
    func droppedDispatchReplacement(command: BrowserCommandID, replaceSurface: Bool) async throws {
        let h = try await AcceptanceReviewHarness()
        let source = try #require(h.owner.session.selectedSurface)
        let count = try #require(h.owner.session.snapshot?.tabs.count)
        let generation = source.documentGeneration
        try await h.show(command)
        var injected = false
        var freshReads = 0
        var replacement: SiteSyntheticSurface?
        h.state.beforeReturningState = { owner in
            if injected { freshReads += 1; return }
            guard owner.palette.target != nil else { return }
            injected = true
            if replaceSurface { replacement = try? h.replaceSelectedSurface() }
            else { source.reload() }
        }
        h.owner.palette.accept()
        await h.settle()
        #expect(injected && freshReads >= 2)
        if replaceSurface {
            #expect(replacement != nil && h.owner.session.selectedSurface === replacement)
            #expect(source.documentGeneration == generation)
        } else { #expect(source.documentGeneration > generation) }
        #expect(h.manager.deliveries.isEmpty && h.owner.session.snapshot?.tabs.count == count)
        #expect(h.owner.palette.isPresented)
        h.state.beforeReturningState = nil
        h.owner.palette.accept()
        await h.settle()
        h.expectDelivery(command, source: replaceSurface ? replacement : source, count: count)
        try await h.close()
    }

    @Test("A busy delivery can retry unchanged authority without losing address-token independence",
          arguments: [BrowserCommandID.manageExtensions, .addExtension])
    func droppedDispatchUnchangedDocument(command: BrowserCommandID) async throws {
        let h = try await AcceptanceReviewHarness()
        let source = try #require(h.owner.session.selectedSurface)
        let count = try #require(h.owner.session.snapshot?.tabs.count)
        try await h.show(command)
        var injected = false
        var busyReads = 0
        h.state.beforeReturningState = { owner in
            if owner.session.hasPendingCommands { busyReads += 1 }
            guard !injected, owner.palette.target != nil else { return }
            injected = true
            owner.recordExplicitInput()
            owner.session.performWindowAction {}
        }
        h.owner.palette.accept()
        await h.settle()
        #expect(injected && busyReads > 0)
        h.expectDelivery(command, source: source, count: count)
        try await h.close()
    }

    @Test("Cancellation or closure before presentation completion cannot dispatch",
          arguments: [BrowserCommandID.manageExtensions, .addExtension], ["dismiss", "edit", "close"])
    func revokedAcceptance(command: BrowserCommandID, reason: String) async throws {
        let h = try await AcceptanceReviewHarness()
        let count = try #require(h.owner.session.snapshot?.tabs.count)
        h.owner.palette.present(.newTab)
        try h.choose(command)
        h.owner.palette.accept()
        switch reason {
        case "dismiss": h.owner.palette.dismiss(returnFocus: false)
        case "edit": h.owner.palette.query("newer synthetic draft")
        default: h.owner.session.close()
        }
        await h.settle()
        #expect(h.manager.deliveries.isEmpty)
        if reason != "close" { #expect(h.owner.session.snapshot?.tabs.count == count) }
        if reason == "edit" {
            #expect(h.owner.palette.isPresented)
            #expect(h.owner.palette.view.input.stringValue == "newer synthetic draft")
        }
        try await h.close()
    }

    @Test("An unchanged empty selection preserves existing Store admission and refuses manager")
    func emptySelection() async throws {
        let h = try await AcceptanceReviewHarness()
        let initialCount = try #require(h.owner.session.snapshot?.tabs.count)
        for _ in 0..<initialCount {
            h.owner.session.closeSelectedTab()
            await h.owner.session.waitForPendingCommands()
        }
        let hasNoSelection = h.owner.session.selectedSurface == nil
        #expect(hasNoSelection)
        let count = try #require(h.owner.session.snapshot?.tabs.count)
        try await h.show(.manageExtensions)
        h.owner.palette.accept()
        await h.settle()
        #expect(h.manager.deliveries.isEmpty && h.owner.palette.isPresented)
        try h.choose(.addExtension)
        h.owner.palette.accept()
        await h.settle()
        h.expectDelivery(.addExtension, source: nil, count: count)
        try await h.close()
    }
}
}
