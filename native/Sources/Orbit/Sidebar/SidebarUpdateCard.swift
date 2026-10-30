import AppKit

/// Sidebar notice metrics: 12 pt corners, 12 pt content inset, 16 pt icon,
/// 13 pt semibold title, 12 pt body and 14 pt body line height.
@MainActor
final class SidebarUpdateCard: NSView {
    static let height: CGFloat = 126
    private let outline = CAShapeLayer()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: uiText("An update is ready!"))
    private let body = NSTextField(labelWithString: uiText("Click to restart"))
    let restart = NSButton(title: uiText("Restart and Update"), target: nil, action: nil)
    var onRestart: (() -> Void)?
    var accent = OrbitTokens.ThemeAccent.defaultPurple { didSet { refreshColors() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        OrbitFloatingMaterial.install(in: self)
        layer?.addSublayer(outline)
        outline.lineWidth = 1
        outline.lineDashPattern = [4, 3]
        icon.image = OrbitIcon.image(sfName: "arrow.down.circle.fill", pointSize: 16, accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        body.font = .systemFont(ofSize: 12)
        title.alignment = .center; body.alignment = .center
        title.lineBreakMode = .byTruncatingTail; body.lineBreakMode = .byTruncatingTail
        restart.bezelStyle = .rounded
        restart.font = .systemFont(ofSize: 12, weight: .semibold)
        restart.target = self; restart.action = #selector(performRestart)
        restart.setAccessibilityIdentifier("sidebar-restart-update")
        for view in [icon, title, body, restart] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("An update is ready!"))
        refreshColors()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    private func refreshColors() {
        let foreground = OrbitFloatingMaterial.body
        effectiveAppearance.performAsCurrentDrawingAppearance {
            outline.strokeColor = foreground.withAlphaComponent(0.24).cgColor
            outline.fillColor = foreground.withAlphaComponent(0.035).cgColor
        }
        title.textColor = foreground
        body.textColor = OrbitFloatingMaterial.secondary
        icon.contentTintColor = foreground
        restart.contentTintColor = .controlAccentColor
    }
    override func layout() {
        super.layout()
        outline.frame = bounds
        outline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 12, cornerHeight: 12, transform: nil)
        icon.frame = NSRect(x: (bounds.width - 16) / 2, y: 12, width: 16, height: 16)
        title.frame = NSRect(x: 12, y: 34, width: max(0, bounds.width - 24), height: 17)
        body.frame = NSRect(x: 12, y: 54, width: max(0, bounds.width - 24), height: 16)
        restart.frame = NSRect(x: 12, y: 82, width: max(0, bounds.width - 24), height: 28)
    }
    @objc private func performRestart() { onRestart?() }
}
