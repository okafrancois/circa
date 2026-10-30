import AppKit
import BrowserShell

/// Passive title help shared by ordinary and pinned rows in the active window.
@MainActor
final class SidebarTabHoverCard {
    static let shared = SidebarTabHoverCard()
    static let appearanceDelay: TimeInterval = 1.5
    static let departureDuration: TimeInterval = 0.1
    private(set) weak var row: SidebarTabRow?
    private weak var warmWindow: NSWindow?
    private let view = SidebarTabHoverCardView()
    private var timer: (any OrbitCancellable)?
    private var epoch: UInt64 = 0
    private var monitor: Any?
    private var observations: [NSObjectProtocol] = []
    private var anchor = NSRect.zero
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> any OrbitCancellable = {
        OrbitRunLoopTimer(after: $0, $1)
    }
    var isPresented: Bool { view.superview != nil }

    func hover(_ row: SidebarTabRow, inside: Bool) {
        if !inside {
            if self.row === row { dismiss(animated: true) }
            return
        }
        guard row.node.tabID != nil, row.commandsEnabled, !row.isRenaming, row.window?.isKeyWindow == true else { return }
        let warm = warmWindow === row.window
        dismiss()
        self.row = row
        anchor = row.convert(row.bounds, to: nil)
        let token = epoch
        installMonitor(in: row.window!)
        if warm { present() }
        else {
            timer = schedule(Self.appearanceDelay) { [weak self] in
                guard let self, self.epoch == token else { return }
                present()
            }
        }
    }

    func invalidate(_ row: SidebarTabRow) {
        if self.row === row { dismiss() }
    }

    func refresh(_ row: SidebarTabRow) {
        guard self.row === row else { return }
        if !row.commandsEnabled || row.isRenaming || row.convert(row.bounds, to: nil) != anchor { dismiss(); return }
        if isPresented { position(row) }
    }

    private func present() {
        guard let row, row.isHovering, row.commandsEnabled, !row.isRenaming,
              let window = row.window, window.isKeyWindow, window.attachedSheet == nil,
              !row.isHiddenOrHasHiddenAncestor, row.convert(row.bounds, to: nil) == anchor,
              let host = window.contentView else { dismiss(); return }
        timer = nil
        view.layer?.removeAllAnimations()
        view.alphaValue = 1
        position(row)
        host.addSubview(view, positioned: .above, relativeTo: nil)
        warmWindow = window
    }

    private func position(_ row: SidebarTabRow) {
        guard let window = row.window, let host = window.contentView else { return }
        let pointer = host.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let size = view.configure(title: row.item.title, maximumWidth: max(0, host.bounds.width - 16))
        let x = max(8, min(pointer.x + 12, host.bounds.width - size.width - 8))
        let top = host.isFlipped ? pointer.y + 5 : pointer.y - 5 - size.height
        view.frame = NSRect(x: x, y: max(8, min(top, host.bounds.height - size.height - 8)), width: size.width, height: size.height)
    }

    func dismiss(animated: Bool = false) {
        epoch &+= 1
        timer?.cancel(); timer = nil
        row = nil
        // Keep the window's warm handoff alive across a passive pointer departure. Any
        // click, keyboard input, scrolling or window lifecycle change retires it.
        if !animated { removeMonitor() }
        guard animated, isPresented, !OrbitMotionPreferences.prefersReducedMotion else {
            view.removeFromSuperview(); return
        }
        let token = epoch
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.departureDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.epoch == token else { return }
                self.view.removeFromSuperview()
            }
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
        observations = []
    }

    private func installMonitor(in window: NSWindow) {
        removeMonitor()
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willBeginSheetNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.warmWindow = nil; self.dismiss()
                }
            })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .keyDown, .scrollWheel]) { [weak self] event in
            self?.warmWindow = nil
            self?.dismiss()
            return event
        }
    }
}

@MainActor
final class SidebarTabHoverCardView: NSView {
    let title = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: uiText("Double-click to rename"))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        OrbitFloatingMaterial.install(in: self, radius: 14)
        title.font = BrandTextStyle.ui.font(size: 12)
        title.textColor = OrbitFloatingMaterial.body
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        hint.font = BrandTextStyle.ui.font(size: 11)
        hint.textColor = OrbitFloatingMaterial.secondary
        for label in [title, hint] { addSubview(label) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(title: String, maximumWidth: CGFloat) -> NSSize {
        self.title.stringValue = title
        let width = min(maximumWidth, ceil(max(
            (title as NSString).size(withAttributes: [.font: self.title.font!]).width,
            (hint.stringValue as NSString).size(withAttributes: [.font: hint.font!]).width)) + 20)
        self.title.frame = NSRect(x: 10, y: 6, width: max(0, width - 20), height: 15)
        hint.frame = NSRect(x: 10, y: 21, width: max(0, width - 20), height: 15)
        return NSSize(width: width, height: 44)
    }
}
