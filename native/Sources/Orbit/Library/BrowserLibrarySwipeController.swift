import AppKit
import BrowserCore

/// The Library boundary is deliberately independent of ordinary Space publication and CEF.
@MainActor
final class BrowserLibrarySwipeController {
    var canOpen: () -> Bool = { false }
    var canInteract: () -> Bool = { false }
    var captureAuthority: () -> (() -> Bool) = { { true } }
    var beginOpening: (() -> Void)?
    var finish: ((Bool, Double) -> Void)?
    private weak var view: BrowserLibraryView?
    private weak var drawer: BrowserLibraryDrawer?
    private weak var sidebar: BrowserSidebarView?
    private weak var sourceWindow: NSWindow?
    private var sourceSize = NSSize.zero
    private var authorityIsCurrent: () -> Bool = { true }
    private var gesture: LibrarySwipeGesture?
    private(set) var ownsGesture = false
    private var swallowMomentum = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    let scrollInput = SidebarScrollInputRouter()

    func install(view: BrowserLibraryView, drawer: BrowserLibraryDrawer, sidebar: BrowserSidebarView) {
        self.view = view; self.drawer = drawer; self.sidebar = sidebar
        sidebar.spaceSwipe.handleLibraryBoundary = { [weak self] event, inside in
            self?.handleOpening(event, inside: inside) ?? false
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.route(event) == nil
            }
            return consumed ? nil : event
        }
    }

    func detach() {
        cancel(restoringPresentation: false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        sidebar?.spaceSwipe.handleLibraryBoundary = nil
    }

    private var environmentIsCurrent: Bool {
        guard let view, let sourceWindow, view.window === sourceWindow,
              sourceWindow.contentView?.bounds.size == sourceSize,
              sourceWindow.isKeyWindow, sourceWindow.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        return canInteract() && authorityIsCurrent()
    }

    func handleOpening(_ event: NSEvent, inside: Bool) -> Bool {
        guard event.hasPreciseScrollingDeltas, let drawer else { return false }
        if ownsGesture { return handle(event) }
        if !event.momentumPhase.isEmpty {
            let consumed = swallowMomentum
            if event.momentumPhase.contains(.ended) { swallowMomentum = false }
            return consumed
        }
        if event.phase.contains(.began) {
            gesture = nil
            swallowMomentum = false
            guard inside, canOpen(), let window = view?.window else { return false }
            capture(window)
            gesture = LibrarySwipeGesture(presented: false, visibleWidth: Double(drawer.width) * drawer.animation.value,
                                          width: Double(drawer.width))
        }
        guard gesture != nil else { return false }
        return handle(event)
    }

    private func capture(_ window: NSWindow) {
        if sourceWindow !== window {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSWindow.didResizeNotification, NSWindow.willBeginSheetNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancel() }
                })
            }
        }
        sourceWindow = window
        sourceSize = window.contentView?.bounds.size ?? .zero
        authorityIsCurrent = captureAuthority()
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        guard event.window === view?.window else { return event }
        if event.type != .scrollWheel {
            if gesture != nil { cancel() }
            return event
        }
        if ownsGesture { return handle(event) ? nil : event }
        guard let view, let drawer else { return event }
        switch scrollInput.replay(event) {
        case .deliver: return event
        case .discard: return nil
        case .recognize, .unrelated: break
        }
        if !event.momentumPhase.isEmpty, swallowMomentum {
            if event.momentumPhase.contains(.ended) { swallowMomentum = false }
            return nil
        }
        guard event.hasPreciseScrollingDeltas, drawer.isPresented else { return event }
        let inside = !view.isHidden && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        guard inside || scrollInput.hasOwnedSequence else { return event }
        let consumed = scrollInput.route(event, inside: inside, captureOwner: { [weak self] in
            guard let self, canInteract(), let window = view.window, window.isKeyWindow,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return nil }
            capture(window)
            return { [weak self] in self?.environmentIsCurrent == true }
        }, recognize: { [weak self] in
            guard let self else { return .inactive }
            if event.phase.contains(.began) {
                gesture = LibrarySwipeGesture(presented: true, visibleWidth: Double(drawer.width) * drawer.animation.value,
                                              width: Double(drawer.width))
            }
            if handle(event) { return .horizontal }
            return gesture?.gesture.intent == .pending ? .pending : .inactive
        }, cancelRecognition: { [weak self] in self?.cancel() })
        return consumed ? nil : event
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard var gesture, let drawer else { return false }
        guard environmentIsCurrent else { let consumed = ownsGesture; cancel(); return consumed }
        if !event.momentumPhase.isEmpty {
            if event.momentumPhase.contains(.ended) { swallowMomentum = false }
            return swallowMomentum
        }
        gesture.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY, time: event.timestamp,
                       began: event.phase.contains(.began))
        self.gesture = gesture
        if gesture.gesture.intent == .vertical || (gesture.gesture.intent == .horizontal && !gesture.takesBoundary && gesture.gesture.displacement < 0) {
            self.gesture = nil
            return false
        }
        if gesture.takesBoundary {
            if !ownsGesture {
                ownsGesture = true
                swallowMomentum = true
                sidebar?.spaceSwipe.cancel(preserveScrollInput: true)
                if !gesture.startsPresented { beginOpening?() }
            }
            drawer.track(visibleWidth: CGFloat(gesture.visibleWidth))
        }
        let consumed = ownsGesture
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            self.gesture = nil
            ownsGesture = false
            if consumed {
                let cancelled = event.phase.contains(.cancelled)
                let destination = gesture.destination(at: event.timestamp, cancelled: cancelled)
                finish?(destination, cancelled ? 0 : gesture.gesture.releaseVelocity(at: event.timestamp) / gesture.width)
            }
        }
        return consumed
    }

    func cancel(restoringPresentation: Bool = true) {
        let previous = gesture
        gesture = nil
        let owned = ownsGesture
        ownsGesture = false
        if restoringPresentation, owned, let previous { finish?(previous.startsPresented, 0) }
        sourceWindow = nil
        scrollInput.invalidate()
    }
}
