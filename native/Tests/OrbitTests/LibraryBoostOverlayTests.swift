import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Library Boost overlays", .serialized)
@MainActor
struct LibraryBoostOverlayTests {
    @Test("Opening retains Library and its selection, editing targets the overlay, and promotion keeps the live page")
    func openEditCloseAndPromote() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.submitAddress("https://source.test/")
        await owner.session.waitForPendingCommands()
        let source = try #require(owner.session.selectedSurface)
        let profile = source.profileID
        let store = try environment.boosts.store(for: profile)
        let draft = try await BrowserBoostEditorSession.create(in: store,
            url: URL(string: "http://127.0.0.1:9187/fixture")!, title: "Synthetic")
        owner.showLibrary(.boosts)
        await owner.session.waitForPendingCommands()
        let selected = owner.session.snapshot?.selectedOccurrenceID
        let count = owner.session.ownedSurfaces.count
        owner.openLibraryBoost(draft.boost, profile: profile)
        await owner.boostTask?.value
        let page = try #require(owner.presentedPeekSurface)
        let editor = try #require(owner.boostEditor)
        #expect(owner.library.isPresented)
        #expect(owner.session.snapshot?.selectedOccurrenceID == selected)
        #expect(owner.session.ownedSurfaces.count == count)
        #expect(page.currentURL?.absoluteString == "http://127.0.0.1:9187")
        #expect(owner.pageCommandSurface() === page)
        #expect(owner.isBoostPageTarget(page))
        #expect(!owner.isBoostPageTarget(source))
        #expect(editor.pageHost === page.hostView)
        #expect(owner.peek.overlay.presentationBounds == owner.peek.overlay.bounds)
        #expect(owner.peek.overlay.toolbar.splitButton.isHidden)
        editor.session.edit { $0.fontFamily = "Courier" }
        await editor.session.pending?.value
        #expect(await store.snapshot().boosts.first?.content.fontFamily == "Courier")
        await owner.library.boostsTask?.value
        owner.library.boostsView.searchField.stringValue = "Renamed"
        owner.library.boostsView.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(owner.library.boostsView.displayed.isEmpty)
        editor.session.rename(to: "Renamed fixture")
        await editor.session.pending?.value
        await owner.library.boostsTask?.value
        #expect(owner.library.boostsView.displayed.map(\.title) == ["Renamed fixture"])
        #expect(!BrowserLibraryBoostsView.matches(editor.session.boost, query: "Synthetic"))
        owner.dismissPeek(animated: false)
        #expect(owner.boostEditor == nil)
        #expect(page.isDisposed)
        #expect(owner.library.isPresented)
        #expect(owner.window?.firstResponder === (owner.libraryFocusView as? NSTextField)?.currentEditor()
                || owner.window?.firstResponder === owner.libraryFocusView)
        owner.openLibraryBoost(draft.boost, profile: profile)
        await owner.boostTask?.value
        let reopened = try #require(owner.presentedPeekSurface)
        let promoted = await owner.promotePeekToTab()?.value
        #expect(promoted != nil)
        await owner.session.waitForPendingCommands()
        #expect(!owner.library.isPresented)
        #expect(!owner.isPeekPresented)
        #expect(owner.session.selectedSurface === reopened)
        #expect(!reopened.isDisposed)
        #expect(owner.boostEditor?.pageHost === reopened.hostView)
        #expect(owner.peek.overlay.placedView !== reopened.hostView)
    }

    @Test("A stale Library open cannot replace a page after the Library closes")
    func staleOpen() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        let profile = try #require(owner.session.activeProfileID)
        let store = try environment.boosts.store(for: profile)
        let draft = try await BrowserBoostEditorSession.create(in: store,
            url: URL(string: "https://example.test:9443")!, title: "Synthetic")
        owner.showLibrary(.boosts)
        await owner.session.waitForPendingCommands()
        owner.openLibraryBoost(draft.boost, profile: profile)
        owner.hideLibrary()
        await owner.boostTask?.value
        #expect(!owner.isPeekPresented)
        #expect(owner.boostEditor == nil)
    }
}
}
