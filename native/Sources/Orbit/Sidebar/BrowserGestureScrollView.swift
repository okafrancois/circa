import AppKit

/// Gesture arbitration must see every packet before native scrolling. AppKit's responsive
/// scrolling can otherwise consume subsequent wheels on its background scroll thread before
/// local event monitors or the window can route them to the view under the pointer.
/// Keep the native scroller and its physics, with event handling on the main thread.
final class BrowserGestureScrollView: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
}
