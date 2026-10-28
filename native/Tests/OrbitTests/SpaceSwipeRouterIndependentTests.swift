import AppKit
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SpaceSwipeRouterIndependentTests {
    private func event(_ phase: Int64, x: Int32 = 0, y: Int32 = 0) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                     wheel1: y, wheel2: x, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.eventSourceUserData, value: 987654)
        cg.timestamp = 0
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test("Space swipe independent ticket exhaustion leaves originals and fresh genuine input untouched")
    func spaceSwipeIndependentTicketCapacity() throws {
        let router = SidebarScrollInputRouter()
        var posted: [NSEvent] = []
        router.postNativeEvent = { posted.insert($0, at: 0) }
        let original = try event(1)
        #expect(router.replayForRecognition(Array(repeating: original, count: 1024), isCurrent: { true }))
        #expect(posted.count == 1024)
        #expect(!router.replayForRecognition([original], isCurrent: { true }))
        #expect(posted.count == 1024)
        #expect(router.replay(original) == .unrelated)
        #expect(original.cgEvent?.getIntegerValueField(.eventSourceUserData) == 987654)
        router.invalidate()
        for copy in posted { #expect(router.replay(copy) == .discard) }
        let fresh = try event(1)
        #expect(router.replay(fresh) == .unrelated)
        #expect(router.route(fresh, inside: false, captureOwner: { nil }, recognize: { .inactive }, cancelRecognition: {} ) == false)
        #expect(!router.hasOwnedSequence)
        #expect(router.replayForRecognition([fresh], isCurrent: { true }))
    }

    @Test("Space swipe independent native tickets reject owner revocation and cannot replay a consumed copy twice")
    func spaceSwipeIndependentNativeTicketRevocation() throws {
        let router = SidebarScrollInputRouter()
        var ownerCurrent = true
        var posted: [NSEvent] = []
        router.postNativeEvent = { posted.insert($0, at: 0) }
        let begin = try event(1)
        let vertical = try event(2, y: 30)
        #expect(router.route(begin, inside: true, captureOwner: { { ownerCurrent } }, recognize: { .pending }, cancelRecognition: {}))
        #expect(router.route(vertical, inside: true, captureOwner: { { ownerCurrent } }, recognize: { .inactive }, cancelRecognition: {}))
        #expect(posted.count == 2)
        let duplicate = try #require(NSEvent(cgEvent: posted[0].cgEvent!.copy()!))
        #expect(router.replay(posted[0]) == .deliver)
        #expect(router.replay(duplicate) == .discard)
        ownerCurrent = false
        #expect(router.replay(posted[1]) == .discard)
        #expect(router.replay(begin) == .unrelated)
        router.releaseUnownedSequence()
        #expect(!router.hasOwnedSequence)
    }
}
}
