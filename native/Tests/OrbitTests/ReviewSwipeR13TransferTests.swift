import AppKit
import Testing
@testable import Orbit

@MainActor
private final class R13Parent: NSView {
    var events: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { events.append(event) }
}

@MainActor
private final class R13Receiver: NSScrollView {
    var events: [NSEvent] = []
    var onWheel: ((NSEvent) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        events.append(event)
        onWheel?(event)
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct ReviewSwipeR13TransferTests {
    private func window() -> NSWindow {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let result = NSWindow(contentRect: .init(x: 173, y: 219, width: 360, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        return result
    }

    private func wheel(windowNumber: Int? = nil, phase: Int64 = 2, momentum: Int64 = 0) throws -> NSEvent {
        let cg: CGEvent
        if let windowNumber {
            let mouse = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .init(x: 30, y: 600),
                modifierFlags: [.shift], timestamp: 5, windowNumber: windowNumber, context: nil,
                eventNumber: 17, clickCount: 0, pressure: 0))
            cg = try #require(mouse.cgEvent?.copy())
            cg.type = .scrollWheel
        } else {
            cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 3,
                                     wheel1: -9, wheel2: 2, wheel3: 3))
            cg.location = .init(x: 13, y: 17)
        }
        cg.timestamp = 9_876_543_210
        cg.flags = [.maskShift, .maskAlternate]
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -9)
        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -2)
        cg.setIntegerValueField(.scrollWheelEventScrollCount, value: 7)
        cg.setIntegerValueField(.eventSourceUserData, value: 731)
        return try #require(NSEvent(cgEvent: cg))
    }

    private func attach(_ window: NSWindow) -> (R13Parent, SidebarSpaceContentViewport, R13Receiver) {
        let parent = R13Parent(frame: window.contentView!.bounds)
        window.contentView = parent
        let viewport = SidebarSpaceContentViewport(frame: .init(x: 11, y: 23, width: 300, height: 580))
        parent.addSubview(viewport)
        let receiver = R13Receiver(frame: .init(x: 7, y: 140, width: 270, height: 320))
        viewport.addSubview(receiver)
        receiver.documentView = NSView(frame: .init(x: 0, y: 0, width: 270, height: 2500))
        receiver.contentView.scroll(to: .init(x: 0, y: 173))
        viewport.scrollReceiver = receiver
        return (parent, viewport, receiver)
    }

    @Test("Representable transfer preserves selected public CG fields and original backing across nested geometry")
    func copiedFieldsAndOriginalLifetime() throws {
        let window = window()
        defer { window.close() }
        let (_, viewport, receiver) = attach(window)
        let original = try wheel()
        let cg = try #require(original.cgEvent)
        let originalData = try #require(cg.data)
        let originalPoint = original.locationInWindow
        viewport.scrollWheel(with: original)
        let forwarded = try #require(receiver.events.first)
        #expect(forwarded !== original)
        #expect(receiver.contentView.convert(receiver.contentView.bounds, to: nil).contains(forwarded.locationInWindow))
        #expect(forwarded.windowNumber == original.windowNumber)
        #expect(forwarded.timestamp == original.timestamp)
        #expect(forwarded.modifierFlags == original.modifierFlags)
        let copy = try #require(forwarded.cgEvent)
        // Include source/process, wheel count, third axis and window-under-pointer fields,
        // beyond the production acceptance guard. Reading numeric fields does not post input.
        let fields: [CGEventField] = [.eventSourceUserData, .eventSourceStateID, .eventSourceUnixProcessID,
            .eventSourceUserID, .eventSourceGroupID, .eventTargetUnixProcessID,
            .scrollWheelEventScrollCount, .scrollWheelEventInstantMouser,
            .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
            .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
            .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3,
            .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase,
            .mouseEventWindowUnderMousePointer, .mouseEventWindowUnderMousePointerThatCanHandleThisEvent]
        for field in fields {
            #expect(copy.getIntegerValueField(field) == cg.getIntegerValueField(field))
            #expect(copy.getDoubleValueField(field) == cg.getDoubleValueField(field))
        }
        #expect((cg.data as Data?) == (originalData as Data))
        #expect(original.locationInWindow == originalPoint)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test("Nonzero Cocoa window backing refuses translation for vertical and momentum packets")
    func nonzeroFallbackIsStillLegacy() throws {
        let window = window()
        defer { window.close() }
        let (_, viewport, receiver) = attach(window)
        for (phase, momentum): (Int64, Int64) in [(1, 0), (2, 0), (4, 0), (8, 0), (0, 1), (0, 2), (0, 3)] {
            let original = try wheel(windowNumber: window.windowNumber, phase: phase, momentum: momentum)
            #expect(original.window === window && original.windowNumber != 0)
            let before = try #require(original.cgEvent?.data)
            #expect(SidebarWheelTransfer.event(original, into: receiver) == nil)
            viewport.scrollWheel(with: original)
            #expect(receiver.events.last === original)
            #expect((original.cgEvent?.data as Data?) == (before as Data))
        }
        #expect(receiver.events.count == 7)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test("Same-window in-rectangle input preserves ordinary responder identity")
    func inRectangleIdentity() throws {
        let window = window()
        defer { window.close() }
        let (parent, viewport, receiver) = attach(window)
        let original = try wheel(windowNumber: window.windowNumber)
        let local = viewport.convert(original.locationInWindow, from: nil)
        receiver.frame = .init(x: local.x - 10, y: local.y - 10, width: 20, height: 20)
        viewport.scrollWheel(with: original)
        #expect(receiver.events.isEmpty)
        #expect(parent.events.count == 1 && parent.events.first === original)
    }

    @Test("A live foreign-window event is rejected even with a current same-window receiver")
    func foreignEventWindow() throws {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let (parent, viewport, receiver) = attach(first)
        let original = try wheel(windowNumber: second.windowNumber)
        #expect(original.window === second)
        viewport.scrollWheel(with: original)
        #expect(receiver.events.isEmpty)
        #expect(parent.events.count == 1 && parent.events.first === original)
    }

    @Test("An unresolved foreign window number cannot forward into the current receiver")
    func unresolvedWindowAssociation() throws {
        let window = window()
        defer { window.close() }
        let (parent, viewport, receiver) = attach(window)
        let original = try wheel(windowNumber: 1_000_000_007)
        #expect(original.windowNumber == 1_000_000_007 && original.window == nil)
        let bytes = try #require(original.cgEvent?.data)
        viewport.scrollWheel(with: original)
        #expect(receiver.events.isEmpty)
        #expect(parent.events.count == 1 && parent.events.first === original)
        #expect((original.cgEvent?.data as Data?) == (bytes as Data))
    }

    @Test("Synchronous responder recursion is bounded and the next wheel remains deliverable")
    func recursiveForwardingResets() throws {
        let window = window()
        defer { window.close() }
        let (parent, viewport, receiver) = attach(window)
        receiver.onWheel = { [weak viewport] event in viewport?.scrollWheel(with: event) }
        for _ in 0..<2 { viewport.scrollWheel(with: try wheel()) }
        #expect(receiver.events.count == 2 && parent.events.count == 2)
        #expect(zip(receiver.events, parent.events).allSatisfy { $0 === $1 })
    }
}
}
