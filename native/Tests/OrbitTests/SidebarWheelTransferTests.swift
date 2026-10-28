import AppKit
import Testing
@testable import Orbit

@MainActor
private final class WheelTransferRecorder: NSScrollView {
    var events: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { events.append(event) }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SidebarWheelTransferTests {
    private func wheel(_ phase: Int64, y: Int32 = 0, x: Int32 = 0, momentum: Int64 = 0,
                       window: NSWindow? = nil, precise: Bool = true) throws -> NSEvent {
        let source = try #require(CGEventSource(stateID: .privateState))
        source.userData = 90213
        let cg: CGEvent
        if let window {
            // Public Cocoa construction supplies a real hidden-window target to the CG copy.
            // No OS posting or unsupported scrollWheel NSEvent constructor is used.
            let mouse = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .init(x: 30, y: 450),
                modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 0, pressure: 0))
            cg = try #require(mouse.cgEvent?.copy())
            cg.type = .scrollWheel
            cg.setSource(source)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(y))
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(x))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(y))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(x))
            cg.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(y) * 65_536)
            cg.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64(x) * 65_536)
        } else {
            cg = try #require(CGEvent(scrollWheelEvent2Source: source, units: precise ? .pixel : .line, wheelCount: 2,
                                      wheel1: y, wheel2: x, wheel3: 0))
            cg.location = CGPoint(x: 30, y: 20)
        }
        cg.timestamp = 1_234_567_890
        cg.flags = precise ? [.maskAlternate] : []
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        let event = try #require(NSEvent(cgEvent: cg))
        if let window { #expect(event.windowNumber == window.windowNumber && event.window === window) }
        return event
    }

    @Test("Favorites native transfer keeps every boundary and momentum packet inside the receiver")
    func sidebarWheelTransferBoundary() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let viewport = SidebarSpaceContentViewport(frame: window.contentView!.bounds)
        window.contentView!.addSubview(viewport)
        let receiver = WheelTransferRecorder(frame: .init(x: 0, y: 120, width: 240, height: 300))
        receiver.documentView = NSView(frame: .init(x: 0, y: 0, width: 240, height: 2000))
        viewport.addSubview(receiver)
        viewport.scrollReceiver = receiver
        let events = try [wheel(1), wheel(2, y: -7), wheel(2, y: -25), wheel(4),
                          wheel(0, y: -12, momentum: 1), wheel(0, y: -6, momentum: 2), wheel(0, momentum: 3),
                          wheel(1), wheel(2, x: -20), wheel(8)]
        for original in events {
            let point = original.locationInWindow
            let quartzPoint = original.cgEvent?.location
            #expect(!receiver.convert(receiver.bounds, to: nil).contains(point))
            viewport.scrollWheel(with: original)
            let forwarded = try #require(receiver.events.last)
            #expect(receiver.convert(receiver.bounds, to: nil).contains(forwarded.locationInWindow))
            #expect(forwarded !== original)
            #expect(forwarded.phase == original.phase && forwarded.momentumPhase == original.momentumPhase)
            #expect(forwarded.scrollingDeltaX == original.scrollingDeltaX && forwarded.scrollingDeltaY == original.scrollingDeltaY)
            #expect(forwarded.timestamp == original.timestamp && forwarded.windowNumber == original.windowNumber)
            #expect(forwarded.modifierFlags == original.modifierFlags && forwarded.modifierFlags.contains(.option))
            #expect(forwarded.deltaX == original.deltaX && forwarded.deltaY == original.deltaY && forwarded.deltaZ == original.deltaZ)
            #expect(forwarded.hasPreciseScrollingDeltas == original.hasPreciseScrollingDeltas)
            #expect(forwarded.isDirectionInvertedFromDevice == original.isDirectionInvertedFromDevice)
            #expect(forwarded.cgEvent?.getIntegerValueField(.eventSourceUserData) == 90213)
            #expect(forwarded.cgEvent?.getIntegerValueField(.eventSourceStateID) == original.cgEvent?.getIntegerValueField(.eventSourceStateID))
            #expect(original.locationInWindow == point && original.cgEvent?.location == quartzPoint)
        }
        #expect(receiver.events.count == events.count)
        #expect(receiver.events.map(\.phase) == events.map(\.phase))
        #expect(receiver.events.map(\.momentumPhase) == events.map(\.momentumPhase))
        #expect(!window.isVisible)
    }
}
}

@MainActor
private final class WheelTransferParent: NSView {
    var events: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { events.append(event) }
}

extension NativeWebKitTests.SidebarWheelTransferTests {
    @Test("A stale receiver in another native window cannot receive Favorites input")
    func sidebarWheelTransferWindowBoundary() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let first = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        let second = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let parent = WheelTransferParent(frame: first.contentView!.bounds)
        first.contentView = parent
        let viewport = SidebarSpaceContentViewport(frame: parent.bounds)
        parent.addSubview(viewport)
        let receiver = WheelTransferRecorder(frame: .init(x: 0, y: 120, width: 240, height: 300))
        second.contentView!.addSubview(receiver)
        viewport.scrollReceiver = receiver
        let original = try wheel(1, y: -7)
        viewport.scrollWheel(with: original)
        #expect(receiver.events.isEmpty && parent.events.count == 1)
        #expect(parent.events.first === original)
    }

    @Test("Detached identity remains unchanged and non-wheel packets are not converted")
    func sidebarWheelTransferCompatibility() throws {
        let detached = WheelTransferRecorder(frame: .init(x: 0, y: 0, width: 240, height: 300))
        let original = try wheel(1, y: -7)
        #expect(SidebarWheelTransfer.event(original, into: detached) === original)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView!.addSubview(detached)
        let other = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0))
        #expect(SidebarWheelTransfer.event(other, into: detached) == nil)
    }
}

@MainActor
private final class WheelTransferDocument: NSView {
    override var isFlipped: Bool { true }
}

extension NativeWebKitTests.SidebarWheelTransferTests {
    @Test("Favorites transfer continues to scroll the real native document in both vertical directions", arguments: [false, true])
    func sidebarWheelTransferNativeVertical(nonzeroWindow: Bool) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let viewport = SidebarSpaceContentViewport(frame: window.contentView!.bounds)
        window.contentView!.addSubview(viewport)
        let receiver = NSScrollView(frame: .init(x: 0, y: 120, width: 240, height: 300))
        receiver.hasVerticalScroller = true
        receiver.hasHorizontalScroller = false
        receiver.horizontalScrollElasticity = .none
        let document = WheelTransferDocument(frame: .init(x: 0, y: 0, width: 240, height: 2000))
        receiver.documentView = document
        viewport.addSubview(receiver)
        viewport.scrollReceiver = receiver
        receiver.tile()
        receiver.contentView.scroll(to: .init(x: 0, y: 200))
        receiver.reflectScrolledClipView(receiver.contentView)
        let start = receiver.contentView.bounds.minY
        // Native discrete wheel animation commits on the run loop. Settle it with a bounded
        // test-only wait, without opening a phased native tracking loop or activating a window.
        for delta: Int32 in [-2, 2] {
            let event = try wheel(0, y: delta, window: nonzeroWindow ? window : nil, precise: false)
            #expect(event.phase.isEmpty && event.momentumPhase.isEmpty)
            #expect(!receiver.convert(receiver.bounds, to: nil).contains(event.locationInWindow))
            let before = receiver.contentView.bounds.minY
            viewport.scrollWheel(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let after = receiver.contentView.bounds.minY
            print("SIDEBAR_WHEEL_NATIVE before=\(before) after=\(after) delta=\(delta) visible=\(window.isVisible)")
            let moved = delta < 0 ? after > before : after < before
            #expect(moved, "Native clip before=\(before) after=\(after) delta=\(delta)")
            #expect(receiver.documentView === document)
        }
        #expect(abs(receiver.contentView.bounds.minY - start) < 1)
        #expect(!window.isVisible)
    }
}

extension NativeWebKitTests.SidebarWheelTransferTests {
    @Test("Actual hidden-window targets retain semantics through mapped or strict compatibility dispatch")
    func sidebarWheelTransferNonzeroWindowSemantics() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let viewport = SidebarSpaceContentViewport(frame: window.contentView!.bounds)
        window.contentView!.addSubview(viewport)
        let receiver = WheelTransferRecorder(frame: .init(x: 0, y: 120, width: 240, height: 300))
        viewport.addSubview(receiver)
        viewport.scrollReceiver = receiver
        let events = try [wheel(1, window: window), wheel(2, y: -7, window: window), wheel(4, window: window),
                          wheel(0, y: -12, momentum: 1, window: window), wheel(0, y: -6, momentum: 2, window: window),
                          wheel(0, momentum: 3, window: window), wheel(1, window: window), wheel(8, window: window)]
        var mapped = 0, fallback = 0
        for original in events {
            #expect(original.windowNumber != 0 && original.window === window)
            let point = original.locationInWindow
            let accepted = SidebarWheelTransfer.event(original, into: receiver) != nil
            viewport.scrollWheel(with: original)
            let forwarded = try #require(receiver.events.last)
            if accepted {
                mapped += 1
                #expect(forwarded !== original)
                #expect(receiver.convert(receiver.bounds, to: nil).contains(forwarded.locationInWindow))
            } else {
                fallback += 1
                #expect(forwarded === original && forwarded.locationInWindow == point)
            }
            #expect(forwarded.windowNumber == window.windowNumber && forwarded.window === window)
            #expect(forwarded.phase == original.phase && forwarded.momentumPhase == original.momentumPhase)
            #expect(forwarded.timestamp == original.timestamp && forwarded.modifierFlags == original.modifierFlags)
            #expect(forwarded.scrollingDeltaX == original.scrollingDeltaX && forwarded.scrollingDeltaY == original.scrollingDeltaY)
            #expect(forwarded.cgEvent?.getIntegerValueField(.eventSourceUserData) == 90213)
            #expect(original.locationInWindow == point)
        }
        print("SIDEBAR_WHEEL_NONZERO mapped=\(mapped) fallback=\(fallback) packets=\(events.count)")
        #expect(mapped + fallback == events.count && receiver.events.count == events.count)
        #expect(receiver.events.map(\.phase) == events.map(\.phase))
        #expect(receiver.events.map(\.momentumPhase) == events.map(\.momentumPhase))
    }
}
