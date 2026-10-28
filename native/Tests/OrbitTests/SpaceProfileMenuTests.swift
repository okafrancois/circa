import AppKit
import BrowserCore
import BrowserShell
import BrowserEngineConformance
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SpaceProfileMenuTests {
    private func respond(_ completion: ((NSApplication.ModalResponse) -> Void)?, _ response: NSApplication.ModalResponse) throws {
        let callback = try #require(completion)
        callback(response)
    }

    private func fixture() async throws -> (BrowserEnvironment<SyntheticEngine>, BrowserWindowController<SyntheticEngine>, SpaceID, ProfileID) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        let window = try await environment.makeWindow()
        let space = try #require(window.session.snapshot?.activeSpaceID)
        let target = try await environment.store.createSettingsProfile(name: "Target")
        await environment.refreshSettingsCatalog()
        await window.session.waitForPendingCommands()
        return (environment, window, space, target)
    }

    @Test("Native context and menu bar destinations list profiles, check the current one, and offer creation last")
    func contents() async throws {
        let (environment, window, space, _) = try await fixture()
        defer { environment.autoArchive.scheduler.stop(); window.window?.close() }
        let menu = try #require(window.makeSpaceProfileMenu(for: space))
        let profiles = try #require(window.session.catalog?.profiles)
        #expect(menu.items.map(\.title) == profiles.map(\.name) + ["", uiText("New Profile…")])
        #expect(menu.items.dropLast(2).map(\.state) == profiles.map { $0.id == window.session.activeProfileID ? .on : .off })
        let context = try #require(window.sidebar.page.spaceContextMenu)
        window.sidebar.page.menuNeedsUpdate(context)
        let entry = try #require(context.items.first { $0.title == uiText("Set Profile") })
        #expect(entry.submenu is BrowserSpaceProfileMenu)
        #expect(context.items.firstIndex(of: entry) == 3)
        let router = BrowserWindowRouter<BrowserWindowController<SyntheticEngine>>(
            create: { _ in window }, present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        try registry.register(.changeProfile) { _, _ in }
        let menus = BrowserCommandMenus(registry: registry)
        menus.profileMenuProvider = { window.makeSpaceProfileMenu(for: space) }
        let bar = menus.makeMenuBar()
        let spaces = try #require(bar.items.first { $0.title == uiText("Spaces") }?.submenu)
        let entryInBar = try #require(spaces.items.first { $0.title == uiText("Change Profile") })
        let dynamic = try #require(entryInBar.submenu as? BrowserDynamicProfileMenu)
        dynamic.menuNeedsUpdate(dynamic)
        #expect(dynamic.items.map(\.title) == menu.items.map(\.title))
        let extra = try await environment.store.createSettingsProfile(name: "Later")
        await environment.refreshSettingsCatalog()
        await window.session.waitForPendingCommands()
        dynamic.menuNeedsUpdate(dynamic)
        #expect(dynamic.items.map(\.title).contains("Later"))
        #expect(window.session.catalog?.profiles.contains { $0.id == extra } == true)
    }

    @Test("Selecting another profile confirms before invoking the environment move and retaining the Space")
    func move() async throws {
        let (environment, window, space, target) = try await fixture()
        defer { environment.autoArchive.scheduler.stop(); window.window?.close() }
        let source = try #require(window.session.activeProfileID)
        let operation = try #require(window.onMoveSpaceToProfile)
        var calls = 0
        window.onMoveSpaceToProfile = { id, to, expected in
            #expect(id == space && to == target && expected == source)
            calls += 1
            try await operation(id, to, expected)
        }
        let menu = try #require(window.makeSpaceProfileMenu(for: space))
        var complete: ((NSApplication.ModalResponse) -> Void)?
        menu.presentAlert = { alert, completion in
            #expect(alert.messageText == "Switch to your Target Profile?")
            #expect(alert.informativeText.contains(menu.space.name + " Space might look a little different!"))
            #expect(alert.informativeText.hasSuffix("This action cannot be undone."))
            #expect(alert.buttons.map(\.title) == [uiText("Switch it up"), uiText("Cancel")])
            complete = completion
        }
        let index = try #require(window.session.catalog?.profiles.firstIndex { $0.id == target })
        menu.performActionForItem(at: index)
        #expect(calls == 0)
        try respond(complete, .alertFirstButtonReturn)
        await menu.pending?.value
        await window.session.waitForPendingCommands()
        #expect(calls == 1)
        #expect(await environment.store.catalogSnapshot().spaces.first { $0.id == space }?.profileID == target)
        #expect(window.session.activeProfileID == target)
        let refreshed = try #require(window.makeSpaceProfileMenu(for: space))
        #expect(refreshed.items[index].state == .on)
        complete?(.alertFirstButtonReturn)
        #expect(calls == 1)
    }

    @Test("Current profile, menu dismissal, warning Cancel and stale confirmation never move a Space")
    func cancelAndStale() async throws {
        let (environment, window, space, target) = try await fixture()
        defer { environment.autoArchive.scheduler.stop(); window.window?.close() }
        let before = await environment.store.sessionDocument()
        let menu = try #require(window.makeSpaceProfileMenu(for: space))
        var complete: ((NSApplication.ModalResponse) -> Void)?
        var alerts = 0
        menu.presentAlert = { _, completion in alerts += 1; complete = completion }
        let profiles = try #require(window.session.catalog?.profiles)
        menu.cancelTracking()
        #expect(await environment.store.sessionDocument() == before)
        menu.performActionForItem(at: try #require(profiles.firstIndex { $0.id == menu.space.profileID }))
        #expect(alerts == 0 && menu.pending == nil)
        let targetIndex = try #require(profiles.firstIndex { $0.id == target })
        menu.performActionForItem(at: targetIndex)
        try respond(complete, .alertSecondButtonReturn)
        #expect(menu.pending == nil)
        #expect(await environment.store.sessionDocument() == before)
        menu.performActionForItem(at: targetIndex)
        try await environment.store.renameSettingsProfile(target, name: "Replaced")
        await environment.refreshSettingsCatalog()
        await window.session.waitForPendingCommands()
        try respond(complete, .alertFirstButtonReturn)
        #expect(menu.pending == nil)
        #expect(await environment.store.catalogSnapshot().spaces.first { $0.id == space }?.profileID == menu.space.profileID)
    }

    @Test("New Profile Cancel has no effects; creation assigns only the captured Space without an extra Space")
    func newProfile() async throws {
        let (environment, window, space, _) = try await fixture()
        defer { environment.autoArchive.scheduler.stop(); window.window?.close() }
        let before = await environment.store.catalogSnapshot()
        let menu = try #require(window.makeSpaceProfileMenu(for: space))
        var complete: ((NSApplication.ModalResponse) -> Void)?
        menu.presentAlert = { alert, completion in
            #expect(alert.messageText == uiText("Create a new Profile"))
            #expect(alert.buttons.map(\.title) == [uiText("Create Profile"), uiText("Cancel")])
            (alert.accessoryView as? NSTextField)?.stringValue = "Created"
            complete = completion
        }
        menu.performActionForItem(at: menu.items.count - 1)
        try respond(complete, .alertSecondButtonReturn)
        #expect(await environment.store.catalogSnapshot() == before)
        menu.performActionForItem(at: menu.items.count - 1)
        try respond(complete, .alertFirstButtonReturn)
        await menu.pending?.value
        let after = await environment.store.catalogSnapshot()
        #expect(after.profiles.count == before.profiles.count + 1)
        #expect(after.spaces.count == before.spaces.count)
        let created = try #require(after.profiles.first { $0.name == "Created" })
        #expect(after.spaces.first { $0.id == space }?.profileID == created.id)
    }
}
}
