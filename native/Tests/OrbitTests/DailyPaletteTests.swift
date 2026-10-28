import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class DailyExtensionProbe: BrowserExtensionHost {
    var supportsActions = false
    var onExtensionsChange: ((ProfileID) -> Void)?
    var managed: (any BrowserEngineSurface)?
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] { [] }
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws {}
    func openManagement(on surface: any BrowserEngineSurface) throws { managed = surface }
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws {}
    func remove(extensionID: String, in profileID: ProfileID) throws {}
}

extension NativeWebKitTests {
@Suite("Daily palette and creation authority", .serialized)
@MainActor
struct DailyPaletteTests {
    @Test("Real application New Window dispatch from the palette creates a window, preserving the source profile and tab count")
    func realApplicationNewWindow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        var keyWindow: NSWindow?
        let app = OrbitApplication(environment: environment, commandKeyWindow: { keyWindow }, windowPresenter: { _, _ in })
        defer { environment.autoArchive.scheduler.stop(); app.windows.shutdown() }
        let firstID = try #require(app.windows.newWindow())
        await app.windows.waitForPendingCommands()
        let first = try #require(app.windows.windows[firstID])
        keyWindow = first.window
        let count = first.session.snapshot?.tabs.count
        #expect(app.commands.registry.dispatch(.newTab, origin: .keyboard))
        await app.windows.waitForPendingCommands()
        await first.palette.waitForResults()
        #expect(first.session.snapshot?.tabs.count == count)
        #expect(first.palette.results.prefix(4).map(\.action) == [.command(.newWindow), .command(.newIncognitoWindow), .command(.manageExtensions), .command(.addExtension)])
        first.palette.query("nouvelle fenêtre")
        let index = try #require(first.palette.results.firstIndex { $0.action == .command(.newWindow) })
        first.palette.move(index - first.palette.selection.index)
        first.palette.accept()
        await first.palette.waitForAcceptance()
        await app.windows.waitForPendingCommands()
        #expect(app.windows.windows.count == 2)
        #expect(first.session.snapshot?.tabs.count == count)
        let created = try #require(app.windows.windows.values.first { $0 !== first })
        #expect(created.session.activeProfileID == first.session.activeProfileID)
        #expect(!first.palette.isPresented)
        #expect(app.windows.windows.values.allSatisfy { $0.window?.isVisible == false })
    }

    @Test("A background palette cannot create a window for the newly selected foreign window")
    func realApplicationForeignWindow() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        var keyWindow: NSWindow?
        let app = OrbitApplication(environment: environment, commandKeyWindow: { keyWindow }, windowPresenter: { _, _ in })
        defer { environment.autoArchive.scheduler.stop(); app.windows.shutdown() }
        let firstID = try #require(app.windows.newWindow())
        let secondID = try #require(app.windows.newWindow())
        await app.windows.waitForPendingCommands()
        let first = try #require(app.windows.windows[firstID])
        let second = try #require(app.windows.windows[secondID])
        app.windows.activate(firstID)
        keyWindow = first.window
        first.palette.present(.newTab)
        await first.palette.waitForResults()
        first.palette.query("new window")
        let index = try #require(first.palette.results.firstIndex { $0.action == .command(.newWindow) })
        first.palette.move(index - first.palette.selection.index)
        app.windows.activate(secondID)
        keyWindow = second.window
        first.palette.accept()
        await first.palette.waitForAcceptance()
        await app.windows.waitForPendingCommands()
        #expect(app.windows.windows.count == 2 && first.palette.isPresented)
        // Even a key-window receipt cannot authorize New Window to inherit from a different
        // router selection while activation/publication is in flight.
        keyWindow = first.window
        first.palette.accept()
        await first.palette.waitForAcceptance()
        await app.windows.waitForPendingCommands()
        #expect(app.windows.windows.count == 2 && first.palette.isPresented)
    }

    @Test("French and English basic actions remain searchable in both palette modes")
    func aliases() throws {
        let actions: [BrowserPaletteResult] = [.newWindow, .manageExtensions, .addExtension].map { id in
            .init(id: id.rawValue, title: id.rawValue, detail: "", section: .commands, action: .command(id),
                  searchAliases: BrowserDailyCommands.aliases(id))
        }
        let tab = BrowserPaletteResult(id: "synthetic-tab", title: "Synthetic tab", detail: "", section: .tabs,
                                       action: .tab(TabID(), windowID: nil, spaceID: nil))
        let empty = BrowserPaletteRanking.results(query: "", mode: .newTab, resolver: AddressResolver(), candidates: [tab], history: [], actions: actions)
        #expect(empty.prefix(3).map(\.action) == actions.map(\.action))
        #expect(empty.dropFirst(3).first?.id == tab.id)
        for (query, command) in [("new window", BrowserCommandID.newWindow), ("nouvelle fenetre", .newWindow),
                                  ("manage extensions", .manageExtensions), ("gérer les extensions", .manageExtensions),
                                  ("add extension", .addExtension), ("ajouter une extension", .addExtension), ("chrome web store", .addExtension)] {
            for mode in [BrowserPaletteMode.newTab, .currentTab] {
                let results = BrowserPaletteRanking.results(query: query, mode: mode, resolver: AddressResolver(), candidates: [], history: [], actions: actions)
                #expect(results.contains { $0.action == .command(command) })
            }
        }
    }

    @Test("Creation callbacks use real routes and reject stale or foreign windows without making a premature tab")
    func capturedCreationRoutes() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let host = DailyExtensionProbe()
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let controller = try await environment.makeWindow()
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(create: { _ in controller }, present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow(id: controller.id)
        await router.waitForPendingCommands()
        controller.palette.registry = registry
        defer { environment.autoArchive.scheduler.stop(); router.shutdown(); controller.window?.close() }
        let source = try #require(controller.session.selectedSurface)
        #expect(registry.dispatch(.newTab, origin: .keyboard))
        await router.waitForPendingCommands()
        await controller.palette.waitForResults()
        controller.palette.query("gérer les extensions")
        let managerIndex = try #require(controller.palette.results.firstIndex { $0.action == .command(.manageExtensions) })
        controller.palette.move(managerIndex - controller.palette.selection.index)
        controller.palette.accept()
        await controller.palette.waitForAcceptance()
        await controller.session.waitForPendingCommands()
        #expect((host.managed as? SiteSyntheticSurface) === source)
        let actions = controller.makeCreationActions()
        let count = controller.session.snapshot?.tabs.count
        let manage = try #require(actions.first { $0.command == .manageExtensions })
        manage.perform()
        await router.waitForPendingCommands(); await controller.session.waitForPendingCommands()
        #expect((host.managed as? SiteSyntheticSurface) === source)
        let stale = try #require(controller.makeCreationActions().first { $0.command == .addExtension })
        host.managed = nil
        controller.palette.present(.newTab)
        await controller.palette.waitForResults()
        controller.palette.query("manage extensions")
        let staleManager = try #require(controller.palette.results.firstIndex { $0.action == .command(.manageExtensions) })
        controller.palette.move(staleManager - controller.palette.selection.index)
        controller.openTab(url: URL(string: "https://synthetic.test/")!)
        await controller.session.waitForPendingCommands()
        let replacement = try #require(controller.session.selectedSurface)
        controller.palette.accept()
        await controller.palette.waitForAcceptance()
        #expect(host.managed == nil && controller.palette.isPresented)
        controller.palette.dismiss(returnFocus: false)
        stale.perform()
        await router.waitForPendingCommands(); await controller.session.waitForPendingCommands()
        #expect(replacement.currentURL?.host == "synthetic.test")
        let store = try #require(controller.makeCreationActions().first { $0.command == .addExtension })
        store.perform()
        await router.waitForPendingCommands(); await controller.session.waitForPendingCommands()
        #expect(replacement.currentURL?.host == "synthetic.test")
        let storeSurface = try #require(controller.session.selectedSurface)
        #expect(storeSurface !== replacement)
        #expect(storeSurface.currentURL?.absoluteString == "https://chromewebstore.google.com/")
        #expect(controller.session.snapshot?.tabs.count == (count ?? 0) + 2)
        let menu = SidebarCreationMenu(actions: controller.makeCreationActions(), accent: .defaultSpace)
        _ = menu.view
        #expect(menu.view.frame.width == 210)
        let buttonFrame = NSRect(x: 186, y: 10, width: 36, height: 36)
        let anchored = SidebarCreationPopup.panelFrame(buttonFrameOnScreen: buttonFrame, size: NSSize(width: 210, height: 270))
        #expect(anchored.maxX == buttonFrame.midX + 24 - 8)
        #expect(anchored.minY == buttonFrame.maxY + 4)
        #expect(menu.handle(#selector(NSResponder.moveDown(_:))))
        #expect(menu.handle(#selector(NSResponder.cancelOperation(_:))))
        host.managed = nil
        let keyboardAction = try #require(controller.makeCreationActions().first { $0.command == .manageExtensions })
        let keyboardMenu = SidebarCreationMenu(actions: [keyboardAction], accent: .defaultSpace)
        _ = keyboardMenu.view
        #expect(keyboardMenu.handle(#selector(NSResponder.moveDown(_:))))
        #expect(keyboardMenu.handle(#selector(NSResponder.insertNewline(_:))))
        await router.waitForPendingCommands(); await controller.session.waitForPendingCommands()
        #expect((host.managed as? SiteSyntheticSurface) === storeSurface)
        engine.extensions = nil
        #expect(!registry.isEnabled(.manageExtensions))
        #expect(controller.makeCreationActions().contains { $0.command == .manageExtensions && !$0.enabled })
        #expect(controller.window?.isVisible == false)
    }
}
}
