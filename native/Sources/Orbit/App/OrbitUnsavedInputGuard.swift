import AppKit
import BrowserEngine
import ObjectiveC.runtime

/// A conservative, content-free mark belonging to the live document, including while it moves
/// between owners. Typing need not actually change a form to veto an unattended relaunch.
@MainActor
final class OrbitUnsavedInputGuard: NSObject {
    private static var associationKey: UInt8 = 0
    private static var observedMethods: Set<String> = []
    private var dirty = false
    private var observationFailed = false

    static func register(_ surface: any BrowserEngineSurface) {
        if state(on: surface.documentView) == nil {
            objc_setAssociatedObject(surface.documentView, &associationKey, OrbitUnsavedInputGuard(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        prepare(surface.documentView.window?.firstResponder)
    }

    static func observedBeforeUnload(_ surface: any BrowserEngineSurface) {
        // A dialog proves this document registered a handler. Keep the veto after Stay;
        // the bridge has no notification for handler registration/removal.
        register(surface)
        state(on: surface.documentView)?.dirty = true
    }

    static func paste(into surface: any BrowserEngineSurface) {
        guard let responder = surface.documentView.window?.firstResponder as? NSView,
              responder.isDescendant(of: surface.documentView) else { return }
        prepare(responder)
        state(for: responder)?.dirty = true
    }

    static func clear(_ surface: any BrowserEngineSurface) { state(on: surface.documentView)?.dirty = false }

    static func preventsInstallation(_ surfaces: [any BrowserEngineSurface]) -> Bool {
        surfaces.contains { surface in
            if surface.isDisposed || surface.isSuspended {
                clear(surface)
                return false
            }
            guard let state = state(on: surface.documentView) else { return true }
            return state.dirty || state.observationFailed
        }
    }

    private static func state(on view: NSView) -> OrbitUnsavedInputGuard? {
        objc_getAssociatedObject(view, &associationKey) as? OrbitUnsavedInputGuard
    }

    private static func state(for responder: NSResponder?) -> OrbitUnsavedInputGuard? {
        // AppKit field editors belong to shell controls, including tab-modal page dialogs.
        guard let view = responder as? NSView, !(view is NSText), view.window?.firstResponder === view else { return nil }
        var ancestor: NSView? = view
        while let current = ancestor {
            if let state = state(on: current) { return state }
            ancestor = current.superview
        }
        return nil
    }

    static func keyDown(in window: NSWindow, event: NSEvent) {
        guard event.type == .keyDown else { return }
        prepare(window.firstResponder)
        state(for: window.firstResponder)?.dirty = true
    }

    /// IME candidate commits and menu Paste can arrive without a key event. Observe the actual
    /// responder's public AppKit entry points and forward their arguments unchanged. The hook
    /// is installed once per class/selector; only a registered, focused web descendant is marked.
    /// No text, key value, or pasteboard contents are read or retained.
    static func prepare(_ responder: NSResponder?) {
        guard let state = state(for: responder), let responder, let cls = object_getClass(responder) else { return }
        let insert = NSSelectorFromString("insertText:replacementRange:")
        if responder.responds(to: insert) {
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject, NSRange) -> Void
            observe(cls, selector: insert, state: state) { original in
                let call = unsafeBitCast(original, to: Original.self)
                let block: @convention(block) (AnyObject, AnyObject, NSRange) -> Void = { target, text, range in
                    MainActor.assumeIsolated { Self.state(for: target as? NSResponder)?.dirty = true }
                    call(target, insert, text, range)
                }
                return imp_implementationWithBlock(block)
            }
        }
        for name in ["paste:", "pasteAsPlainText:", "pasteAndMatchStyle:"] {
            let selector = NSSelectorFromString(name)
            guard responder.responds(to: selector) else { continue }
            typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            observe(cls, selector: selector, state: state) { original in
                let call = unsafeBitCast(original, to: Original.self)
                let block: @convention(block) (AnyObject, AnyObject?) -> Void = { target, sender in
                    MainActor.assumeIsolated { Self.state(for: target as? NSResponder)?.dirty = true }
                    call(target, selector, sender)
                }
                return imp_implementationWithBlock(block)
            }
        }
    }

    private static func observe(_ cls: AnyClass, selector: Selector, state: OrbitUnsavedInputGuard,
                                replacement: (IMP) -> IMP) {
        let key = NSStringFromClass(cls) + "." + NSStringFromSelector(selector)
        guard !observedMethods.contains(key) else { return }
        guard let method = class_getInstanceMethod(cls, selector), let encoding = method_getTypeEncoding(method) else {
            state.observationFailed = true
            return
        }
        let implementation = replacement(method_getImplementation(method))
        // Add an override for inherited methods instead of changing the superclass's behavior.
        if !class_addMethod(cls, selector, implementation, encoding) {
            method_setImplementation(method, implementation)
        }
        observedMethods.insert(key)
    }
}

final class OrbitBrowserWindow: NSWindow {
    weak var sidebarAddress: OrbitLocationField?
    private weak var middleClickTarget: NSView?
    private weak var hoverPopover: SidebarHoverPopover?
    private var ownsPointerHover = false
    private var restoreCursorRects = false
    private(set) var isRestoringPopoverHover = false
    private var swallowedPopoverPresses: Set<Int> = []
    private var dispatchingPointerLocation: NSPoint?

    func presentHoverPopover(_ popover: SidebarHoverPopover) {
        let previous = hoverPopover
        hoverPopover = popover
        if previous !== popover { previous?.displace() }
        reconcilePopoverHover(at: dispatchingPointerLocation ?? mouseLocationOutsideOfEventStream)
    }

    func retireHoverPopover(_ popover: SidebarHoverPopover) {
        guard hoverPopover === popover else { return }
        hoverPopover = nil
        reconcilePopoverHover(at: dispatchingPointerLocation ?? mouseLocationOutsideOfEventStream)
    }

    func ownsPopoverHover(at point: NSPoint) -> Bool {
        guard let hoverPopover else { return false }
        return hoverPopover.destination(at: point, in: self) != .outside
    }

    func permitsHover(for view: NSView, at point: NSPoint) -> Bool {
        !ownsPopoverHover(at: point) || isInHoverPopover(view)
    }

    func hoverPopoverHit(at point: NSPoint) -> NSView? {
        guard let hoverPopover, let panel = hoverPopover.popover else { return nil }
        switch hoverPopover.destination(at: point, in: self) {
        case .panel: return panel.hitTest(panel.superview?.convert(point, from: nil) ?? point) ?? panel
        case .corridor: return panel
        case .trigger, .outside: return nil
        }
    }

    private func isInHoverPopover(_ view: NSView) -> Bool {
        guard let panel = hoverPopover?.popover else { return false }
        return view === panel || view.isDescendant(of: panel)
    }

    private func reconcilePopoverHover(at point: NSPoint) {
        let owned = ownsPopoverHover(at: point)
        // Background cursor rects stay disabled while the frontmost popover supplies its cursor.
        let cursor = hoverPopover?.popover?.pointerReceiver?(hoverPopoverHit(at: point))
        guard ownsPointerHover != owned else {
            if owned { cursor?.set() }
            return
        }
        ownsPointerHover = owned
        if owned {
            restoreCursorRects = areCursorRectsEnabled
            if restoreCursorRects { disableCursorRects() }
            (cursor ?? .arrow).set()
        } else {
            NSCursor.arrow.set()
            if restoreCursorRects { enableCursorRects() }
            restoreCursorRects = false
        }
        guard isKeyWindow, NSApp.isActive, let contentView else { return }

        // Tracking areas are geometric and can stay entered even when another view covers them.
        // Balance their state at the stationary pointer as the hit target changes.
        let now = ProcessInfo.processInfo.systemUptime
        let crossing = NSEvent.enterExitEvent(with: owned ? .mouseExited : .mouseEntered,
            location: point, modifierFlags: [], timestamp: now, windowNumber: windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        let movement = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: now, windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        isRestoringPopoverHover = !owned
        defer { isRestoringPopoverHover = false }
        func reconcile(_ view: NSView) {
            guard let rect = SidebarHoverPopover.visibleRect(of: view, in: self), rect.contains(point),
                  !isInHoverPopover(view) else { return }
            let local = view.convert(point, from: nil)
            for area in view.trackingAreas where area.options.contains(.inVisibleRect) || area.rect.contains(local) {
                let owner = area.owner as? NSView
                // A hosted page can use a tracking-area proxy. The view itself still
                // processes mouse movement, including Chromium's hit-test-based DOM leave.
                if owned, area.options.contains(.mouseMoved), let movement {
                    (owner ?? view).mouseMoved(with: movement)
                }
                if let owner, let crossing, area.options.contains(.mouseEnteredAndExited) {
                    if owned { owner.mouseExited(with: crossing) }
                    else { owner.mouseEntered(with: crossing) }
                }
                if !owned, area.options.contains(.mouseMoved), let movement {
                    (owner ?? view).mouseMoved(with: movement)
                }
            }
            for child in view.subviews { reconcile(child) }
        }
        reconcile(contentView)
    }

    func routePopoverScroll(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard let hoverPopover else { return false }
        let destination = hoverPopover.destination(at: point, in: self)
        guard destination != .outside else { return false }
        if destination == .panel {
            hoverPopover.popover?.scrollReceiver?.scrollWheel(with: event)
            reconcilePopoverHover(at: point)
        }
        return true
    }

    private func routePopoverEvent(_ event: NSEvent) -> Bool {
        guard event.window === self else { return false }
        guard hoverPopover != nil || !swallowedPopoverPresses.isEmpty else { return false }
        let point = event.locationInWindow
        let destination = hoverPopover?.destination(at: point, in: self) ?? .outside
        switch event.type {
        case .mouseMoved:
            reconcilePopoverHover(at: point)
        case .mouseEntered, .cursorUpdate:
            if destination != .outside, let view = event.trackingArea?.owner as? NSView,
               !isInHoverPopover(view) { return true }
        case .scrollWheel:
            return routePopoverScroll(event, at: point)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            swallowedPopoverPresses.remove(event.buttonNumber)
            if destination == .corridor || (destination == .panel && event.type != .leftMouseDown) {
                swallowedPopoverPresses.insert(event.buttonNumber)
                return true
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if swallowedPopoverPresses.remove(event.buttonNumber) != nil { return true }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if swallowedPopoverPresses.contains(event.buttonNumber) { return true }
        default: break
        }
        return false
    }

    /// Browser windows never hand their state or contents to macOS window restoration: Circa
    /// restores its own sessions. A private window also stays out of screenshots and screen
    /// recordings made by other applications, and so do the panels it presents.
    func applyContentPrivacy(isPrivate: Bool) {
        isRestorable = false
        sharingType = isPrivate ? .none : .readOnly
    }

    override func addChildWindow(_ childWindow: NSWindow, ordered place: NSWindow.OrderingMode) {
        if sharingType == .none { childWindow.sharingType = .none }
        super.addChildWindow(childWindow, ordered: place)
    }

    private static let popoverPointerEvents: Set<NSEvent.EventType> = [
        .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate, .scrollWheel,
        .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
    ]

    override func sendEvent(_ event: NSEvent) {
        let previousPointerLocation = dispatchingPointerLocation
        if Self.popoverPointerEvents.contains(event.type), event.window === self {
            dispatchingPointerLocation = event.locationInWindow
        }
        defer { dispatchingPointerLocation = previousPointerLocation }
        if routePopoverEvent(event) { return }
        // Route the resting text before AppKit makes its inline editor first responder.
        if event.type == .leftMouseDown, !event.modifierFlags.contains(.control), event.window === self,
           let field = sidebarAddress, let press = field.onAddressPress,
           field.textCursorRect.contains(field.convert(event.locationInWindow, from: nil)),
           let root = contentView, let hit = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
           hit === field || hit === field.currentEditor() {
            press()
            return
        }
        OrbitUnsavedInputGuard.keyDown(in: self, event: event)
        // AppKit routes auxiliary buttons to the first responder. Sidebar middle clicks
        // instead belong to the row under the press, through its matching release.
        if [.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(event.type),
           event.buttonNumber == 2, event.window === self {
            switch event.type {
            case .otherMouseDown:
                middleClickTarget = nil
                if let root = contentView {
                    var hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
                    while let view = hit {
                        if let row = view as? SidebarListRow {
                            middleClickTarget = row
                            row.otherMouseDown(with: event)
                            return
                        }
                        if view is BrowserSidebarView {
                            middleClickTarget = view
                            return
                        }
                        hit = view.superview
                    }
                }
            case .otherMouseUp:
                if let target = middleClickTarget {
                    middleClickTarget = nil
                    (target as? SidebarListRow)?.otherMouseUp(with: event)
                    return
                }
            case .otherMouseDragged:
                if let target = middleClickTarget {
                    (target as? SidebarListRow)?.otherMouseDragged(with: event)
                    return
                }
            default: break
            }
        }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { OrbitUnsavedInputGuard.prepare(firstResponder) }
        return accepted
    }
}
