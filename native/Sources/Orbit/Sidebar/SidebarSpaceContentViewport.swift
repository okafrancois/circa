import AppKit

/// Full Space body below the URL field and above navigation in the footer. Preview instances
/// stay inside this native clip; wheel delivery over Favorites reaches the current native list.
@MainActor
final class SidebarSpaceContentViewport: SidebarFlippedView {
    weak var scrollReceiver: NSScrollView?
    private var isForwardingWheel = false

    override func scrollWheel(with event: NSEvent) {
        guard !isForwardingWheel, let scrollReceiver,
              !scrollReceiver.convert(scrollReceiver.bounds, to: nil).contains(event.locationInWindow) else {
            super.scrollWheel(with: event)
            return
        }
        guard scrollReceiver.window === window,
              event.window == nil || event.window === window,
              event.windowNumber == 0 || event.windowNumber == window?.windowNumber else {
            super.scrollWheel(with: event)
            return
        }
        isForwardingWheel = true
        defer { isForwardingWheel = false }
        // Keep native scrolling, including original phase/momentum, without supplying a point
        // in another native view's region. Unrepresentable events retain legacy delivery rather than discarding input.
        let transferred = SidebarWheelTransfer.event(event, into: scrollReceiver) ?? event
        scrollReceiver.scrollWheel(with: transferred)
    }
}
