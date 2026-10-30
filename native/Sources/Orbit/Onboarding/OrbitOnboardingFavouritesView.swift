import AppKit
import BrowserCore
import BrowserShell

@MainActor
final class OrbitOnboardingFavouritesView: NSView {
    var onToggle: ((Int) -> Void)?
    private var checks: [CALayer] = []
    private var buttons: [OrbitOnboardingFavouriteButton] = []
    private let pins = OrbitOnboardingFlippedView(frame: NSRect(x: 0, y: 210, width: 216, height: 88))
    init(sites: [BrowserOnboardingFavourite]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 512, height: 300))
        wantsLayer = true
        pins.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = pins.bounds
        gradient.colors = BrandPalette.sidebarPreviewColors
        gradient.startPoint = CGPoint(x: 0, y: 0); gradient.endPoint = CGPoint(x: 1, y: 1)
        gradient.cornerRadius = 12
        pins.layer?.addSublayer(gradient)
        pins.layer?.cornerRadius = 12
        addSubview(pins)
        let hint = NSTextField(wrappingLabelWithString: uiText("how it looks in the sidebar"))
        hint.font = OrbitOnboardingFonts.mono(12); hint.textColor = BrandPalette.ink3
        hint.frame = NSRect(x: 230, y: 238, width: 250, height: 36); addSubview(hint)
        for index in sites.indices {
            let button = OrbitOnboardingFavouriteButton(frame: NSRect(x: CGFloat(index % 4) * 130.5, y: CGFloat(index / 4) * 102, width: 120.5, height: 92))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 14
            button.layer?.backgroundColor = NSColor.white.cgColor
            let check = CALayer(); check.frame = CGRect(x: 94.5, y: 8, width: 18, height: 18)
            check.cornerRadius = 9
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
        for (index, site) in sites.enumerated() where buttons.indices.contains(index) {
            let button = buttons[index]
            let color = BrandPalette.siteColors[index % BrandPalette.siteColors.count]
            button.artwork.image = NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
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
            button.layer?.borderWidth = site.selected ? 1.5 : 1
            button.layer?.borderColor = (site.selected ? OrbitOnboardingColors.accent : OrbitOnboardingColors.optionBorder).cgColor
            checks[index].backgroundColor = (site.selected ? BrandPalette.controlAccent : .white).cgColor
            checks[index].borderWidth = site.selected ? 0 : 1.5
            checks[index].borderColor = BrandPalette.controlBorder.cgColor
            checks[index].sublayers?.forEach { $0.removeFromSuperlayer() }
            if site.selected {
                let tick = CAShapeLayer(); let path = CGMutablePath()
                path.move(to: CGPoint(x: 4, y: 9)); path.addLine(to: CGPoint(x: 8, y: 13)); path.addLine(to: CGPoint(x: 14, y: 6))
                tick.path = path; tick.strokeColor = NSColor.white.cgColor; tick.fillColor = nil; tick.lineWidth = 1.8
                checks[index].addSublayer(tick)
            }
            button.setAccessibilityLabel(site.title + ", " + hint)
            button.setAccessibilityValue(site.selected ? 1 : 0)
        }
        pins.subviews.forEach { $0.removeFromSuperview() }
        let selected = sites.filter(\.selected)
        let rows = max(2, Int(ceil(Double(selected.count) / 3)))
        pins.setFrameSize(NSSize(width: 216, height: CGFloat(rows) * 40 + 8))
        pins.layer?.sublayers?.first?.frame = pins.bounds
        setFrameSize(NSSize(width: 512, height: max(300, pins.frame.maxY)))
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
    @objc private func toggle(_ sender: NSButton) { onToggle?(sender.tag) }
}

@MainActor
private final class OrbitOnboardingFavouriteButton: NSButton {
    let artwork = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let hintField = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        artwork.frame = NSRect(x: (frame.width - 30) / 2, y: 10, width: 30, height: 30)
        nameField.frame = NSRect(x: 8, y: 49, width: frame.width - 16, height: 17)
        nameField.font = OrbitOnboardingFonts.ui(12)
        nameField.textColor = BrandPalette.ink
        hintField.frame = NSRect(x: 8, y: 68, width: frame.width - 16, height: 14)
        hintField.font = OrbitOnboardingFonts.mono(10)
        hintField.textColor = BrandPalette.ink3
        for field in [nameField, hintField] {
            field.alignment = .center
            field.lineBreakMode = .byTruncatingMiddle
            field.setAccessibilityElement(false)
        }
        artwork.setAccessibilityElement(false)
        for child in [artwork, nameField, hintField] { addSubview(child) }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
}
