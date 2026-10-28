import AppKit
import BrowserCore
import BrowserShell
import Testing
import WebKitEngine
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeCommandIntegrationTests {
    @Test("Production handlers retain command order while New Tab only presents the palette")
    func realSessionCommandOrder() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { controller, action in controller.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry)
        let first = try #require(router.newWindow())
        // The second command is accepted while creation or session publication is pending.
        #expect(registry.dispatch(.newTab, origin: .keyboard))
        #expect(registry.dispatch(.duplicate, origin: .menu))
        #expect(registry.dispatch(.archiveTab, origin: .keyboard))
        #expect(registry.dispatch(.restoreLastClosedTab, origin: .palette))
        let second = try #require(router.newWindow())
        #expect(registry.dispatch(.newTab, origin: .keyboard))
        await router.waitForPendingCommands()
        let firstWindow = try #require(router.windows[first])
        let secondWindow = try #require(router.windows[second])
        await firstWindow.session.waitForPendingCommands()
        await secondWindow.session.waitForPendingCommands()
        #expect(firstWindow.session.snapshot?.tabs.count == 2)
        #expect(secondWindow.session.snapshot?.tabs.count == 1)
        let firstSurface = try #require(firstWindow.session.selectedSurface)
        let secondSurface = try #require(secondWindow.session.selectedSurface)
        #expect(firstSurface !== secondSurface)
        #expect(firstWindow.window?.isVisible == false)
        #expect(secondWindow.window?.isVisible == false)
    }

    @Test("Production sidebar and zoom handlers target the captured hidden window without activation")
    func realCapturedWindowCommands() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { controller, action in controller.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry)
        let first = try #require(router.newWindow())
        registry.dispatch(.newTab, origin: .keyboard)
        await router.waitForPendingCommands()
        let firstWindow = try #require(router.windows[first])
        await firstWindow.session.waitForPendingCommands()
        let target = try #require(registry.captureTarget())
        let second = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let secondWindow = try #require(router.windows[second])
        #expect(registry.dispatch(.showHideSidebar, origin: .contextMenu, target: target))
        await firstWindow.session.waitForPendingCommands()
        #expect(!firstWindow.isSidebarVisible)
        #expect(secondWindow.isSidebarVisible)
        let zoomTarget = try #require(registry.captureTarget(windowID: first))
        #expect(registry.dispatch(.zoomIn, origin: .palette, target: zoomTarget))
        await firstWindow.session.waitForPendingCommands()
        #expect(firstWindow.session.selectedSurface?.pageZoom ?? 0 > 1)
        #expect(router.selectedWindowID == second)
        #expect(firstWindow.window?.isVisible == false)
        #expect(!NSApp.isActive)
    }
    @Test("A palette target survives delegated field edits while an address edit revokes an explicit-input capture")
    func paletteAndAddressFieldDelegates() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        router.newWindow()
        await router.waitForPendingCommands()
        let controller = try #require(router.selectedWindow)
        await controller.session.waitForPendingCommands()
        let palette = try #require(registry.capturePaletteTarget())
        let regular = try #require(registry.captureTarget())
        let token = controller.explicitInputToken
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: NSTextField()))
        #expect(controller.explicitInputToken == token)
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.addressField))
        #expect(controller.explicitInputToken != token)
        #expect(registry.isEnabled(.showHideSidebar, target: palette))
        #expect(!registry.isEnabled(.showHideSidebar, target: regular))
        #expect(controller.window?.isVisible == false)
    }

    @Test("The THEME sidebar binding remains page-first while the menu follows Orbit without feature appendices")
    func mergedFeatureMenuRouting() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { controller, action in controller.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry)
        #expect(registry.isImplemented(.showSiteControls))
        #expect(registry.isImplemented(.showHideSidebar))
        router.newWindow()
        await router.waitForPendingCommands()
        let controller = try #require(router.selectedWindow)
        await controller.session.waitForPendingCommands()
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        let menus = BrowserCommandMenus(registry: registry)
        let bar = menus.makeMenuBar()
        let view = try #require(bar.items.first { $0.title == "View" }?.submenu)
        let site = view.items.filter { $0.identifier?.rawValue == BrowserCommandID.showSiteControls.rawValue }
        #expect(site.isEmpty)
        #expect(site.allSatisfy { $0.allowsAutomaticKeyEquivalentLocalization && $0.allowsAutomaticKeyEquivalentMirroring })
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 1, windowNumber: 0, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        #expect(!keyboard.handle(event))
        let original = controller.isSidebarShown
        // A handled page event stops here and never reaches the native menu.
        await controller.session.waitForPendingCommands()
        #expect(controller.isSidebarShown == original)
        // The same event, declined by the page, reaches the real THEME handler via the menu.
        #expect(bar.performKeyEquivalent(with: event))
        await controller.session.waitForPendingCommands()
        #expect(controller.isSidebarShown != original)
        #expect(!keyboard.handle(event))
        #expect(bar.performKeyEquivalent(with: event))
        await controller.session.waitForPendingCommands()
        #expect(controller.isSidebarShown == original)
        #expect(controller.window?.isVisible == false)
    }

}

}
