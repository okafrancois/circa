import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class MiddleClickHandler: SidebarRowEventHandler {
    var closed: [TabID] = []
    var selections = 0
    var drags = 0
    func rowMouseDown(_ row: SidebarListRow, with event: NSEvent) { selections += 1 }
    func rowMouseUp(_ row: SidebarListRow, with event: NSEvent) { selections += 1 }
    func rowMouseDragged(_ row: SidebarListRow, with event: NSEvent) { drags += 1 }
    func rowRightMouseDown(_ row: SidebarListRow, with event: NSEvent) {}
    func rowPerformPress(_ row: SidebarListRow) -> Bool { selections += 1; return true }
    func rowClose(_ row: SidebarTabRow) { closed.append(row.item.id) }
    func rowResetToPinnedURL(_ row: SidebarTabRow) {}
    func rowDidFinishRename(_ row: SidebarListRow, title: String?, initialTitle: String) {}
}

extension NativeWebKitTests {
@Suite(.serialized) @MainActor struct SidebarMiddleClickTests {
    private func event(_ type: CGEventType, button: UInt32 = 2, point: CGPoint = .init(x: 80, y: 16)) throws -> NSEvent {
        let kind: NSEvent.EventType = type == .otherMouseDown ? .otherMouseDown
            : type == .otherMouseUp ? .otherMouseUp : .otherMouseDragged
        let native = try #require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let cg = try #require(native.cgEvent)
        cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test("Regular and nested split rows close on middle release without selection or dragging", arguments: [false, true])
    func regularAndSplit(selected: Bool) throws {
        let handler = MiddleClickHandler()
        let item = SidebarTabItem(id: TabID(), title: "Synthetic", selected: selected)
        let rows: [SidebarTabRow] = [SidebarTabRow(item: item, depth: 2),
            SidebarSplitRow(item: item, node: .split(SplitGroupID()), depth: 1)]
        for row in rows {
            row.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
            row.events = handler
            let before = handler.closed.count
            row.otherMouseDown(with: try event(.otherMouseDown))
            #expect(handler.closed.count == before)
            row.otherMouseDragged(with: try event(.otherMouseDragged))
            row.otherMouseUp(with: try event(.otherMouseUp))
            #expect(handler.closed.count == before + 1)
            #expect(handler.closed.last == item.id)
        }
        #expect(handler.selections == 0 && handler.drags == 0)
    }

    @Test("Folders, unavailable controls and side buttons do not close rows")
    func ignoredTargets() throws {
        let handler = MiddleClickHandler()
        let folder = SidebarFolderRow(item: .init(id: FolderID(), title: "Folder", isCollapsed: false, childCount: 0))
        let hidden = SidebarTabRow(item: .init(id: TabID(), title: "Hidden control", selected: false))
        hidden.closeButton.isHidden = true
        let disabled = SidebarTabRow(item: .init(id: TabID(), title: "Disabled", selected: false))
        disabled.commandsEnabled = false
        for row: SidebarListRow in [folder, hidden, disabled] {
            row.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
            row.events = handler
            row.otherMouseDown(with: try event(.otherMouseDown))
            row.otherMouseUp(with: try event(.otherMouseUp))
        }
        let regular = SidebarTabRow(item: .init(id: TabID(), title: "Regular", selected: false))
        regular.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
        regular.events = handler
        for button: UInt32 in [3, 4] {
            regular.otherMouseDown(with: try event(.otherMouseDown, button: button))
            regular.otherMouseUp(with: try event(.otherMouseUp, button: button))
        }
        #expect(handler.closed.isEmpty)
        #expect(handler.selections == 0 && handler.drags == 0)
    }

    @Test("Pinned rows accept middle release whether loaded or dormant", arguments: [false, true])
    func pinned(loaded: Bool) throws {
        let handler = MiddleClickHandler()
        let row = SidebarTabRow(item: .init(id: TabID(), title: "Pin", selected: false, isPinned: true, isLoadedInThisWindow: loaded), depth: 1)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
        row.events = handler
        row.otherMouseDown(with: try event(.otherMouseDown))
        row.otherMouseUp(with: try event(.otherMouseUp))
        #expect(handler.closed == [row.item.id])
    }

    @Test("Favorite tiles ignore middle clicks without selection or dragging")
    func favoriteIgnored() throws {
        let org = SyntheticOrganization()
        guard case let .tab(tab) = org.tab(pinned: true) else { return }
        let tile = FavoriteTileView(item: .init(tab: tab))
        var actions = 0
        tile.onSelect = { actions += 1 }
        tile.onDrag = { _ in actions += 1 }
        tile.otherMouseDown(with: try event(.otherMouseDown))
        tile.otherMouseDragged(with: try event(.otherMouseDragged))
        tile.otherMouseUp(with: try event(.otherMouseUp))
        #expect(actions == 0 && !tile.isPressed)
    }

    @Test("Release outside, unmatched release and row reuse cancel middle close")
    func cancellation() throws {
        let row = SidebarTabRow(item: .init(id: TabID(), title: "Synthetic", selected: false))
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
        let handler = MiddleClickHandler()
        row.events = handler
        row.otherMouseUp(with: try event(.otherMouseUp))
        row.otherMouseDown(with: try event(.otherMouseDown))
        row.otherMouseUp(with: try event(.otherMouseUp, point: .init(x: 80, y: 50)))
        row.otherMouseDown(with: try event(.otherMouseDown))
        row.resetForReuse()
        row.otherMouseUp(with: try event(.otherMouseUp))
        row.otherMouseDown(with: try event(.otherMouseDown))
        row.rebind(node: .tab(TabID()), depth: 0)
        row.otherMouseUp(with: try event(.otherMouseUp))
        #expect(handler.closed.isEmpty)
    }
}
}
