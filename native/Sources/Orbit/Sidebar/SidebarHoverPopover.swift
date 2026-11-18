import AppKit

/// The convex hull of the two visible rectangles includes diagonal transfers without keeping
/// the unused corners of their bounding box open.
struct SidebarHoverRegion {
    let trigger: NSRect?
    let popover: NSRect

    enum Destination: Equatable {
        case panel, trigger, corridor, outside
    }

    func destination(at point: NSPoint) -> Destination {
        guard let trigger, !trigger.isEmpty else { return .outside }
        if popover.contains(point) { return .panel }
        if trigger.contains(point) { return .trigger }
        return contains(point) ? .corridor : .outside
    }

    func contains(_ point: NSPoint) -> Bool {
        guard let trigger, !trigger.isEmpty else { return false }
        if trigger.contains(point) || popover.contains(point) { return true }
        guard !popover.isEmpty, trigger.union(popover).contains(point) else { return false }

        let corners = [trigger, popover].flatMap { rect in
            [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.minX, y: rect.maxY),
             NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.maxY)]
        }.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        func cross(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        func halfHull(_ points: some Sequence<NSPoint>) -> [NSPoint] {
            var result: [NSPoint] = []
            for point in points {
                while result.count >= 2, cross(result[result.count - 2], result[result.count - 1], point) <= 0 {
                    result.removeLast()
                }
                result.append(point)
            }
            return result
        }
        let hull = halfHull(corners).dropLast() + halfHull(corners.reversed()).dropLast()
        return zip(hull, hull.dropFirst() + hull.prefix(1)).allSatisfy { cross($0, $1, point) >= 0 }
    }
}

/// Provides a hit target even over blank space and swallows unhandled pointer input.
@MainActor
class SidebarHoverPopoverSurface: NSView {
    var retiresPointerInput = false
    weak var scrollReceiver: NSScrollView?
    var pointerReceiver: ((NSView?) -> NSCursor?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !retiresPointerInput else { return nil }
        return super.hitTest(point)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// Tracks a presented preview in window coordinates, independently of AppKit's ordering of
/// enter/exit events on the individual views.
@MainActor
final class SidebarHoverPopover: NSResponder {
    private let closeDelay: TimeInterval
    private var departure: (any OrbitCancellable)?
    private weak var host: NSView?
    private(set) weak var popover: SidebarHoverPopoverSurface?
    private weak var sidebar: BrowserSidebarView?
    private var tracking: NSTrackingArea?
    private var monitor: Any?
    private var mouseMoves: OrbitMouseMoveTracking?
    private var triggerRect: (() -> NSRect?)?
    var onDismiss: ((Bool) -> Void)?
    var onResize: (() -> Void)?

    init(closeDelay: TimeInterval) {
        self.closeDelay = closeDelay
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    static func visibleRect(of view: NSView, in window: NSWindow) -> NSRect? {
        guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        // A non-clipping view can report a visibleRect extending past its own bounds.
        let rect = view.bounds.intersection(view.visibleRect)
        return rect.isEmpty ? nil : view.convert(rect, to: nil)
    }

    func start(trigger: NSView, popover: SidebarHoverPopoverSurface, rect: (() -> NSRect?)? = nil) {
        stop()
        guard let window = trigger.window, let host = window.contentView else { return }
        self.host = host
        self.popover = popover
        popover.retiresPointerInput = false
        var ancestor: NSView? = trigger
        while let view = ancestor {
            if let sidebar = view as? BrowserSidebarView { self.sidebar = sidebar; break }
            ancestor = view.superview
        }
        triggerRect = rect ?? { [weak trigger, weak window] in
            guard let trigger, let window else { return nil }
            return Self.visibleRect(of: trigger, in: window)
        }

        let tracking = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow,
            .mouseEnteredAndExited, .assumeInside], owner: self)
        host.addTrackingArea(tracking)
        self.tracking = tracking

        mouseMoves = OrbitMouseMoveTracking(in: window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(interrupt(_:)), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(interrupt(_:)), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(resize(_:)), name: NSWindow.didResizeNotification, object: window)
        (window as? OrbitBrowserWindow)?.presentHoverPopover(self)
    }

    func stop() {
        departure?.cancel(); departure = nil
        if let tracking { host?.removeTrackingArea(tracking) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        mouseMoves?.cancel(); mouseMoves = nil
        NotificationCenter.default.removeObserver(self)
        popover?.retiresPointerInput = true
        let window = host?.window as? OrbitBrowserWindow
        tracking = nil; monitor = nil; triggerRect = nil; host = nil; popover = nil; sidebar = nil
        window?.retireHoverPopover(self)
    }

    var containsPointer: Bool {
        guard let window = host?.window else { return false }
        return region(in: window)?.contains(window.convertPoint(fromScreen: NSEvent.mouseLocation)) == true
    }

    override func mouseEntered(with event: NSEvent) { update(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { update(at: event.locationInWindow) }

    func update() {
        guard let window = host?.window else { return }
        update(at: window.convertPoint(fromScreen: NSEvent.mouseLocation))
    }

    func destination(at point: NSPoint, in window: NSWindow) -> SidebarHoverRegion.Destination {
        region(in: window)?.destination(at: point) ?? .outside
    }

    func displace() { onDismiss?(false) }

    private func region(in window: NSWindow) -> SidebarHoverRegion? {
        guard sidebar?.isPresentationHidden != true, let trigger = triggerRect?(),
              let popover, let frame = Self.visibleRect(of: popover, in: window) else { return nil }
        return SidebarHoverRegion(trigger: trigger, popover: frame)
    }

    private func update(at point: NSPoint) {
        guard let window = host?.window else { return }
        guard let region = region(in: window) else { onDismiss?(false); return }
        if region.contains(point) {
            departure?.cancel(); departure = nil
        } else if departure == nil {
            departure = OrbitRunLoopTimer(after: closeDelay) { [weak self] in
                guard let self else { return }
                departure = nil
                if !containsPointer { onDismiss?(true) }
            }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = host?.window else { return event }
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if event.window === window { update(at: event.locationInWindow) }
            else { update() }
            return event
        case .keyDown:
            if event.window === window, event.keyCode == 53 { onDismiss?(false); return nil }
            return event
        default: break
        }
        let point = event.locationInWindow
        if event.window === window {
            switch destination(at: point, in: window) {
            case .panel, .corridor: return event
            case .trigger where event.type == .scrollWheel: return event
            default: break
            }
        }
        if event.type != .scrollWheel || (event.window === window
            && sidebar.flatMap { Self.visibleRect(of: $0, in: window) }?.contains(point) == true) {
            onDismiss?(false)
        }
        return event
    }

    @objc private func interrupt(_ notification: Notification) { onDismiss?(false) }
    @objc private func resize(_ notification: Notification) {
        host?.layoutSubtreeIfNeeded()
        onResize?()
        update()
    }
}

extension NSView {
    func permitsPopoverHover(_ event: NSEvent) -> Bool {
        (window as? OrbitBrowserWindow)?.permitsHover(for: self, at: event.locationInWindow) ?? true
    }
}
