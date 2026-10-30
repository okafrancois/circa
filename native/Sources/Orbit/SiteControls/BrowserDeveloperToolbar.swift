import AppKit
import BrowserShell
import BrowserCore
import BrowserEngine

/// A compact 35-point developer toolbar with a page-coloured surface.
/// The content card supplies the top corner clipping; the page boundary stays square.
@MainActor
final class BrowserDeveloperToolbar: NSView {
    static let height: CGFloat = 35
    static let buttonPitch: CGFloat = 24.5
    let address = NSTextField()
    private let lock = SiteControlButton("", identifier: "developer-security", onPress: {})
    private let background = OrbitThemeFillView()
    private let actions = NSStackView()
    private var separators: [NSView] = []
    private(set) var pageTint: BrowserPageTint?
    private(set) var foreground: NSColor = .black
    private let extensions = NSStackView()
    private var extensionButtons: [String: SiteControlButton] = [:]
    private var badges: [String: BrowserExtensionBadgeView] = [:]
    private var captureButton: NSButton!
    private var captureSeparator: NSView!
    var onNavigate: ((String) -> Void)?
    var onPanel: ((BrowserDeveloperPanel) -> Void)?
    var onSiteControls: (() -> Void)?
    var onCapture: (() -> Void)?
    var onExtensions: (() -> Void)?
    var onSplit: (() -> Void)?
    var onExtension: ((String, NSButton) -> Void)?
    var extensionContextMenu: ((String) -> NSMenu?)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 958.5, height: Self.height))
        setAccessibilityIdentifier("developer-toolbar")
        wantsLayer = true
        background.frame = bounds
        background.autoresizingMask = [.width, .height]
        addSubview(background)
        lock.image = Self.glyph("lock.fill", width: 11.5, height: 13.5, weight: .medium)
        lock.isBordered = false
        lock.setAccessibilityLabel(uiText("Site Settings"))
        lock.toolTip = uiText("Site Settings")
        lock.onPress = { [weak self] in self?.onSiteControls?() }
        address.font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        address.isBordered = false; address.isBezeled = false; address.drawsBackground = false
        address.focusRingType = .none
        address.lineBreakMode = .byTruncatingMiddle
        address.setAccessibilityIdentifier("developer-url")
        address.setAccessibilityLabel(uiText("Address"))
        address.target = self; address.action = #selector(navigate)
        actions.orientation = .horizontal; actions.spacing = 0
        for view in [lock, address, actions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            lock.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13.25),
            lock.widthAnchor.constraint(equalToConstant: 12.5),
            lock.heightAnchor.constraint(equalToConstant: 18),
            lock.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.25),
            address.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36.5),
            address.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -10),
            address.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            address.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5.5),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        addButton("link", label: uiText("Copy Link"), id: "developer-copy", width: 44.5) { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address.stringValue, forType: .string)
        }
        captureSeparator = addSeparator()
        // Portrait capture has no implemented action.
        captureButton = addButton("camera", label: uiText("Capture…"), id: "developer-capture") { [weak self] in self?.onCapture?() }
        addSeparator()
        addButton("terminal", label: uiText("Toggle Console"), id: "developer-console") { [weak self] in self?.onPanel?(.console) }
        addButton("network", label: uiText("Toggle Network Panel"), id: "developer-network") { [weak self] in self?.onPanel?(.network) }
        addButton("scope", label: uiText("Inspect Element"), id: "developer-inspect") { [weak self] in self?.onPanel?(.elements) }
        addSeparator()
        addButton("puzzlepiece", label: uiText("Extensions Menu"), id: "developer-extensions") { [weak self] in self?.onExtensions?() }
        extensions.orientation = .horizontal; extensions.spacing = 0
        actions.addArrangedSubview(extensions)
        addButton("rectangle.split.2x1", label: uiText("Split View Menu"), id: "developer-split") { [weak self] in self?.onSplit?() }
        background.onAppearanceChange = { [weak self] in self?.refreshTint() }
        apply(theme: .default)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func navigate() { onNavigate?(address.stringValue) }
    @discardableResult
    private func addButton(_ symbol: String, label: String, id: String,
                           width: CGFloat = buttonPitch, action: @escaping () -> Void) -> NSButton {
        let button = SiteControlButton("", identifier: id, onPress: action)
        if symbol == "network" {
            // Use SF's native vector at its configured size, without a rotated bitmap canvas.
            button.image = OrbitGlyph.symbol(symbol, pointSize: 12.5, weight: .regular)
            button.symbolConfiguration = .init(pointSize: 12.5, weight: .regular)
            button.imageScaling = .scaleNone
        } else if symbol == "puzzlepiece" {
            button.image = Self.horizontalPuzzle
            button.imageScaling = .scaleNone
        } else {
            let ink: NSSize = switch symbol {
            case "link": NSSize(width: 13, height: 13)
            case "camera": NSSize(width: 15, height: 12)
            case "terminal": NSSize(width: 14, height: 11)
            case "scope": NSSize(width: 13, height: 13)
            default: NSSize(width: 11, height: 11)
            }
            button.image = Self.glyph(symbol, width: ink.width, height: ink.height,
                                      weight: symbol == "scope" ? .medium : .regular)
        }
        button.setAccessibilityLabel(label); button.toolTip = label
        button.isBordered = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        actions.addArrangedSubview(button)
        return button
    }
    private static func glyph(_ name: String, width: CGFloat, height: CGFloat,
                              weight: NSFont.Weight = .regular) -> NSImage? {
        guard let image = OrbitGlyph.symbol(name, pointSize: 14, weight: weight) else { return nil }
        // SF Symbols retain alignment padding when drawn into a canvas.
        let sized = NSImage(size: NSSize(width: width * 1.25, height: height * 1.25), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        sized.isTemplate = true
        return sized
    }
    /// Horizontal puzzle outline: 16.5×12 pt ink, outward tabs, recessed top/bottom.
    /// Draw paths at the destination backing scale; no asset copy or bitmap resizing.
    private static var horizontalPuzzle: NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 13), flipped: true) { _ in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 5.2, y: 1.2))
            p.line(to: NSPoint(x: 6.8, y: 1.2)); p.line(to: NSPoint(x: 6.8, y: 2.7))
            p.curve(to: NSPoint(x: 10.2, y: 2.7), controlPoint1: NSPoint(x: 6.8, y: 4.4), controlPoint2: NSPoint(x: 10.2, y: 4.4))
            p.line(to: NSPoint(x: 10.2, y: 1.2)); p.line(to: NSPoint(x: 11.8, y: 1.2))
            p.curve(to: NSPoint(x: 12.5, y: 1.9), controlPoint1: NSPoint(x: 12.35, y: 1.2), controlPoint2: NSPoint(x: 12.5, y: 1.35))
            p.line(to: NSPoint(x: 12.5, y: 4.2)); p.line(to: NSPoint(x: 14, y: 4.2))
            p.curve(to: NSPoint(x: 14, y: 8.8), controlPoint1: NSPoint(x: 17.1, y: 4.2), controlPoint2: NSPoint(x: 17.1, y: 8.8))
            p.line(to: NSPoint(x: 12.5, y: 8.8)); p.line(to: NSPoint(x: 12.5, y: 11.1))
            p.curve(to: NSPoint(x: 11.8, y: 11.8), controlPoint1: NSPoint(x: 12.5, y: 11.65), controlPoint2: NSPoint(x: 12.35, y: 11.8))
            p.line(to: NSPoint(x: 10.2, y: 11.8)); p.line(to: NSPoint(x: 10.2, y: 10.3))
            p.curve(to: NSPoint(x: 6.8, y: 10.3), controlPoint1: NSPoint(x: 10.2, y: 8.6), controlPoint2: NSPoint(x: 6.8, y: 8.6))
            p.line(to: NSPoint(x: 6.8, y: 11.8)); p.line(to: NSPoint(x: 5.2, y: 11.8))
            p.curve(to: NSPoint(x: 4.5, y: 11.1), controlPoint1: NSPoint(x: 4.65, y: 11.8), controlPoint2: NSPoint(x: 4.5, y: 11.65))
            p.line(to: NSPoint(x: 4.5, y: 8.8)); p.line(to: NSPoint(x: 3, y: 8.8))
            p.curve(to: NSPoint(x: 3, y: 4.2), controlPoint1: NSPoint(x: -0.1, y: 8.8), controlPoint2: NSPoint(x: -0.1, y: 4.2))
            p.line(to: NSPoint(x: 4.5, y: 4.2)); p.line(to: NSPoint(x: 4.5, y: 1.9))
            p.curve(to: NSPoint(x: 5.2, y: 1.2), controlPoint1: NSPoint(x: 4.5, y: 1.35), controlPoint2: NSPoint(x: 4.65, y: 1.2))
            p.close(); p.lineWidth = 1.1; p.lineJoinStyle = .round
            NSColor.black.setStroke(); p.stroke()
            return true
        }
        image.isTemplate = true
        image.cacheMode = .never
        return image
    }
    @discardableResult
    private func addSeparator() -> NSView {
        let container = NSView()
        container.widthAnchor.constraint(equalToConstant: 14.5).isActive = true
        container.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.23).cgColor
        line.frame = NSRect(x: 7, y: 0, width: 0.5, height: 18)
        container.addSubview(line)
        separators.append(line)
        actions.addArrangedSubview(container)
        return container
    }
    func apply(theme: OrbitTokens.SpaceTheme) {
        background.apply(theme)
        refreshTint()
    }
    func updateTint(_ tint: BrowserPageTint?) {
        guard pageTint != tint else { return }
        pageTint = tint
        refreshTint()
    }
    private func refreshTint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.isHidden = pageTint != nil
        if let tint = pageTint {
            layer?.backgroundColor = NSColor(srgbRed: CGFloat(tint.red) / 255, green: CGFloat(tint.green) / 255,
                                              blue: CGFloat(tint.blue) / 255, alpha: 1).cgColor
            foreground = tint.prefersWhiteForeground ? .white : .black
        } else {
            layer?.backgroundColor = nil
            let stops = background.resolvedStops.compactMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
            let color = stops.isEmpty ? NSColor.windowBackgroundColor : stops[stops.count / 2]
            let rgb = color.usingColorSpace(.sRGB) ?? .white
            let tint = BrowserPageTint(red: UInt8(max(0, min(255, rgb.redComponent * 255))),
                                       green: UInt8(max(0, min(255, rgb.greenComponent * 255))),
                                       blue: UInt8(max(0, min(255, rgb.blueComponent * 255))))
            foreground = tint.prefersWhiteForeground ? .white : .black
        }
        // Keep text opaque: at the WCAG crossover, an opacity wash would drop below 4.5:1.
        address.textColor = foreground
        if let editor = address.currentEditor() as? NSTextView {
            editor.textColor = foreground
            editor.insertionPointColor = .controlAccentColor
        }
        lock.contentTintColor = foreground
        for case let button as NSButton in actions.arrangedSubviews { button.contentTintColor = foreground }
        for button in extensionButtons.values { button.contentTintColor = foreground }
        for line in separators { line.layer?.backgroundColor = foreground.withAlphaComponent(0.23).cgColor }
        CATransaction.commit()
    }
    func update(url: URL?, canCapture: Bool = true) {
        if address.currentEditor() == nil { address.stringValue = url?.absoluteString ?? "" }
        lock.isHidden = url?.scheme?.lowercased() != "https"
        captureButton.isHidden = !canCapture
        captureSeparator.isHidden = !canCapture
    }
    func updateExtensions(_ items: [BrowserExtensionSummary]) {
        let ids = Set(items.map(\.id))
        for id in Array(extensionButtons.keys) where !ids.contains(id) {
            extensionButtons.removeValue(forKey: id)?.removeFromSuperview()
            badges[id] = nil
        }
        for (index, item) in items.enumerated() {
            let button: SiteControlButton
            if let existing = extensionButtons[item.id] { button = existing }
            else {
                let created = SiteControlButton("", identifier: "developer-extension-" + item.id, onPress: {})
                created.onPress = { [weak self, weak created] in
                    guard let created else { return }; self?.onExtension?(item.id, created)
                }
                created.contextMenuBuilder = { [weak self] in self?.extensionContextMenu?(item.id) }
                created.isBordered = false
                created.imageScaling = .scaleProportionallyDown
                created.widthAnchor.constraint(equalToConstant: Self.buttonPitch).isActive = true
                created.heightAnchor.constraint(equalToConstant: 28).isActive = true
                let badge = BrowserExtensionBadgeView()
                badge.install(on: created, iconSize: 14)
                badges[item.id] = badge
                extensionButtons[item.id] = created
                button = created
            }
            if extensions.arrangedSubviews.count <= index || extensions.arrangedSubviews[index] !== button {
                if extensions.arrangedSubviews.contains(button) { extensions.removeArrangedSubview(button) }
                extensions.insertArrangedSubview(button, at: index)
            }
            button.contentTintColor = foreground
            button.setAccessibilityLabel(item.name); button.toolTip = item.actionState?.title ?? item.name
            button.setAccessibilityValue(item.actionState?.badgeText ?? item.actionBadgeText ?? "")
            badges[item.id]?.text = item.actionState?.badgeText ?? item.actionBadgeText
            badges[item.id]?.backgroundARGB = item.actionState?.badgeBackgroundColor
            button.isEnabled = item.actionState?.isEnabled != false
            if let encoded = item.actionState?.iconPNGBase64 ?? item.iconPNGBase64, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                image.size = NSSize(width: 14, height: 14); button.image = image
            }
        }
    }
}

/// Extension badges overlap the icon's lower right, with white compact numerals.
/// This view never intercepts clicks.
@MainActor
final class BrowserExtensionBadgeView: NSView {
    var text: String? { didSet { isHidden = text?.isEmpty != false; invalidateIntrinsicContentSize(); needsDisplay = true } }
    var backgroundARGB: UInt32? { didSet { needsDisplay = true } }
    static let font = BrandTextStyle.ui.font(size: 5, weight: .bold)
    private var badgeFont: NSFont {
        (text?.count ?? 0) > 4 ? BrandTextStyle.ui.font(size: 6, weight: .bold) : Self.font
    }
    override var intrinsicContentSize: NSSize {
        let width = ((text ?? "") as NSString).size(withAttributes: [.font: badgeFont]).width
        if (text?.count ?? 0) > 4 { return NSSize(width: max(9, ceil(width) + 3), height: 8) }
        return NSSize(width: max(8, ceil(width) + 2), height: 7)
    }
    func install(on button: NSButton, iconSize: CGFloat) {
        translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(self)
        NSLayoutConstraint.activate([
            trailingAnchor.constraint(equalTo: button.centerXAnchor, constant: iconSize / 2 - 1),
            bottomAnchor.constraint(equalTo: button.centerYAnchor, constant: iconSize / 2 - 1)
        ])
    }
    override init(frame: NSRect) { super.init(frame: frame); isHidden = true; setAccessibilityElement(false) }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let text, !text.isEmpty else { return }
        let background = backgroundARGB.map {
            NSColor(srgbRed: CGFloat(($0 >> 16) & 255) / 255, green: CGFloat(($0 >> 8) & 255) / 255,
                    blue: CGFloat($0 & 255) / 255, alpha: CGFloat(($0 >> 24) & 255) / 255)
        } ?? NSColor(srgbRed: 0.19, green: 0.19, blue: 0.20, alpha: 1)
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: badgeFont, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                 withAttributes: attributes)
    }
}
