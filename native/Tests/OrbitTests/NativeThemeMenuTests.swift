import AppKit
import BrowserCore
@testable import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Theme menu command routing", .serialized)
@MainActor
struct NativeThemeMenuTests {
    private typealias Controller = BrowserWindowController<PeekSyntheticEngine>

    @MainActor
    private final class Fixture {
        let environment: BrowserEnvironment<PeekSyntheticEngine>
        let controller: Controller
        let router: BrowserWindowRouter<Controller>
        var key: NSWindow?

        init() async throws {
            NSApplication.shared.setActivationPolicy(.prohibited)
            environment = BrowserEnvironment(engine: PeekSyntheticEngine())
            controller = try await environment.makeWindow()
            let controller = controller
            router = BrowserWindowRouter(create: { _ in controller }, present: { _, _ in },
                                         dispose: { $0.session.close(); $0.window?.close() })
            key = controller.window
        }

        // Match production's key-window route rather than the registry's selected-window default.
        func commands() throws -> BrowserCommandRegistry<Controller> {
            let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
                currentWindowID: { [unowned self] in
                    BrowserCommandWindowRouting.route(router: router, keyWindow: key, nativeWindow: { $0.window }).windowID
                }, deliver: { window, action in window.performAcceptedCommand(action) })
            BrowserWindowCommands.install(in: registry, commandKeyWindow: { [unowned self] in key })
            return registry
        }

        func prepare() async {
            router.newWindow(id: controller.id)
            await router.waitForPendingCommands()
        }

        func close() { router.shutdown() }
    }

    private func themeItem(_ menus: BrowserCommandMenus<Controller>) throws -> NSMenuItem {
        let spaces = try #require(menus.makeMenuBar().items.first { $0.title == "Spaces" }?.submenu)
        return try #require(spaces.items.first { $0.identifier?.rawValue == BrowserCommandID.editTheme.rawValue })
    }

    private func invoke(_ item: NSMenuItem) throws {
        #expect(NSApplication.shared.sendAction(try #require(item.action), to: item.target, from: item))
    }

    @Test("Spaces menu opens the existing editor for the active Space and captured profile")
    func menuOpensEditor() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        await fixture.prepare()
        let registry = try fixture.commands()
        let menus = BrowserCommandMenus(registry: registry, keyWindow: { fixture.key })
        let item = try themeItem(menus)
        #expect(registry.isImplemented(.editTheme))
        #expect(item.toolTip?.contains("Not implemented") == false)
        #expect(menus.validateMenuItem(item))
        let space = try #require(fixture.controller.session.snapshot?.activeSpaceID)
        let profile = try #require(fixture.controller.session.activeProfileID)
        try invoke(item)
        await fixture.router.waitForPendingCommands()
        await fixture.controller.session.waitForPendingCommands()
        let editor = try #require(fixture.controller.themeEditor)
        #expect(editor.spaceID == space && editor.profileID == profile)
        #expect(editor.panel?.isVisible == false && fixture.controller.window?.isVisible == false)
        editor.close(animated: false)
        await editor.waitUntilFinished()
    }

    @Test("Settings and Little Orbit key windows never borrow a background browser Space")
    func auxiliaryWindowsRefuseThemeCommand() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        await fixture.prepare()
        let registry = try fixture.commands()
        let settings = BrowserSettingsWindowController(model: BrowserSettingsModel(environment: fixture.environment,
            profileID: fixture.controller.session.activeProfileID, shortcuts: []))
        defer { settings.window?.close() }
        let little = try await fixture.environment.makeQuickWindow(spaceID: fixture.controller.session.snapshot?.activeSpaceID,
                                                               url: URL(string: "about:blank")!)
        defer { little.window?.close() }
        BrowserQuickWindowCommands.install(in: registry, active: { fixture.key === little.window ? little : nil },
                                         promote: { _ in }, chooseSpace: { _ in })
        let menus = BrowserCommandMenus(registry: registry, keyWindow: { fixture.key })
        let item = try themeItem(menus)
        for key in [settings.window, little.window, nil] {
            fixture.key = key
            #expect(!menus.validateMenuItem(item))
            #expect(item.toolTip?.contains("Requires an active Space") == true)
            try invoke(item)
            await fixture.router.waitForPendingCommands()
            await fixture.controller.session.waitForPendingCommands()
            #expect(fixture.controller.themeEditor == nil)
        }
    }

    @Test("Captured menu targets are refused after a cross-profile Space switch")
    func capturedTargetCannotFollowProfileSwitch() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        await fixture.prepare()
        let registry = try fixture.commands()
        let capture = try #require(registry.captureTarget())
        let menus = BrowserCommandMenus(registry: registry, target: capture, keyWindow: { fixture.key })
        let item = try themeItem(menus)
        let profile = await fixture.environment.store.createProfile(name: "Other synthetic profile")
        let space = try await fixture.environment.store.createSpace(name: "Other synthetic Space", profileID: profile)
        fixture.controller.session.activateSpace(space)
        await fixture.controller.session.waitForPendingCommands()
        #expect(!menus.validateMenuItem(item))
        try invoke(item)
        await fixture.router.waitForPendingCommands()
        await fixture.controller.session.waitForPendingCommands()
        #expect(fixture.controller.themeEditor == nil)
    }

    @Test("Theme command resolves earlier Space switches in session order")
    func pendingSpaceSwitchUsesItsProfile() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        await fixture.prepare()
        let registry = try fixture.commands()
        let profile = await fixture.environment.store.createProfile(name: "Queued synthetic profile")
        let space = try await fixture.environment.store.createSpace(name: "Queued synthetic Space", profileID: profile)
        fixture.controller.session.activateSpace(space)
        #expect(registry.dispatch(.editTheme, origin: .menu))
        await fixture.router.waitForPendingCommands()
        await fixture.controller.session.waitForPendingCommands()
        let editor = try #require(fixture.controller.themeEditor)
        #expect(editor.spaceID == space && editor.profileID == profile)
        editor.close(animated: false)
        await editor.waitUntilFinished()
    }

    @Test("A deleted Space refuses captured menu delivery without editing its fallback")
    func deletedSpaceIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        await fixture.prepare()
        let registry = try fixture.commands()
        let space = try #require(fixture.controller.session.snapshot?.activeSpaceID)
        let profile = try #require(fixture.controller.session.activeProfileID)
        _ = try await fixture.environment.store.createSpace(name: "Synthetic fallback", profileID: profile)
        fixture.controller.session.refreshCatalog()
        await fixture.controller.session.waitForPendingCommands()
        let capture = try #require(registry.captureTarget())
        let menus = BrowserCommandMenus(registry: registry, target: capture, keyWindow: { fixture.key })
        let item = try themeItem(menus)
        var rejected = false
        fixture.controller.session.onError = { _ in rejected = true }
        try await fixture.environment.store.removeSettingsSpace(space, expectedProfileID: profile)
        try invoke(item)
        await fixture.router.waitForPendingCommands()
        await fixture.controller.session.waitForPendingCommands()
        #expect(fixture.controller.themeEditor == nil)
        #expect(rejected, "Store authority must reject a deleted Space even before the displayed context refreshes")
    }
}
}
