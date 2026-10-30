import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeShortcutParityTests {
    @Test("Force refresh and console retain the displayed document and stay page-first")
    func documentCommands() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = PeekSyntheticEngine()
        engine.capabilities.formUnion([.cacheBypassingReload, .devTools])
        let environment = BrowserEnvironment(engine: engine)
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { controller, action in controller.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry)
        router.newWindow()
        await router.waitForPendingCommands()
        let controller = try #require(router.selectedWindow)
        await controller.session.waitForPendingCommands()
        let surface = try #require(controller.session.selectedSurface)
        for id in [BrowserCommandID.forceRefreshThePage, .javascriptConsole] {
            #expect(!registry.prefersBrowser(id))
            #expect(registry.dispatch(id, origin: .keyboard))
            await controller.session.waitForPendingCommands()
        }
        #expect(surface.cacheBypassingReloadCount == 1)
        #expect(surface.developerPanels == [.console])
        engine.capabilities.remove(.cacheBypassingReload)
        #expect(!registry.isEnabled(.forceRefreshThePage))
        #expect(!registry.dispatch(.forceRefreshThePage, origin: .keyboard))
    }

    @Test("Paste as a new tab captures explicit clipboard input without replacing the document")
    func pasteNewTab() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        var clipboard: String? = "http://127.0.0.1:19876/pasted"
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { controller, action in controller.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry, pasteboardString: { clipboard })
        router.newWindow()
        await router.waitForPendingCommands()
        let controller = try #require(router.selectedWindow)
        await controller.session.waitForPendingCommands()
        let original = try #require(controller.session.selectedSurface)
        let count = try #require(controller.session.snapshot?.tabs.count)
        #expect(registry.dispatch(.pasteAsNewTab, origin: .keyboard))
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.tabs.count == count + 1)
        #expect(controller.session.selectedSurface !== original)
        #expect(controller.session.selectedSurface?.navigationState.url?.path == "/pasted")
        clipboard = "synthetic clipboard search"
        registry.dispatch(.pasteAsNewTab, origin: .keyboard)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface?.currentURL == controller.addressResolver.searchEngine.searchURL(for: clipboard!))
        for invalid in [nil, "", "javascript:alert(1)", "https://user:secret@example.invalid/"] {
            clipboard = invalid
            registry.dispatch(.pasteAsNewTab, origin: .keyboard)
            await controller.session.waitForPendingCommands()
            #expect(controller.session.snapshot?.tabs.count == count + 2)
        }
    }

    @Test("Native Find actions retain their responder selectors and panel tags")
    func nativeFindActions() {
        #expect(BrowserStandardActions.selector(for: .findAndReplace) == #selector(NSTextView.performFindPanelAction(_:)))
        #expect(BrowserStandardActions.tag(for: .findAndReplace) == 12)
        #expect(BrowserStandardActions.tag(for: .useSelectionToFind) == 7)
        #expect(BrowserStandardActions.selector(for: .jumpToSelection) == #selector(NSResponder.centerSelectionInVisibleArea(_:)))
    }
}
}
