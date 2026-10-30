import AppKit

struct SidebarCreationAction {
    let command: BrowserCommandID
    let title: String
    let symbol: String
    let shortcut: String
    let enabled: Bool
    let perform: () -> Void
}

@MainActor
final class SidebarCreationMenu: NSViewController {
    let actions: [SidebarCreationAction]
    let accent: OrbitTokens.ThemeAccent
    let popover = SidebarCreationPopup()
    var onClose: (() -> Void)?
    private var rows: [CreationMenuRow] = []
    private var selection = -1
    private weak var previousResponder: NSResponder?
    private weak var sourceWindow: NSWindow?

    init(actions: [SidebarCreationAction], accent: OrbitTokens.ThemeAccent) {
        self.actions = actions
        self.accent = accent
        super.init(nibName: nil, bundle: nil)
        popover.contentViewController = self
        popover.surfaceColor = accent.menuSurface
        popover.onClose = { [weak self] in self?.didClose() }
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = CreationMenuContent()
        content.onKey = { [weak self] selector in self?.handle(selector) ?? false }
        let m = OrbitTokens.Metrics.Sidebar.self
        // New Space, Folder, then navigation/extension actions. Unimplemented Orbit items are omitted.
        let height = CGFloat(actions.count) * m.plusMenuItemPitch + 16 + m.plusMenuSeparatorExtraGap
        content.setAccessibilityRole(.menu)
        content.setAccessibilityLabel(OrbitShellText.create)
        content.frame = NSRect(x: 0, y: 0, width: m.plusMenuWidth, height: height)
        content.wantsLayer = true
        content.layer?.cornerRadius = OrbitTokens.Radius.plusMenu
        content.layer?.backgroundColor = accent.menuSurface.resolvedCGColor(for: content.effectiveAppearance)
        for (index, action) in actions.enumerated() {
            let row = CreationMenuRow(action: action, accent: accent)
            row.frame = NSRect(x: m.plusMenuHighlightInset,
                               y: 8 + CGFloat(index) * m.plusMenuItemPitch + (index >= 2 ? m.plusMenuSeparatorExtraGap : 0),
                               width: m.plusMenuWidth - 2 * m.plusMenuHighlightInset, height: m.plusMenuItemPitch)
            row.onPress = { [weak self] in self?.activate(index) }
            row.onHover = { [weak self] in self?.select(index) }
            rows.append(row)
            content.addSubview(row)
        }
        if actions.count > 2 {
            let line = NSView(frame: NSRect(x: 18, y: 8 + 2 * m.plusMenuItemPitch + 8,
                                           width: m.plusMenuWidth - 36, height: 1))
            line.wantsLayer = true
            line.layer?.backgroundColor = accent.soft.resolvedCGColor(for: content.effectiveAppearance)
            content.addSubview(line)
        }
        view = content
    }

    func show(relativeTo button: NSView) {
        previousResponder = button.window?.firstResponder
        sourceWindow = button.window
        let anchor = NSRect(x: button.bounds.midX, y: button.bounds.minY, width: 1, height: 1)
        popover.show(relativeTo: anchor, of: button, preferredEdge: .minY)
        select(actions.firstIndex(where: \.enabled) ?? -1)
        popover.window?.makeFirstResponder(view)
    }

    private func didClose() {
        if let sourceWindow, sourceWindow.isKeyWindow, let previousResponder {
            sourceWindow.makeFirstResponder(previousResponder)
        }
        onClose?()
    }
    private func select(_ index: Int) {
        guard actions.indices.contains(index), actions[index].enabled else { return }
        selection = index
        for (i, row) in rows.enumerated() { row.setSelected(i == index) }
    }
    @discardableResult
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): popover.performClose(nil)
        case #selector(NSResponder.insertNewline(_:)): activate(selection)
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            let delta = selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) ? -1 : 1
            guard !actions.isEmpty else { return true }
            for step in 1...actions.count {
                let next = ((selection + delta * step) % actions.count + actions.count) % actions.count
                if actions[next].enabled { select(next); break }
            }
        default: return false
        }
        return true
    }
    func activate(_ index: Int) {
        guard actions.indices.contains(index), actions[index].enabled else { return }
        popover.performClose(nil)
        actions[index].perform()
    }
}

@MainActor
final class CreationMenuContent: NSView {
    var onKey: ((Selector) -> Bool)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func doCommand(by selector: Selector) {
        if onKey?(selector) != true { super.doCommand(by: selector) }
    }
}

@MainActor
final class CreationMenuRow: NSView {
    let enabled: Bool
    let destructive: Bool
    let accent: OrbitTokens.ThemeAccent
    var onPress: (() -> Void)?
    var onHover: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    convenience init(action: SidebarCreationAction, accent: OrbitTokens.ThemeAccent) {
        self.init(title: action.title, symbol: action.symbol, shortcut: action.shortcut,
                  enabled: action.enabled, identifier: "creation-" + action.command.rawValue, accent: accent)
    }
    init(title text: String, symbol: String, shortcut keys: String = "", enabled: Bool,
         identifier: String, accent: OrbitTokens.ThemeAccent, destructive: Bool = false) {
        self.enabled = enabled
        self.destructive = destructive
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = OrbitTokens.Radius.plusMenuRow
        icon.image = OrbitIcon.image(sfName: symbol, pointSize: OrbitTokens.Metrics.Sidebar.plusMenuIconSize, accessibilityDescription: nil)
        icon.contentTintColor = destructive ? .systemRed : OrbitTokens.Color.Text.commandBarPrimary
        title.stringValue = text
        title.font = OrbitTokens.Typography.menuItem
        title.lineBreakMode = .byTruncatingTail
        title.textColor = destructive ? .systemRed : OrbitTokens.Color.Text.commandBarPrimary
        shortcut.stringValue = keys
        shortcut.font = OrbitTokens.Typography.menuShortcut
        shortcut.textColor = accent.menuShortcut
        shortcut.alignment = .right
        for child in [icon, title, shortcut] { child.setAccessibilityElement(false); addSubview(child) }
        alphaValue = enabled ? 1 : 0.4
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(text)
        setAccessibilityEnabled(enabled)
        setAccessibilityIdentifier(identifier)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let m = OrbitTokens.Metrics.Sidebar.self
        icon.frame = NSRect(x: 12, y: 11, width: m.plusMenuIconSize, height: m.plusMenuIconSize)
        let x = m.plusMenuTextOriginX - m.plusMenuHighlightInset
        let shortcutWidth = shortcut.intrinsicContentSize.width
        shortcut.frame = NSRect(x: bounds.width - shortcutWidth - 10, y: 11, width: shortcutWidth, height: 18)
        title.frame = NSRect(x: x, y: 11, width: max(0, bounds.width - x - shortcutWidth - 16), height: 18)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = (selected ? accent.soft : .clear).resolvedCGColor(for: effectiveAppearance)
        setAccessibilitySelected(selected)
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if enabled, bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        onPress?(); return true
    }
}

/// A child panel keeps the right alignment even when the sidebar is far from a screen
/// edge. NSPopover centres its bubble on the anchor and cannot reproduce that Orbit placement.
@MainActor
final class SidebarCreationPopup: NSObject, NSWindowDelegate {
    weak var contentViewController: NSViewController?
    var usesGlass = false
    var surfaceColor = OrbitTokens.Color.Surface.popover
    var onClose: (() -> Void)?
    private(set) var window: NSPanel?
    private weak var source: NSWindow?
    private var mouseMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    private var sourceCloseObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []

    static func panelFrame(buttonFrameOnScreen button: NSRect, size: NSSize) -> NSRect {
        NSRect(x: button.midX + 24 - OrbitTokens.Metrics.Sidebar.plusMenuRightInset - size.width,
               y: button.maxY + 4, width: size.width, height: size.height)
    }

    func show(relativeTo anchor: NSRect, of button: NSView, preferredEdge: NSRectEdge) {
        guard window == nil, let source = button.window, let content = contentViewController?.view else { return }
        let buttonRect = source.convertToScreen(button.convert(button.bounds, to: nil))
        let width = content.frame.width
        let height = content.frame.height + 6
        var frame = Self.panelFrame(buttonFrameOnScreen: buttonRect, size: NSSize(width: width, height: height))
        if usesGlass, let screen = source.screen?.visibleFrame {
            frame.origin.x = max(screen.minX + 8, min(frame.minX, screen.maxX - width - 8))
            frame.origin.y = max(screen.minY + 8, min(frame.minY, screen.maxY - height - 8))
        }
        let panel = CreationMenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.delegate = self
        let background = CreationPopupBackground(frame: NSRect(origin: .zero, size: frame.size))
        background.color = usesGlass ? .clear : surfaceColor
        if usesGlass {
            let glass = NSVisualEffectView(frame: background.bounds)
            glass.material = .popover
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = OrbitTokens.Radius.plusMenu
            glass.layer?.masksToBounds = true
            glass.autoresizingMask = [.width, .height]
            background.addSubview(glass)
        }
        content.frame.origin = .zero
        background.addSubview(content)
        panel.contentView = background
        self.source = source
        window = panel
        source.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [self] event in
            if event.window !== window { performClose(nil) }
            return event
        }
        sourceCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: source, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.performClose(nil) }
        }
        if usesGlass {
            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                         NSWindow.didResizeNotification, NSWindow.willBeginSheetNotification] {
                lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: source, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.performClose(nil) }
                })
            }
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.performClose(nil) }
        }
    }

    func performClose(_ sender: Any?) {
        guard let panel = window else { return }
        let restoreKey = panel.isKeyWindow
        window = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        deactivateObserver = nil
        if let sourceCloseObserver { NotificationCenter.default.removeObserver(sourceCloseObserver) }
        sourceCloseObserver = nil
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers.removeAll()
        source?.removeChildWindow(panel)
        panel.close()
        if restoreKey { source?.makeKey() }
        onClose?()
    }
    func windowDidResignKey(_ notification: Notification) { performClose(nil) }
}

@MainActor
private final class CreationMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class CreationPopupBackground: NSView {
    var color = OrbitTokens.Color.Surface.popover
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 6),
                     xRadius: OrbitTokens.Radius.plusMenu, yRadius: OrbitTokens.Radius.plusMenu).fill()
        let x = bounds.width - OrbitTokens.Metrics.Sidebar.plusMenuArrowCenterFromRight
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: x - 6, y: bounds.height - 6))
        tail.line(to: NSPoint(x: x, y: bounds.height))
        tail.line(to: NSPoint(x: x + 6, y: bounds.height - 6))
        tail.close()
        tail.fill()
    }
}
