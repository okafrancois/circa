import AppKit
import BrowserCore
import BrowserShell

@MainActor
final class OrbitOnboardingFavouritesView: NSView {
    var onToggle: ((Int) -> Void)?
    var icons: [URL: NSImage] = [:] { didSet { update(sites: currentSites) } }
    var resolvedIcons: [URL: NSImage] {
        Dictionary(uniqueKeysWithValues: zip(currentSites, buttons).compactMap { site, button in
            button.artwork.image.map { (site.url, $0) }
        })
    }
    private var currentSites: [BrowserOnboardingFavourite] = []
    private var checks: [CALayer] = []
    private var buttons: [OrbitOnboardingFavouriteButton] = []
    private let pins = OrbitOnboardingFlippedView(frame: NSRect(x: 0, y: 210, width: 216, height: 88))
    init(sites: [BrowserOnboardingFavourite]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 474, height: 220))
        wantsLayer = true
        clipsToBounds = false
        pins.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = pins.bounds
        gradient.colors = BrandPalette.sidebarPreviewColors
        gradient.startPoint = CGPoint(x: 0, y: 0); gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.cornerRadius = 12
        pins.layer?.addSublayer(gradient)
        pins.layer?.cornerRadius = 12
        pins.isHidden = true
        addSubview(pins)
        let hint = NSTextField(wrappingLabelWithString: uiText("how it looks in the sidebar"))
        hint.font = OrbitOnboardingFonts.mono(12); hint.textColor = BrandPalette.ink3
        hint.isHidden = true; addSubview(hint)
        for index in sites.indices {
            let button = OrbitOnboardingFavouriteButton(frame: NSRect(x: CGFloat(index % 4) * 120.39, y: CGFloat(index / 4) * 99.08, width: 106.18, height: 84.94))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 20.53
            button.clipsToBounds = false
            button.layer?.masksToBounds = false
            button.layer?.backgroundColor = BrandPalette.pageWhite.withAlphaComponent(0.6).cgColor
            let check = CALayer(); check.frame = CGRect(x: button.bounds.width - 18.95, y: -7.89, width: 26.84, height: 26.84)
            check.cornerRadius = 13.42
            check.transform = CATransform3DMakeScale(0, 0, 1)
            button.layer?.addSublayer(check); checks.append(check)
            button.imagePosition = .noImage
            button.imageScaling = .scaleNone
            button.target = self; button.action = #selector(toggle(_:)); button.tag = index
            button.setAccessibilityRole(.checkBox)
            addSubview(button); buttons.append(button)
        }
        update(sites: sites)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func update(sites: [BrowserOnboardingFavourite]) {
        currentSites = sites
        for (index, site) in sites.enumerated() where buttons.indices.contains(index) {
            let button = buttons[index]
            let color = BrandPalette.siteColors[index % BrandPalette.siteColors.count]
            button.artwork.image = icons[site.url] ?? NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
                color.setFill(); NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
                let letter = String(site.title.prefix(1))
                let attributes: [NSAttributedString.Key: Any] = [.font: OrbitOnboardingFonts.ui(13, weight: .bold), .foregroundColor: NSColor.white]
                let size = letter.size(withAttributes: attributes)
                letter.draw(at: NSPoint(x: (30-size.width)/2, y: (30-size.height)/2), withAttributes: attributes)
                return true
            }
            let hint = site.visits.map { uiFormat("%d visits", $0) } ?? site.url.host ?? ""
            button.nameField.stringValue = site.title
            button.hintField.stringValue = hint
            button.layer?.borderWidth = 0
            button.outline.frame = button.bounds
            button.outline.path = CGPath(roundedRect: button.bounds.insetBy(dx: -1.58, dy: -1.58), cornerWidth: 22.11, cornerHeight: 22.11, transform: nil)
            button.outline.opacity = site.selected ? 1 : 0
            button.layer?.borderColor = BrandPalette.ink.cgColor
            button.isSelectedTile = site.selected
            let check = checks[index]
            let wasSelected = check.transform.m11 > 0.5
            CATransaction.begin(); CATransaction.setDisableActions(true)
            check.transform = CATransform3DMakeScale(site.selected ? 1 : 0, site.selected ? 1 : 0, 1)
            CATransaction.commit()
            if wasSelected != site.selected, !OrbitMotionPreferences.prefersReducedMotion {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                let from = wasSelected ? 1.0 : 0.0, to = site.selected ? 1.0 : 0.0
                pop.values = (0...60).map { frame in
                    let t = Double(frame) / 60 - 1
                    return from + (to - from) * (1 + 4 * t * t * t + 3 * t * t)
                }
                pop.timingFunction = CAMediaTimingFunction(name: .linear)
                pop.duration = 0.3; check.add(pop, forKey: "orbit.checkPop")
            }
            check.backgroundColor = BrandPalette.controlAccent.cgColor
            if check.sublayers?.isEmpty != false {
                let tick = CAShapeLayer(); let path = CGMutablePath()
                path.move(to: CGPoint(x: 6, y: 13.5)); path.addLine(to: CGPoint(x: 12, y: 19.5)); path.addLine(to: CGPoint(x: 21, y: 9))
                tick.path = path; tick.strokeColor = NSColor.white.cgColor; tick.fillColor = nil; tick.lineWidth = 1.8
                check.addSublayer(tick)
            }
            button.setAccessibilityLabel(site.title + ", " + hint)
            button.setAccessibilityValue(site.selected ? 1 : 0)
        }
        pins.subviews.forEach { $0.removeFromSuperview() }
        let selected = sites.filter(\.selected)
        let rows = max(2, Int(ceil(Double(selected.count) / 3)))
        pins.setFrameSize(NSSize(width: 216, height: CGFloat(rows) * 40 + 8))
        pins.layer?.sublayers?.first?.frame = pins.bounds
        setFrameSize(NSSize(width: 474, height: max(200, CGFloat((sites.count + 3) / 4) * 99.08)))
        for i in 0..<max(6, Int(ceil(Double(selected.count) / 3)) * 3) {
            let pin = NSTextField(labelWithString: i < selected.count ? String(selected[i].title.prefix(1)) : "")
            pin.alignment = .center; pin.font = OrbitOnboardingFonts.ui(14, weight: .bold)
            pin.textColor = .white
            pin.frame = NSRect(x: 7 + CGFloat(i % 3) * 69, y: 7 + CGFloat(i / 3) * 40, width: 63, height: 34)
            pin.wantsLayer = true; pin.layer?.cornerRadius = 8
            pin.layer?.backgroundColor = NSColor.white.withAlphaComponent(i < selected.count ? 0.22 : 0.1).cgColor
            pins.addSubview(pin)
        }
    }
    @objc private func toggle(_ sender: NSButton) { onToggle?(sender.tag); OrbitOnboardingMotion.pop(sender, from: 0.88, duration: 0.35) }
}

@MainActor
private final class OrbitOnboardingFavouriteButton: NSButton {
    var isSelectedTile = false { didSet { refreshSurface() } }
    private var isHovered = false
    private var tracking: NSTrackingArea?
    let outline = CAShapeLayer()
    let artwork = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let hintField = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        wantsLayer = true
        outline.fillColor = nil; outline.strokeColor = BrandPalette.ink.cgColor; outline.lineWidth = 3.16
        layer?.addSublayer(outline)
        artwork.frame = NSRect(x: (frame.width - 37.9) / 2, y: (frame.height - 37.9) / 2, width: 37.9, height: 37.9)
        nameField.frame = NSRect(x: 8, y: 49, width: frame.width - 16, height: 17)
        nameField.font = OrbitOnboardingFonts.ui(12)
        nameField.textColor = BrandPalette.ink
        hintField.frame = NSRect(x: 8, y: 68, width: frame.width - 16, height: 14)
        hintField.font = OrbitOnboardingFonts.mono(10)
        hintField.textColor = BrandPalette.ink3
        for field in [nameField, hintField] {
            field.isHidden = true
            field.alignment = .center
            field.lineBreakMode = .byTruncatingMiddle
            field.setAccessibilityElement(false)
        }
        artwork.setAccessibilityElement(false)
        for child in [artwork, nameField, hintField] { addSubview(child) }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    private func refreshSurface() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = BrandPalette.pageWhite.withAlphaComponent(isSelectedTile || isHovered ? 1 : 0.6).cgColor
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    private func hover(_ value: Bool) {
        let previous = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        isHovered = value; refreshSurface()
        guard !OrbitMotionPreferences.prefersReducedMotion else { return }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = previous; fade.toValue = layer?.backgroundColor
        fade.duration = 0.15; fade.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        layer?.add(fade, forKey: "orbit.favouriteHover")
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
}
