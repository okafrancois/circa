import AppKit

/// Native anchored presentation shared by the Space icon entry points.
@MainActor
final class SpacePickerPopover: NSObject, NSPopoverDelegate {
    let popover = OrbitFrostPopover()
    weak var contentViewController: NSViewController?
    var onClose: (() -> Void)?
    var window: NSWindow? { popover.isShown ? popover.contentViewController?.view.window : nil }
    private weak var source: NSWindow?
    private var observers: [NSObjectProtocol] = []

    init(usesFrost: Bool = true) {
        super.init()
        popover.usesFrost = usesFrost
        popover.behavior = .transient
        popover.delegate = self
    }

    func show(relativeTo anchor: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        guard !popover.isShown, let source = view.window, source.isVisible else { return }
        self.source = source
        popover.animates = true
        popover.contentViewController = contentViewController
        popover.appearance = view.effectiveAppearance
        popover.show(relativeTo: anchor, of: view, preferredEdge: preferredEdge)
        for name in [NSWindow.willCloseNotification, NSWindow.willEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didResizeNotification,
                     NSWindow.willBeginSheetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: source, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.performClose(nil) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.performClose(nil) }
        })
    }

    func performClose(_ sender: Any?) {
        popover.animates = false
        popover.performClose(sender)
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        popover.animates = false
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        popover.contentViewController = nil
        if source?.isVisible == true { source?.makeKey() }
        onClose?()
    }
}
