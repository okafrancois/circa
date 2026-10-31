import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized) @MainActor struct SidebarClick3Tests {
    private func environment() -> BrowserEnvironment<PeekSyntheticEngine> {
        NSApplication.shared.setActivationPolicy(.prohibited)
        return BrowserEnvironment(engine: PeekSyntheticEngine())
    }

    /// The view that receives a pointer event at the centre of `row`, through the list's hit test.
    private func hitView(atCenterOf row: NSView, in list: SidebarListView) -> NSView? {
        let center = NSPoint(x: row.frame.minX + 60, y: row.frame.midY)
        return list.hitTest(list.superview.map { list.convert(center, to: $0) } ?? center)
    }

    private func belongs(_ view: NSView?, to row: NSView) -> Bool {
        guard let view else { return false }
        return view === row || view.isDescendant(of: row)
    }

    private func click(_ list: SidebarListView, at row: NSView, in window: NSWindow) throws {
        let point = row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
        let target = try #require(hitView(atCenterOf: row, in: list))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
        }
    }

    @Test("A recycled row left above a live row never swallows that row's clicks")
    func recycledRowDoesNotCoverLiveRow() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        for index in 0..<4 {
            c.session.openTab(url: URL(string: "https://synthetic.test/row-\(index)")!)
            await c.session.waitForPendingCommands()
        }
        c.window?.contentView?.layoutSubtreeIfNeeded()
        let list = c.sidebar.page.list
        let rows = list.tabRows
        // A closed row whose view is above (later in z-order) the row that slides into its slot.
        let closing = try #require(rows.indices.dropLast().first { index in
            (list.subviews.firstIndex(of: rows[index]) ?? 0) > (list.subviews.firstIndex(of: rows[index + 1]) ?? 0)
        })
        let closedTab = try #require(rows[closing].node.tabID)
        let survivorTab = try #require(rows[closing + 1].node.tabID)
        c.performSidebarRowAction([closedTab])
        await c.session.waitForPendingCommands()
        c.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(c.session.organization?.tab(closedTab) == nil)
        for row in list.tabRows {
            #expect(belongs(hitView(atCenterOf: row, in: list), to: row), "row \(row.node) is covered")
        }
        // The selection moves to the survivor through an ordinary pointer click.
        let other = try #require(list.tabRows.first { $0.node.tabID != survivorTab }?.node.tabID)
        c.session.selectTab(other)
        await c.session.waitForPendingCommands()
        let survivor = try #require(list.row(for: .tab(survivorTab)))
        try click(list, at: survivor, in: try #require(c.window))
        await c.session.waitForPendingCommands()
        #expect(c.session.organization?.selectedTab?.id == survivorTab)
    }

    @Test("Pooled and leaving rows never answer hit tests; live rows still do")
    func pooledAndLeavingRowsRefuseHits() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        for index in 0..<3 {
            c.session.openTab(url: URL(string: "https://synthetic.test/pool-\(index)")!)
            await c.session.waitForPendingCommands()
        }
        c.window?.contentView?.layoutSubtreeIfNeeded()
        let list = c.sidebar.page.list
        let closed = try #require(list.tabRows.first?.node.tabID)
        c.performSidebarRowAction([closed])
        await c.session.waitForPendingCommands()
        let pooled = try #require(list.subviews.compactMap { $0 as? SidebarTabRow }.first { $0.isHidden })
        #expect(pooled.hitTest(NSPoint(x: pooled.frame.minX + 60, y: pooled.frame.midY)) == nil)
        let live = try #require(list.tabRows.first)
        let center = NSPoint(x: live.frame.minX + 60, y: live.frame.midY)
        #expect(belongs(live.hitTest(center), to: live))
        live.isLeaving = true
        #expect(live.hitTest(center) == nil)
        live.isLeaving = false
        #expect(belongs(live.hitTest(center), to: live))
    }

    @Test("A release delivered to a rebuilt row view still selects the pressed tab")
    func reboundRelease() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        for index in 0..<2 {
            c.session.openTab(url: URL(string: "https://synthetic.test/rebound-\(index)")!)
            await c.session.waitForPendingCommands()
        }
        c.window?.contentView?.layoutSubtreeIfNeeded()
        let list = c.sidebar.page.list
        let selected = try #require(c.session.organization?.selectedTab?.id)
        let target = try #require(list.tabRows.first { $0.node.tabID != selected })
        let other = try #require(list.tabRows.first { $0 !== target })
        let targetTab = try #require(target.node.tabID)
        let window = try #require(c.window)
        let point = target.convert(NSPoint(x: 60, y: target.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        list.rowMouseDown(target, with: down)
        // AppKit delivers the release to the view that took the press; that view now shows another node.
        list.rowMouseUp(other, with: up)
        await c.session.waitForPendingCommands()
        #expect(c.session.organization?.selectedTab?.id == targetTab)
    }

    @Test("Clicking the selected row re-presents its page when the host left the window")
    func selectedRowRepairsDetachedHost() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        c.session.openTab(url: URL(string: "https://synthetic.test/selected")!)
        await c.session.waitForPendingCommands()
        let tab = try #require(c.session.organization?.selectedTab?.id)
        let surface = try #require(c.session.selectedSurface)
        surface.hostView.removeFromSuperview()
        #expect(surface.hostView.window == nil)
        c.activateSidebarTab(tab)
        await c.session.waitForPendingCommands()
        #expect(surface.hostView.window === c.window)
        #expect(c.session.organization?.selectedTab?.id == tab)
    }

    /// A row whose view sits above the row sliding into its slot when it leaves the list.
    private func coveringCandidate(in list: SidebarListView) -> (leaving: TabID, survivor: TabID)? {
        let rows = list.tabRows
        guard let index = rows.indices.dropLast().first(where: {
            (list.subviews.firstIndex(of: rows[$0]) ?? 0) > (list.subviews.firstIndex(of: rows[$0 + 1]) ?? 0) }),
              let leaving = rows[index].node.tabID, let survivor = rows[index + 1].node.tabID else { return nil }
        return (leaving, survivor)
    }

    @Test("After a row is dropped into another window, the row that slid into its slot takes clicks")
    func dropIntoAnotherWindow() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        let space = try #require(c.session.snapshot?.activeSpaceID)
        let receiver = try await e.makeWindow(spaceID: space, opensInitialTab: false, standalone: true)
        defer { receiver.window?.close() }
        for index in 0..<4 {
            c.session.openTab(url: URL(string: "https://synthetic.test/drag-\(index)")!)
            await c.session.waitForPendingCommands()
        }
        c.window?.contentView?.layoutSubtreeIfNeeded()
        let list = c.sidebar.page.list
        let (dragged, survivor) = try #require(coveringCandidate(in: list))
        // The drop path of a sidebar drag released over another window's sidebar.
        let payload = try #require(c.sidebar.list(list, dragPayloadFor: .tab(dragged), grabOffsetX: 0))
        receiver.performSidebarDrop(payload, to: .init(.standalone(try #require(receiver.session.snapshot?.id))),
                                    changesOrganization: true)
        for _ in 0..<5 {
            await c.session.waitForPendingCommands()
            await receiver.session.waitForPendingCommands()
            await Task.yield()
        }
        c.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(c.session.organization?.tab(dragged) == nil)
        for row in list.tabRows {
            #expect(belongs(hitView(atCenterOf: row, in: list), to: row), "row \(row.node) is covered after the drop")
        }
        let other = try #require(list.tabRows.first { $0.node.tabID != survivor }?.node.tabID)
        c.session.selectTab(other)
        await c.session.waitForPendingCommands()
        try click(list, at: try #require(list.row(for: .tab(survivor))), in: try #require(c.window))
        await c.session.waitForPendingCommands()
        #expect(c.session.organization?.selectedTab?.id == survivor)
    }

    @Test("A press whose release was taken by a drag or menu does not block the next click")
    func pressWithoutRelease() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        for index in 0..<2 {
            c.session.openTab(url: URL(string: "https://synthetic.test/press-\(index)")!)
            await c.session.waitForPendingCommands()
        }
        c.window?.contentView?.layoutSubtreeIfNeeded()
        let list = c.sidebar.page.list, window = try #require(c.window)
        let selected = try #require(c.session.organization?.selectedTab?.id)
        let first = try #require(list.tabRows.first { $0.node.tabID != selected })
        let second = try #require(list.tabRows.first { $0.node.tabID == selected })
        let point = first.convert(NSPoint(x: 60, y: first.bounds.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        first.mouseDown(with: down)   // No release: the system drag loop or a menu consumed it.
        c.session.selectTab(try #require(first.node.tabID))
        await c.session.waitForPendingCommands()
        try click(list, at: second, in: window)
        await c.session.waitForPendingCommands()
        #expect(c.session.organization?.selectedTab?.id == second.node.tabID)
        #expect(!first.isPressed)
    }

    @Test("Closing the Library always returns pointer input to the sidebar")
    func libraryCloseRestoresSidebarInput() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        c.window?.contentView?.layoutSubtreeIfNeeded()
        c.showLibrary()
        await c.session.waitForPendingCommands()
        c.hideLibrary()
        await c.session.waitForPendingCommands()
        c.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(!c.sidebar.isLibraryInputSuppressed)
        let row = try #require(c.sidebar.page.list.tabRows.first)
        #expect(belongs(hitView(atCenterOf: row, in: c.sidebar.page.list), to: row))
    }

    @Test("The last Library progress step releases sidebar input even without a geometry pass")
    func libraryFinalProgressReleasesInput() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        c.window?.contentView?.layoutSubtreeIfNeeded()
        // A spring settling under 0.01 pt of visible width publishes no further width change.
        c.windowShell.setLibraryProgress(0.00002)
        c.windowShell.applyGeometry()
        #expect(c.sidebar.isLibraryInputSuppressed)
        c.windowShell.setLibraryProgress(0)
        #expect(!c.sidebar.isLibraryInputSuppressed)
        let row = try #require(c.sidebar.page.list.tabRows.first)
        let point = c.sidebar.convert(NSPoint(x: row.frame.minX + 60, y: row.frame.midY), from: c.sidebar.page.list)
        #expect(c.sidebar.hitTest(c.sidebar.superview.map { c.sidebar.convert(point, to: $0) } ?? point) != nil)
    }
}
}
