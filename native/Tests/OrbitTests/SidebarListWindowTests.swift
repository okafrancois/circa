import AppKit
@testable import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

/// Hidden windows on the synthetic engine, one shared store and the production registry.
@MainActor
private final class SidebarListHarness {
    typealias Controller = BrowserWindowController<SiteSyntheticEngine>
    let store = BrowserStore()
    let engine = SiteSyntheticEngine()
    let profileID: ProfileID
    let spaceID: SpaceID
    let router: BrowserWindowRouter<Controller>
    let registry: BrowserCommandRegistry<Controller>
    private(set) var windows: [Controller] = []
    var window: Controller { windows[0] }

    init(usesSyntheticKeyWindow: Bool = false) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = store, engine = engine
        profileID = await store.createProfile(name: "Synthetic list")
        let space = try await store.createSpace(name: "List", profileID: profileID)
        spaceID = space
        router = BrowserWindowRouter(create: { id in
            let controller = Controller(id: id, store: store, spaceID: space, engine: engine, onClose: {}, onActivate: {})
            controller.session.onError = { _ in }
            await controller.session.waitForPendingCommands()
            return controller
        }, present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
                                              deliver: { $0.performAcceptedCommand($1) })
        if usesSyntheticKeyWindow {
            BrowserWindowCommands.install(in: registry, commandKeyWindow: { [weak self] in self?.windows.first?.window })
        } else { BrowserWindowCommands.install(in: registry) }
        try await newWindow()
    }

    @discardableResult
    func newWindow() async throws -> Controller {
        let id = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let controller = try #require(router.windows[id])
        controller.favorites.bind(to: registry)
        windows.append(controller)
        await settle()
        return controller
    }

    func settle() async {
        await router.waitForPendingCommands()
        for _ in 0..<3 {
            for window in windows { await window.session.waitForPendingCommands() }
            for window in windows { await window.sidebar.undoRouter.waitForPendingCommands() }
            await Task.yield()
        }
        for window in windows { window.window?.contentView?.layoutSubtreeIfNeeded() }
    }

    @discardableResult
    func openTab(_ address: String, in controller: Controller? = nil, activate: Bool = false) async -> TabID? {
        let controller = controller ?? window
        let before = Set(controller.session.organization?.allTabs.map(\.id) ?? [])
        controller.session.openTab(url: URL(string: address)!, activate: activate)
        await settle()
        return controller.session.organization?.allTabs.map(\.id).first { !before.contains($0) }
    }

    func shutdown() { router.shutdown() }
}

private extension BrowserWindowController where Engine == SiteSyntheticEngine {
    var list: SidebarListView { sidebar.page.list }
    var organization: BrowserOrganizationSnapshot { session.organization! }

    /// A sidebar point over a list row (x inside the title area unless given).
    func sidebarPoint(listY: CGFloat, x: CGFloat = 120) -> NSPoint {
        sidebar.convert(NSPoint(x: x, y: listY), from: list)
    }

    func center(_ node: BrowserOrganizationNode) -> CGFloat { list.displayedCenterY(of: .node(node))! }

    func payload(_ node: BrowserOrganizationNode) -> SidebarDragPayload {
        sidebar.list(list, dragPayloadFor: node, grabOffsetX: 0)!
    }
}

private func section(_ tab: BrowserOrganizationTabItem?) -> String {
    switch tab?.section {
    case .favorites?: return "favorites"
    case .pinned?: return "pinned"
    case .today?: return "today"
    case nil: return "none"
    }
}

/// A page-like edit with real symmetric NSUndoManager registration and an observable value.
@MainActor
private final class SyntheticUndoEdit: NSObject {
    let manager: UndoManager
    private(set) var value = 0
    private(set) var changes = 0

    init(manager: UndoManager) { self.manager = manager }

    func change(to next: Int) {
        let previous = value
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { $0.change(to: previous) }
        manager.setActionName("Page Edit")
        value = next
        changes += 1
        manager.endUndoGrouping()
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SidebarListWindowTests {
    @Test("Folder preview and sidebar resolve a dormant tab's shared icon before an occurrence exists")
    func folderPreviewDormantCachedFavicon() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let controller = harness.window
        let home = URL(string: "https://folder-preview.test/")!
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        controller.sidebarIcons.memoryCache.put(icon, profile: harness.profileID, home: home)
        let tab = BrowserOrganizationTabItem(id: TabID(), section: .pinned(harness.spaceID), url: home,
            pinnedURL: home, pageTitle: "Synthetic dormant tab", customTitle: nil,
            occurrenceID: nil, isLoadedInThisWindow: false, isSelected: false, isOpenInAnotherWindow: false)
        #expect(controller.sidebar.liveActivity(tab).favicon === icon)
        #expect(controller.folderPreview.favicon(tab) === icon)
    }

    @Test("Rows come from the organization, keyed by TabID, and keep their views across selection and moves")
    func rowsKeyedByLogicalTab() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let a = try #require(await harness.openTab("https://a.test/"))
        let b = try #require(await harness.openTab("https://b.test/"))
        let rows = c.sidebar.page.tabRows
        #expect(Set(rows.map(\.item.id)) == Set(c.organization.today.map(\.node.tabID!)))
        #expect(c.displayedTabTitles.contains("a.test") && c.displayedTabTitles.contains("b.test"))
        let rowA = try #require(c.list.row(for: .tab(a)) as? SidebarTabRow)
        #expect(rowA.accessibilityPerformPress())
        await harness.settle()
        #expect(c.organization.selectedTab?.id == a)
        #expect(rowA.item.selected && rowA.item.occurrenceID == c.session.snapshot?.selectedOccurrenceID)
        #expect(c.list.row(for: .tab(a)) === rowA)
        // Pinning keeps the same row view, now above the separator.
        c.session.pinTabs([b])
        await harness.settle()
        let rowB = try #require(c.list.row(for: .tab(b)) as? SidebarTabRow)
        #expect(rowB.item.isPinned && rowB.frame.midY < c.sidebar.page.separatorFrame.midY)
        #expect(c.list.row(for: .tab(a)) === rowA)
        #expect(c.sidebar.pinnedRowCount == 1)
        // The page geometry follows the list (first Today row below New Tab).
        let geometry = c.sidebar.geometry
        let rowAFrame = rowA.convert(rowA.bounds, to: c.sidebar)
        #expect(geometry.todayRowCenters.contains { abs(geometry.pageFrame.minY + $0 - rowAFrame.midY) < 0.5 })
    }

    @Test("Folders indent their children by 16, toggle on click with closed/open glyphs, and collapse hides children")
    func foldersIndentAndToggle() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let a = try #require(await harness.openTab("https://a.test/"))
        c.session.pinTabs([a])
        await harness.settle()
        let created = c.session.createFolder(title: "Docs", at: .init(.pinned(harness.spaceID)), containing: [.tab(a)])
        let folder = try #require(await created.value)
        await harness.settle()
        let folderRow = try #require(c.list.row(for: .folder(folder)) as? SidebarFolderRow)
        let child = try #require(c.list.row(for: .tab(a)) as? SidebarTabRow)
        #expect(folderRow.glyph.isOpen && folderRow.depth == 0 && child.depth == 1)
        #expect(child.iconX == folderRow.iconX + OrbitTokens.Metrics.Sidebar.folderChildIndent)
        #expect(child.titleLabel.frame.minX == folderRow.titleLabel.frame.minX + 16)
        #expect(child.frame.midY - folderRow.frame.midY == OrbitTokens.Metrics.Sidebar.rowPitch)
        #expect(folderRow.titleLabel.font == OrbitTokens.Typography.sidebarFolderTitle)
        #expect(folderRow.accessibilityPerformPress())
        await harness.settle()
        #expect(c.organization.isCollapsed(folder))
        #expect(!folderRow.glyph.isOpen && c.list.row(for: .tab(a)) == nil)
        #expect(c.sidebar.listContent.entry(for: .tab(a)) == nil)
        #expect(folderRow.accessibilityPerformPress())
        await harness.settle()
        #expect(!c.organization.isCollapsed(folder) && c.list.row(for: .tab(a)) != nil)
        // Collapse All / Expand All and Collapse Pinned Section through the registry.
        #expect(harness.registry.dispatch(.collapseAllFolders, origin: .menu))
        await harness.settle()
        #expect(c.organization.isCollapsed(folder))
        #expect(harness.registry.dispatch(.collapsePinnedSection, origin: .menu))
        await harness.settle()
        #expect(c.organization.isPinnedSectionCollapsed && c.list.row(for: .folder(folder)) == nil)
        #expect(!harness.registry.isEnabled(.collapsePinnedSection) && harness.registry.isEnabled(.expandPinnedSection))
        #expect(harness.registry.dispatch(.expandPinnedSection, origin: .menu))
        await harness.settle()
        #expect(c.list.row(for: .folder(folder)) != nil)
    }

    @Test("Inline rename commits on Return, cancels on Escape, leaves IME compositions alone and restores the web title")
    func inlineRename() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let a = try #require(await harness.openTab("https://a.test/"))
        let row = try #require(c.list.row(for: .tab(a)) as? SidebarTabRow)
        func begin() throws -> (NSTextField, NSTextView) {
            c.sidebar.beginRename(.tab(a))
            let field = try #require(c.list.renameField)
            let editor = try #require(field.currentEditor() as? NSTextView)
            return (field, editor)
        }
        var (field, editor) = try begin()
        #expect(editor.string == "a.test" && editor.selectedRange() == NSRange(location: 0, length: 6))
        #expect(c.isEditingInSidebar)
        editor.string = "Renamed"
        #expect(row.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await harness.settle()
        #expect(c.organization.tab(a)?.customTitle == "Renamed" && row.item.title == "Renamed")
        #expect(c.list.renameField == nil && c.window?.firstResponder === c.list)
        (field, editor) = try begin()
        editor.string = "Discarded"
        #expect(row.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        await harness.settle()
        #expect(c.organization.tab(a)?.customTitle == "Renamed")
        (field, editor) = try begin()
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!row.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!row.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(c.list.renameField === field)
        editor.unmarkText()
        editor.string = ""
        #expect(row.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await harness.settle()
        #expect(c.organization.tab(a)?.customTitle == nil && row.item.title == "a.test")
        // Unchanged text commits nothing (the web title is not frozen as a custom title).
        (field, editor) = try begin()
        #expect(row.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await harness.settle()
        #expect(c.organization.tab(a)?.customTitle == nil)
        // Return on the focused list renames the current row; the command is the menu entry.
        c.window?.makeFirstResponder(c.list)
        #expect(harness.registry.dispatch(.renameCurrentItem, origin: .menu))
        await harness.settle()
        #expect(c.list.renameField != nil)
        c.list.cancelRename()
        #expect(c.list.renameField == nil)
    }

    @Test("⌘-click and ⇧-click build the model selection, Escape clears it, close is atomic and the list undoes it")
    func multiSelectionCloseAndUndo() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        var tabs: [TabID] = []
        for host in ["a", "b", "c", "d"] { tabs.append(try #require(await harness.openTab("https://\(host).test/"))) }
        let order = c.sidebar.listContent.entries.map(\.node)
        let selected = try #require(c.organization.selectedTab?.id)
        let others = order.filter { $0 != .tab(selected) }
        c.sidebar.list(c.list, activate: others[0], modifiers: .command)
        #expect(c.sidebar.selection.nodes == [.tab(selected), others[0]])
        #expect((c.list.row(for: others[0]) as? SidebarTabRow)?.item.isMultiSelected == true)
        #expect((c.list.row(for: .tab(selected)) as? SidebarTabRow)?.item.isMultiSelected == true)
        c.sidebar.list(c.list, activate: others[2], modifiers: .shift)
        let range = Set(order[order.firstIndex(of: others[0])!...order.firstIndex(of: others[2])!])
        #expect(c.sidebar.selection.nodes == range)
        #expect(c.sidebar.commandTargets() == order.filter(range.contains))
        #expect(c.organization.selectedTab?.id == selected)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: c.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        c.list.keyDown(with: escape)
        #expect(c.sidebar.selection.nodes == [.tab(selected)])
        // Select two background rows and close them through the registry entry.
        c.sidebar.list(c.list, activate: others[0], modifiers: .command)
        c.sidebar.list(c.list, activate: others[1], modifiers: .command)
        c.sidebar.list(c.list, activate: .tab(selected), modifiers: .command)
        #expect(c.sidebar.commandTargets() == order.filter { [others[0], others[1]].contains($0) })
        let before = c.organization.today.count
        #expect(harness.registry.dispatch(.sidebarCloseItems, origin: .menu))
        await harness.settle()
        #expect(c.organization.today.count == before - 2)
        #expect(c.organization.undoAction == .closeTabs)
        #expect(c.organization.selectedTab?.id == selected)
        // ⌘Z in the sidebar: the focused list validates and performs organization undo.
        c.window?.makeFirstResponder(c.list)
        let item = NSMenuItem(title: "Undo", action: #selector(SidebarListView.undo(_:)), keyEquivalent: "")
        #expect(c.list.validateUserInterfaceItem(item))
        c.list.undo(nil)
        await harness.settle()
        #expect(c.organization.today.count == before)
        #expect(Set(c.organization.today.map(\.node)).isSuperset(of: [others[0], others[1]]))
        let redo = NSMenuItem(title: "Redo", action: #selector(SidebarListView.redo(_:)), keyEquivalent: "")
        #expect(c.list.validateUserInterfaceItem(redo))
        // A rename field keeps its own undo: the list is no longer the responder.
        c.sidebar.beginRename(others[0])
        #expect(c.window?.firstResponder !== c.list)
        c.list.cancelRename()
    }

    @Test("Drops pin, file into folders, leave folders, refuse invalid targets and skip no-op moves")
    func dropsThroughTheSidebar() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let p = try #require(await harness.openTab("https://p.test/"))
        let child = try #require(await harness.openTab("https://child.test/"))
        let t1 = try #require(await harness.openTab("https://t1.test/"))
        let t2 = try #require(await harness.openTab("https://t2.test/"))
        c.session.pinTabs([p, child])
        await harness.settle()
        let folder = try #require(await c.session.createFolder(title: "Docs", at: .init(.pinned(harness.spaceID)), containing: [.tab(child)]).value)
        await harness.settle()
        // Hovering above the separator lifts the row and opens a placeholder; leaving closes it.
        let hover = c.sidebar.simulateDragHover(c.payload(.tab(t2)), at: c.sidebarPoint(listY: c.center(.tab(p)) + 10))
        #expect(hover?.isValid == true && hover?.proposal.destination == .init(.pinned(harness.spaceID), position: .after(.tab(p))))
        #expect(c.list.gapPlaceholderFrame != nil && c.list.row(for: .tab(t2)) == nil)
        c.sidebar.simulateDragExit()
        #expect(c.list.gapPlaceholderFrame == nil && c.list.row(for: .tab(t2)) != nil)
        // Into the folder (middle of its row).
        let into = c.sidebar.simulateDrop(c.payload(.tab(t2)), at: c.sidebarPoint(listY: c.center(.folder(folder))))
        #expect(into?.proposal.folderTarget == folder)
        await harness.settle()
        #expect(c.organization.location(of: .tab(t2))?.1 == [folder] && section(c.organization.tab(t2)) == "pinned")
        #expect(!c.list.isAwaitingDropCommit && c.list.row(for: .tab(t2)) != nil)
        // Out of the folder: below its last child with the dragged icon left of the folder's.
        // The dragged row is lifted out of the list: "below the last child" is below `child`.
        let outPayload = c.sidebar.list(c.list, dragPayloadFor: .tab(t2), grabOffsetX: 0)!
        let below = c.center(.tab(child)) + 12
        c.sidebar.simulateDrop(outPayload, at: c.sidebarPoint(listY: below, x: 18))
        await harness.settle()
        #expect(c.organization.location(of: .tab(t2))?.1 == [] && section(c.organization.tab(t2)) == "pinned")
        // Back to Today, first row: hovering lifts the row (the list closes up), then the drop
        // lands where the pointer is in the displayed list.
        let back = c.payload(.tab(t2))
        c.sidebar.simulateDragHover(back, at: c.sidebarPoint(listY: c.list.displayedLayout.newTabCenterY))
        c.sidebar.simulateDrop(back, at: c.sidebarPoint(listY: c.list.displayedLayout.newTabCenterY))
        await harness.settle()
        #expect(c.organization.today.first?.node == .tab(t2))
        // A folder cannot go to Today: refused, nothing changes, no placeholder.
        let organizationBefore = c.organization
        let refused = c.sidebar.simulateDrop(c.payload(.folder(folder)), at: c.sidebarPoint(listY: c.center(.tab(t1))))
        #expect(refused?.isValid == false && refused?.error == .invalidDestination)
        await harness.settle()
        #expect(c.organization == organizationBefore && c.list.gapPlaceholderFrame == nil)
        // Dropping a row back where it was sends no command.
        let undo = c.organization.undoAction
        let first = try #require(c.organization.today.first?.node)
        c.sidebar.simulateDrop(c.payload(first), at: c.sidebarPoint(listY: c.center(first) - 6))
        await harness.settle()
        #expect(c.organization.today.first?.node == first && c.organization.undoAction == undo)
        #expect(!c.list.isAwaitingDropCommit && c.list.row(for: first) != nil)
    }

    @Test("Rows dropped from another window of the same Space bring their live document")
    func crossWindowDrop() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://x.test/", in: a, activate: true))
        let b = try await harness.newWindow()
        let surface = try #require(a.session.selectedSurface)
        let rowInB = try #require(b.list.row(for: .tab(x)) as? SidebarTabRow)
        #expect(rowInB.item.isOpenInAnotherWindow && !rowInB.item.isLoadedInThisWindow)
        #expect(b.sidebar.listContent.entry(for: .tab(x))?.tab?.isOpenInAnotherWindow == true)
        let payload = a.payload(.tab(x))
        b.sidebar.simulateDrop(payload, at: b.sidebarPoint(listY: b.list.displayedLayout.newTabCenterY))
        await harness.settle()
        #expect(b.organization.tab(x)?.isLoadedInThisWindow == true && b.organization.tab(x)?.isSelected == true)
        #expect(b.session.selectedSurface === surface)
        #expect(a.organization.tab(x)?.isLoadedInThisWindow == false)
        #expect(b.organization.today.first?.node == .tab(x))
        #expect((a.list.row(for: .tab(x)) as? SidebarTabRow)?.item.isOpenInAnotherWindow == true)
    }

    @Test("A tab dropped in another Space moves its live document and history with one undoable placement")
    func crossSpaceLiveMove() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let remaining = try #require(await harness.openTab("https://source.test/", in: a, activate: true))
        let first = URL(string: "https://history.test/first")!
        let x = try #require(await harness.openTab(first.absoluteString, in: a, activate: true))
        let surface = try #require(a.session.selectedSurface)
        surface.navigate(to: URL(string: "https://history.test/second")!)
        let b = try await harness.newWindow()
        let space = try await harness.store.createSpace(name: "Destination", profileID: harness.profileID)
        b.session.activateSpace(space)
        await harness.settle()
        let payload = a.payload(.tab(x))
        a.sidebar.list(a.list, dragLeftWindow: payload)
        await harness.settle()
        #expect(a.organization.selectedTab?.id == remaining)
        let point = b.sidebarPoint(listY: b.list.displayedLayout.newTabCenterY)
        let hover = b.sidebar.simulateDragHover(payload, at: point)
        #expect(hover?.isValid == true)
        #expect(b.list.insertionLineFrame != nil && b.list.gapPlaceholderFrame == nil)
        b.sidebar.simulateDrop(payload, at: point)
        await harness.settle()
        #expect(b.session.selectedSurface === surface && !surface.isDisposed)
        #expect(b.organization.selectedTab?.id == x)
        #expect(a.organization.tab(x) == nil && a.liveSidebarSurface(of: x) == nil)
        #expect(b.organization.allTabs.filter { $0.id == x }.count == 1)
        #expect(b.session.snapshot?.tabs.filter { $0.id == x }.count == 1)
        #expect(surface.navigationState.canGoBack)
        #expect(surface.goBack() == first)
        await harness.settle()
        #expect(b.organization.undoAction == .moveItems)
        let undone = await b.session.undoOrganization().value
        #expect(undone != nil)
        await harness.settle()
        #expect(a.organization.tab(x) != nil && b.organization.tab(x) == nil)
        _ = await b.session.redoOrganization().value
        await harness.settle()
        #expect(a.organization.tab(x) == nil && b.organization.allTabs.filter { $0.id == x }.count == 1)
    }

    @Test("A cross-profile drop leaves document, history and organization untouched")
    func foreignProfileDropRefused() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://identity.test/", in: a, activate: true))
        let surface = try #require(a.session.selectedSurface)
        let b = try await harness.newWindow()
        let profile = await harness.store.createProfile(name: "Foreign")
        let space = try await harness.store.createSpace(name: "Foreign", profileID: profile)
        b.session.activateSpace(space)
        await harness.settle()
        let verdict = b.sidebar.simulateDrop(a.payload(.tab(x)), at: b.sidebarPoint(listY: b.list.displayedLayout.newTabCenterY))
        await harness.settle()
        #expect(verdict?.error == .crossProfileMove)
        #expect(a.session.selectedSurface === surface && !surface.isDisposed)
        #expect(b.organization.tab(x) == nil && a.organization.tab(x)?.isSelected == true)
    }

    @Test("List rows reach the Favorites grid through the FAVORITES drop adapter, and tiles drop into the list")
    func favoritesDropAdapter() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let t = try #require(await harness.openTab("https://fav.test/"))
        #expect(c.sidebar.favoriteCount == 0)
        // The empty grid has no height: the potential zone under the address field reveals it.
        let zone = NSPoint(x: 100, y: c.sidebar.geometry.addressFrame.maxY + 4)
        let hover = c.sidebar.simulateDragHover(c.payload(.tab(t)), at: zone)
        #expect(hover?.proposal.destination.container == .favorites(harness.profileID) && hover?.isValid == true)
        #expect(c.sidebar.showsEmptyFavoritesDropZone)
        c.sidebar.simulateDragExit()
        #expect(!c.sidebar.showsEmptyFavoritesDropZone)
        c.sidebar.simulateDrop(c.payload(.tab(t)), at: zone)
        await harness.settle()
        #expect(section(c.organization.tab(t)) == "favorites" && c.sidebar.favoriteCount == 1)
        #expect(c.sidebar.listContent.entry(for: .tab(t)) == nil)
        // A folder is refused over the Favorites zone.
        let folder = try #require(await c.session.createFolder(title: "F", at: .init(.pinned(harness.spaceID))).value)
        await harness.settle()
        let refused = c.sidebar.simulateDragHover(c.payload(.folder(folder)), at: c.sidebar.convert(NSPoint(x: 20, y: 20), from: c.favorites.grid))
        #expect(refused?.isValid == false)
        c.sidebar.simulateDragExit()
        // A Favorite tile dropped on the list leaves the Favorites (the tile payload shape).
        let tile = SidebarDragPayload(sourceWindow: c.id, spaceID: harness.spaceID, profileID: harness.profileID,
                                      nodes: [.tab(t)], rowCount: 1, grabOffsetX: 0)
        c.sidebar.simulateDrop(tile, at: c.sidebarPoint(listY: c.list.displayedLayout.newTabCenterY))
        await harness.settle()
        #expect(section(c.organization.tab(t)) == "today" && c.sidebar.favoriteCount == 0)
    }

    @Test("Row context menus are built, retitled and dispatched by the command registry")
    func contextMenusThroughRegistry() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let t = try #require(await harness.openTab("https://menu.test/"))
        let nodes = c.sidebar.prepareContextMenu(for: .tab(t))
        #expect(nodes == [.tab(t)] && (c.list.row(for: .tab(t)) as? SidebarTabRow)?.isContextTarget == true)
        let built = try #require(c.makeSidebarContextMenu(for: nodes))
        let titles = built.menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles == ["Copy Link", "—", "Change Icon…", "Rename…", "Mute", "—", "Open in Split View", "Duplicate", "Move to", "—", "Archive Tab", "Archive Tabs Below"])
        #expect(!built.menu.items.contains { $0.title == "New Folder with Selection" })
        c.sidebar.endContextMenu()
        c.session.pinTabs([t])
        await harness.settle()
        let again = c.sidebar.prepareContextMenu(for: .tab(t))
        let menu = try #require(c.makeSidebarContextMenu(for: again))
        #expect(menu.menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == [
            "Copy Link", "—", "Change Icon…", "Rename…", "Mute", "Edit Pinned Page", "—",
            "Add Split View", "Duplicate", "Move to", "—", "Remove Pin"])
        let submenu = try #require(menu.menu.items.first { $0.title == "Edit Pinned Page" }?.submenu)
        #expect(submenu.items.map(\.title) == ["Edit…"])
        menu.menu.performActionForItem(at: menu.menu.indexOfItem(withTitle: "Remove Pin"))
        await harness.settle()
        c.sidebar.endContextMenu()
        #expect(section(c.organization.tab(t)) == "today")
        let creation = c.session.createFolder(title: "Group", at: .init(.pinned(harness.spaceID)), containing: [.tab(t)])
        let folder = try #require(await creation.value)
        await harness.settle()
        // Folder menu entries.
        let folderMenu = try #require(c.makeSidebarContextMenu(for: c.sidebar.prepareContextMenu(for: .folder(folder))))
        #expect(folderMenu.menu.items.map { $0.isSeparatorItem ? "—" : $0.title } == [
            "New Nested Folder…", "—", "Move to", "Rename", "—", "Copy All Links", "Copy All Links as Markdown", "—",
            "Delete", "Archive Folder"])
        folderMenu.menu.performActionForItem(at: folderMenu.menu.indexOfItem(withTitle: "Delete"))
        await harness.settle()
        c.sidebar.endContextMenu()
        #expect(c.organization.pinned.map(\.node) == [.tab(t)])
        // ⌘D from the menu bar toggles the visible tab (ORG-MODEL semantics).
        let visible = try #require(c.organization.selectedTab?.id)
        #expect(harness.registry.dispatch(.pinUnpinTab, origin: .keyboard))
        await harness.settle()
        #expect(section(c.organization.tab(visible)) == "pinned")
    }

    @Test("Relative archive targets only Today around the clicked row, retaining pins and the selection")
    func archiveAboveBelow() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let first = try #require(await harness.openTab("https://menus.test/first"))
        let middle = try #require(await harness.openTab("https://menus.test/middle"))
        let last = try #require(await harness.openTab("https://menus.test/last"))
        c.session.pinTabs([first])
        c.session.moveItems([.tab(middle)], to: .init(.today(harness.spaceID), position: .end))
        c.session.moveItems([.tab(last)], to: .init(.today(harness.spaceID), position: .end))
        await harness.settle()
        let nodes = c.sidebar.prepareContextMenu(for: .tab(middle))
        let menu = try #require(c.makeSidebarContextMenu(for: nodes))
        #expect(c.sidebarRelativeTodayTabs(above: false) == [last])
        #expect(!c.sidebarRelativeTodayTabs(above: true).contains(first))
        menu.menu.performActionForItem(at: menu.menu.indexOfItem(withTitle: "Archive Tabs Below"))
        await harness.settle()
        c.sidebar.endContextMenu()
        #expect(c.organization.tab(last) == nil)
        #expect(c.organization.tab(first) != nil && c.organization.tab(middle) != nil)
        #expect(harness.registry.dispatch(.revealCurrentTab, origin: .keyboard))
        await harness.settle()
        #expect(c.isSidebarVisible)
    }

    @Test("Mute acts on the clicked live tab and its next menu offers Unmute")
    func muteClickedTab() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let first = try #require(await harness.openTab("https://menus.test/audio", activate: true))
        let surface = try #require(c.session.selectedSurface)
        _ = await harness.openTab("https://menus.test/other", activate: true)
        let selected = try #require(c.session.selectedSurface)
        let menu = try #require(c.makeSidebarContextMenu(for: c.sidebar.prepareContextMenu(for: .tab(first))))
        #expect(menu.menu.items.contains { $0.title == "Mute" })
        menu.menu.performActionForItem(at: menu.menu.indexOfItem(withTitle: "Mute"))
        await harness.settle()
        for _ in 0..<20 { await Task.yield() }
        #expect(surface.media.isAudioMuted == true && selected.media.isAudioMuted == false)
        c.sidebar.endContextMenu()
        let next = try #require(c.makeSidebarContextMenu(for: c.sidebar.prepareContextMenu(for: .tab(first))))
        #expect(next.menu.items.contains { $0.title == "Unmute" })
        c.sidebar.endContextMenu()
    }

    @Test("Copy and Duplicate act on the clicked row while another tab stays selected")
    func capturedObjectActions() async throws {
        let harness = try await SidebarListHarness(); defer { harness.shutdown() }
        let c = harness.window
        let first = try #require(await harness.openTab("https://copy-menu.test/first"))
        let second = try #require(await harness.openTab("https://copy-menu.test/second", activate: true))
        let built = try #require(c.makeSidebarContextMenu(for: c.sidebar.prepareContextMenu(for: .tab(first))))
        built.menu.performActionForItem(at: built.menu.indexOfItem(withTitle: "Copy Link"))
        await harness.settle()
        #expect(NSPasteboard.general.string(forType: .string) == "https://copy-menu.test/first")
        #expect(c.organization.selectedTab?.id == second)
        built.menu.performActionForItem(at: built.menu.indexOfItem(withTitle: "Duplicate"))
        await harness.settle()
        #expect(c.organization.selectedTab?.url.absoluteString == "https://copy-menu.test/first")
        #expect(c.organization.today.filter { if case .tab(let tab) = $0 { return tab.url.absoluteString == "https://copy-menu.test/first" }; return false }.count == 2)
        c.sidebar.endContextMenu()
    }

    @Test("Move to uses the captured row and refuses a menu after a context change")
    func moveMenuAuthority() async throws {
        let harness = try await SidebarListHarness(); defer { harness.shutdown() }
        let c = harness.window
        let first = try #require(await harness.openTab("https://move-menu.test/first"))
        let menu = try #require(SidebarMoveMenu(owner: c, nodes: [.tab(first)]))
        let favorites = try #require(menu.item.submenu?.items.first { $0.title == "Favorites" })
        #expect(menu.validateMenuItem(favorites))
        _ = try #require(await harness.openTab("https://move-menu.test/second", activate: true))
        #expect(!menu.validateMenuItem(favorites))
        menu.item.submenu?.performActionForItem(at: 0)
        await harness.settle()
        #expect(c.organization.favorites.isEmpty)
        let current = try #require(SidebarMoveMenu(owner: c, nodes: [.tab(first)]))
        current.item.submenu?.performActionForItem(at: 0)
        await harness.settle()
        #expect(c.organization.favorites.map(\.node) == [.tab(first)])
    }

    @Test("A Pinned tab away from its URL shows the slash and resets in place; Clear goes through the archive hook")
    func pinnedResetAndClear() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let home = URL(string: "https://home.test/start")!
        let p = try #require(await harness.openTab(home.absoluteString, activate: true))
        c.session.pinTabs([p])
        await harness.settle()
        let surface = try #require(c.session.selectedSurface)
        surface.navigate(to: URL(string: "https://home.test/elsewhere")!)
        await harness.settle()
        let row = try #require(c.list.row(for: .tab(p)) as? SidebarTabRow)
        #expect(row.item.isAwayFromPinnedURL && !row.isResetButtonVisible)
        #expect(harness.registry.isEnabled(.resetTabToOriginalURL))
        c.list.rowResetToPinnedURL(row)
        await harness.settle()
        #expect(surface.currentURL == home && !c.organization.tab(p)!.isAwayFromPinnedURL && !row.item.isAwayFromPinnedURL)
        // Clear: revealed by the Today zone hover, archives the background Today tabs.
        let background = try #require(await harness.openTab("https://today.test/"))
        #expect(!c.list.isClearRevealed)
        c.list.setTodayHoveredForTesting(true)
        #expect(c.list.isClearRevealed)
        c.list.clearButton.performClick(nil)
        await harness.settle()
        #expect(c.organization.tab(background) == nil)
        #expect(await c.session.archivedTabs().value.contains { $0.id == background })
        #expect(c.organization.tab(p) != nil)
    }

    @Test("Moves follow interruptible springs when animated; reduced motion and hidden windows jump")
    func rowMotion() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        for host in ["a", "b", "c"] { _ = await harness.openTab("https://\(host).test/") }
        let order = c.organization.today.map(\.node)
        let moving = try #require(order.last)
        let oldY = c.center(moving)
        #expect(!c.list.animator.isAnimating)
        var now: CFTimeInterval = 100
        c.list.animator.clock = { now }
        c.list.forcesAnimation = true
        OrbitMotionPreferences.overrideReducedMotion = false
        defer { OrbitMotionPreferences.overrideReducedMotion = nil }
        c.session.moveItems([moving], to: .init(.today(harness.spaceID), position: .start))
        await harness.settle()
        let newY = try #require(c.list.displayedLayout.centerY(of: .node(moving)))
        #expect(newY < oldY && c.list.animator.isAnimating)
        #expect(c.list.displayedCenterY(of: .node(moving), at: now) == oldY)
        now += 0.06
        let mid = try #require(c.list.displayedCenterY(of: .node(moving), at: now))
        #expect(mid < oldY && mid > newY)
        // Interrupt: move it back; the row continues from where it is.
        c.session.moveItems([moving], to: .init(.today(harness.spaceID), position: .end))
        await harness.settle()
        #expect(abs(c.list.displayedCenterY(of: .node(moving), at: now)! - mid) < 0.5)
        now += 3
        c.list.animator.advance(to: now)
        #expect(!c.list.animator.isAnimating)
        #expect(c.list.row(for: moving)?.frame.midY == oldY)
        // Reduced motion: no spring.
        OrbitMotionPreferences.overrideReducedMotion = true
        c.session.moveItems([moving], to: .init(.today(harness.spaceID), position: .start))
        await harness.settle()
        #expect(!c.list.animator.isAnimating && c.list.row(for: moving)?.frame.midY == newY)
        c.list.forcesAnimation = false
    }

    @Test("A drop between windows moves the tab: the dragged document replaces the target's own, none stays behind")
    func crossWindowMoveReplacesExistingOccurrence() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://x.test/", in: a, activate: true))
        let b = try await harness.newWindow()
        b.session.selectTab(x)
        await harness.settle()
        let dragged = try #require(a.liveSidebarSurface(of: x))
        let own = try #require(b.liveSidebarSurface(of: x))
        #expect(dragged !== own && b.organization.tab(x)?.isLoadedInThisWindow == true)
        b.sidebar.simulateDrop(a.payload(.tab(x)), at: b.sidebarPoint(listY: b.list.displayedLayout.newTabCenterY))
        await harness.settle()
        #expect(b.session.selectedSurface === dragged && b.organization.tab(x)?.isSelected == true)
        #expect(b.session.snapshot?.tabs.filter { $0.id == x }.count == 1)
        #expect(own.isDisposed && !dragged.isDisposed)
        #expect(a.organization.tab(x)?.isLoadedInThisWindow == false && a.liveSidebarSurface(of: x) == nil)
        #expect(a.session.snapshot?.tabs.contains { $0.id == x } == false)
        // The logical tab was neither archived nor duplicated.
        #expect(a.organization.allTabs.filter { $0.id == x }.count == 1)
        #expect(await a.session.archivedTabs().value.contains { $0.id == x } == false)
        // A tab A has not loaded is only shown in B: A keeps nothing, B selects it.
        let y = try #require(await harness.openTab("https://y.test/", in: b))
        #expect(a.liveSidebarSurface(of: y) == nil)
        b.sidebar.simulateDrop(a.payload(.tab(y)), at: b.sidebarPoint(listY: b.list.displayedLayout.newTabCenterY))
        await harness.settle()
        #expect(b.organization.selectedTab?.id == y && a.liveSidebarSurface(of: y) == nil)
    }

    @Test("Return in an untouched rename field never freezes the title shown at edit start, even after the web title changed")
    func renameUntouchedAfterTitleChange() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let a = try #require(await harness.openTab("https://first.test/", activate: true))
        let row = try #require(c.list.row(for: .tab(a)) as? SidebarTabRow)
        c.sidebar.beginRename(.tab(a))
        let field = try #require(c.list.renameField)
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.string == "first.test")
        // The page title changes while the field is open (the synthetic engine titles by host).
        try #require(c.session.selectedSurface).navigate(to: URL(string: "https://second.test/")!)
        await harness.settle()
        #expect(row.item.title == "second.test" && c.list.renameField === field)
        #expect(row.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await harness.settle()
        #expect(c.organization.tab(a)?.customTitle == nil && row.item.title == "second.test")
        // An edited field still commits.
        c.sidebar.beginRename(.tab(a))
        let again = try #require(c.list.renameField?.currentEditor() as? NSTextView)
        again.string = "Chosen"
        #expect(row.control(try #require(c.list.renameField), textView: again, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await harness.settle()
        #expect(c.organization.tab(a)?.customTitle == "Chosen")
    }

    @Test("Reveal scrolls to a row once the publication expanding its folder shows it")
    func revealAfterExpanding() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        var pinned: [TabID] = []
        for index in 0..<16 { pinned.append(try #require(await harness.openTab("https://p\(index).test/"))) }
        let x = try #require(await harness.openTab("https://x.test/"))
        c.session.pinTabs(pinned + [x])
        await harness.settle()
        let folder = try #require(await c.session.createFolder(title: "Deep", at: .init(.pinned(harness.spaceID)), containing: [.tab(x)]).value)
        c.session.setFolderCollapsed(folder, true)
        await harness.settle()
        let scroll = c.sidebar.page.pageScrollView
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(c.list.row(for: .tab(x)) == nil)
        c.revealInSidebar(.tab(x))
        // The expansion is asynchronous: the reveal waits for the row.
        #expect(c.list.isRevealPending)
        await harness.settle()
        #expect(!c.organization.isCollapsed(folder) && !c.list.isRevealPending)
        let row = try #require(c.list.row(for: .tab(x)))
        let visible = c.list.visibleRect
        #expect(row.frame.minY >= visible.minY && row.frame.maxY <= visible.maxY, "row \(row.frame) visible \(visible)")
        #expect(scroll.contentView.bounds.minY > 0)
    }

    @Test("Favorites tiles carry their window's Space: a drop from a window of another Space is refused")
    func favoritesCrossSpaceRefused() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let favorite = try #require(await harness.openTab("https://fav.test/", in: a))
        a.session.addToFavorites([favorite])
        let other = try await harness.store.createSpace(name: "Other", profileID: harness.profileID)
        let c = try await harness.newWindow()
        c.session.activateSpace(other)
        await harness.settle()
        #expect(c.organization.spaceID == other && c.organization.favorites.contains { $0.node == .tab(favorite) })
        let tile = FavoritesDragPayload(profileID: harness.profileID, nodes: [.tab(favorite)])
        let fromOtherSpace = try #require(SidebarDragPayload(favorites: tile, sourceWindow: c.id))
        #expect(fromOtherSpace.spaceID == other)
        let refused = a.sidebar.simulateDrop(fromOtherSpace, at: a.sidebarPoint(listY: a.list.displayedLayout.newTabCenterY))
        #expect(refused?.isValid == false && refused?.error == .notVisibleInContext)
        await harness.settle()
        #expect(section(a.organization.tab(favorite)) == "favorites")
        // The same tile from this window's own grid is accepted; an unattributed tile is refused.
        let local = try #require(SidebarDragPayload(favorites: tile, sourceWindow: a.id))
        #expect(local.spaceID == harness.spaceID)
        #expect(SidebarDragPayload(favorites: tile, sourceWindow: UUID()) == nil)
        #expect(SidebarDragPayload(favorites: tile, sourceWindow: nil) == nil)
        a.sidebar.simulateDrop(local, at: a.sidebarPoint(listY: a.list.displayedLayout.newTabCenterY))
        await harness.settle()
        #expect(section(a.organization.tab(favorite)) == "today")
    }

    @Test("While rows spring, a drop aims at where rows are drawn, not where they will settle")
    func dropDuringMotionUsesPresentedPositions() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let p1 = try #require(await harness.openTab("https://p1.test/"))
        let child = try #require(await harness.openTab("https://child.test/"))
        let p2 = try #require(await harness.openTab("https://p2.test/"))
        let t = try #require(await harness.openTab("https://t.test/"))
        c.session.pinTabs([p1, child, p2])
        await harness.settle()
        let folder = try #require(await c.session.createFolder(title: "F", at: .init(.pinned(harness.spaceID), position: .after(.tab(p1))),
                                                               containing: [.tab(child)]).value)
        c.session.setFolderCollapsed(folder, true)
        c.session.moveItems([.tab(p2)], to: .init(.pinned(harness.spaceID), position: .end))
        c.session.moveItems([.tab(p1)], to: .init(.pinned(harness.spaceID), position: .start))
        await harness.settle()
        #expect(c.organization.pinned.map(\.node) == [.tab(p1), .folder(folder), .tab(p2)])
        let folderRest = c.center(.folder(folder))
        var now: CFTimeInterval = 500
        c.list.animator.clock = { now }
        c.list.forcesAnimation = true
        OrbitMotionPreferences.overrideReducedMotion = false
        defer {
            OrbitMotionPreferences.overrideReducedMotion = nil
            c.list.forcesAnimation = false
        }
        // p1 moves to the end: the folder springs up one pitch; early on it is still drawn near its old place.
        c.session.moveItems([.tab(p1)], to: .init(.pinned(harness.spaceID), position: .end))
        await harness.settle()
        now += 0.02
        let drawn = try #require(c.list.displayedCenterY(of: .node(.folder(folder)), at: now))
        let settled = try #require(c.list.displayedLayout.centerY(of: .node(.folder(folder))))
        #expect(settled < folderRest && drawn > settled + OrbitTokens.Metrics.Sidebar.rowPitch / 2)
        // Aiming at the drawn folder files into it (the settled layout would insert around p2).
        let hover = c.sidebar.simulateDragHover(c.payload(.tab(t)), at: c.sidebarPoint(listY: drawn))
        #expect(hover?.proposal.folderTarget == folder)
        let resting = SidebarDropResolver.resolve(y: drawn, iconX: 18, layout: c.list.dropLayout, entries: c.sidebar.listContent.entries,
                                                  spaceID: harness.spaceID, draggedRows: 1)
        #expect(resting.folderTarget == nil)
        c.sidebar.simulateDragExit()
    }

    @Test("A list leaving its window mid-animation stops its springs and its display link")
    func displayLinkStopsWithTheList() async throws {
        let org = SyntheticOrganization()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        scroll.documentView = list
        window.contentView = scroll
        list.spaceTitleCenterY = 20
        let tabs = (0..<4).map { _ in TabID() }
        list.apply(SidebarListContent(snapshot: org.snapshot(today: tabs.map { org.tab($0) })), animated: false)
        list.layoutSubtreeIfNeeded()
        list.forcesAnimation = true
        OrbitMotionPreferences.overrideReducedMotion = false
        defer { OrbitMotionPreferences.overrideReducedMotion = nil }
        list.apply(SidebarListContent(snapshot: org.snapshot(today: tabs.reversed().map { org.tab($0) })), animated: true)
        #expect(list.animator.isAnimating && list.animator.hasDisplayLink)
        scroll.removeFromSuperview()
        #expect(!list.animator.isAnimating && !list.animator.hasDisplayLink)
        #expect(list.row(for: .tab(tabs[3])).map { abs($0.frame.midY - list.displayedLayout.centerY(of: .node(.tab(tabs[3])))!) < 0.5 } != false)
    }

    @Test("⌘W closes a sidebar multi-selection as one command, else the visible tab")
    func commandWClosesMultiSelection() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let a = try #require(await harness.openTab("https://a.test/"))
        let b = try #require(await harness.openTab("https://b.test/"))
        let visible = try #require(c.organization.selectedTab?.id)
        c.sidebar.list(c.list, activate: .tab(a), modifiers: .command)
        c.sidebar.list(c.list, activate: .tab(b), modifiers: .command)
        c.sidebar.list(c.list, activate: .tab(visible), modifiers: .command)
        #expect(c.sidebar.selection.nodes == [.tab(a), .tab(b)])
        #expect(harness.registry.dispatch(.archiveTab, origin: .keyboard))
        await harness.settle()
        #expect(c.organization.tab(a) == nil && c.organization.tab(b) == nil)
        #expect(c.organization.selectedTab?.id == visible && c.organization.undoAction == .closeTabs)
        #expect(c.sidebar.selection.nodes == [.tab(visible)])
        // No multi-selection: the visible tab closes as before.
        _ = await harness.openTab("https://keep.test/")
        #expect(harness.registry.dispatch(.archiveTab, origin: .keyboard))
        await harness.settle()
        #expect(c.organization.tab(visible) == nil)
    }

    @Test("⌘Z undoes the window's most recent undoable action: organization or page edit; a focused field keeps its own")
    func undoRouting() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let c = harness.window
        let window = try #require(c.window)
        let router = c.sidebar.undoRouter
        #expect(router.isInstalled)
        // The router sits in every view's chain before the window (it answers nil-target undo:).
        var responder: NSResponder? = c.contentCard
        var chain: [NSResponder] = []
        while let current = responder, current !== window { chain.append(current); responder = current.nextResponder }
        #expect(chain.contains { $0 === router })
        let a = try #require(await harness.openTab("https://a.test/"))
        window.makeFirstResponder(nil)
        // 1. Organization command, then a page edit in the shared undo manager.
        c.session.pinTabs([a])
        await harness.settle()
        let manager = try #require(window.undoManager)
        final class Edit: NSObject { var undone = 0 }
        let edit = Edit()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: edit) { $0.undone += 1 }
        manager.endUndoGrouping()
        // Edits group by event: the group closes at the end of this run loop turn.
        try await Task.sleep(for: .milliseconds(50))
        #expect(router.nextSource(redo: false) == .window)
        let item = NSMenuItem(title: "", action: Selector(("undo:")), keyEquivalent: "")
        #expect(router.validateUserInterfaceItem(item))
        router.undo(nil)
        await harness.settle()
        #expect(edit.undone == 1)
        // 2. Next ⌘Z: the organization command, with its own menu title.
        #expect(router.nextSource(redo: false) == .organization)
        #expect(router.validateUserInterfaceItem(item) && item.title == "Undo Pin Tab")
        router.undo(nil)
        await harness.settle()
        #expect(section(c.organization.tab(a)) == "today")
        // ⇧⌘Z redoes the most recently undone first.
        #expect(router.nextSource(redo: true) == .organization)
        router.redo(nil)
        await harness.settle()
        #expect(section(c.organization.tab(a)) == "pinned")
        // 3. A focused text field owns ⌘Z, even when organization is the most recent action.
        c.session.unpinTabs([a])
        await harness.settle()
        #expect(router.nextSource(redo: false) == .organization)
        window.makeFirstResponder(c.addressControl)
        #expect(window.firstResponder is NSText)
        #expect(router.nextSource(redo: false) != .organization)
        window.makeFirstResponder(c.list)
        // The focused list prefers organization.
        #expect(router.nextSource(redo: false, preferringOrganization: true) == .organization)
        c.list.undo(nil)
        await harness.settle()
        #expect(section(c.organization.tab(a)) == "pinned")
    }

    @Test("A conflicted newer organization record leaves the real undo candidate before the intervening page edit")
    func undoConflictPreservesPageEditOrder() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://pin.test/", in: a))
        let y = try #require(await harness.openTab("https://rename.test/", in: a))
        let b = try await harness.newWindow()
        let window = try #require(a.window)
        window.makeFirstResponder(nil)
        let manager = try #require(window.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        let router = a.sidebar.undoRouter
        // A: Pin X, page edit E, Rename Y. B then invalidates A's Rename Y.
        a.session.pinTabs([x])
        await harness.settle()
        let pinRecord = try #require(a.organization.undoRecordID)
        final class Edit: NSObject { var undone = 0 }
        let edit = Edit()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: edit) { target in
            target.undone += 1
            manager.registerUndo(withTarget: target) { $0.undone -= 1 }
        }
        manager.setActionName("Page Edit")
        manager.endUndoGrouping()
        a.session.renameTab(y, to: "Local")
        await harness.settle()
        let renameRecord = try #require(a.organization.undoRecordID)
        #expect(renameRecord != pinRecord && router.nextSource(redo: false) == .organization)
        b.session.renameTab(y, to: "Remote")
        await harness.settle()
        #expect(a.organization.undoAction == .pinTabs && a.organization.undoRecordID == pinRecord)
        #expect(a.organization.undoRecordCount == renameRecord)
        let item = NSMenuItem(title: "", action: #selector(SidebarUndoRouter.undo(_:)), keyEquivalent: "")
        #expect(router.nextSource(redo: false) == .window)
        #expect(router.validateUserInterfaceItem(item) && item.title == "Undo Page Edit")
        router.undo(nil)
        await harness.settle()
        #expect(edit.undone == 1 && section(a.organization.tab(x)) == "pinned")
        #expect(a.organization.tab(y)?.customTitle == "Remote")
        #expect(router.validateUserInterfaceItem(item) && item.title == "Undo Pin Tab")
        router.undo(nil)
        await harness.settle()
        #expect(section(a.organization.tab(x)) == "today" && a.organization.tab(y)?.customTitle == "Remote")
        #expect(a.organization.redoRecordID == pinRecord)
        // Redo follows the order of the successful undos, keeping the same record identity.
        #expect(router.nextSource(redo: true) == .organization)
        router.redo(nil)
        await harness.settle()
        #expect(section(a.organization.tab(x)) == "pinned" && a.organization.undoRecordID == pinRecord)
        #expect(router.nextSource(redo: true) == .window)
        router.redo(nil)
        await harness.settle()
        #expect(edit.undone == 0)
    }

    @Test("A peer metadata conflict strictly after the source choice cannot replay an older organization record before a page edit")
    func conflictAfterSourceChoiceReresolves() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://late-pin.test/"))
        let y = try #require(await harness.openTab("https://late-rename.test/"))
        let b = try await harness.newWindow()
        let peerWindow = try #require(b.session.snapshot?.id)
        let peerContext = try await harness.store.captureContext(in: peerWindow)
        let window = try #require(a.window)
        window.makeFirstResponder(nil)
        let manager = try #require(window.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        a.session.pinTabs([x])
        await harness.settle()
        let edit = SyntheticUndoEdit(manager: manager)
        edit.change(to: 1)
        a.session.renameTab(y, to: "Local")
        await harness.settle()
        let renameID = try #require(a.organization.undoRecordID)
        let router = a.sidebar.undoRouter
        let original = router.replayOrganization
        defer { router.replayOrganization = original }
        let store = harness.store
        var peerMutation: Task<Void, Error>?
        var injected = false
        router.replayOrganization = { [weak a] redo, choose, completion in
            original(redo, {
                let organization = choose()
                if organization, !injected {
                    injected = true
                    #expect(a?.organization.undoRecordID == renameID)
                    // Deterministic test barrier: the non-MainActor store finishes the peer edit
                    // after the choice, while the MainActor cannot refresh or call replay yet.
                    let finished = DispatchSemaphore(value: 0)
                    peerMutation = Task.detached {
                        defer { finished.signal() }
                        _ = try await store.renameTab(y, to: "Remote", from: peerContext)
                    }
                    #expect(finished.wait(timeout: .now() + 5) == .success)
                }
                return organization
            }, completion)
        }
        router.undo(nil)
        await harness.settle()
        try await peerMutation?.value
        #expect(injected && edit.value == 0 && edit.changes == 2)
        #expect(section(a.organization.tab(x)) == "pinned")
        #expect(a.organization.tab(y)?.customTitle == "Remote")
        #expect(router.nextSource(redo: false) == .organization)
        router.undo(nil)
        await harness.settle()
        #expect(section(a.organization.tab(x)) == "today" && edit.value == 0)
    }

    @Test("A new native edit overtaking a queued undo or redo supersedes the request without touching the later edit",
          arguments: [false, true])
    func newerNativeEditSupersedesQueuedReplay(redo: Bool) async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://native-boundary.test/"))
        let window = try #require(a.window)
        window.makeFirstResponder(nil)
        let manager = try #require(window.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        a.session.pinTabs([x])
        await harness.settle()
        let edit = SyntheticUndoEdit(manager: manager)
        edit.change(to: 1)
        let router = a.sidebar.undoRouter
        var reasons: [SidebarUndoRouter.SupersessionReason] = []
        router.onSuperseded = { reasons.append($0) }
        if redo { router.undo(nil); await harness.settle() }
        let changesBefore = edit.changes
        if redo { router.redo(nil) } else { router.undo(nil) }
        edit.change(to: 2) // No await: this edit is newer than the accepted physical request.
        if redo { manager.undo() } // E2, not E1, is now the native redo candidate.
        await harness.settle()
        let laterValue = redo ? 0 : 2
        #expect(edit.value == laterValue && edit.changes == changesBefore + (redo ? 2 : 1))
        #expect(reasons == [.newerNativeEdit] && router.supersededRequestCount == 1)
        #expect(section(a.organization.tab(x)) == "pinned")
        // A fresh, valid native pair acts on E2 and its inverse without another publication gap.
        let stableChanges = edit.changes
        if redo {
            router.redo(nil)
            router.undo(nil)
        } else {
            router.undo(nil)
            router.redo(nil)
        }
        await harness.settle()
        #expect(edit.value == laterValue && edit.changes == stableChanges + 2 && reasons.count == 1)
        #expect(section(a.organization.tab(x)) == "pinned")
    }

    @Test("External native redo or undo after receipt revokes an older routing boundary",
          arguments: [false, true])
    func externalNativeReplaySupersedesQueuedRequest(queuedRedo: Bool) async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://external-replay.test/"))
        let window = try #require(a.window)
        window.makeFirstResponder(nil)
        let manager = try #require(window.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        let edit = SyntheticUndoEdit(manager: manager)
        edit.change(to: 1) // E1 predates the organization record.
        a.session.pinTabs([x])
        await harness.settle()
        let pinID = try #require(a.organization.undoRecordID)
        edit.change(to: 2) // E2 follows Pin X.
        manager.undo() // E2 is undone outside the routing FIFO; E1 is still applied.
        #expect(edit.value == 1)
        let router = a.sidebar.undoRouter
        var reasons: [SidebarUndoRouter.SupersessionReason] = []
        router.onSuperseded = { reasons.append($0) }
        // No await between the accepted request and the external native history mutation.
        if queuedRedo {
            router.redo(nil) // Intended native candidate: E2.
            manager.undo() // The external undo of E1 changes the native redo candidate.
        } else {
            router.undo(nil)
            manager.redo() // E2 is restored after receipt, outside the routing FIFO.
        }
        let valueAfterExternalReplay = queuedRedo ? 0 : 2
        let changesAfterExternalReplay = edit.changes
        await harness.settle()
        #expect(edit.value == valueAfterExternalReplay && edit.changes == changesAfterExternalReplay)
        #expect(section(a.organization.tab(x)) == "pinned" && a.organization.undoRecordID == pinID)
        #expect(reasons == [.externalNativeReplay] && router.supersededRequestCount == 1)
        // The FIFO's own replays do not invalidate the next accepted inverse request.
        if queuedRedo {
            router.redo(nil)
            router.undo(nil)
        } else {
            router.undo(nil)
            router.redo(nil)
        }
        await harness.settle()
        #expect(edit.value == valueAfterExternalReplay && edit.changes == changesAfterExternalReplay + 2)
        #expect(reasons.count == 1 && router.supersededRequestCount == 1)
    }

    @Test("An open native group is not closed or undone by a deferred replay")
    func openNativeGroupIsAnUnstableBoundary() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        _ = await harness.openTab("https://open-group.test/")
        let manager = try #require(a.window?.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        let edit = SyntheticUndoEdit(manager: manager)
        manager.beginUndoGrouping()
        edit.change(to: 1)
        let router = a.sidebar.undoRouter
        var reasons: [SidebarUndoRouter.SupersessionReason] = []
        router.onSuperseded = { reasons.append($0) }
        router.undo(nil)
        edit.change(to: 2)
        await harness.settle()
        #expect(edit.value == 2 && manager.groupingLevel == 1)
        #expect(reasons == [.unstableNativeGroup])
        manager.endUndoGrouping()
    }

    @Test("Rapid undo, redo and inverse requests resolve after each earlier replay has published")
    func rapidUndoRedoUsesPublishedCandidates() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://rapid-pin.test/"))
        let y = try #require(await harness.openTab("https://rapid-rename.test/"))
        let window = try #require(a.window)
        window.makeFirstResponder(nil)
        let manager = try #require(window.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        let edit = SyntheticUndoEdit(manager: manager)
        edit.change(to: 1)
        a.session.pinTabs([x])
        a.session.renameTab(y, to: "Chosen")
        await harness.settle()
        let pinID = a.organization.undoRecordCount - 1
        let renameID = try #require(a.organization.undoRecordID)
        let router = a.sidebar.undoRouter
        // Stable E -> Pin X -> Rename Y; no publication between either physical keystroke.
        router.undo(nil)
        router.undo(nil)
        await harness.settle()
        #expect(section(a.organization.tab(x)) == "today" && a.organization.tab(y)?.customTitle == nil)
        #expect(edit.value == 1 && edit.changes == 1)
        #expect(a.organization.redoRecordID == pinID)
        router.redo(nil)
        router.redo(nil)
        await harness.settle()
        #expect(section(a.organization.tab(x)) == "pinned" && a.organization.tab(y)?.customTitle == "Chosen")
        #expect(edit.value == 1 && a.organization.undoRecordID == renameID)
        // The inverse request is accepted before undo creates a published redo candidate.
        router.undo(nil)
        let redoItem = NSMenuItem(title: "", action: #selector(SidebarUndoRouter.redo(_:)), keyEquivalent: "")
        #expect(router.validateUserInterfaceItem(redoItem))
        router.redo(nil)
        await harness.settle()
        #expect(a.organization.tab(y)?.customTitle == "Chosen" && edit.changes == 1)
        // Crossing both sources still preserves the complete FIFO, including the window redo.
        router.undo(nil)
        router.undo(nil)
        router.undo(nil)
        router.redo(nil)
        router.redo(nil)
        router.redo(nil)
        await harness.settle()
        #expect(section(a.organization.tab(x)) == "pinned" && a.organization.tab(y)?.customTitle == "Chosen")
        #expect(edit.value == 1 && edit.changes == 3)
        #expect(a.organization.undoRecordID == renameID)
        // An ordinary session command between two accepted undo requests keeps its input slot.
        router.undo(nil)
        a.session.renameTab(y, to: "Replacement")
        router.undo(nil)
        await harness.settle()
        #expect(a.organization.tab(y)?.customTitle == nil && section(a.organization.tab(x)) == "pinned")
        #expect(edit.value == 1 && edit.changes == 3)
    }

    @Test("The production registry accepts consecutive sidebar undo and redo dispatches without granting other responders pending input")
    func registrySerializesRapidSidebarReplays() async throws {
        let harness = try await SidebarListHarness(usesSyntheticKeyWindow: true)
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://registry-pin.test/"))
        let y = try #require(await harness.openTab("https://registry-rename.test/"))
        let window = try #require(a.window)
        let document = try #require(a.session.selectedSurface?.documentView)
        window.makeFirstResponder(document)
        let manager = try #require(window.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        let edit = SyntheticUndoEdit(manager: manager)
        edit.change(to: 1)
        a.session.pinTabs([x])
        a.session.renameTab(y, to: "Chosen")
        await harness.settle()
        let undo = #selector(SidebarUndoRouter.undo(_:))
        #expect(a.commandResponder(for: undo, keyWindow: window) === a.sidebar.undoRouter)
        #expect(!window.isVisible && !window.isKeyWindow)
        let captured = try #require(harness.registry.captureTarget())
        #expect(harness.registry.dispatch(.undo, origin: .keyboard))
        #expect(a.session.hasPendingCommands)
        // The same pending input permission must not spread to native field editors or Copy.
        window.makeFirstResponder(a.addressControl)
        #expect(window.firstResponder is NSText)
        #expect(!harness.registry.isEnabled(.undo) && !harness.registry.isEnabled(.redo))
        #expect(!harness.registry.dispatch(.copy, origin: .keyboard))
        #expect(!harness.registry.dispatch(.paste, origin: .keyboard))
        window.makeFirstResponder(document)
        #expect(!harness.registry.dispatch(.undo, origin: .contextMenu, target: captured))
        let secondUndo = harness.registry.dispatch(.undo, origin: .keyboard)
        #expect(secondUndo)
        await harness.settle()
        guard secondUndo else { return }
        #expect(section(a.organization.tab(x)) == "today" && a.organization.tab(y)?.customTitle == nil)
        #expect(edit.value == 1 && edit.changes == 1)
        window.makeFirstResponder(a.list)
        #expect(harness.registry.dispatch(.redo, origin: .keyboard))
        #expect(harness.registry.dispatch(.redo, origin: .keyboard))
        await harness.settle()
        #expect(section(a.organization.tab(x)) == "pinned" && a.organization.tab(y)?.customTitle == "Chosen")
        #expect(edit.value == 1 && edit.changes == 1)
        // The reserved, unimplemented incognito binding must never fall through to New Folder.
        #expect(harness.registry.resolve(.init(key: "n", modifiers: [.command, .shift])) == nil)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test("Accepted undo keeps the editor or sidebar preference even if focus changes before delivery",
          arguments: [false, true])
    func queuedUndoPreservesResponderPreference(textFocused: Bool) async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://focus.test/"))
        let window = try #require(a.window)
        let manager = try #require(window.undoManager)
        manager.removeAllActions()
        manager.groupsByEvent = false
        let edit = SyntheticUndoEdit(manager: manager)
        if textFocused { edit.change(to: 1) }
        a.session.pinTabs([x])
        await harness.settle()
        if !textFocused { edit.change(to: 1) }
        if textFocused {
            window.makeFirstResponder(a.addressControl)
            #expect(window.firstResponder is NSText)
            a.sidebar.undoRouter.undo(nil)
        } else {
            window.makeFirstResponder(a.list)
            a.list.undo(nil)
        }
        window.makeFirstResponder(nil)
        await harness.settle()
        #expect(section(a.organization.tab(x)) == (textFocused ? "pinned" : "today"))
        #expect(edit.value == (textFocused ? 0 : 1))
    }

    @Test("A row dropped into another window's Favorites moves the exact live document without a replay",
          arguments: [false, true])
    func favoritesCrossWindowTransfersDocument(replacingExisting: Bool) async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://favorite.test/", in: a, activate: true))
        let dragged = try #require(a.liveSidebarSurface(of: x))
        dragged.navigate(to: URL(string: "https://favorite.test/form")!)
        let draft = NSTextField(string: "Unsaved synthetic form")
        dragged.documentView.addSubview(draft)
        await harness.settle()
        let b = try await harness.newWindow()
        if replacingExisting { b.session.selectTab(x); await harness.settle() }
        let own = b.liveSidebarSurface(of: x)
        #expect((own != nil) == replacingExisting)
        let surfacesBefore = harness.engine.surfaces.count
        let loadsBefore = dragged.requestedURLs
        let zone = NSPoint(x: 100, y: b.sidebar.geometry.addressFrame.maxY + 4)
        let verdict = b.sidebar.simulateDrop(a.payload(.tab(x)), at: zone)
        #expect(verdict?.isValid == true && verdict?.proposal.destination.container == .favorites(harness.profileID))
        await harness.settle()
        #expect(b.session.selectedSurface === dragged && b.liveSidebarSurface(of: x) === dragged)
        #expect(b.organization.tab(x)?.isSelected == true && section(b.organization.tab(x)) == "favorites")
        #expect(b.session.snapshot?.tabs.filter { $0.id == x }.count == 1)
        #expect(a.liveSidebarSurface(of: x) == nil && !a.owns(dragged) && b.owns(dragged))
        #expect(a.session.snapshot?.tabs.contains { $0.id == x } == false)
        #expect(!dragged.isDisposed && own?.isDisposed != false)
        #expect(harness.engine.surfaces.count == surfacesBefore && dragged.requestedURLs == loadsBefore)
        #expect(draft.superview === dragged.documentView && draft.stringValue == "Unsaved synthetic form")
        #expect(dragged.navigationState.canGoBack && dragged.currentURL?.path == "/form")
        #expect(b.organization.favorites.filter { $0.node == .tab(x) }.count == 1)
        #expect(await b.session.archivedTabs().value.contains { $0.id == x } == false)
    }

    @Test("Favorites rejects row drops across Spaces and profiles without moving or loading any document")
    func favoritesRejectsForeignRowDocuments() async throws {
        let harness = try await SidebarListHarness()
        defer { harness.shutdown() }
        let a = harness.window
        let x = try #require(await harness.openTab("https://source.test/", in: a, activate: true))
        let dragged = try #require(a.liveSidebarSurface(of: x))
        let b = try await harness.newWindow()
        let otherSpace = try await harness.store.createSpace(name: "Other", profileID: harness.profileID)
        let foreignProfile = await harness.store.createProfile(name: "Foreign synthetic")
        let foreignSpace = try await harness.store.createSpace(name: "Foreign", profileID: foreignProfile)
        for space in [otherSpace, foreignSpace] {
            b.session.activateSpace(space)
            await harness.settle()
            let count = harness.engine.surfaces.count
            let zone = NSPoint(x: 100, y: b.sidebar.geometry.addressFrame.maxY + 4)
            let verdict = b.sidebar.simulateDrop(a.payload(.tab(x)), at: zone)
            #expect(verdict?.isValid == false)
            // Delivery rechecks the same boundary even if the gesture was accepted earlier.
            b.performSidebarDrop(a.payload(.tab(x)), to: .init(.favorites(harness.profileID)), changesOrganization: true)
            await harness.settle()
            #expect(a.liveSidebarSurface(of: x) === dragged && a.owns(dragged) && !dragged.isDisposed)
            #expect(b.session.selectedSurface == nil && harness.engine.surfaces.count == count)
            #expect(section(a.organization.tab(x)) == "today" && b.organization.favorites.isEmpty)
        }
        b.session.activateSpace(harness.spaceID)
        await harness.settle()
        let unknown = SidebarDragPayload(sourceWindow: a.id, spaceID: harness.spaceID,
            profileID: harness.profileID, nodes: [.tab(TabID())], rowCount: 1, grabOffsetX: 0)
        let zone = NSPoint(x: 100, y: b.sidebar.geometry.addressFrame.maxY + 4)
        #expect(b.sidebar.simulateDrop(unknown, at: zone)?.isValid == false)
        let captured = a.payload(.tab(x))
        a.session.activateSpace(otherSpace)
        await harness.settle()
        let destinationDocument = b.session.selectedSurface
        let surfacesBeforeStaleDrop = harness.engine.surfaces.count
        // The source changed Space while a previously validated delivery was queued.
        b.performSidebarDrop(captured, to: .init(.favorites(harness.profileID)), changesOrganization: true)
        await harness.settle()
        #expect(b.organization.favorites.isEmpty && b.session.selectedSurface === destinationDocument)
        #expect(harness.engine.surfaces.count == surfacesBeforeStaleDrop && !dragged.isDisposed)
        a.session.activateSpace(harness.spaceID)
        await harness.settle()
        #expect(a.liveSidebarSurface(of: x) === dragged && section(a.organization.tab(x)) == "today")
    }

    @Test("500 rows: a few dozen views, linear updates; timings recorded")
    func fiveHundredRows() async throws {
        let org = SyntheticOrganization()
        let selected = TabID()
        func makeSnapshot(rename index: Int? = nil, reversed: Bool = false, collapsed: Bool = false) -> BrowserOrganizationSnapshot {
            var pinned: [BrowserOrganizationItem] = []
            let folderChildren = (0..<100).map { org.tab(TabID(uuid: 1_000 + $0), pinned: true, title: "Folder child \($0)") }
            pinned.append(org.folder(FolderID(uuid: 1), title: "Big folder", collapsed: collapsed, folderChildren))
            pinned += (0..<99).map { org.tab(TabID(uuid: 2_000 + $0), pinned: true, title: "Pinned \($0)") }
            var today = (0..<300).map { i in
                org.tab(i == 0 ? selected : TabID(uuid: 3_000 + i), title: i == index ? "Renamed \(i)" : "Today \(i)",
                        occurrence: i == 0 ? TabOccurrenceID() : nil, selected: i == 0)
            }
            if reversed { today.reverse() }
            return org.snapshot(pinned: pinned, today: today)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 228, height: 640), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 228, height: 640))
        scroll.documentView = list
        window.contentView = scroll
        list.spaceTitleCenterY = 20
        let clock = ContinuousClock()
        func measure(_ body: () -> Void) -> Double {
            let start = clock.now
            body()
            let elapsed = clock.now - start
            return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        }
        func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }
        // Warm AppKit up (fonts, symbols, first views) so the samples measure the list.
        list.apply(SidebarListContent(snapshot: org.snapshot(today: [org.tab(title: "Warm-up")])), animated: false)
        list.layoutSubtreeIfNeeded()
        var content = SidebarListContent()
        let build = median((0..<5).map { _ in measure { content = SidebarListContent(snapshot: makeSnapshot()) } })
        #expect(content.entries.count == 500)
        var initialSamples: [Double] = []
        var renameSamples: [Double] = [], reorderSamples: [Double] = [], foldSamples: [Double] = [], scrollSamples: [Double] = []
        let maxViews = Int(640 / OrbitTokens.Metrics.Sidebar.rowPitch) + 2 * OrbitTokens.Metrics.Sidebar.virtualizationOverscanRows + 3
        let base = SidebarListContent(snapshot: makeSnapshot())
        let renamed = SidebarListContent(snapshot: makeSnapshot(rename: 1))
        let reversed = SidebarListContent(snapshot: makeSnapshot(reversed: true))
        let folded = SidebarListContent(snapshot: makeSnapshot(reversed: true, collapsed: true))
        for _ in 0..<5 {
            list.apply(SidebarListContent(), animated: false)
            list.scroll(.zero)
            initialSamples.append(measure {
                list.apply(base, animated: false)
                list.frame.size.height = list.documentHeight
                list.layoutSubtreeIfNeeded()
            })
            #expect(list.materializedRowCount <= maxViews && list.materializedRowCount > 5)
            renameSamples.append(measure { list.apply(renamed, animated: true) })
            reorderSamples.append(measure { list.apply(reversed, animated: true) })
            foldSamples.append(measure { list.apply(folded, animated: true) })
            #expect(list.content.entries.count == 400)
            scrollSamples.append(measure {
                list.scroll(NSPoint(x: 0, y: list.documentHeight - 640))
                scroll.reflectScrolledClipView(scroll.contentView)
            })
            #expect(list.materializedRowCount <= maxViews)
            #expect(list.tabRows.last.map { $0.frame.maxY > list.documentHeight - 700 } == true)
        }
        let initial = median(initialSamples), rename = median(renameSamples), reorder = median(reorderSamples)
        let fold = median(foldSamples), scrollTime = median(scrollSamples)
        // Generous debug-build budgets on medians; the measured values are reported by the lot.
        #expect(build < 50 && initial < 300 && rename < 50 && reorder < 100 && fold < 100 && scrollTime < 50)
        print(String(format: "SB-LIST 500 rows, median of 5 (ms): build %.2f, first render %.2f, title %.2f, reorder %.2f, fold 100 %.2f, scroll %.2f, views %d",
                     build, initial, rename, reorder, fold, scrollTime, list.materializedRowCount))
    }
}
}

private extension TabID {
    init(uuid value: Int) { self.init(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!) }
}

private extension FolderID {
    init(uuid value: Int) { self.init(UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", value))!) }
}
