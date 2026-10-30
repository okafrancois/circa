import AppKit
import BrowserShell
import BrowserCore

/// runtime geometry: a 236 pt content view, 48 × 32 pt tiles on a 56 pt pitch.
/// The system popover supplies its material, border and arrow; unsupported product features
/// are omitted rather than represented by inert controls.
@MainActor
final class OrbitSiteControlCenterView: NSView {
    private let topActions: [NSView]
    private let tiles: [NSView]
    private let settings: [NSView]
    private let extensionTitle = NSTextField(labelWithString: uiText("Extensions"))
    private let settingsTitle = NSTextField(labelWithString: uiText("Settings"))
    private let manage: NSButton
    private let secure: NSView
    private let more: NSView
    private let separator = NSBox()
    private let message: NSTextField?
    private let messageHeight: CGFloat
    private var hoverArea: NSTrackingArea?
    override var isFlipped: Bool { true }

    init(topActions: [NSView], tiles: [NSView], settings: [NSView], manage: NSButton,
         secure: NSView, more: NSView, status: String? = nil) {
        self.topActions = topActions; self.tiles = tiles; self.settings = settings
        self.manage = manage; self.secure = secure; self.more = more
        if let status {
            let field = NSTextField(wrappingLabelWithString: status)
            field.font = BrandTextStyle.ui.font(size: 12)
            field.textColor = OrbitFloatingMaterial.secondary
            message = field
            messageHeight = ceil((status as NSString).boundingRect(
                with: NSSize(width: 216, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: field.font!]).height) + 12
        } else { message = nil; messageHeight = 0 }
        let tileRows = max(1, (tiles.count + 3) / 4)
        let height = 211 + CGFloat(tileRows - 1) * 40 + CGFloat(settings.count) * 43 + messageHeight
        super.init(frame: NSRect(x: 0, y: 0, width: 236, height: height))
        setAccessibilityIdentifier("siteControlCenterView")
        for label in [extensionTitle, settingsTitle] {
            label.font = BrandTextStyle.ui.font(size: 15, weight: .bold)
            label.textColor = OrbitFloatingMaterial.body
        }
        manage.isBordered = false
        manage.font = BrandTextStyle.ui.font(size: 13)
        manage.contentTintColor = OrbitFloatingMaterial.secondary
        manage.alphaValue = 0
        manage.setAccessibilityHidden(true)
        separator.boxType = .separator
        for view in topActions + tiles + settings + [extensionTitle, settingsTitle, manage, separator, secure, more] {
            addSubview(view)
        }
        if let message { addSubview(message) }
        layout()
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        for (index, view) in topActions.enumerated() {
            view.frame = NSRect(x: 9 + CGFloat(index) * 56, y: 9, width: 48, height: 32)
        }
        extensionTitle.frame = NSRect(x: 10, y: 52, width: 160, height: 19)
        manage.frame = NSRect(x: 179, y: 53, width: 47, height: 17)
        for (index, view) in tiles.enumerated() {
            view.frame = NSRect(x: 10 + CGFloat(index % 4) * 56, y: 79 + CGFloat(index / 4) * 40,
                                width: 56, height: 39)
        }
        let settingsY = 126 + CGFloat(max(1, (tiles.count + 3) / 4) - 1) * 40
        settingsTitle.frame = NSRect(x: 10, y: settingsY, width: 216, height: 19)
        for (index, view) in settings.enumerated() {
            view.frame = NSRect(x: 10, y: settingsY + 27 + CGFloat(index) * 43, width: 208, height: 33)
        }
        let messageY = settingsY + 33 + CGFloat(settings.count) * 43
        message?.frame = NSRect(x: 10, y: messageY, width: 216, height: max(0, messageHeight - 12))
        let dividerY = messageY + messageHeight
        separator.frame = NSRect(x: 10, y: dividerY, width: 216, height: 1)
        secure.frame = NSRect(x: 10, y: dividerY + 10, width: 32, height: 32)
        more.frame = NSRect(x: 194, y: dividerY + 10, width: 32, height: 32)
    }

    static func connectionButton(isSecure: Bool, onPress: @escaping () -> Void) -> SiteControlButton {
        footerButton(symbol: isSecure ? "lock.fill" : "lock.open", pointSize: 14,
                     label: isSecure ? uiText("Secure connection") : uiText("Connection is not secure"),
                     identifier: "site-connection", onPress: onPress)
    }

    static func footerButton(symbol: String, pointSize: CGFloat = 16, label: String,
                             identifier: String, onPress: @escaping () -> Void) -> SiteControlButton {
        let button = SiteControlButton("", identifier: identifier, onPress: onPress)
        button.frame.size = NSSize(width: 32, height: 32)
        button.image = OrbitGlyph.symbol(symbol, pointSize: pointSize)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.isBordered = false
        button.setAccessibilityLabel(label)
        button.toolTip = label
        button.wantsLayer = true
        button.layer?.cornerRadius = 16
        button.layer?.backgroundColor = OrbitFloatingMaterial.body.withAlphaComponent(0.04).cgColor
        return button
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: NSRect(x: 0, y: 45, width: 236,
                                              height: 76 + CGFloat(max(0, (tiles.count - 1) / 4)) * 40),
                                  options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { manage.alphaValue = 1; manage.setAccessibilityHidden(false) }
    override func mouseExited(with event: NSEvent) { manage.alphaValue = 0; manage.setAccessibilityHidden(true) }
}

@MainActor
final class ControlCenterActionTile: NSView {
    let button: NSButton
    private let pin: NSButton?
    private var pinned: Bool
    private let dark: Bool
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private var hoverTask: Task<Void, Never>?
    override var isFlipped: Bool { true }

    init(button: NSButton, pin: NSButton? = nil, pinned: Bool = false, dark: Bool = false) {
        self.button = button; self.pin = pin; self.pinned = pinned; self.dark = dark
        super.init(frame: NSRect(x: 0, y: 0, width: 56, height: 39))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        if dark { button.contentTintColor = NSColor(white: 0.8, alpha: 1) }
        button.frame = NSRect(x: 0, y: 0, width: 48, height: 32)
        addSubview(button)
        if let pin {
            pin.isBordered = false
            pin.imagePosition = .imageOnly
            pin.imageScaling = .scaleProportionallyDown
            pin.image?.size = NSSize(width: 9, height: 9)
            pin.wantsLayer = true
            pin.layer?.cornerRadius = 7
            pin.layer?.backgroundColor = NSColor.clear.cgColor
            pin.contentTintColor = .windowBackgroundColor
            pin.frame = NSRect(x: 37, y: 21, width: 14, height: 14)
            addSubview(pin)
            (pin as? ControlCenterPinButton)?.isPinned = pinned
        }
        refreshPin()
    }
    required init?(coder: NSCoder) { nil }
    func setPinned(_ value: Bool) {
        guard value != pinned else { return }
        pinned = value
        (pin as? ControlCenterPinButton)?.isPinned = value
        pin?.setAccessibilityLabel(value ? uiText("Unpin") : uiText("Pin"))
        pin?.toolTip = value ? uiText("Unpin") : uiText("Pin")
        refreshPin()
    }
    private func refreshPin(animated: Bool = false) {
        let alpha: CGFloat = pinned || hovered ? 1 : 0
        let animate = animated && window?.isVisible == true && !OrbitMotionPreferences.prefersReducedMotion
        NSAnimationContext.runAnimationGroup { context in
            // calls easeInOut(duration: 0.12); hover-in adds 0.36 s.
            context.duration = animate ? 0.12 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            if animate { pin?.animator().alphaValue = alpha } else { pin?.alphaValue = alpha }
        }
        pin?.setAccessibilityHidden(!(pinned || hovered))
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            if !OrbitMotionPreferences.prefersReducedMotion { try? await Task.sleep(for: .milliseconds(360)) }
            guard !Task.isCancelled, let self else { return }
            hovered = true; refreshPin(animated: true)
        }
    }
    override func mouseExited(with event: NSEvent) {
        hoverTask?.cancel(); hoverTask = nil
        hovered = false; refreshPin(animated: true)
    }
    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: 0, y: 0, width: 48, height: 32)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if dark {
            NSGradient(starting: NSColor(white: hovered ? 0.22 : 0.16, alpha: 1),
                       ending: NSColor(white: 0.07, alpha: 1))?.draw(in: path, angle: 90)
            NSColor.white.withAlphaComponent(0.28).setStroke(); path.lineWidth = 0.5; path.stroke()
        } else {
            OrbitFloatingMaterial.body.withAlphaComponent(hovered ? 0.10 : 0.055).setFill(); path.fill()
        }
    }
}

/// Drawing the badge explicitly avoids NSButtonCell's bezel covering a layer background and
/// resolves its colors at draw time when the panel's appearance changes.
@MainActor
final class ControlCenterPinButton: NSButton {
    private let onPress: () -> Void
    var isPinned = false { didSet { needsDisplay = true } }
    init(identifier: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        title = ""
        target = self; action = #selector(pressed)
        isBordered = false
        setAccessibilityIdentifier(identifier)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func pressed() { onPress() }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer(); context.restoreGState() }
        OrbitFloatingMaterial.body.withAlphaComponent(isHighlighted ? 0.65 : (isPinned ? 1 : 0.33)).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        // 8 pt black symbol, rotation 0.5759586531581288 rad (33°).
        if let image = OrbitGlyph.symbol("pin.fill", pointSize: 8, weight: .black) {
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
            let rotation = NSAffineTransform(transform: transform)
            rotation.rotate(byDegrees: -33)
            rotation.translateX(by: -bounds.midX, yBy: -bounds.midY)
            rotation.concat()
            let size = image.size
            let target = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                width: size.width, height: size.height)
            // Orbit cuts the symbol out of the circle, exposing the actual panel material.
            image.draw(in: target, from: .zero, operation: .destinationOut, fraction: 1,
                       respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// Keeps native popup-button accessibility and selection while matching Orbit's two-line rows.
@MainActor
final class ControlCenterPermissionPicker: NSPopUpButton {
    override var isFlipped: Bool { true }
    private let permission: BrowserSitePermission
    private let symbol: NSImage?
    private let onSelect: (BrowserSitePermissionSetting) -> Void

    init(permission: BrowserSitePermission, setting: BrowserSitePermissionSetting,
         symbol: String, onSelect: @escaping (BrowserSitePermissionSetting) -> Void) {
        self.permission = permission; self.symbol = OrbitGlyph.symbol(symbol, pointSize: 16)
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: 216, height: 33), pullsDown: false)
        addItems(withTitles: [uiText("Ask"), uiText("Allow"), uiText("Block")])
        selectItem(at: BrowserSitePermissionSetting.allCases.firstIndex(of: setting) ?? 0)
        isBordered = false
        setAccessibilityLabel(permission.displayTitle)
        setAccessibilityIdentifier("site-permission-" + permission.rawValue)
        target = self; action = #selector(changed)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func changed() {
        guard BrowserSitePermissionSetting.allCases.indices.contains(indexOfSelectedItem) else { return }
        needsDisplay = true
        onSelect(BrowserSitePermissionSetting.allCases[indexOfSelectedItem])
    }
    override func draw(_ dirtyRect: NSRect) {
        OrbitFloatingMaterial.body.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
        if let symbol { OrbitGlyph.draw(symbol, centeredIn: NSRect(x: 0, y: 0, width: 32, height: 32), tint: .secondaryLabelColor, in: self) }
        let title = permission.displayTitle as NSString
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        title.draw(in: NSRect(x: 41, y: 0, width: bounds.width - 41, height: 18), withAttributes: [
            .font: BrandTextStyle.ui.font(size: 15, weight: .semibold), .foregroundColor: OrbitFloatingMaterial.body, .paragraphStyle: paragraph])
        (titleOfSelectedItem ?? "").draw(in: NSRect(x: 41, y: 18, width: bounds.width - 41, height: 16), withAttributes: [
            .font: BrandTextStyle.ui.font(size: 13), .foregroundColor: OrbitFloatingMaterial.secondary])
    }
}

@MainActor
final class ControlCenterSettingButton: NSButton {
    private let rowTitle: String
    private let subtitle: String
    private let symbol: NSImage?
    private let onPress: () -> Void
    private let active: Bool
    override var isFlipped: Bool { true }

    init(title: String, subtitle: String, symbol: String, identifier: String, active: Bool, onPress: @escaping () -> Void) {
        rowTitle = title; self.subtitle = subtitle
        self.onPress = onPress
        self.active = active
        self.symbol = OrbitGlyph.symbol(symbol, pointSize: 16)
        super.init(frame: NSRect(x: 0, y: 0, width: 208, height: 33))
        self.title = ""
        target = self; action = #selector(pressed)
        setAccessibilityIdentifier(identifier)
        isBordered = false
        setAccessibilityLabel(title + ", " + subtitle)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func pressed() { onPress() }
    override func draw(_ dirtyRect: NSRect) {
        OrbitFloatingMaterial.body.withAlphaComponent(active ? 0.92 : 0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
        if let symbol { OrbitGlyph.draw(symbol, centeredIn: NSRect(x: 0, y: 0, width: 32, height: 32), tint: active ? .windowBackgroundColor : .secondaryLabelColor, in: self) }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (rowTitle as NSString).draw(in: NSRect(x: 41, y: 0, width: bounds.width - 41, height: 18), withAttributes: [
            .font: BrandTextStyle.ui.font(size: 15, weight: .semibold), .foregroundColor: OrbitFloatingMaterial.body,
            .paragraphStyle: paragraph])
        (subtitle as NSString).draw(in: NSRect(x: 41, y: 18, width: bounds.width - 41, height: 16), withAttributes: [
            .font: BrandTextStyle.ui.font(size: 13), .foregroundColor: OrbitFloatingMaterial.secondary])
    }
}

@MainActor
final class SiteActionMenu: NSMenu {
    private var handlers: [() -> Void] = []
    init() { super.init(title: ""); autoenablesItems = false }
    required init(coder: NSCoder) { super.init(coder: coder) }
    func addAction(_ title: String, enabled: Bool = true, checked: Bool = false, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self; item.tag = handlers.count; item.isEnabled = enabled
        item.state = checked ? .on : .off
        handlers.append(action); addItem(item)
    }
    @objc private func choose(_ sender: NSMenuItem) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }
}
