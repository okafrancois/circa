import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Test("Space swipe follows signed distance, reverses, and never wraps at edges")
func spaceSwipeProgressAndEdges() {
    var gesture = SpaceSwipeGesture()
    gesture.update(x: -80, y: 2, time: 1)
    #expect(gesture.intent == .horizontal)
    #expect(gesture.offset(width: 228, hasPrevious: true, hasNext: true) == -80)
    gesture.update(x: 120, y: 0, time: 1.1)
    #expect(gesture.offset(width: 228, hasPrevious: true, hasNext: true) == 40)
    let resistance = gesture.offset(width: 228, hasPrevious: false, hasNext: true)
    #expect(resistance > 0 && resistance < 40)
    #expect(gesture.destination(width: 228, hasPrevious: false, hasNext: true, at: 1.1) == nil)
}

@Test("Space swipe axis lock preserves vertical list scroll for the whole gesture")
func spaceSwipeAxisLock() {
    var gesture = SpaceSwipeGesture()
    gesture.update(x: 2, y: 15, time: 1)
    gesture.update(x: -160, y: 0, time: 1.1)
    #expect(gesture.intent == .vertical)
    #expect(gesture.offset(width: 228, hasPrevious: true, hasNext: true) == 0)
    #expect(gesture.destination(width: 228, hasPrevious: true, hasNext: true, at: 1.1) == nil)
    var ambiguous = SpaceSwipeGesture()
    ambiguous.update(x: 4, y: 4, time: 1)
    #expect(ambiguous.intent == .pending)
    ambiguous.update(x: 1, y: 1, time: 1.02)
    #expect(ambiguous.intent == .pending)
}

@Test("Space swipe uses nearest page at rest and directional release with fresh velocity")
func spaceSwipeCommitment() {
    var gesture = SpaceSwipeGesture()
    gesture.update(x: -20, y: 0, time: 1)
    #expect(gesture.destination(width: 228, hasPrevious: true, hasNext: true, at: 1) == nil)
    gesture.update(x: -20, y: 0, time: 1.02)
    #expect(gesture.destination(width: 228, hasPrevious: true, hasNext: true, at: 1.02) == 1)
    #expect(gesture.destination(width: 228, hasPrevious: true, hasNext: true, at: 1.3) == nil)
    gesture.update(x: -80, y: 0, time: 1.4)
    #expect(gesture.destination(width: 228, hasPrevious: true, hasNext: true, at: 1.6) == 1)
    gesture.update(x: 10, y: 0, time: 1.41)
    #expect(gesture.destination(width: 228, hasPrevious: true, hasNext: true, at: 1.41) == nil)
}

extension NativeWebKitTests {
@Test("Space swipe spring starts at finger position with explicit release velocity and settles exactly")
@MainActor
func spaceSwipeSpringVelocity() {
    let motion = SidebarSlotMotion(from: -92, to: -228, at: 10, spring: OrbitTokens.Motion.spaceSwitchSidebar, velocity: -420)
    #expect(motion.state(at: 10).value == -92)
    #expect(abs(motion.state(at: 10).velocity + 420) < 0.001)
    #expect(motion.value(at: 10.02) < -92)
    #expect(motion.isSettled(at: 12))
    #expect(motion.value(at: 12) == -228)
    let cancel = SidebarSlotMotion(from: -92, to: 0, at: 10, spring: OrbitTokens.Motion.spaceSwitchSidebar, velocity: 120)
    #expect(cancel.value(at: 12) == 0)
}
}

extension NativeWebKitTests {
@Test("Space swipe adjacent metadata projection respects Space order without activating or making surfaces")
@MainActor
func spaceSwipeReadOnlyProjection() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let first = try await store.createSpace(name: "First", profileID: profile)
    let second = try await store.createSpace(name: "Second", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: first)
    let context = try await store.captureContext(in: window)
    _ = try await store.openTab(url: URL(string: "https://synthetic.invalid/first")!, from: context, activate: true)
    try await store.activateSpace(second, in: window)
    let secondContext = try await store.captureContext(in: window)
    _ = try await store.openTab(url: URL(string: "https://synthetic.invalid/second")!, from: secondContext, activate: true)
    try await store.activateSpace(first, in: window)
    let before = await store.sessionDocument()
    let content = SpaceSwipePreview.content(document: before, spaceID: second)
    #expect(content.entries.count == 1)
    #expect(content.tabs.allSatisfy { !$0.selected && $0.occurrenceID == nil })
    #expect(await store.sessionDocument() == before)
    #expect(SpaceSwipePreview.content(document: before, spaceID: SpaceID()).entries.isEmpty)
}
}


@Test("Space swipe retake presentation does not fabricate axis intent from a zero Began")
func spaceSwipeRetakeAxisIntent() {
    var retake = SpaceSwipeGesture(displacement: 180, velocity: -200)
    #expect(retake.intent == .pending)
    #expect(retake.destination(width: 240, hasPrevious: true, hasNext: true, at: 1) == nil)
    retake.update(x: 0, y: 30, time: 1)
    #expect(retake.intent == .vertical)
    #expect(retake.destination(width: 240, hasPrevious: true, hasNext: true, at: 1) == nil)
}
