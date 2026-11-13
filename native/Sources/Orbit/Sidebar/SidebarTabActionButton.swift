import AppKit
import BrowserShell

/// The pinned-row action owns its passive help so row-title help cannot compete with it.
@MainActor
final class SidebarTabActionButton: OrbitGlyphButton {
    static let appearanceDelay: TimeInterval = 0.75
    static let appearanceDuration: TimeInterval = 0
    static let departureDuration: TimeInterval = 0.3
    private(set) var pinned = false
    private(set) var tabAction = SidebarTabTrailingAction.closePage
    private let pill = SidebarTabActionPill()
    private var timer: (any OrbitCancellable)?
    private var epoch: UInt64 = 0
    private var isDismissing = false
    private var monitor: Any?
    private var observations: [NSObjectProtocol] = []
    private var anchor = NSRect.zero
    private var entryPoint = NSPoint.zero
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> any OrbitCancellable = {
        OrbitRunLoopTimer(after: $0, $1)
    }
    var isPillPresented: Bool { pill.superview != nil }

    func configure(pinned: Bool, action: SidebarTabTrailingAction) {
        guard self.pinned != pinned || tabAction != action else { return }
        dismissPill()
        self.pinned = pinned
        tabAction = action
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard pinned else { super.draw(dirtyRect); return }
        // Both marks have round terminals and remain centred in the 24 pt target.
        customDrawing = { [weak self] button, rect in
            guard let self else { return }
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            let center = NSPoint(x: rect.midX, y: rect.midY)
            if tabAction == .closePage {
                path.move(to: NSPoint(x: center.x - 6, y: center.y))
                path.line(to: NSPoint(x: center.x + 6, y: center.y))
            } else {
                for direction: CGFloat in [-1, 1] {
                    path.move(to: NSPoint(x: center.x - 4.4, y: center.y - 4.4 * direction))
                    path.line(to: NSPoint(x: center.x + 4.4, y: center.y + 4.4 * direction))
                }
            }
            (button.isEnabled ? button.tint : button.disabledTint).setStroke()
            path.stroke()
        }
        super.draw(dirtyRect)
        customDrawing = nil
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard pinned, isEnabled, let row = superview as? SidebarTabRow,
              row.commandsEnabled, !row.isRenaming, let window, window.isKeyWindow else { return }
        SidebarTabHoverCard.shared.invalidate(row)
        dismissPill()
        anchor = convert(bounds, to: nil)
        entryPoint = event.locationInWindow
        let token = epoch
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .keyDown, .scrollWheel]) { [weak self] event in
            self?.dismissPill()
            return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willBeginSheetNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissPill() }
            })
        }
        timer = schedule(Self.appearanceDelay) { [weak self] in
            guard let self, epoch == token, isHovering, isEnabled,
                  let row = superview as? SidebarTabRow, row.isHovering, !row.isRenaming,
                  row.commandsEnabled, let window = self.window, window.isKeyWindow, window.attachedSheet == nil,
                  !isHiddenOrHasHiddenAncestor, convert(bounds, to: nil) == anchor,
                  let host = window.contentView else { return }
            timer = nil
            let size = pill.configure(action: tabAction)
            let screenPointer = NSEvent.mouseLocation
            let point = window.frame.contains(screenPointer) ? window.convertPoint(fromScreen: screenPointer) : entryPoint
            let pointer = host.convert(point, from: nil)
            let x = max(8, min(pointer.x + 6, host.bounds.width - size.width - 8))
            let y = host.isFlipped ? pointer.y + 8 : pointer.y - 8 - size.height
            pill.frame = NSRect(x: x, y: max(8, min(y, host.bounds.height - size.height - 8)), width: size.width, height: size.height)
            pill.layer?.removeAllAnimations()
            pill.alphaValue = 1
            host.addSubview(pill, positioned: .above, relativeTo: nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        dismissPill(animated: true)
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { dismissPill() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissPill() }
    }

    override func viewDidHide() { super.viewDidHide(); dismissPill() }

    func refreshPill() {
        guard timer != nil || isPillPresented else { return }
        guard let row = superview as? SidebarTabRow, row.commandsEnabled, !row.isRenaming,
              convert(bounds, to: nil) == anchor else { dismissPill(); return }
    }

    func dismissPill(animated: Bool = false) {
        if animated && isDismissing { return }
        isDismissing = animated && isPillPresented
        epoch &+= 1
        timer?.cancel(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observation in observations { NotificationCenter.default.removeObserver(observation) }
        observations.removeAll()
        guard animated, isPillPresented, !OrbitMotionPreferences.prefersReducedMotion else {
            isDismissing = false
            pill.removeFromSuperview(); return
        }
        let token = epoch
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.departureDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pill.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.epoch == token else { return }
                self.isDismissing = false
                self.pill.removeFromSuperview()
            }
        }
    }
}

@MainActor
final class SidebarTabActionPill: NSView {
    let label = NSTextField(labelWithString: "")
    private let command = NSTextField(labelWithString: uiText("⌘"))
    private let key = NSTextField(labelWithString: uiText("W"))
    static let height: CGFloat = 28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 28/255, green: 22/255, blue: 28/255, alpha: 1).cgColor
        layer?.cornerRadius = Self.height / 2
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor(srgbRed: 226/255, green: 220/255, blue: 226/255, alpha: 1)
        for field in [command, key] {
            field.font = .systemFont(ofSize: 12, weight: .semibold)
            field.alignment = .center
            field.textColor = NSColor(srgbRed: 86/255, green: 76/255, blue: 89/255, alpha: 1)
            field.wantsLayer = true
            field.layer?.backgroundColor = NSColor(srgbRed: 219/255, green: 209/255, blue: 222/255, alpha: 1).cgColor
            field.layer?.cornerRadius = 3
        }
        for field in [label, command, key] { field.setAccessibilityElement(false); addSubview(field) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(action: SidebarTabTrailingAction) -> NSSize {
        label.stringValue = action.pillText
        let width = ceil(label.intrinsicContentSize.width)
        label.frame = NSRect(x: 10, y: 6, width: width, height: 16)
        command.isHidden = action != .closePage
        key.isHidden = command.isHidden
        command.frame = NSRect(x: width + 17, y: 5, width: 18, height: 18)
        key.frame = command.frame.offsetBy(dx: 22, dy: 0)
        return NSSize(width: width + (action == .closePage ? 67 : 20), height: Self.height)
    }
}
