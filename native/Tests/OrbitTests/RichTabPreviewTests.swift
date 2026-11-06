import AppKit
import BrowserCore
import Testing
@testable import Orbit

@MainActor
private final class RichPreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class RichPreviewTicket: OrbitCancellable {
    let delay: TimeInterval
    let action: @MainActor () -> Void
    var cancelled = false
    init(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) { self.delay = delay; self.action = action }
    func cancel() { cancelled = true }
}

@MainActor
private final class RichPreviewFixture {
    let window = RichPreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                                   styleMask: [.borderless], backing: .buffered, defer: true)
    let controller = RichTabPreviewController()
    let first = SidebarTabRow(item: .init(id: TabID(), title: "Same title", selected: false))
    let second = SidebarTabRow(item: .init(id: TabID(), title: "Same title", selected: true))
    var contents: [TabID: RichTabPreviewContent] = [:]
    var tickets: [RichPreviewTicket] = []
    var actions: [(RichTabPreviewAction, RichTabPreviewIdentity)] = []
    init() {
        window.isReleasedWhenClosed = false
        let profile = ProfileID(), space = SpaceID()
        for (index, row) in [first, second].enumerated() {
            row.frame = NSRect(x: 8, y: 100 + index * 40, width: 230, height: 36)
            window.contentView?.addSubview(row)
            let identity = RichTabPreviewIdentity(profile: profile, space: space, tab: row.item.id,
                occurrence: TabOccurrenceID(), generation: 1, url: URL(string: "https://example.test/\(index)")!, section: .today(space))
            contents[row.item.id] = RichTabPreviewContent(identity: identity, title: "Same title \(index)",
                icon: NSImage(size: NSSize(width: 16, height: 16)), snapshot: NSImage(size: NSSize(width: 160, height: 90)))
        }
        controller.allowed = { true }
        controller.reducedMotion = { false }
        controller.content = { [weak self] in self?.contents[$0] }
        controller.schedule = { [weak self] delay, action in
            let ticket = RichPreviewTicket(delay, action); self?.tickets.append(ticket); return ticket
        }
        controller.action = { [weak self] in self?.actions.append(($0, $1)) }
    }
    func close() { controller.shutdown(); window.close() }
    func show() { controller.hover(first, inside: true); tickets.last?.action() }
}

extension NativeWebKitTests {
@Suite("Rich tab hover previews")
@MainActor
struct RichTabPreviewTests {
    @Test("Cold dwell cancels and duplicate-title warm handoff is immediate without an entry animation")
    func fastHandoff() {
        let f = RichPreviewFixture(); defer { f.close() }
        let responder = f.window.firstResponder
        f.controller.hover(f.first, inside: true)
        #expect(f.tickets.count == 1 && f.tickets[0].delay == 0.12)
        #expect(!f.controller.isPresented)
        f.controller.hover(f.first, inside: false)
        f.tickets[0].action()
        #expect(f.tickets[0].cancelled && !f.controller.isPresented)
        f.show()
        #expect(f.controller.isPresented)
        f.controller.hover(f.first, inside: false)
        let departure = f.tickets.last!
        let count = f.tickets.count
        f.controller.hover(f.second, inside: true)
        #expect(f.controller.isPresented && f.controller.row === f.second)
        #expect(f.controller.view.title.stringValue == "Same title 1")
        #expect(f.tickets.count == count)
        #expect(f.controller.view.layer?.animation(forKey: "rich-entry") == nil)
        departure.action()
        #expect(f.controller.isPresented && f.controller.row === f.second)
        #expect(f.window.firstResponder === responder)
    }

    @Test("Pointer crossing holds the card, while a fading card cannot receive actions or retain page pixels")
    func crossingAndExit() {
        let f = RichPreviewFixture(); defer { f.close() }
        f.show()
        f.controller.hover(f.first, inside: false)
        let stale = f.tickets.last!
        f.controller.view.onPointer?(true)
        stale.action()
        #expect(f.controller.isPresented)
        f.controller.dismiss(animated: true)
        let removal = f.tickets.last!
        #expect(removal.delay == 0.08)
        #expect(!f.controller.view.isInteractive)
        f.controller.view.onPointer?(true)
        f.controller.invoke(.favorite)
        removal.action()
        #expect(f.actions.isEmpty && !f.controller.isPresented)
        #expect(f.controller.view.picture.image == nil && f.controller.view.placeholder.image == nil)
        #expect(f.controller.view.superview == nil)
    }

    @Test("Profile, Space, occurrence, URL and generation changes revoke queued preview actions")
    func identityFences() {
        for field in 0..<5 {
            let f = RichPreviewFixture(); defer { f.close() }
            f.show()
            let old = f.contents[f.first.item.id]!.identity
            let next = RichTabPreviewIdentity(profile: field == 0 ? ProfileID() : old.profile,
                space: field == 1 ? SpaceID() : old.space, tab: old.tab,
                occurrence: field == 2 ? TabOccurrenceID() : old.occurrence,
                generation: field == 3 ? 2 : old.generation,
                url: field == 4 ? URL(string: "https://example.test/new")! : old.url, section: old.section)
            f.contents[old.tab] = RichTabPreviewContent(identity: next, title: "New document", icon: nil, snapshot: nil)
            f.controller.invoke(.pin)
            #expect(f.actions.isEmpty && !f.controller.isPresented)
            #expect(f.controller.view.picture.image == nil)
        }
    }

    @Test("Actions bind to the hovered tab, Ask stays gated and reduced motion has no dwell or transform")
    func actionsAndReducedMotion() {
        let f = RichPreviewFixture(); defer { f.close() }
        f.controller.reducedMotion = { true }
        f.controller.hover(f.second, inside: true)
        #expect(f.controller.isPresented && f.tickets.isEmpty)
        #expect(f.controller.view.layer?.animationKeys()?.isEmpty != false)
        #expect(!f.controller.view.buttons[3].isEnabled)
        f.controller.invoke(.ask)
        #expect(f.actions.isEmpty)
        f.controller.hover(f.second, inside: true)
        f.controller.invoke(.favorite)
        #expect(f.actions.count == 1 && f.actions.first?.1.tab == f.second.item.id)
        #expect(!f.controller.isPresented)
    }

    @Test("A moved row, permission revocation and shutdown clear cached title and image immediately")
    func lifecycle() {
        let f = RichPreviewFixture(); defer { f.close() }
        f.show()
        let before = f.first.convert(f.first.bounds, to: nil)
        f.first.frame.origin.y += 40
        let after = f.first.convert(f.first.bounds, to: nil)
        #expect(before != after)
        f.controller.reconcile()
        #expect(!f.controller.isPresented)
        #expect(f.controller.view.title.stringValue.isEmpty)
        f.show()
        f.controller.allowed = { false }
        f.controller.reconcile()
        #expect(!f.controller.isPresented && f.controller.view.picture.image == nil)
    }

    @Test("The preview stays within a narrow viewport near its bottom edge")
    func clamping() {
        for flipped in [true, false] {
            let viewport = NSRect(x: 0, y: 0, width: 300, height: 300)
            let result = RichTabPreviewController.frame(anchor: NSRect(x: 8, y: 270, width: 230, height: 28), bounds: viewport, flipped: flipped)
            #expect(viewport.insetBy(dx: 8, dy: 8).contains(result))
            #expect(result.size == RichTabPreviewView.size)
        }
    }
}
}
