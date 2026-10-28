import AppKit
import BrowserCore
@testable import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Independent theme menu review", .serialized)
@MainActor
struct NativeThemeMenuIndependentReviewTests {
    private typealias Controller = BrowserWindowController<PeekSyntheticEngine>

    @MainActor
    private final class Fixture {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        var controllers: [UUID: Controller] = [:]
        var key: NSWindow?
        lazy var router = BrowserWindowRouter<Controller>(
            create: { [unowned self] id in controllers[id]! }, present: { _, _ in },
            dispose: { $0.session.close(); $0.window?.close() })
        lazy var registry: BrowserCommandRegistry<Controller> = {
            let registry = try! BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
                currentWindowID: { [unowned self] in
                    BrowserCommandWindowRouting.route(router: router, keyWindow: key, nativeWindow: { $0.window }).windowID
                }, deliver: { controller, action in controller.performAcceptedCommand(action) })
            BrowserWindowCommands.install(in: registry, commandKeyWindow: { [unowned self] in key })
            return registry
        }()

        func addWindow(spaceID: SpaceID? = nil) async throws -> Controller {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let controller = try await environment.makeWindow(spaceID: spaceID)
            controllers[controller.id] = controller
            router.newWindow(id: controller.id)
            await router.waitForPendingCommands()
            return controller
        }

        func close() { router.shutdown() }
    }

    @Test("The key browser wins over router selection and later focus changes do not redirect accepted input")
    func twoBrowserFocus() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let first = try await fixture.addWindow()
        let profile = await fixture.environment.store.createProfile(name: "Independent synthetic profile")
        let space = try await fixture.environment.store.createSpace(name: "Independent synthetic Space", profileID: profile)
        let second = try await fixture.addWindow(spaceID: space)
        #expect(fixture.router.selectedWindowID == second.id)
        fixture.key = first.window
        #expect(fixture.registry.dispatch(.editTheme, origin: .menu))
        fixture.key = second.window
        await first.session.waitForPendingCommands()
        let editor = try #require(first.themeEditor)
        #expect(editor.spaceID == first.session.snapshot?.activeSpaceID)
        #expect(editor.profileID == first.session.activeProfileID)
        #expect(editor.profileID != profile)
        #expect(second.themeEditor == nil)
        #expect(first.window?.isVisible == false && second.window?.isVisible == false)
        editor.close(animated: false)
        await editor.waitUntilFinished()
    }

    @Test("Closing or freezing between admission and session execution refuses a queued editor", arguments: [false, true])
    func lifetimeRevalidation(freeze: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let controller = try await fixture.addWindow()
        fixture.key = controller.window
        // No suspension before invalidation: the session Task cannot run on MainActor yet.
        #expect(fixture.registry.dispatch(.editTheme, origin: .menu))
        if freeze {
            #expect(await fixture.environment.themeEditors.finishAll())
        } else {
            controller.session.close()
        }
        await controller.session.waitForPendingCommands()
        #expect(controller.themeEditor == nil)
        #expect(!fixture.registry.isEnabled(.editTheme))
    }

    @Test("Deletion followed by profile quarantine cannot open a stale menu editor or fallback editor")
    func quarantinedProfile() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        _ = try await fixture.environment.initialContext.value
        let profile = try await fixture.environment.store.createSettingsProfile(name: "Independent quarantined profile")
        let space = try await fixture.environment.store.createSpace(name: "Independent deleted Space", profileID: profile)
        let controller = try await fixture.addWindow(spaceID: space)
        fixture.key = controller.window
        let target = try #require(fixture.registry.captureTarget())
        var rejected = false
        controller.session.onError = { _ in rejected = true }
        try await fixture.environment.store.removeSettingsSpace(space, expectedProfileID: profile)
        _ = try await fixture.environment.store.reserveSettingsProfileRemoval(profile)
        _ = fixture.registry.dispatch(.editTheme, origin: .contextMenu, target: target)
        await controller.session.waitForPendingCommands()
        #expect(controller.themeEditor == nil)
        #expect(rejected)
        #expect(await fixture.environment.store.isSettingsProfileBeingRemoved(profile))
        await fixture.environment.store.cancelSettingsProfileReservation(profile)
    }
}
}
