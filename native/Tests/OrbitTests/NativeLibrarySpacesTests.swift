import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Library Spaces destination", .serialized)
@MainActor
struct NativeLibrarySpacesTests {
    private typealias Controller = BrowserWindowController<SiteSyntheticEngine>
    private func fixture(onInput: ((@escaping @MainActor (Controller) -> Void) -> Void)? = nil) async throws -> (Controller, BrowserStore, ProfileID, ProfileID, SpaceID, SpaceID, SpaceID) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let a = await store.createProfile(name: "Synthetic Málaga")
        let b = await store.createProfile(name: "Synthetic Other")
        let first = try await store.createSpace(name: "Mint", profileID: a)
        let second = try await store.createSpace(name: "Violet", profileID: a)
        let third = try await store.createSpace(name: "Coral", profileID: b)
        let identity = try await store.createWindow(activeSpaceID: first)
        let controller = Controller(id: UUID(), store: store, spaceID: first, engine: SiteSyntheticEngine(),
            restoringWindowID: identity, onInput: onInput, onClose: {}, onActivate: {})
        await controller.session.waitForPendingCommands()
        controller.session.openTab(url: URL(string: "https://library-spaces.fixture.test/form")!)
        await controller.session.waitForPendingCommands()
        return (controller, store, a, b, first, second, third)
    }

    @Test("The native Library exposes Spaces alongside retained destinations")
    func visibleDestination() {
        let titles = BrowserLibraryCategory.allCases.map(\.title)
        #expect(titles.contains(uiText("Spaces")))
        let view = BrowserLibraryView()
        #expect(view.categoryButtons.count == 4)
    }

    @Test("Spaces inventory searches names and profiles without materializing documents")
    func inventoryAndSearch() async throws {
        let (controller, _, _, _, first, _, _) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        let surface = try #require(controller.session.selectedSurface)
        let created = controller.engine.surfaces.count
        let generation = surface.documentGeneration
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let view = controller.library.spacesView
        #expect(!view.isHidden && view.rows.count == 3)
        #expect(controller.libraryFocusView === view.searchField)
        #expect(controller.engine.surfaces.count == created)
        #expect(controller.session.snapshot?.activeSpaceID == first)
        view.searchField.stringValue = "malaga"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(view.rows.map(\.space.name) == ["Mint", "Violet"])
        view.searchField.stringValue = "coRAL"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(view.rows.map(\.space.name) == ["Coral"])
        view.cancelOperation(nil)
        #expect(view.rows.count == 3 && controller.library.isPresented)
        view.cancelOperation(nil)
        await controller.session.waitForPendingCommands()
        #expect(!controller.library.isPresented && view.rows.isEmpty)
        #expect(controller.session.selectedSurface === surface && surface.documentGeneration == generation)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Actual row activation crosses profiles explicitly and preserves the original document on return")
    func activateAndReturn() async throws {
        let (controller, _, _, b, first, _, third) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        let surface = try #require(controller.session.selectedSurface)
        let requests = surface.requestedURLs
        let generation = surface.documentGeneration
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let view = controller.library.spacesView
        view.table.selectRowIndexes(IndexSet(integer: try #require(view.rows.firstIndex { $0.space.id == third })), byExtendingSelection: false)
        view.table.onReturn?()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == third && controller.session.activeProfileID == b)
        #expect(!controller.library.isPresented)
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        view.table.selectRowIndexes(IndexSet(integer: try #require(view.rows.firstIndex { $0.space.id == first })), byExtendingSelection: false)
        view.openSelected()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface === surface)
        #expect(surface.documentGeneration == generation && surface.requestedURLs == requests)
        #expect(controller.window?.isVisible == false)
    }

    @Test("A queued inventory click cannot be reinterpreted after a source change or close and reopen")
    func queuedRevocation() async throws {
        var delayed: (@MainActor (Controller) -> Void)?
        let (controller, _, _, _, _, second, third) = try await fixture(onInput: { delayed = $0 })
        defer { controller.session.close(); controller.window?.close() }
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let view = controller.library.spacesView
        let oldTicket = controller.library.presentationID
        let catalog = try #require(controller.session.catalog)
        view.table.selectRowIndexes(IndexSet(integer: try #require(view.rows.firstIndex { $0.space.id == third })), byExtendingSelection: false)
        view.openSelected()
        let action = try #require(delayed)
        controller.session.activateSpace(second)
        await controller.session.waitForPendingCommands()
        action(controller)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == second)
        controller.hideLibrary()
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        view.onOpen?(third, catalog, oldTicket)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == second && controller.library.isPresented)
    }

    @Test("A reassigned target is rejected atomically against the displayed catalog")
    func targetReassignment() async throws {
        let (controller, store, a, _, first, _, third) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let view = controller.library.spacesView
        view.table.selectRowIndexes(IndexSet(integer: try #require(view.rows.firstIndex { $0.space.id == third })), byExtendingSelection: false)
        try await store.assignSettingsSpace(third, to: a)
        view.openSelected()
        await controller.session.waitForPendingCommands()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == first)
        #expect(controller.library.isPresented)
        #expect(view.rows.first(where: { $0.space.id == third })?.space.profileID == a)
    }

    @Test("Search arrows and Return activate visible identity while filtering never retargets a selection")
    func keyboardAndIdentity() async throws {
        let (controller, _, _, b, _, _, third) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let view = controller.library.spacesView
        let input = NSTextView()
        #expect(view.control(view.searchField, textView: input, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(view.table.selectedRow == 0)
        view.searchField.stringValue = "Coral"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(view.rows.count == 1 && view.table.selectedRow == -1)
        #expect(view.control(view.searchField, textView: input, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(view.control(view.searchField, textView: input, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == third && controller.session.activeProfileID == b)
    }

    @Test("Inventory exposes the saved composed emoji and fits the retained minimum drawer geometry")
    func iconAndGeometry() async throws {
        let (controller, _, _, _, first, _, _) = try await fixture()
        defer { controller.session.close(); controller.window?.close() }
        let previousMotion = OrbitMotionPreferences.overrideReducedMotion
        defer { OrbitMotionPreferences.overrideReducedMotion = previousMotion }
        let runtime = BrowserSettingsRuntime(store: try BrowserSettingsStore())
        try await runtime.updateSpace(first) { $0.icon = "🧑🏽‍💻" }
        controller.settingsPreferences = BrowserWindowSettings(runtime: runtime)
        controller.window?.setContentSize(NSSize(width: 600, height: 400))
        controller.showLibrary(.spaces)
        await controller.session.waitForPendingCommands()
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let view = controller.library.spacesView
        #expect(view.rows.first(where: { $0.space.id == first })?.icon == "🧑🏽‍💻")
        #expect(view.searchField.bounds.width > 0)
        #expect(!view.hasAmbiguousLayout)
        #expect(controller.library.view.body.frame.maxX <= controller.library.view.bounds.maxX)
        #expect(!controller.contentCard.isHidden)
    }
}
}
