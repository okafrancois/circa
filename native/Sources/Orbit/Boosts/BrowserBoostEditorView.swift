import AppKit
import BrowserCore

@MainActor
final class BrowserBoostEditorView: NSView {
    let session: BrowserBoostEditorSession
    var onClose: (() -> Void)?
    var onZap: (() -> Void)?
    var onCode: (() -> Void)?
    var onAllBoosts: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRename: (() -> Void)?
    private let titleButton = BoostButton(title: "")
    var onRender: (() -> Void)?
    var isZapping = false { didSet { render() } }
    private let wheel = BrowserBoostColorWheel()
    private let size = BoostButton(title: uiText("Size"))
    private let textCase = BoostButton(title: uiText("Case"))
    private let zap = BoostButton(title: uiText("Zap"))
    private let code = BoostButton(title: uiText("Code"))
    private let zapGlyph = NSImageView()
    private let zapCount = NSTextField(labelWithString: "")
    private var fontButtons: [BoostButton] = []
    private var selectedFontIndex: Int?
    private let fontTray = LibraryFlippedView()
    private var advanced: NSPopover?
    private var introduction: BrowserBoostIntroductionView?

    init(session: BrowserBoostEditorSession, firstRun: Bool) {
        self.session = session
        selectedFontIndex = session.boost.content.fontFamily.flatMap { Self.fontFamilies.firstIndex(of: $0) }
        super.init(frame: NSRect(x: 0, y: 0, width: 183, height: 588))
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.985, green: 0.985, blue: 0.99, alpha: 1).cgColor
        layer?.borderWidth = 0.5; layer?.borderColor = NSColor.gray.withAlphaComponent(0.5).cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        let close = BoostButton(symbol: "xmark.circle.fill", label: uiText("Close"))
        close.fill = .clear
        close.actionBlock = { [weak self] in self?.onClose?() }
        place(close, 6, 6, 28, 28)
        titleButton.fill = .clear
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.actionBlock = { [weak self] in self?.showHeaderMenu() }
        titleButton.textTrailingInset = 20
        place(titleButton, 40, 6, 100, 28)
        let chevron = NSImageView(image: OrbitIcon.image(sfName: "chevron.down", pointSize: 16, accessibilityDescription: nil)!)
        chevron.contentTintColor = .gray
        titleButton.addSubview(chevron); chevron.frame = NSRect(x: 84, y: 9, width: 12, height: 10)
        let reset = BoostButton(symbol: "arrow.counterclockwise", label: uiText("Reset to original colors"))
        reset.fill = .clear
        reset.actionBlock = { [weak session] in session?.resetColors() }
        place(reset, 148, 6, 28, 28)
        wheel.onChange = { [weak session] hue, saturation in
            session?.edit {
                var colors = $0.colorScheme ?? .init()
                colors.source = .colorWheelDriven; colors.hue = hue; colors.saturation = saturation
                $0.colorScheme = colors
            }
        }
        place(wheel, 18, 58, 147, 147)
        let invert = BoostButton(symbol: "lightbulb", label: uiText("Invert lightness"))
        invert.actionBlock = { [weak session] in session?.edit {
            var colors = $0.colorScheme ?? .init()
            colors.invertLightness = !(colors.invertLightness ?? false); $0.colorScheme = colors
        } }
        let controls = BoostButton(symbol: "slider.horizontal.3", label: uiText("Advanced color controls"))
        controls.actionBlock = { [weak self, weak controls] in
            guard let self, let controls else { return }
            let popover = NSPopover(); popover.behavior = .transient; popover.animates = false
            let controller = NSViewController(); controller.view = BrowserBoostColorControls(session: session)
            popover.contentViewController = controller; advanced = popover
            popover.show(relativeTo: controls.bounds, of: controls, preferredEdge: .maxY)
        }
        let original = BoostButton(symbol: "nosign", label: uiText("Reset to original colors"))
        original.actionBlock = { [weak session] in session?.resetColors() }
        for (index, button) in [invert, controls, original].enumerated() { place(button, 18 + CGFloat(index) * 52.5, 220, 42, 38) }
        fontTray.wantsLayer = true; fontTray.layer?.backgroundColor = NSColor.white.cgColor
        fontTray.clipsToBounds = false
        fontTray.layer?.cornerRadius = 10
        fontTray.layer?.shadowOpacity = 0.1; fontTray.layer?.shadowRadius = 4
        fontTray.layer?.shadowOffset = NSSize(width: 0, height: -1)
        place(fontTray, 18, 273, 147, 120)
        for (index, family) in Self.fontFamilies.enumerated() {
            let button = BoostButton(title: uiText("Aa"))
            button.font = family.flatMap { NSFont(name: $0, size: 11) } ?? .systemFont(ofSize: 11)
            button.contentTintColor = NSColor(calibratedWhite: 0.6, alpha: 1)
            button.fill = .clear
            button.setAccessibilityLabel(family ?? uiText("Default"))
            button.cornerRadius = 13
            button.actionBlock = { [weak self, weak session] in self?.selectedFontIndex = index; session?.edit { $0.fontFamily = family } }
            fontTray.addSubview(button)
            button.frame = NSRect(x: 5 + CGFloat(index % 5) * 28, y: 8 + CGFloat(index / 5) * 25.5, width: 27, height: 25)
            fontButtons.append(button)
        }
        size.setAccessibilityLabel(uiText("Change text size"))
        size.actionBlock = { [weak session] in session?.edit { content in
            let levels = [1.0, 1.1, 1.25, 1.5, 0.9]
            let index = levels.firstIndex(of: content.textZoom ?? 1) ?? 0
            let next = levels[(index + 1) % levels.count]
            content.textZoom = next == 1 ? nil : next
        } }
        textCase.setAccessibilityLabel(uiText("Change text case"))
        textCase.actionBlock = { [weak session] in session?.edit { content in
            switch content.textTransform {
            case nil: content.textTransform = .uppercase
            case .uppercase: content.textTransform = .lowercase
            case .lowercase: content.textTransform = .capitalize
            case .capitalize: content.textTransform = nil
            }
        } }
        place(size, 18, 408, 69, 38); place(textCase, 95, 408, 70, 38)
        zap.actionBlock = { [weak self] in self?.onZap?() }
        code.actionBlock = { [weak self] in self?.onCode?() }
        zap.alignment = .left; code.alignment = .left
        place(zap, 18, 461, 147, 38); place(code, 18, 514, 147, 38)
        zapGlyph.frame = NSRect(x: 137, y: 471, width: 18, height: 18)
        zapGlyph.image = OrbitIcon.image(sfName: "bolt.fill", pointSize: 16, accessibilityDescription: nil); zapGlyph.contentTintColor = .darkGray; addSubview(zapGlyph)
        zapCount.font = .systemFont(ofSize: 13, weight: .medium); zapCount.alignment = .right
        place(zapCount, 131, 470, 26, 20)
        let codeGlyph = NSTextField(labelWithString: uiText("{}"))
        codeGlyph.font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        place(codeGlyph, 137, 522, 22, 24)
        if firstRun {
            let intro = BrowserBoostIntroductionView(host: session.boost.hostPattern.host)
            intro.onContinue = { [weak self] in self?.introduction?.removeFromSuperview(); self?.introduction = nil }
            intro.onLater = { [weak self] in self?.onClose?() }
            introduction = intro
            place(intro, 0, 0, 183, 588)
        }
        session.onChange = { [weak self] in self?.render() }
        render()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    // The platform's families are used directly; no font resources are copied into the app.
    static let fontFamilies: [String?] = [nil, "Helvetica Neue", "Avenir", "Futura", "Arial Rounded MT Bold",
        "DIN Alternate", "PT Mono", "Courier", "Times New Roman", "Charter", "Baskerville", "Hoefler Text",
        "Palatino", "Chalkboard", "SignPainter", "Snell Roundhand", "Papyrus", "Apple Chancery", "Luminari", "Wingdings"]

    private func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        addSubview(view); view.frame = NSRect(x: x, y: y, width: width, height: height)
    }
    func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = !session.isClosed && !session.isDeleting
            menu.addItem(item)
        }
        add(uiText("Rename this Boost…"), #selector(renameAction))
        add(uiText("Reset all Edits"), #selector(resetAction))
        add(uiText("Delete this Boost"), #selector(deleteAction))
        menu.addItem(.separator())
        add(uiText("All Boosts…"), #selector(allBoostsAction))
        return menu
    }
    private func showHeaderMenu() {
        makeHeaderMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: titleButton.bounds.maxY), in: titleButton)
    }
    @objc private func resetAction() { session.resetAllEdits() }
    @objc private func renameAction() { onRename?() }
    @objc private func deleteAction() { onDelete?() }
    @objc private func allBoostsAction() { onAllBoosts?() }

    func render() {
        onRender?()
        titleButton.title = session.boost.title
        titleButton.setAccessibilityLabel(session.boost.title)
        selectedFontIndex = session.boost.content.fontFamily.flatMap { Self.fontFamilies.firstIndex(of: $0) }
        wheel.scheme = session.boost.content.colorScheme
        for (index, button) in fontButtons.enumerated() {
            button.fill = selectedFontIndex == index ? .black.withAlphaComponent(0.12) : .clear
        }
        let transform = session.boost.content.textTransform
        textCase.fill = transform == nil ? NSColor(calibratedWhite: 0.92, alpha: 1) : .systemOrange
        textCase.contentTintColor = transform == nil ? .darkGray : .white
        textCase.title = transform == .uppercase ? uiText("AA") : transform == .lowercase ? uiText("aa") : transform == .capitalize ? uiText("Aa") : uiText("Case")
        let zoom = session.boost.content.textZoom
        size.fill = zoom == nil ? NSColor(calibratedWhite: 0.92, alpha: 1) : .systemOrange
        size.contentTintColor = zoom == nil ? .darkGray : .white
        zap.fill = isZapping ? .darkGray : NSColor(calibratedWhite: 0.92, alpha: 1)
        zap.contentTintColor = isZapping ? .white : .darkGray
        size.title = zoom.map { uiFormat("%ld %%", Int(($0 * 100).rounded())) } ?? uiText("Size")
        let count = session.boost.content.zapSelectors.count
        zap.title = uiText("Zap")
        zapGlyph.isHidden = count > 0; zapGlyph.contentTintColor = isZapping ? .white : .darkGray
        zapCount.isHidden = count == 0; zapCount.stringValue = String(count)
        zapCount.textColor = isZapping ? .white : .darkGray
    }
}

@MainActor
final class BoostButton: NSButton {
    var actionBlock: (() -> Void)?
    var shortcutBadge: String?
    var outlinesShortcutBadge = false
    var shortcutBadgeColor: NSColor = .white.withAlphaComponent(0.16)
    var shortcutBadgeTextColor: NSColor = .white.withAlphaComponent(0.8)
    var textTrailingInset: CGFloat = 0
    var cornerRadius: CGFloat = 8
    var fill = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.925, alpha: 1) { didSet { needsDisplay = true } }
    convenience init(title: String) { self.init(frame: .zero); self.title = title }
    convenience init(symbol: String, label: String) {
        self.init(frame: .zero)
        image = OrbitIcon.image(sfName: symbol, pointSize: 16, accessibilityDescription: label)
        imagePosition = .imageOnly; setAccessibilityLabel(label); toolTip = label
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; font = .systemFont(ofSize: 13, weight: .medium)
        contentTintColor = .darkGray; focusRingType = .none
        target = self; action = #selector(performAction)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func performAction() { actionBlock?() }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        if image != nil { super.draw(dirtyRect); return }
        if let shortcutBadge {
            let badgeWidth: CGFloat = outlinesShortcutBadge ? 27 : 34
            let badge = NSRect(x: bounds.maxX - badgeWidth - 12, y: (bounds.height - 20) / 2, width: badgeWidth, height: 20)
            let path = NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4)
            if outlinesShortcutBadge { NSColor.white.withAlphaComponent(0.4).setStroke(); path.lineWidth = 1; path.stroke() }
            else { shortcutBadgeColor.setFill(); path.fill() }
            let label = shortcutBadge as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: outlinesShortcutBadge ? 17 : 10, weight: .semibold), .foregroundColor: shortcutBadgeTextColor]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: 12, y: (bounds.height - 16) / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: contentTintColor ?? .white])
            return
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = lineBreakMode
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: contentTintColor ?? NSColor.darkGray, .paragraphStyle: paragraph]
        let height = (title as NSString).size(withAttributes: attributes).height
        let inset: CGFloat = alignment == .left ? 12 : 0
        (title as NSString).draw(in: NSRect(x: inset, y: (bounds.height - height) / 2, width: bounds.width - inset * 2 - textTrailingInset, height: height), withAttributes: attributes)
    }
}

@MainActor
final class BrowserBoostColorWheel: NSView {
    var scheme: BrowserBoostColorScheme? { didSet { needsDisplay = true } }
    var onChange: ((Double, Double) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 4)
        NSColor.white.setFill(); NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
        NSGraphicsContext.saveGraphicsState()
        let ring = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        ring.lineWidth = 7
        ring.addClip()
        for x in stride(from: 0.0, through: Double(bounds.width), by: 2) {
            for y in stride(from: 0.0, through: Double(bounds.height), by: 2) {
                let angle = atan2(y - 73.5, x - 73.5) / (.pi * 2) + 0.5
                let color = scheme == nil ? NSColor(calibratedWhite: 0.25 + (Double(bounds.height) - y) / 250, alpha: 1)
                    : NSColor(calibratedHue: (1.5 - angle).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 1, alpha: 1)
                color.setFill(); NSRect(x: x, y: y, width: 2, height: 2).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: 7, dy: 7), xRadius: 11, yRadius: 11).fill()
        NSColor.lightGray.withAlphaComponent(0.3).setFill()
        for x in stride(from: 14, through: 133, by: 4) { for y in stride(from: 14, through: 133, by: 4) {
            NSBezierPath(ovalIn: NSRect(x: CGFloat(x), y: CGFloat(y), width: 0.7, height: 0.7)).fill()
        } }
        NSColor.lightGray.withAlphaComponent(0.16).setStroke()
        let orbit = NSBezierPath(ovalIn: NSRect(x: 34, y: 34, width: 79, height: 79)); orbit.lineWidth = 1.5; orbit.stroke()
        let darkPuck = NSRect(x: 43, y: 30, width: 21, height: 21)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 3; shadow.shadowOffset = .zero; shadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: darkPuck.insetBy(dx: -2, dy: -2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.darkGray.setFill(); NSBezierPath(ovalIn: darkPuck).fill()
        let hue = scheme?.hue ?? 0.75, saturation = scheme?.saturation ?? 0
        let puck = NSRect(x: 16 + hue * 90, y: 18 + saturation * 80, width: 32, height: 32)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: puck.insetBy(dx: -2, dy: -2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        (scheme == nil ? NSColor.gray : NSColor(calibratedHue: hue, saturation: saturation, brightness: 0.7, alpha: 1)).setFill()
        NSBezierPath(ovalIn: puck).fill()
    }
    override func mouseDown(with event: NSEvent) { update(event) }
    override func mouseDragged(with event: NSEvent) { update(event) }
    private func update(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onChange?(min(1, max(0, Double(point.x / bounds.width))), min(1, max(0, Double(point.y / bounds.height))))
    }
}
