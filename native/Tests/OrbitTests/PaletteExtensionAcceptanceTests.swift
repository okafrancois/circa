import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class PaletteManagerProbe: BrowserExtensionHost {
    var supportsDetachedActions = true
    var supportsActions = true
    var supportsOptionsPages = true
    var items: [BrowserExtensionSummary] = []
    var actions: [String] = []
    var options: [String] = []
    var actionSurfaces: [ObjectIdentifier] = []
    var onExtensionsChange: ((ProfileID) -> Void)?
    private(set) var managed: [ObjectIdentifier] = []
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] { items }
    func openManagement(on surface: any BrowserEngineSurface) throws { managed.append(ObjectIdentifier(surface)) }
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws {
        actions.append(extensionID)
        Issue.record("Palette must not use an anchored action")
    }
    func performDetachedAction(extensionID: String, on surface: any BrowserEngineSurface) throws {
        actions.append(extensionID)
        actionSurfaces.append(ObjectIdentifier(surface))
    }
    func openOptions(extensionID: String, on surface: any BrowserEngineSurface) throws { options.append(extensionID) }
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws {}
    func remove(extensionID: String, in profileID: ProfileID) throws {}
}

@MainActor
private final class ExtensionAcceptanceHarness {
    let probe = PaletteManagerProbe()
    let environment: BrowserEnvironment<SiteSyntheticEngine>
    let owner: BrowserWindowController<SiteSyntheticEngine>
    let router: BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>
    let registry: BrowserCommandRegistry<BrowserWindowController<SiteSyntheticEngine>>

    init() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        engine.extensions = probe
        environment = BrowserEnvironment(engine: engine)
        owner = try await environment.makeWindow()
        let controller = owner
        router = BrowserWindowRouter(create: { _ in controller }, present: { _, _ in }, dispose: { _ in })
        registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow(id: owner.id)
        await router.waitForPendingCommands()
        owner.palette.registry = registry
        owner.openTab(url: URL(string: "https://palette-acceptance.test/form")!)
        await owner.session.waitForPendingCommands()
    }

    func choose(_ command: BrowserCommandID) throws {
        owner.palette.query(command == .manageExtensions ? "manage extensions" : "add extension")
        let index = try #require(owner.palette.results.firstIndex { $0.action == .command(command) })
        owner.palette.move(index - owner.palette.selection.index)
    }

    func settle() async {
        await owner.palette.waitForAcceptance()
        await router.waitForPendingCommands()
        await owner.session.waitForPendingCommands()
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
@Suite("Extension palette acceptance retains its original document", .serialized)
@MainActor
struct PaletteExtensionAcceptanceTests {
    @Test("Installed actions use the original surface after dismissing the palette", arguments: [false, true])
    func installedAction(newTab: Bool) async throws {
        let h = try await ExtensionAcceptanceHarness()
        var item = BrowserExtensionSummary(id: "fixture", name: "Palette Fixture", version: "1", isEnabled: true, hasAction: true)
        item.hasOptionsPage = true
        item.iconPNGBase64 = NativeFaviconReceiptTests.png().base64EncodedString()
        h.probe.items = [item]
        if newTab {
            h.owner.openTab(url: nil)
            await h.owner.session.waitForPendingCommands()
        }
        let source = try #require(h.owner.session.selectedSurface)
        h.owner.palette.present(.newTab)
        await h.owner.palette.waitForResults()
        h.owner.palette.query("Palette Fixture")
        let action: BrowserPaletteAction = .extensionAction(item.id)
        let index = try #require(h.owner.palette.results.firstIndex { $0.action == action })
        #expect(h.owner.palette.view.favicons[h.owner.palette.results[index].id] != nil)
        h.owner.palette.move(index - h.owner.palette.selection.index)
        if newTab { h.owner.palette.view.onSelect?(index) }
        else { h.owner.palette.accept() }
        await h.settle()
        #expect(!h.owner.palette.isPresented)
        #expect(h.probe.actions == [item.id])
        #expect(h.probe.options.isEmpty)
        #expect(h.probe.actionSurfaces == [ObjectIdentifier(source)])
        try await h.close()
    }

    @Test("A queued navigation or disabled extension revokes installed action acceptance", arguments: [false, true])
    func staleInstalledAction(disabled: Bool) async throws {
        let h = try await ExtensionAcceptanceHarness()
        h.probe.items = [.init(id: "fixture", name: "Palette Fixture", version: "1", isEnabled: true, hasAction: true)]
        h.owner.palette.present(.newTab)
        await h.owner.palette.waitForResults()
        h.owner.palette.query("Palette Fixture")
        let index = try #require(h.owner.palette.results.firstIndex { $0.action == .extensionAction("fixture") })
        h.owner.palette.move(index - h.owner.palette.selection.index)
        if disabled { h.probe.items[0].isEnabled = false }
        else { h.owner.session.performOnSelectedSurface { $0.reload() } }
        h.owner.palette.accept()
        await h.settle()
        #expect(h.probe.actions.isEmpty)
        #expect(h.owner.palette.isPresented)
        try await h.close()
    }

    @Test("Queued document commits revoke extension actions in either palette mode",
          arguments: [BrowserCommandID.manageExtensions, .addExtension], [false, true])
    func pendingDocument(command: BrowserCommandID, currentTab: Bool) async throws {
        let h = try await ExtensionAcceptanceHarness()
        let source = try #require(h.owner.session.selectedSurface)
        let generation = source.documentGeneration
        let count = h.owner.session.snapshot?.tabs.count
        h.owner.palette.present(currentTab ? .currentTab : .newTab)
        await h.owner.palette.waitForResults()
        try h.choose(command)
        h.owner.session.performOnSelectedSurface { $0.reload() }
        #expect(h.owner.session.hasPendingCommands)
        h.owner.palette.accept()
        await h.settle()
        #expect(source.documentGeneration > generation)
        #expect(h.probe.managed.isEmpty)
        #expect(h.owner.session.snapshot?.tabs.count == count)
        #expect(h.owner.session.selectedSurface === source)
        #expect(h.owner.palette.isPresented)
        // A later explicit acceptance belongs to the new document and remains functional.
        h.owner.palette.accept()
        await h.settle()
        if command == .manageExtensions {
            #expect(h.probe.managed == [ObjectIdentifier(source)])
            #expect(h.owner.session.snapshot?.tabs.count == count)
        } else {
            #expect(h.owner.session.snapshot?.tabs.count == (count ?? 0) + 1)
            #expect(h.owner.session.selectedSurface !== source)
            #expect(h.owner.session.selectedSurface?.currentURL?.absoluteString == "https://chromewebstore.google.com/")
        }
        #expect(!h.owner.palette.isPresented)
        #expect(h.owner.window?.isVisible == false)
        try await h.close()
    }

    @Test("Acceptance before the presentation boundary does not borrow the later document",
          arguments: [BrowserCommandID.manageExtensions, .addExtension])
    func presentationBoundary(command: BrowserCommandID) async throws {
        let h = try await ExtensionAcceptanceHarness()
        let source = try #require(h.owner.session.selectedSurface)
        let generation = source.documentGeneration
        let count = h.owner.session.snapshot?.tabs.count
        h.owner.session.performOnSelectedSurface { $0.reload() }
        h.owner.palette.present(.newTab)
        try h.choose(command)
        h.owner.palette.accept()
        await h.settle()
        #expect(source.documentGeneration > generation)
        #expect(h.probe.managed.isEmpty)
        #expect(h.owner.session.snapshot?.tabs.count == count)
        #expect(h.owner.palette.isPresented)
        #expect(h.owner.window?.isVisible == false)
        try await h.close()
    }
}
}
