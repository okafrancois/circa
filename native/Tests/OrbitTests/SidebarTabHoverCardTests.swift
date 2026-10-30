import AppKit
import BrowserCore
import Testing
@testable import Orbit

@MainActor
private final class HoverKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class HoverTicket: OrbitCancellable {
    let action: @MainActor () -> Void
    var cancelled = false
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { cancelled = true }
}

extension NativeWebKitTests {
@Suite("Sidebar title help and folder creation")
@MainActor
struct SidebarTabHoverCardTests {
    @Test("Cold dwell cancels without resurrection; warm handoff keeps the page responder")
    func dwellCancellationAndHandoff() throws {
        let window = HoverKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                    styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let card = SidebarTabHoverCard()
        defer { card.dismiss(); SidebarTabHoverCard.shared.dismiss(); window.close() }
        let a = SidebarTabRow(item: .init(id: TabID(), title: "Alpha", selected: false))
        let b = SidebarTabRow(item: .init(id: TabID(), title: "Beta", selected: true))
        for (index, row) in [a, b].enumerated() {
            row.frame = NSRect(x: 8, y: 100 + index * 40, width: 230, height: 36)
            window.contentView?.addSubview(row)
            row.mouseEntered(with: NSEvent())
        }
        SidebarTabHoverCard.shared.dismiss()
        let responder = window.firstResponder
        var tickets: [HoverTicket] = []
        card.schedule = { delay, action in
            #expect(delay == 1.5)
            let ticket = HoverTicket(action); tickets.append(ticket); return ticket
        }
        card.hover(a, inside: true)
        #expect(!card.isPresented && tickets.count == 1)
        card.hover(a, inside: false)
        tickets[0].action()
        #expect(tickets[0].cancelled && !card.isPresented)
        card.hover(b, inside: true)
        tickets[1].action()
        #expect(card.isPresented && card.row === b)
        card.hover(b, inside: false)
        card.hover(a, inside: true)
        #expect(card.isPresented && card.row === a && tickets.count == 2)
        #expect(window.firstResponder === responder)
        card.invalidate(a)
        #expect(!card.isPresented)
    }

    @Test("A changed row anchor retires a pending dwell")
    func movedAnchor() {
        let window = HoverKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                    styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let card = SidebarTabHoverCard()
        defer { card.dismiss(); SidebarTabHoverCard.shared.dismiss(); window.close() }
        let row = SidebarTabRow(item: .init(id: TabID(), title: "Alpha", selected: false))
        row.frame = NSRect(x: 8, y: 100, width: 230, height: 36)
        window.contentView?.addSubview(row)
        row.mouseEntered(with: NSEvent())
        SidebarTabHoverCard.shared.dismiss()
        var ticket: HoverTicket?
        card.schedule = { _, action in let result = HoverTicket(action); ticket = result; return result }
        card.hover(row, inside: true)
        row.frame.origin.y += 40
        ticket?.action()
        #expect(!card.isPresented)
    }

    @Test("Folder creation waits for insertion before editing and cancellation retires dispatched work")
    func creationRename() throws {
        #expect(SidebarListStrings.newFolder == "Untitled")
        #expect(SidebarListView.creationRenameDelay == 0.25)
        #expect(OrbitAnimationTiming.tabList.duration == 0.12)
        #expect(SidebarTabHoverCard.departureDuration == 0.1)
        let fixture = SyntheticOrganization(), id = FolderID()
        let window = HoverKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 500),
                                    styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 240, height: 500))
        window.contentView = list
        list.apply(SidebarListContent(snapshot: fixture.snapshot(pinned: [fixture.folder(id)])), animated: false)
        var tickets: [HoverTicket] = []
        list.scheduleRename = { delay, action in
            #expect(delay == 0.25)
            let ticket = HoverTicket(action); tickets.append(ticket); return ticket
        }
        list.beginRename(.folder(id), after: SidebarListView.creationRenameDelay)
        #expect(list.renameField == nil)
        list.cancelRename()
        tickets[0].action()
        #expect(list.renameField == nil && tickets[0].cancelled)
        list.beginRename(.folder(id), after: SidebarListView.creationRenameDelay)
        tickets[1].action()
        #expect(list.renameField != nil)
        list.cancelRename()
    }

    @Test("Title help uses cached title, localized hint and a passive forty-four point surface")
    func cardContent() {
        let view = SidebarTabHoverCardView()
        let size = view.configure(title: "Alpha", maximumWidth: 320)
        #expect(size.height == 44)
        #expect(view.title.stringValue == "Alpha")
        #expect(view.hint.stringValue == "Double-click to rename")
        #expect(view.hitTest(.zero) == nil)
        #expect(view.subviews.first is OrbitFrostView)
    }
}
}
