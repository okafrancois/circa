import AppKit
import QuartzCore

/// One inline row; meeting data is discarded when its runtime binding changes.
@MainActor
final class CalendarReminderView: NSView {
    private let title = NSTextField(labelWithString: "")
    let join = CalendarJoinButton(title: "", target: nil, action: nil)
    private let joinLabel = NSTextField(labelWithString: uiText("Join"))
    private let check = NSImageView()
    private var identity: String?
    private var joined = false
    var onJoin: (() -> Bool)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = OrbitTokens.Typography.sidebarTabTitle
        title.lineBreakMode = .byTruncatingTail; title.maximumNumberOfLines = 1
        addSubview(title)
        join.isBordered = false; join.wantsLayer = true; join.layer?.cornerRadius = 4
        join.font = .systemFont(ofSize: 11, weight: .semibold)
        join.contentTintColor = .white
        join.target = self; join.action = #selector(activate)
        join.setAccessibilityIdentifier("calendar-join")
        addSubview(join)
        joinLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        joinLabel.textColor = .white; joinLabel.alignment = .center; joinLabel.wantsLayer = true
        join.addSubview(joinLabel)
        join.setAccessibilityLabel(uiText("Join"))
        check.image = OrbitIcon.image(sfName: "checkmark", pointSize: 12)
        check.contentTintColor = .white; check.alphaValue = 0
        join.addSubview(check)
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    func render(id: String?, title value: String?, action: (() -> Bool)?) {
        if identity != id {
            identity = id; joined = false; joinLabel.alphaValue = 1; check.alphaValue = 0; check.layer?.mask = nil
            joinLabel.layer?.removeAllAnimations(); join.setAccessibilityLabel(uiText("Join"))
            join.alphaValue = 1; join.isEnabled = true
        }
        title.stringValue = value.map { ($0.first?.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) == true ? "" : "📅 ") + $0 } ?? ""
        onJoin = action
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        title.textColor = OrbitTokens.Color.Text.primary
    }
    override func layout() {
        super.layout()
        title.frame = .init(x: 8, y: 8, width: max(0, bounds.width - 58), height: 18)
        join.frame = .init(x: bounds.width - 44, y: 8, width: 38, height: 20)
        joinLabel.frame = .init(x: 0, y: 2, width: join.bounds.width, height: 16)
        check.frame = join.bounds.insetBy(dx: 12, dy: 4)
    }
    @objc private func activate() {
        guard !joined, onJoin?() == true else { return }
        joined = true; join.isEnabled = false
        let id = identity
        let shrink = CABasicAnimation(keyPath: "transform")
        let center = CGPoint(x: joinLabel.bounds.midX, y: joinLabel.bounds.midY)
        let centered = CATransform3DTranslate(CATransform3DMakeScale(0.1, 0.1, 1), center.x * 9, center.y * 9, 0)
        shrink.fromValue = CATransform3DIdentity; shrink.toValue = centered; shrink.duration = 0.16
        joinLabel.layer?.add(shrink, forKey: "calendar.joinLabel")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            joinLabel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.identity == id, self.joined else { return }
                self.join.setAccessibilityLabel(uiText("Joined"))
                self.check.wantsLayer = true
                let mask = CALayer(); mask.anchorPoint = .zero; mask.position = .zero
                mask.bounds = self.check.bounds; mask.backgroundColor = NSColor.white.cgColor
                self.check.layer?.mask = mask
                let reveal = CABasicAnimation(keyPath: "bounds.size.width")
                reveal.fromValue = 0; reveal.toValue = self.check.bounds.width; reveal.duration = 0.14
                mask.add(reveal, forKey: "calendar.checkReveal")
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    self.check.animator().alphaValue = 1
                }
            }
        })
    }
}

@MainActor
final class CalendarJoinButton: NSButton {
    private var hovered = false
    private var tracking: NSTrackingArea?
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        let fill = OrbitTokens.Color.Calendar.join
        fill.blended(withFraction: 0.25, of: .black)?.setFill()
        NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
        (hovered || isHighlighted ? fill.blended(withFraction: 0.12, of: .black) ?? fill : fill).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}
