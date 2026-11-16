import AppKit
import CoreVideo

/// Keeps a Core Video display link on the display that shows a window, so a window on a
/// secondary monitor animates at that monitor's refresh rate rather than the main display's.
/// It follows the window across displays through `NSWindow.didChangeScreenNotification`.
/// `CADisplayLink`s created from an `NSView` or `NSWindow` already follow their display.
@MainActor
final class OrbitDisplayLinkScreen {
    /// Display identifier of a window's current screen; nil when it has none.
    var displayOfWindow: @MainActor (NSWindow) -> CGDirectDisplayID? = { window in
        window.screen.flatMap { OrbitDisplayLinkScreen.displayID($0) }
    }
    /// Points a link at a display; injected by tests.
    var setDisplay: (CVDisplayLink, CGDirectDisplayID) -> Bool = { link, display in
        CVDisplayLinkSetCurrentCGDisplay(link, display) == kCVReturnSuccess
    }
    private(set) var display: CGDirectDisplayID?
    private(set) var rebinds = 0
    private var link: CVDisplayLink?
    private weak var window: NSWindow?
    // Registered on MainActor; NotificationCenter removal is thread-safe in deinit.
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// A link that can run on any active display; `bind(_:to:)` chooses the display.
    static func makeLink() -> CVDisplayLink? {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess else { return nil }
        return link
    }

    /// Binds `link` to `window`'s display now and whenever the window changes screen.
    func bind(_ link: CVDisplayLink, to window: NSWindow?) {
        self.link = link
        if window !== self.window || observer == nil {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            self.window = window
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.follow() }
                }
            }
        }
        display = nil
        follow()
    }

    func unbind() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        link = nil
        window = nil
        display = nil
    }

    /// Re-reads the window's display and moves the link there when it changed.
    func follow() {
        guard let link else { return }
        let target = window.flatMap(displayOfWindow) ?? CGMainDisplayID()
        guard target != display else { return }
        if setDisplay(link, target) {
            if display != nil { rebinds += 1 }
            display = target
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
