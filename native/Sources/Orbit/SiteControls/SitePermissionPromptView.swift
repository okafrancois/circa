import AppKit
import BrowserCore

/// observed on localhost on 2026-10-28: the same compact native popover
/// for notifications, camera, microphone, location and clipboard. AppKit supplies the
/// arrow, corner radius, material and presentation animation; this view stays transparent.
@MainActor
final class SitePermissionPromptView: NSView {
    static let width: CGFloat = 236
    let message: NSTextField
    let notNowButton: NSButton
    let allowButton: NSButton
    let symbolName: String
    private let badge: SitePermissionBadge
    private let headerHeight: CGFloat
    override var isFlipped: Bool { true }

    init(origin: BrowserSiteOrigin, permissions: [BrowserSitePermission],
         onChoice: @escaping (BrowserSitePermissionChoice) -> Void) {
        symbolName = Self.symbol(for: permissions)
        badge = SitePermissionBadge(symbol: symbolName)
        message = NSTextField(wrappingLabelWithString: Self.message(origin: origin, permissions: permissions))
        message.font = .systemFont(ofSize: 14, weight: .medium)
        message.textColor = .labelColor
        message.preferredMaxLayoutWidth = 176
        message.cell?.wraps = true
        message.cell?.isScrollable = false
        headerHeight = max(32, ceil(message.cell!.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: 176, height: 1000)).height))
        notNowButton = SitePermissionActionButton(uiText("Not Now"), identifier: "permission-not-now") {
            // Orbit reports denied even after reloading after Not Now. Closing the popover
            // without choosing still uses the coordinator's non-persistent dismissal.
            onChoice(.block)
        }
        allowButton = SitePermissionActionButton(uiText("Allow"), identifier: "permission-allow") {
            onChoice(permissions.allSatisfy(\.supportsPersistentAllow) ? .alwaysAllow : .allowOnce)
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10 + headerHeight + 16 + 32 + 10))
        setAccessibilityIdentifier("site-permission-prompt")
        for view in [badge, message, notNowButton, allowButton] { addSubview(view) }
        // A request initiated by a page must not turn the next Return into a persistent grant.
        notNowButton.keyEquivalent = "\u{1b}"
        layout()
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        badge.frame = NSRect(x: 10, y: 10, width: 32, height: 32)
        message.frame = NSRect(x: 50, y: 10, width: 176, height: headerHeight)
        let buttonY = 10 + headerHeight + 16
        notNowButton.frame = NSRect(x: 10, y: buttonY, width: 104, height: 32)
        allowButton.frame = NSRect(x: 122, y: buttonY, width: 104, height: 32)
    }

    static func message(origin: BrowserSiteOrigin, permissions: [BrowserSitePermission]) -> String {
        let format: String
        switch Set(permissions) {
        case [.notifications]: format = uiText("Allow %@ to send you notifications?")
        case [.camera]: format = uiText("Allow %@ to access your camera?")
        case [.microphone]: format = uiText("Allow %@ to access your microphone?")
        case [.camera, .microphone]: format = uiText("Allow %@ to access your camera, microphone?")
        case [.geolocation]: format = uiText("Allow %@ to access your location?")
        case [.clipboardRead], [.clipboardWrite], [.clipboardRead, .clipboardWrite]:
            format = uiText("Allow %@ to access your clipboard?")
        default:
            return String(format: uiText("Allow %@ to access %@?"), origin.value,
                          permissions.map(\.displayTitle).joined(separator: ", "))
        }
        return String(format: format, origin.value)
    }

    static func symbol(for permissions: [BrowserSitePermission]) -> String {
        if permissions.contains(.camera) { return "camera.fill" }
        if permissions.contains(.microphone) { return "mic.fill" }
        if permissions.contains(.notifications) { return "bell.fill" }
        if permissions.contains(.geolocation) { return "location.fill" }
        if permissions.contains(.clipboardRead) || permissions.contains(.clipboardWrite) { return "clipboard.fill" }
        if permissions.contains(.screenSharing) { return "rectangle.on.rectangle" }
        return "hand.raised.fill"
    }
}

@MainActor
private final class SitePermissionBadge: NSView {
    private let icon: NSImageView
    override var isFlipped: Bool { true }

    init(symbol: String) {
        icon = NSImageView(image: OrbitGlyph.symbol(symbol, pointSize: 16) ?? NSImage())
        icon.contentTintColor = .labelColor
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        addSubview(icon)
        setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 7, dy: 7)
    }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds)
        NSColor.labelColor.withAlphaComponent(0.04).setFill()
        circle.fill()
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        NSGradient(starting: NSColor.systemRed.withAlphaComponent(0.50), ending: .clear)?
            .draw(fromCenter: NSPoint(x: 24, y: 9), radius: 0,
                  toCenter: NSPoint(x: 24, y: 9), radius: 18, options: [])
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class SitePermissionActionButton: NSButton {
    private let onPress: () -> Void
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    init(_ title: String, identifier: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        font = .systemFont(ofSize: 15, weight: .semibold)
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(press)
        setAccessibilityIdentifier(identifier)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func press() { onPress() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.18 : hovered ? 0.12 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        super.draw(dirtyRect)
    }
}
