import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized) @MainActor struct WindowFreeze2Tests {
    private func environment() -> BrowserEnvironment<PeekSyntheticEngine> {
        NSApplication.shared.setActivationPolicy(.prohibited)
        return BrowserEnvironment(engine: PeekSyntheticEngine())
    }

    @Test("Rapid A B A row activation preserves the final physical selection")
    func rapidReturnSelection() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        c.session.openTab(url: URL(string: "https://synthetic.test/b")!)
        await c.session.waitForPendingCommands()
        let tabs = try #require(c.session.snapshot?.tabs)
        let a = tabs[0].id, b = tabs[1].id
        c.session.selectTab(a)
        await c.session.waitForPendingCommands()
        c.activateSidebarTab(b)
        c.activateSidebarTab(a)
        await c.session.waitForPendingCommands()
        #expect(c.session.organization?.selectedTab?.id == a)
        #expect(c.session.selectedSurface != nil)
    }

    @Test("A double-count click on an unselected row still selects it")
    func doubleCountOnDifferentRow() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        c.session.openTab(url: URL(string: "https://synthetic.test/other")!)
        await c.session.waitForPendingCommands()
        let tab = try #require(c.session.snapshot?.tabs.first?.id)
        c.window?.contentView?.layoutSubtreeIfNeeded()
        let row = try #require(c.sidebar.page.list.row(for: .tab(tab)))
        let point = row.convert(NSPoint(x: 60, y: row.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                windowNumber: c.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
            if type == .leftMouseDown { row.mouseDown(with: event) } else { row.mouseUp(with: event) }
        }
        await c.session.waitForPendingCommands()
        #expect(c.session.organization?.selectedTab?.id == tab)
        #expect(c.sidebar.page.list.renameField == nil)
    }

    @Test("Window undo restores all Spaces, occurrences and per-Space selection without replacing another window")
    func wholeWindow() async throws {
        let e = environment(), c = try await e.makeWindow(), other = try await e.makeWindow()
        defer { other.window?.close() }
        let profile = try #require(c.session.activeProfileID)
        let space = try await e.store.createSpace(name: "Synthetic secondary", profileID: profile)
        c.session.openTab(url: URL(string: "https://synthetic.test/first")!)
        c.session.activateSpace(space)
        c.session.openTab(url: URL(string: "https://synthetic.test/second")!)
        await c.session.waitForPendingCommands()
        let before = try #require(c.session.snapshot)
        let document = await e.store.sessionDocument()
        let saved = try #require(document.windows.first { $0.id == before.id })
        let otherID = other.session.snapshot?.id
        c.window?.close()
        let reopened = try #require(try await e.reopenClosedWindow())
        defer { reopened.window?.close() }
        await reopened.session.waitForPendingCommands()
        #expect(reopened.session.snapshot?.id == before.id)
        #expect(reopened.session.snapshot?.activeSpaceID == space)
        #expect(reopened.session.snapshot?.selectedOccurrenceID == before.selectedOccurrenceID)
        #expect(await e.store.sessionDocument().windows.first { $0.id == before.id }?.spaces == saved.spaces)
        #expect(other.session.snapshot?.id == otherID && !other.session.isClosed)
    }

    @Test("Undo can reopen Peek, while native text editors retain undo even without an edit")
    func peekAndText() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        #expect(c.openPeek(URL(string: "https://synthetic.test/peek")!) != nil)
        c.dismissPeek()
        let router = c.sidebar.undoRouter
        c.window?.makeFirstResponder(c.sidebar.page.list)
        #expect(router.nextSource(redo: false) == .closedItem)
        router.undo(nil)
        await router.waitForPendingCommands()
        await c.session.waitForPendingCommands()
        #expect(c.isPeekPresented)
        c.dismissPeek()
        let editor = NSTextView()
        c.window?.contentView?.addSubview(editor)
        c.window?.makeFirstResponder(editor)
        #expect(router.nextSource(redo: false) != .closedItem)
    }

    @Test("The surviving window routes Command-Z to the latest closed window after a newer tab undo")
    func routedWindowUndo() async throws {
        let e = environment(), closed = try await e.makeWindow(), c = try await e.makeWindow()
        defer { c.window?.close() }
        let id = try #require(closed.session.snapshot?.id)
        var reopened: WindowID?
        e.onReopenClosedWindow = { reopened = $0 }
        closed.window?.close()
        await closed.session.waitForPendingCommands()
        for _ in 0..<20 where e.lastClosedWindowDate == nil { await Task.yield() }
        c.session.openTab(url: URL(string: "https://synthetic.test/newer-close")!)
        await c.session.waitForPendingCommands()
        let tab = try #require(c.session.organization?.selectedTab?.id)
        c.performSidebarRowAction([tab]); await c.session.waitForPendingCommands()
        c.window?.makeFirstResponder(c.sidebar.page.list)
        #expect(c.sidebar.undoRouter.nextSource(redo: false) == .organization)
        c.sidebar.undoRouter.undo(nil)
        await c.sidebar.undoRouter.waitForPendingCommands()
        #expect(c.session.organization?.tab(tab) != nil)
        #expect(c.sidebar.undoRouter.nextSource(redo: false) == .closedItem)
        c.sidebar.undoRouter.undo(nil)
        await c.sidebar.undoRouter.waitForPendingCommands()
        for _ in 0..<100 where reopened == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reopened == id)
    }

    @Test("Command-Z restores a closed tab through the existing organization journal")
    func tabUndo() async throws {
        let e = environment(), c = try await e.makeWindow()
        defer { c.window?.close() }
        c.session.openTab(url: URL(string: "https://synthetic.test/closed")!)
        await c.session.waitForPendingCommands()
        let tab = try #require(c.session.organization?.selectedTab?.id)
        c.performSidebarRowAction([tab])
        await c.session.waitForPendingCommands()
        c.window?.makeFirstResponder(c.sidebar.page.list)
        c.sidebar.undoRouter.undo(nil)
        await c.sidebar.undoRouter.waitForPendingCommands()
        #expect(c.session.organization?.tab(tab) != nil)
    }
}
}
