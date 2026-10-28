import AppKit

/// Local native dispatch only: keep wheel semantics, map a Favorites point into the list.
/// The source event and application queue are untouched. No event-source replacement or posting.
@MainActor
enum SidebarWheelTransfer {
    static func event(_ original: NSEvent, into receiver: NSScrollView) -> NSEvent? {
        // Detached recording/responders keep the existing identity contract; no native window
        // coordinate space exists to transfer into until the view is attached.
        guard receiver.window != nil else { return original }
        guard original.type == .scrollWheel, let cg = original.cgEvent?.copy() else { return nil }
        let clip = receiver.contentView
        guard clip.bounds.width > 0, clip.bounds.height > 0 else { return nil }
        let target = clip.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY), to: nil)
        guard receiver.convert(receiver.bounds, to: nil).contains(target) else { return nil }
        let source = original.locationInWindow
        // Cocoa window coordinates increase upward; Quartz display coordinates increase downward.
        // Use a relative translation, so screen origins, Retina scale and window placement cancel.
        let location = cg.location
        cg.location = CGPoint(x: location.x + target.x - source.x, y: location.y - target.y + source.y)
        guard let transferred = NSEvent(cgEvent: cg),
              abs(transferred.locationInWindow.x - target.x) < 0.01,
              abs(transferred.locationInWindow.y - target.y) < 0.01,
              transferred.windowNumber == original.windowNumber,
              transferred.timestamp == original.timestamp, transferred.modifierFlags == original.modifierFlags,
              transferred.phase == original.phase, transferred.momentumPhase == original.momentumPhase,
              transferred.scrollingDeltaX == original.scrollingDeltaX, transferred.scrollingDeltaY == original.scrollingDeltaY,
              transferred.deltaX == original.deltaX, transferred.deltaY == original.deltaY, transferred.deltaZ == original.deltaZ,
              transferred.hasPreciseScrollingDeltas == original.hasPreciseScrollingDeltas,
              transferred.isDirectionInvertedFromDevice == original.isDirectionInvertedFromDevice,
              transferred.cgEvent?.getIntegerValueField(.eventSourceUserData) == original.cgEvent?.getIntegerValueField(.eventSourceUserData),
              transferred.cgEvent?.getIntegerValueField(.eventSourceStateID) == original.cgEvent?.getIntegerValueField(.eventSourceStateID)
        else { return nil }
        return transferred
    }
}
