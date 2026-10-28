import AppKit
import Testing
@testable import Orbit
@testable import BrowserCore

@MainActor
private final class FolderPreviewClock {
    final class Ticket: OrbitCancellable {
        let deadline: Double
        let action: @MainActor () -> Void
        var cancelled = false
        init(_ deadline: Double, _ action: @escaping @MainActor () -> Void) { self.deadline = deadline; self.action = action }
        func cancel() { cancelled = true }
    }
    var time = 0.0
    var tickets: [Ticket] = []
    func schedule(_ delay: Double, _ action: @escaping @MainActor () -> Void) -> any OrbitCancellable {
        let ticket = Ticket(time + delay, action); tickets.append(ticket); return ticket
    }
    func advance(_ amount: Double) {
        time += amount
        let due = tickets.filter { $0.deadline <= time && !$0.cancelled }
        for ticket in due { ticket.cancelled = true; ticket.action() }
    }
}

extension NativeWebKitTests {
@Suite("Folder preview deterministic ownership")
@MainActor
struct FolderPreviewTests {
    @Test("A dispatched first departure cannot expire the grace of a later departure")
    func independentRepeatedDepartureRegression() {
        let fixture = SyntheticOrganization(), clock = FolderPreviewClock(), intent = FolderPreviewIntent()
        let folder = FolderID()
        intent.schedule = clock.schedule
        intent.arm(folder: folder, snapshot: fixture.snapshot(pinned: [fixture.folder(folder)]))
        clock.advance(0.3)
        intent.departure()
        let firstDeparture = clock.tickets.last!
        clock.advance(0.10)
        intent.returnToPreview()
        intent.departure()
        // The first timer was already dispatched when cancelled. Its deadline is now due,
        // while the second traversal still has 100 ms of its own grace remaining.
        clock.advance(0.08)
        firstDeparture.action()
        #expect(intent.phase == .leaving)
        clock.advance(0.10)
        #expect(intent.phase == .idle)
    }

    @Test("Departure before delay never presents or activates; cancelled callbacks cannot resurrect A-B-A")
    func delayAndABA() {
        let fixture = SyntheticOrganization(), clock = FolderPreviewClock(), intent = FolderPreviewIntent()
        let a = FolderID(), b = FolderID(), tab = TabID()
        let snapshot = fixture.snapshot(pinned: [fixture.folder(a, [fixture.tab(tab)]), fixture.folder(b)])
        intent.schedule = clock.schedule
        var presentations = 0
        intent.onShow = { presentations += 1 }
        intent.arm(folder: a, snapshot: snapshot)
        clock.advance(0.299)
        #expect(presentations == 0)
        intent.departure()
        clock.advance(1)
        #expect(presentations == 0 && intent.phase == .idle)
        intent.arm(folder: a, snapshot: snapshot)
        let stale = clock.tickets.last!
        intent.arm(folder: b, snapshot: snapshot)
        intent.arm(folder: a, snapshot: snapshot)
        stale.action() // Simulate already dispatched, uncancellable work.
        #expect(intent.phase == .armed && presentations == 0)
        clock.advance(0.300)
        #expect(presentations == 1 && intent.results.map(\.tab.id) == [tab])
        #expect(snapshot.selectedTab == nil && snapshot.tab(tab)?.occurrenceID == nil)
    }

    @Test("Traversal grace, stale leave and stale searches cannot affect successor")
    func graceSearchAndSuccessor() {
        let fixture = SyntheticOrganization(), clock = FolderPreviewClock(), intent = FolderPreviewIntent()
        let folder = FolderID(), alpha = TabID(), beta = TabID()
        let snapshot = fixture.snapshot(pinned: [fixture.folder(folder, [fixture.tab(alpha, title: "Alpha"), fixture.tab(beta, title: "Béta")])])
        intent.schedule = clock.schedule
        intent.arm(folder: folder, snapshot: snapshot); clock.advance(0.3)
        intent.departure(); let leave = clock.tickets.last!
        clock.advance(0.179); intent.returnToPreview(); clock.advance(0.01)
        #expect(intent.phase == .visible)
        leave.action()
        #expect(intent.phase == .visible)
        let previousAdmission = intent.admission
        intent.search("Alpha"); let oldSearch = clock.tickets.last!
        #expect(intent.results.isEmpty && !previousAdmission.isValid)
        intent.search("beta"); oldSearch.action()
        #expect(intent.results.isEmpty)
        clock.advance(0.1)
        #expect(intent.results.map(\.tab.id) == [beta])
        let token = intent.epoch
        #expect(intent.permits(beta, epoch: token, current: snapshot))
        #expect(!intent.permits(alpha, epoch: token, current: snapshot))
        #expect(!intent.permits(beta, epoch: token - 1, current: snapshot))
        intent.search("Alpha"); let cancelledSearch = clock.tickets.last!
        intent.revoke(); intent.arm(folder: folder, snapshot: snapshot)
        cancelledSearch.action(); leave.action()
        #expect(intent.phase == .armed && intent.results.isEmpty)
        #expect(!intent.permits(beta, epoch: token, current: snapshot))
    }

    @Test("Removal, movement, profile/window/Space and monotone roundtrip publication revoke all actions")
    func contextRevocation() {
        let fixture = SyntheticOrganization(), other = SyntheticOrganization()
        let folder = FolderID(), tab = TabID()
        let snapshot = fixture.snapshot(pinned: [fixture.folder(folder, [fixture.tab(tab)])])
        var roundtrip = snapshot
        roundtrip.organizationRevision += 2
        let cases: [BrowserOrganizationSnapshot?] = [nil, fixture.snapshot(),
            fixture.snapshot(pinned: [fixture.folder(folder), fixture.tab(tab)]),
            other.snapshot(pinned: [other.folder(folder, [other.tab(tab)])]), roundtrip]
        for next in cases {
            let intent = FolderPreviewIntent(), clock = FolderPreviewClock()
            intent.schedule = clock.schedule
            intent.arm(folder: folder, snapshot: snapshot); clock.advance(0.3)
            let epoch = intent.epoch
            intent.search("ignored"); let search = clock.tickets.last!
            intent.reconcile(next); search.action()
            #expect(intent.phase == .idle && intent.results.isEmpty)
            #expect(!intent.permits(tab, epoch: epoch, current: snapshot))
        }
    }

    @Test("Nested folders and split panes retain stored order, paths and exact tab identities")
    func recursiveSplitOrder() throws {
        let fixture = SyntheticOrganization(), root = FolderID(), splitID = SplitGroupID()
        let a = TabID(), b = TabID(), c = TabID(), d = TabID()
        let paneB = try #require(fixture.snapshot(today: [fixture.tab(b)]).tab(b))
        let paneC = try #require(fixture.snapshot(today: [fixture.tab(c)]).tab(c))
        let split = BrowserOrganizationItem.split(.init(group: .init(id: splitID, tabIDs: [b, c]), tabs: [paneB, paneC]))
        let snapshot = fixture.snapshot(pinned: [fixture.folder(root, [fixture.tab(a), fixture.folder(title: "Nested", [split]), fixture.tab(d)])])
        let intent = FolderPreviewIntent()
        intent.arm(folder: root, snapshot: snapshot)
        let rows = intent.allResults
        #expect(rows.map(\.tab.id) == [a, b, c, d])
        #expect(rows.map(\.path) == [[], ["Nested"], ["Nested"], []])
        #expect(rows.map(\.split) == [nil, splitID, splitID, nil])
        #expect(rows.allSatisfy { $0.tab.occurrenceID == nil })
        #expect(FolderPreviewResult.ordered([]).isEmpty)
    }

    @Test("Detached/dormant capture fallback never requests a paint or navigation")
    func dormantFallback() {
        let cache = BrowserSwitcherSnapshots<SwitcherSnapshotSurface>()
        let surface = SwitcherSnapshotSurface()
        #expect(cache.request(surface) == nil)
        #expect(cache.image(for: surface) == nil && surface.requests.isEmpty)
        surface.isDisposed = true
        #expect(cache.request(surface) == nil && surface.requests.isEmpty)
        cache.shutdown()
        #expect(FolderPreviewView.recency(nil) == uiText("Last access unavailable"))
        #expect(FolderPreviewView.recency(Date.distantFuture) == uiText("Last access unavailable"))
    }
}
}

extension NativeWebKitTests {
@Suite("Folder preview owned fullscreen hover hold")
@MainActor
struct FolderPreviewHoverHoldTests {
    @Test("Anchor traversal and search hold the revealed sidebar; stale dismissal cannot release a successor")
    func ownedHoldAndSuccessor() {
        let fixture = SyntheticOrganization(), clock = FolderPreviewClock()
        let preview = FolderPreviewIntent(), hover = OrbitSidebarHoverReveal()
        let folder = FolderID()
        let snapshot = fixture.snapshot(pinned: [fixture.folder(folder)])
        var ownedPreview = false
        preview.schedule = clock.schedule
        hover.schedule = clock.schedule
        var pointerInside = false
        hover.isPointerInside = { pointerInside } // Pointer has moved from the floating sidebar to the page/overlay.
        hover.isHeld = { ownedPreview } // Explicit owned presentation, no child-window heuristic.
        preview.onShow = { ownedPreview = true; hover.holdDidChange() }
        preview.onHide = {
            if ownedPreview { ownedPreview = false; hover.holdDidChange() }
        }
        hover.setEnabled(true); hover.pointerEnteredEdge(); clock.advance(hover.dwell)
        preview.arm(folder: folder, snapshot: snapshot); clock.advance(0.3)
        hover.pointerExitedPanel()
        #expect(hover.phase == .revealed && ownedPreview)
        preview.departure(); let oldLeave = clock.tickets.last!
        preview.returnToPreview(); preview.search("test")
        #expect(hover.phase == .revealed && ownedPreview)
        preview.revoke()
        #expect(hover.phase == .leaving && !ownedPreview)
        pointerInside = true; hover.pointerEnteredPanel()
        preview.arm(folder: folder, snapshot: snapshot); clock.advance(0.3)
        pointerInside = false; hover.pointerExitedPanel()
        // The new owned overlay cancels dismissal and cannot be released by the old leave callback.
        oldLeave.action()
        #expect(ownedPreview && hover.isRevealed && preview.phase == .visible)
        preview.reconcile(nil)
        #expect(!ownedPreview && hover.phase == .leaving)
        clock.advance(hover.leaveDelay)
        #expect(hover.phase == .idle) // Existing fullscreen reveal seam returns control to the page.
    }
}
}

@MainActor
private final class FolderPreviewComposition: NSTextView {
    var composing = false
    override func hasMarkedText() -> Bool { composing }
}

extension NativeWebKitTests {
@Suite("Folder preview native keyboard")
@MainActor
struct FolderPreviewKeyboardTests {
    @Test("IME owns Return, arrows and Escape; committed input activates only a current result")
    func compositionAndExplicitSelection() {
        let fixture = SyntheticOrganization(), id = TabID()
        let view = FolderPreviewView(), editor = FolderPreviewComposition()
        let results = FolderPreviewResult.ordered([fixture.tab(id, title: "Synthetic result")])
        var activated: [TabID] = [], escapes = 0
        view.onChoose = { activated.append($0) }
        view.onEscape = { escapes += 1 }
        view.render(results, image: { _ in nil })
        editor.composing = true
        for selector in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(!view.control(view.search, textView: editor, doCommandBy: selector))
        }
        #expect(activated.isEmpty && escapes == 0)
        editor.composing = false
        #expect(view.control(view.search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(view.control(view.search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(activated == [id])
        view.render([], image: { _ in nil })
        #expect(view.control(view.search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(activated == [id])
        #expect(view.control(view.search, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(escapes == 1)
    }
}
}


@Suite("Folder preview viewport geometry")
struct FolderPreviewGeometryTests {
    @Test("Empty, large and edge-anchored previews fit either native coordinate system")
    func clippingAndEmptyContent() {
        let viewport = NSRect(x: 0, y: 0, width: 800, height: 600)
        for flipped in [true, false] {
            for anchor in [NSRect(x: 10, y: 80, width: 200, height: 36), NSRect(x: 700, y: 580, width: 90, height: 20)] {
                for count in [0, 3, 100] {
                    let frame = FolderPreviewGeometry.frame(anchor: anchor, viewport: viewport, flipped: flipped, count: count)
                    #expect(viewport.insetBy(dx: 8, dy: 8).contains(frame))
                    #expect(frame.width == 320 && frame.height <= 530)
                    if count == 0 { #expect(frame.height == 124) }
                }
            }
        }
        let small = NSRect(x: 0, y: 0, width: 220, height: 150)
        #expect(small.contains(FolderPreviewGeometry.frame(anchor: small, viewport: small, flipped: false, count: 100)))
    }
}
