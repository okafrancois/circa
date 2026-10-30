import AppKit
import BrowserShell

/// A noninteractive explanation; only the service can invoke the system request.
@MainActor
final class OrbitOnboardingPromptMock: NSView {
    private let yes = NSTextField(labelWithString: uiText("Use Circa"))
    private let material = NSVisualEffectView()
    private let tint = CALayer()
    private let highlight = CAGradientLayer()
    private let top = CALayer()
    private let observers = OrbitWorkspaceObservers()
    private var appearanceObservation: NSKeyValueObservation?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.shadowColor = OrbitOnboardingColors.title.cgColor
        layer?.shadowOpacity = BrandPalette.Frost.shadowOpacity; layer?.shadowRadius = BrandPalette.Frost.shadowRadius; layer?.shadowOffset = BrandPalette.Frost.shadowOffset
        material.frame = bounds
        material.material = BrandPalette.Frost.material; material.blendingMode = .withinWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 16; material.layer?.masksToBounds = true
        addSubview(material)
        tint.frame = bounds
        tint.cornerRadius = 16; tint.borderWidth = 1
        let tintView = NSView(frame: bounds)
        tintView.wantsLayer = true
        tintView.layer?.cornerRadius = 16
        tintView.layer?.masksToBounds = true
        tintView.layer?.addSublayer(tint)
        addSubview(tintView)
        highlight.frame = bounds
        highlight.locations = [0, BrandPalette.Frost.highlightEnd]; highlight.startPoint = CGPoint(x: 0, y: 1); highlight.endPoint = CGPoint(x: 1, y: 0)
        tintView.layer?.addSublayer(highlight)
        top.frame = CGRect(x: 12, y: bounds.height - 1.5, width: bounds.width - 24, height: 1.5)
        tintView.layer?.addSublayer(top)
        let title = NSTextField(wrappingLabelWithString: uiText("Make Circa your default browser?"))
        title.font = BrandTextStyle.ui.font(size: 15, weight: .semibold); title.alignment = .center
        title.frame = NSRect(x: 20, y: 76, width: 260, height: 42)
        addSubview(title)
        let mark = OrbitOnboardingMarkView(frame: NSRect(x: 124, y: 22, width: 52, height: 39))
        addSubview(mark)
        yes.font = OrbitOnboardingFonts.ui(13, weight: .semibold); yes.alignment = .center
        yes.frame = NSRect(x: 18, y: 144, width: 264, height: 28)
        yes.wantsLayer = true; yes.layer?.backgroundColor = OrbitOnboardingColors.accent.cgColor
        yes.layer?.cornerRadius = 8; yes.textColor = .white
        addSubview(yes)
        let no = NSTextField(labelWithString: uiText("Keep current browser"))
        no.font = OrbitOnboardingFonts.ui(12); no.alignment = .center
        no.frame = NSRect(x: 18, y: 184, width: 264, height: 22)
        addSubview(no)
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMaterial() }
        }
        observers.tokens.append((center, token))
        // The onboarding stage has fixed chrome; this system-prompt preview follows the app.
        appearance = NSApp.effectiveAppearance
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            MainActor.assumeIsolated {
                self?.appearance = app.effectiveAppearance
                self?.refreshMaterial()
            }
        }
        refreshMaterial()
        setAccessibilityElement(true)
        setAccessibilityLabel(uiText("Preview of the macOS default browser confirmation"))
    }
    required init?(coder: NSCoder) { nil }
    func refreshAccent() { yes.layer?.backgroundColor = BrandPalette.controlAccent.cgColor }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMaterial()
    }
    func refreshMaterial(reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        material.isHidden = reduceTransparency
        material.state = reduceTransparency ? .inactive : .active
        tint.backgroundColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(reduceTransparency ? 1 : BrandPalette.Frost.tint).cgColor
        tint.borderColor = NSColor.white.withAlphaComponent(BrandPalette.Frost.edge(dark: dark)).cgColor
        highlight.colors = [NSColor.white.withAlphaComponent(BrandPalette.Frost.highlight(dark: dark)).cgColor, NSColor.clear.cgColor]
        highlight.isHidden = reduceTransparency
        top.backgroundColor = NSColor.white.withAlphaComponent(BrandPalette.Frost.top(dark: dark)).cgColor
        CATransaction.commit()
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
