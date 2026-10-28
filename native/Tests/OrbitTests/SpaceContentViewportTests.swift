import AppKit
import Testing
@testable import Orbit

@MainActor
private final class RecordingSpaceScrollView: NSScrollView {
    var events: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { events.append(event) }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SpaceContentViewportTests {
    @Test("Favorites wheel delivery reaches the native list once while list-origin delivery never recurses")
    func spaceContentWheelForwarding() throws {
        let viewport = SidebarSpaceContentViewport(frame: NSRect(x: 0, y: 0, width: 240, height: 500))
        let receiver = RecordingSpaceScrollView(frame: NSRect(x: 0, y: 100, width: 240, height: 400))
        viewport.addSubview(receiver)
        viewport.scrollReceiver = receiver
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 30, wheel2: 0, wheel3: 0))
        cg.location = .init(x: 30, y: 20)
        let favoriteEvent = try #require(NSEvent(cgEvent: cg))
        // No native tracking loop: a recording receiver proves the responder forwarding seam.
        viewport.scrollWheel(with: favoriteEvent)
        #expect(receiver.events.count == 1)
        #expect(receiver.events.first === favoriteEvent)
        cg.location = .init(x: 30, y: 200)
        let listEvent = try #require(NSEvent(cgEvent: cg))
        receiver.frame = viewport.convert(NSRect(x: listEvent.locationInWindow.x - 10,
                                                y: listEvent.locationInWindow.y - 10, width: 20, height: 20), from: nil)
        #expect(receiver.convert(receiver.bounds, to: nil).contains(listEvent.locationInWindow))
        viewport.scrollWheel(with: listEvent)
        #expect(receiver.events.count == 1)
    }
}
}
