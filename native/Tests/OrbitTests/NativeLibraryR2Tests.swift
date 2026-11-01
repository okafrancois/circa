import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

/// Synthetic navigation emits real controller/recorder events but never requests network data.
@MainActor
private final class LibraryPersistentEngine: BrowserEngine {
    typealias Surface = SiteSyntheticSurface
    let base = SiteSyntheticEngine()
    let kind = BrowserEngineKind.synthetic
    var capabilities: BrowserEngineCapabilities { base.capabilities.union(.persistentProfiles) }
    var extensions: (any BrowserExtensionHost)? { nil }
    var conformanceProbe: (any BrowserEngineConformanceProbe<Surface>)? { nil }
    func profile(for id: ProfileID) -> BrowserEngineProfile { .init(profileID: id, persistence: .persistent) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<Surface>) -> Surface {
        base.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async { await base.shutdown() }
}

@MainActor
private struct LibraryR2Fixture {
    let root: URL
    let recorder: BrowserHistoryRecorder
    let controller: BrowserWindowController<LibraryPersistentEngine>
    let a: ProfileID
    let b: ProfileID
    let spaceA: SpaceID
    let spaceB: SpaceID
    static func make() async throws -> Self {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-library-r2-\(UUID())")
        let engine = LibraryPersistentEngine()
        let recorder = BrowserHistoryRecorder(directory: root, resolveProfile: engine.profile(for:))
        let store = BrowserStore()
        let a = await store.createProfile(name: "Synthetic A")
        let b = await store.createProfile(name: "Synthetic B")
        let spaceA = try await store.createSpace(name: "A", profileID: a)
        let spaceB = try await store.createSpace(name: "B", profileID: b)
        let window = try await store.createWindow(activeSpaceID: spaceA)
        let controller = BrowserWindowController(id: UUID(), store: store, spaceID: spaceA,
            engine: engine, restoringWindowID: window, history: recorder, onClose: {}, onActivate: {})
        await controller.session.waitForPendingCommands()
        return Self(root: root, recorder: recorder, controller: controller, a: a, b: b, spaceA: spaceA, spaceB: spaceB)
    }
    func show() async {
        controller.showLibrary(.history)
        await controller.session.waitForPendingCommands()
        await controller.library.history.task?.value
    }
    func close() async throws {
        controller.session.close(); controller.window?.close()
        await controller.library.deletionTask?.value
        try await recorder.close()
        try FileManager.default.removeItem(at: root)
    }
}

extension NativeWebKitTests.NativeLibraryTests {
@Suite("Library R2 regressions", .serialized)
@MainActor
struct RoundTwo {
    @Test("Inserts between OFFSET pages never duplicate IDs and day headings merge across real multi-day pages")
    func insertedPagesAndDays() async throws {
        let f = try await LibraryR2Fixture.make()
        let calendar = Calendar.current
        let noon = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12)))
        let visits = (0..<450).map { index in
            BrowserHistoryVisit(url: URL(string: "https://pages.library.test/\(index)")!, title: "Synthetic",
                visitedAt: noon.addingTimeInterval(-Double(index < 201 ? index : 86400 + index)))
        }
        _ = try await f.recorder.importDocument(.init(profileID: f.a, visits: visits))
        await f.show()
        let model = f.controller.library.history
        #expect(model.visits.count == 200)
        let incoming = (1...5).map { BrowserHistoryVisit(url: URL(string: "https://new.library.test/\($0)")!, visitedAt: noon.addingTimeInterval(Double($0))) }
        _ = try await f.recorder.importDocument(.init(profileID: f.a, visits: incoming))
        model.loadMore(); await model.task?.value
        #expect(model.visits.count == 395)
        model.loadMore(); await model.task?.value
        #expect(Set(model.visits.map(\.id)) == Set(visits.map(\.id)))
        #expect(model.visits.count == 450)
        #expect(!model.hasMore)
        let days = f.controller.library.historyView.rows.compactMap { row -> Date? in if case .day(let date) = row { return date }; return nil }
        #expect(days.count == 2)
        #expect(Set(days).count == 2)
        try await f.close()
    }

    @Test("Debounced latest-only searches keep rows and avoid loading-state table reloads")
    func debounceAndRows() async throws {
        let f = try await LibraryR2Fixture.make()
        let visits = [BrowserHistoryVisit(url: URL(string: "https://search.library.test/one")!, title: "Café"),
                      BrowserHistoryVisit(url: URL(string: "https://search.library.test/two")!, title: "Other")]
        _ = try await f.recorder.importDocument(.init(profileID: f.a, visits: visits))
        await f.show()
        let model = f.controller.library.history
        let view = f.controller.library.historyView
        let before = view.reloadCount
        model.search("oth")
        let cancelled = model.task
        model.search("cafe")
        #expect(cancelled?.isCancelled == true)
        #expect(model.visits.count == 2)
        #expect(view.reloadCount == before)
        await model.task?.value
        #expect(model.visits.map(\.id) == [visits[0].id])
        #expect(view.reloadCount == before + 1)
        try await f.close()
    }

    @Test("Persistent controller history follows Space profiles, rejects stale rows and opens the displayed visit")
    func controllerProfilesAndOpen() async throws {
        let f = try await LibraryR2Fixture.make()
        let one = BrowserHistoryVisit(url: URL(string: "https://a.library.test/open")!, title: "Profile A")
        let two = BrowserHistoryVisit(url: URL(string: "https://b.library.test/open")!, title: "Profile B")
        _ = try await f.recorder.importDocument(.init(profileID: f.a, visits: [one]))
        _ = try await f.recorder.importDocument(.init(profileID: f.b, visits: [two]))
        await f.show()
        #expect(f.controller.library.history.visits.map(\.id) == [one.id])
        f.controller.session.activateSpace(f.spaceB)
        await f.controller.session.waitForPendingCommands()
        await f.controller.library.history.task?.value
        #expect(f.controller.library.isPresented)
        #expect(f.controller.library.history.visits.map(\.id) == [two.id])
        f.controller.library.historyView.onOpen?(one)
        await f.controller.session.waitForPendingCommands()
        #expect(f.controller.library.isPresented)
        f.controller.library.historyView.onOpen?(two)
        await f.controller.session.waitForPendingCommands()
        #expect(!f.controller.library.isPresented)
        #expect(f.controller.session.selectedSurface?.currentURL == two.url)
        #expect(f.controller.session.activeProfileID == f.b)
        #expect(f.controller.window?.isVisible == false)
        try await f.close()
    }

    @Test("Controller deletion confirmations name host and profile, delete exactly and reject a profile switch")
    func controllerConfirmations() async throws {
        let f = try await LibraryR2Fixture.make()
        let one = BrowserHistoryVisit(url: URL(string: "https://target.library.test/one")!)
        let sub = BrowserHistoryVisit(url: URL(string: "https://sub.target.library.test/keep")!)
        _ = try await f.recorder.importDocument(.init(profileID: f.a, visits: [one, sub]))
        _ = try await f.recorder.importDocument(.init(profileID: f.b, visits: [one]))
        await f.show()
        var title = ""; var detail = ""
        f.controller.library.historyConfirmation = { alert in
            title = alert.messageText; detail = alert.informativeText
            return .alertFirstButtonReturn
        }
        f.controller.library.historyView.onDeleteSite?(one)
        await f.controller.library.confirmationTask?.value
        await f.controller.library.deletionTask?.value
        #expect(title.contains("Synthetic A"))
        #expect(detail.contains("target.library.test"))
        #expect(f.controller.library.isPresented)
        #expect(f.controller.library.history.visits.map(\.id) == [sub.id])
        #expect(try await f.recorder.visits(for: f.b).count == 1)
        f.controller.library.historyConfirmation = { alert in
            #expect(alert.informativeText.contains("All History"))
            f.controller.session.activateSpace(f.spaceB)
            await f.controller.session.waitForPendingCommands()
            await f.controller.library.history.task?.value
            return .alertFirstButtonReturn
        }
        f.controller.library.historyView.onDeleteRange?(4)
        await f.controller.library.confirmationTask?.value
        #expect(try await f.recorder.visits(for: f.a).map(\.id) == [sub.id])
        #expect(try await f.recorder.visits(for: f.b).count == 1)
        #expect(f.controller.window?.isVisible == false)
        try await f.close()
    }

    @Test("Custom range confirmations name their boundaries and apply the half-open interval")
    func controllerRangeConfirmation() async throws {
        let f = try await LibraryR2Fixture.make()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let one = BrowserHistoryVisit(url: URL(string: "https://range.library.test/start")!, visitedAt: now)
        let two = BrowserHistoryVisit(url: URL(string: "https://range.library.test/end")!, visitedAt: now.addingTimeInterval(60))
        _ = try await f.recorder.importDocument(.init(profileID: f.a, visits: [one, two]))
        await f.show()
        f.controller.library.historyConfirmation = { alert in
            #expect(alert.messageText.contains("Synthetic A"))
            let range = try! #require(alert.accessoryView as? BrowserLibraryDateRangeView)
            range.start.dateValue = now; range.end.dateValue = now.addingTimeInterval(60)
            range.validateInterval()
            #expect(alert.informativeText.contains(DateFormatter.localizedString(from: now, dateStyle: .medium, timeStyle: .medium)))
            return .alertFirstButtonReturn
        }
        f.controller.library.historyView.onDeleteRange?(3)
        await f.controller.library.confirmationTask?.value
        await f.controller.library.deletionTask?.value
        #expect(f.controller.library.history.visits.map(\.id) == [two.id])
        try await f.close()
    }

    @Test("Tab selection including the selected row, new tabs, address entry and palette activation dismiss Library")
    func navigationDismissal() async throws {
        let f = try await LibraryR2Fixture.make()
        f.controller.openTab(url: URL(string: "https://navigation.library.test/one")!)
        await f.controller.session.waitForPendingCommands()
        let tab = try #require(f.controller.session.organization?.selectedTab?.id)
        for category in BrowserLibraryCategory.allCases {
            f.controller.showLibrary(category); await f.controller.session.waitForPendingCommands()
            f.controller.activateSidebarTab(tab)
            #expect(!f.controller.library.isPresented)
            #expect(!f.controller.archive.isPresented)
            #expect(f.controller.downloadsPane.isHidden)
        }
        await f.show()
        f.controller.openTab(url: URL(string: "https://navigation.library.test/two")!)
        await f.controller.session.waitForPendingCommands()
        #expect(!f.controller.library.isPresented)
        await f.show()
        f.controller.submitAddress("https://navigation.library.test/three")
        await f.controller.session.waitForPendingCommands()
        #expect(!f.controller.library.isPresented)
        await f.show()
        f.controller.session.selectTab(tab)
        await f.controller.session.waitForPendingCommands()
        #expect(f.controller.library.isPresented) // Programmatic selection keeps the Library (R3).
        let router = BrowserWindowRouter<BrowserWindowController<LibraryPersistentEngine>>(create: { _ in f.controller }, present: { _, _ in }, dispose: { _ in })
        _ = router.newWindow(); await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        f.controller.palette.registry = registry
        await f.show()
        #expect(registry.dispatch(.newTab, origin: .keyboard))
        await f.controller.session.waitForPendingCommands()
        #expect(!f.controller.library.isPresented)
        f.controller.palette.dismiss()
        router.shutdown()
        try await f.close()
    }

    @Test("Delete retains the visible history anchor and time-zone notifications regroup without database reads")
    func scrollAndCalendarRefresh() async throws {
        let f = try await LibraryR2Fixture.make()
        let visits = (0..<300).map { BrowserHistoryVisit(url: URL(string: "https://scroll.library.test/\($0)")!, visitedAt: Date().addingTimeInterval(-Double($0))) }
        _ = try await f.recorder.importDocument(.init(profileID: f.a, visits: visits))
        await f.show()
        let view = f.controller.library.historyView
        f.controller.window?.contentView?.layoutSubtreeIfNeeded()
        let scroll = try #require(view.table.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: 30).minY + 2))
        #expect(scroll.contentView.bounds.origin.y > 0, "table=\(view.table.frame), clip=\(scroll.contentView.bounds), target=\(view.table.rect(ofRow: 30))")
        func firstVisitRow() -> Int {
            var point = scroll.contentView.bounds.origin
            point.y += view.table.rect(ofRow: 0).height + view.table.intercellSpacing.height + 1
            return view.table.row(at: point)
        }
        let beforeRow = firstVisitRow()
        guard case .visit(let anchor) = view.rows[beforeRow] else { Issue.record("Expected a visit scroll anchor"); try await f.close(); return }
        #expect(await f.controller.library.history.delete(.visit(visits[0].id), in: f.a))
        let afterRow = firstVisitRow()
        guard case .visit(let kept) = view.rows[afterRow] else { Issue.record("Lost visit scroll anchor"); try await f.close(); return }
        #expect(kept.id == anchor.id)
        let count = view.reloadCount
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try await waitForNativeState("time-zone headings refreshed") { view.reloadCount == count + 1 }
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        await Task.yield()
        #expect(view.reloadCount == count + 1) // Same-day notification is deduplicated (R3).
        #expect(!f.controller.library.history.isLoading)
        try await f.close()
    }

    @Test("Find Next and Previous leave the hidden page's find session untouched")
    func hiddenPageFind() async throws {
        let f = try await LibraryR2Fixture.make()
        f.controller.openTab(url: URL(string: "https://find.library.test/page")!)
        await f.controller.session.waitForPendingCommands()
        let surface = try #require(f.controller.session.selectedSurface)
        f.controller.findSession.show(on: surface)
        f.controller.findSession.submit("Synthetic")
        await f.show()
        var publications = 0
        let previous = f.controller.findSession.onChange
        f.controller.findSession.onChange = { publications += 1; previous?() }
        f.controller.findNext(); f.controller.findPrevious()
        await f.controller.session.waitForPendingCommands()
        #expect(publications == 0)
        #expect(f.controller.library.isPresented)
        try await f.close()
    }

    @Test("Escape clears each category search before closing and Peek stays above the Library")
    func searchEscapeAndLayering() async throws {
        let f = try await LibraryR2Fixture.make()
        let view = f.controller.library.historyView
        await f.show()
        view.searchField.stringValue = "term"
        #expect(view.control(view.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(view.searchField.stringValue.isEmpty)
        #expect(f.controller.library.isPresented)
        #expect(view.control(view.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!f.controller.library.isPresented)
        for category in [BrowserLibraryCategory.downloads, .archive] {
            f.controller.showLibrary(category); await f.controller.session.waitForPendingCommands()
            let field = category == .downloads ? f.controller.downloadsPane.searchField : f.controller.archive.view.searchField
            field.stringValue = "term"
            if category == .downloads {
                _ = f.controller.downloadsPane.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            } else {
                _ = f.controller.archive.view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            }
            #expect(field.stringValue.isEmpty); #expect(f.controller.library.isPresented)
            f.controller.hideLibrary()
        }
        let children = try #require(f.controller.window?.contentView?.subviews)
        let libraryIndex = try #require(children.firstIndex { $0 === f.controller.library.view })
        let peekIndex = try #require(children.firstIndex { $0 === f.controller.peek.overlay })
        #expect(peekIndex > libraryIndex)
        try await f.close()
    }
}
}

extension NativeWebKitTests.NativeLibraryTests {
@Suite("Library R3 gesture and rendering policy", .serialized)
@MainActor
struct RoundThree {
    @Test("New search results reset scroll even when visits match, while refresh preserves the query's position")
    func queryScroll() async throws {
        let f = try await LibraryR2Fixture.make()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let visits = (0..<250).map { BrowserHistoryVisit(url: URL(string: "https://scroll.library.test/\($0)")!, visitedAt: now.addingTimeInterval(-Double($0))) }
        _ = try await f.recorder.importDocument(.init(profileID: f.a, visits: visits))
        await f.show()
        let view = f.controller.library.historyView
        let model = f.controller.library.history
        f.controller.window?.contentView?.layoutSubtreeIfNeeded()
        let clip = try #require(view.table.enclosingScrollView?.contentView)
        func scrollDown() { clip.scroll(to: NSPoint(x: 0, y: view.table.rect(ofRow: 30).minY + 2)) }
        scrollDown(); #expect(clip.bounds.origin.y > 0)
        model.search("scroll.library.test")
        #expect(model.isDebouncing)
        #expect(clip.bounds.origin.y > 0)
        await model.task?.value
        #expect(clip.bounds.origin.y == 0)
        scrollDown()
        let position = clip.bounds.origin.y
        model.reload(); await model.task?.value
        #expect(clip.bounds.origin.y == position)
        try await f.close()
    }

    @Test("Layer ordering keeps the Library below the sidebar and Peek's veil above the whole window")
    func overlayOrder() async throws {
        let f = try await LibraryR2Fixture.make()
        // First access installs the deferred bar in its original stacking position.
        _ = f.controller.findBar
        let children = try #require(f.controller.window?.contentView?.subviews)
        func index(_ view: NSView) throws -> Int { try #require(children.firstIndex { $0 === view }) }
        #expect(try index(f.controller.contentCard) < index(f.controller.findBar))
        #expect(try index(f.controller.findBar) < index(f.controller.library.view))
        #expect(try index(f.controller.library.view) < index(f.controller.windowShell.floatingBackdrop))
        #expect(try index(f.controller.windowShell.floatingBackdrop) < index(f.controller.sidebar))
        // Like Orbit, Peek dims the sidebar too: its overlay covers the whole browser window.
        #expect(try index(f.controller.sidebar) < index(f.controller.peek.overlay))
        await f.show()
        try await f.close()
    }

    @Test("Programmatic tab changes and engine window.open/close keep Library; explicit tab selection dismisses it")
    func programmaticSelection() async throws {
        let f = try await LibraryR2Fixture.make()
        f.controller.openTab(url: URL(string: "https://gestures.library.test/source")!)
        await f.controller.session.waitForPendingCommands()
        let source = try #require(f.controller.session.selectedSurface)
        let tab = try #require(f.controller.session.organization?.selectedTab?.id)
        await f.show()
        f.controller.session.openTab(url: URL(string: "https://gestures.library.test/programmatic")!)
        await f.controller.session.waitForPendingCommands()
        #expect(f.controller.library.isPresented)
        f.controller.session.closeSelectedTab()
        await f.controller.session.waitForPendingCommands()
        #expect(f.controller.library.isPresented)
        let popup = try #require(source.openNewTarget(URL(string: "https://gestures.library.test/popup")!))
        try await waitForNativeState("synthetic popup adopted") { f.controller.session.ownedSurfaces.contains { $0 === popup } }
        await f.controller.session.waitForPendingCommands()
        #expect(f.controller.library.isPresented)
        popup.requestClose()
        await f.controller.session.waitForPendingCommands()
        #expect(f.controller.library.isPresented)
        f.controller.activateSidebarTab(tab)
        #expect(!f.controller.library.isPresented)
        try await f.close()
    }

    @Test("Production commands close Library with Command-W, protect hidden pages and allow the presented Peek")
    func commandPolicy() async throws {
        let f = try await LibraryR2Fixture.make()
        let router = BrowserWindowRouter<BrowserWindowController<LibraryPersistentEngine>>(create: { _ in f.controller }, present: { _, _ in }, dispose: { _ in })
        _ = router.newWindow(); await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        BrowserPeekCommands.install(in: registry)
        await f.show()
        // An empty Space still has a local Library to close, without inventing a page surface.
        #expect(f.controller.session.selectedSurface == nil)
        #expect(registry.isEnabled(.archiveTab))
        #expect(registry.dispatch(.archiveTab, origin: .keyboard))
        #expect(!f.controller.library.isPresented)
        f.controller.openTab(url: URL(string: "https://commands.library.test/source")!)
        await f.controller.session.waitForPendingCommands()
        let source = try #require(f.controller.session.selectedSurface)
        let selected = f.controller.session.snapshot?.selectedOccurrenceID
        await f.show()
        let pageCommands: [BrowserCommandID] = [.find, .findNext, .findPrevious, .zoomIn, .zoomOut, .zoomToActualSize, .copyURL]
        for command in pageCommands { #expect(!registry.isEnabled(command)); #expect(!registry.dispatch(command, origin: .keyboard)) }
        f.controller.changePageZoom(.increase)
        f.controller.showFind()
        await f.controller.session.waitForPendingCommands()
        #expect(source.pageZoom == 1)
        #expect(f.controller.pageCommandSurface() == nil)
        _ = f.controller.openPeek(URL(string: "https://commands.library.test/peek")!)
        #expect(f.controller.isPeekPresented)
        for command in pageCommands { #expect(registry.isEnabled(command)) }
        let peek = try #require(f.controller.presentedPeekSurface)
        #expect(registry.dispatch(.zoomIn, origin: .keyboard))
        await f.controller.session.waitForPendingCommands()
        #expect(peek.pageZoom > 1); #expect(source.pageZoom == 1)
        #expect(registry.dispatch(.archiveTab, origin: .keyboard))
        #expect(!f.controller.library.isPresented)
        #expect(f.controller.isPeekPresented)
        #expect(f.controller.pageCommandSurface() === peek)
        #expect(f.controller.session.snapshot?.selectedOccurrenceID == selected)
        f.controller.dismissPeek(animated: false)
        router.shutdown()
        try await f.close()
    }

    @Test("Closing an Archive Peek before hiding the Library leaves teardown state consistent")
    func archivePeekCloseThenHide() async throws {
        let f = try await LibraryR2Fixture.make()
        let router = BrowserWindowRouter<BrowserWindowController<LibraryPersistentEngine>>(create: { _ in f.controller }, present: { _, _ in }, dispose: { _ in })
        _ = router.newWindow(); await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        BrowserPeekCommands.install(in: registry)
        f.controller.openTab(url: URL(string: "https://archive-peek.library.test/source")!)
        await f.controller.session.waitForPendingCommands()
        let tabID = try #require(f.controller.session.organization?.selectedTab?.id)
        f.controller.session.closeSelectedTab()
        await f.controller.session.waitForPendingCommands()
        f.controller.showArchive()
        await f.controller.session.waitForPendingCommands()
        await f.controller.archive.task?.value
        let record = try #require(f.controller.archive.view.rows.compactMap { row -> BrowserArchivedTab? in
            if case .tab(let value) = row, value.id == tabID { return value }
            return nil
        }.first)
        f.controller.archive.view.onPreview?(record)
        await f.controller.session.waitForPendingCommands()
        let peek = try #require(f.controller.presentedPeekSurface)
        #expect(f.controller.archive.previewTabID == tabID)

        #expect(registry.dispatch(.archiveTab, origin: .keyboard))
        #expect(!f.controller.isPeekPresented)
        #expect(f.controller.library.isPresented)
        #expect(f.controller.archive.previewTabID == nil)
        f.controller.hideLibrary(focus: false)
        await f.controller.session.waitForPendingCommands()
        #expect(!f.controller.library.isPresented)
        #expect(!f.controller.isPeekPresented)
        #expect(!f.controller.peek.owns(peek))
        router.shutdown()
        try await f.close()
    }

    @Test("Hidden downloads are purged once rather than on every History or Archive projection")
    func downloadsPurge() async throws {
        let f = try await LibraryR2Fixture.make()
        f.controller.showDownloads(); await f.controller.session.waitForPendingCommands()
        let list = f.controller.downloadsPane.list
        let before = list.renderCount
        await f.show()
        #expect(list.renderCount == before + 1)
        let hidden = list.renderCount
        for _ in 0..<3 { f.controller.renderLibrary() }
        f.controller.showArchive(); await f.controller.session.waitForPendingCommands()
        for _ in 0..<3 { f.controller.renderLibrary() }
        #expect(list.renderCount == hidden)
        try await f.close()
    }

    @Test("Debounce keeps the loading indicator quiet and midnight triggers refresh only once")
    func debounceAndMidnight() async throws {
        let f = try await LibraryR2Fixture.make()
        await f.show()
        f.controller.library.history.search("term")
        #expect(f.controller.library.history.isDebouncing)
        #expect(f.controller.library.historyView.displayedStatus != libraryText("loading", "Loading…"))
        await f.controller.library.history.task?.value
        #expect(!f.controller.library.history.isDebouncing)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let observer = BrowserLibraryDateObserver(now: { now })
        var changes = 0
        observer.onChange = { changes += 1 }
        now = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        observer.refreshCalendar() // timer
        observer.refreshCalendar() // NSCalendarDayChanged for the same local day
        #expect(changes == 1)
        observer.refreshCalendar(force: true) // locale/time-zone invalidation
        #expect(changes == 2)
        try await f.close()
    }
}
}
