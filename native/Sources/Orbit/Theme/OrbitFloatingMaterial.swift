import AppKit
import BrowserShell

/// Public AppKit material and a bounded tint keep floating content readable even when
/// the backdrop is completely black or white. The tint is independent of Space colours.
@MainActor
enum OrbitFloatingMaterial {
    enum Variant: CaseIterable { case light, dark }

    @MainActor
    struct Style {
        let variant: Variant
        let reducesTransparency: Bool
        var selectedSidebarSurface = false
        var sidebarTintOpacity: CGFloat?
        var tintOpacity: CGFloat { reducesTransparency ? 1 : (sidebarTintOpacity ?? (variant == .light ? (selectedSidebarSurface ? 0.72 : 0.64) : 0.76)) }
        var tint: NSColor { variant == .light ? .white : NSColor(srgbRed: 14/255, green: 14/255, blue: 17/255, alpha: 1) }
        var body: NSColor { variant == .light ? NSColor(srgbRed: 20/255, green: 19/255, blue: 23/255, alpha: 1) : NSColor(white: 0.97, alpha: 1) }
        var secondary: NSColor { variant == .light ? NSColor(srgbRed: 55/255, green: 52/255, blue: 62/255, alpha: 1) : NSColor(srgbRed: 208/255, green: 205/255, blue: 214/255, alpha: 1) }
        var edge: NSColor { NSColor.white.withAlphaComponent(variant == .light ? 0.75 : 0.18) }
        var highlightOpacity: CGFloat { variant == .light ? 0.12 : 0.04 }

        /// Conservative contrast: ignore any extra protection provided by the system blur.
        func background(over backdrop: NSColor, highlight: Bool = false) -> NSColor {
            let base = OrbitFloatingMaterial.composite(tint, opacity: tintOpacity, over: backdrop)
            return highlight && !reducesTransparency
                ? OrbitFloatingMaterial.composite(.white, opacity: highlightOpacity, over: base) : base
        }
    }

    static func style(for appearance: NSAppearance, reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) -> Style {
        Style(variant: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light,
              reducesTransparency: reduceTransparency)
    }

    static let body = NSColor(name: "Orbit.Floating.body") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.97, alpha: 1) : NSColor(srgbRed: 20/255, green: 19/255, blue: 23/255, alpha: 1)
    }
    static let secondary = NSColor(name: "Orbit.Floating.secondary") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 208/255, green: 205/255, blue: 214/255, alpha: 1)
            : NSColor(srgbRed: 55/255, green: 52/255, blue: 62/255, alpha: 1)
    }

    static let accentText = NSColor(name: "Orbit.Floating.accentText") { _ in
        contrastingInk(on: .controlAccentColor)
    }

    nonisolated static func contrastingInk(on fill: NSColor) -> NSColor {
        contrast(.black, fill) >= contrast(.white, fill) ? .black : .white
    }

    static func composite(_ foreground: NSColor, opacity: CGFloat, over background: NSColor) -> NSColor {
        let f = foreground.usingColorSpace(.sRGB)!, b = background.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: f.redComponent * opacity + b.redComponent * (1 - opacity),
                       green: f.greenComponent * opacity + b.greenComponent * (1 - opacity),
                       blue: f.blueComponent * opacity + b.blueComponent * (1 - opacity), alpha: 1)
    }

    nonisolated static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB)!
            func linear(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @discardableResult
    static func install(in view: NSView, blending: NSVisualEffectView.BlendingMode = .withinWindow, radius: CGFloat = 12) -> OrbitFrostView {
        if let existing = view.subviews.first(where: { $0 is OrbitFrostView }) as? OrbitFrostView { return existing }
        let frost = OrbitFrostView(frame: view.bounds, blending: blending, radius: radius)
        frost.autoresizingMask = [.width, .height]
        view.addSubview(frost, positioned: .below, relativeTo: nil)
        return frost
    }

    /// Keep the material polarity tied to the same painted fill as sidebar ink.
    static func sidebarInk(_ accent: OrbitTokens.ThemeAccent) -> OrbitTokens.ThemeAccent {
        guard let theme = accent.contrastTheme, theme.frostAmount > 0 else { return accent }
        var result = accent
        let ink = NSColor(name: nil) { appearance in
            MainActor.assumeIsolated {
                let variant: Variant = OrbitThemeForeground.isLight(on: accent.foreground.resolved(for: appearance)) ? .light : .dark
                return Style(variant: variant, reducesTransparency: false).body
            }
        }
        result.sidebarText = ink
        result.icon = ink
        return result
    }

    static func alert() -> NSAlert {
        let alert = OrbitFrostAlert()
        alert.window.isOpaque = false
        alert.window.backgroundColor = .clear
        if let content = alert.window.contentView {
            install(in: content, blending: .behindWindow)
        }
        return alert
    }
}

/// Constructed before presentation; appearance/accessibility changes update layers without
/// swapping the content tree or disturbing the surface's existing transition.
@MainActor
final class OrbitFrostView: NSView {
    let effect = NSVisualEffectView()
    private let tint = NSView()
    private let highlight = CAGradientLayer()
    private let observers = OrbitWorkspaceObservers()
    var sidebarTheme: OrbitTokens.SpaceTheme? { didSet { if sidebarTheme != oldValue { refresh() } } }
    var sidebarForeground: NSColor? { didSet { refresh() } }
    var selectedSidebarSurface = false { didSet { refresh() } }
    var fixedVariant: OrbitFloatingMaterial.Variant? { didSet { refresh() } }
    private(set) var style: OrbitFloatingMaterial.Style!

    init(frame: NSRect = .zero, blending: NSVisualEffectView.BlendingMode = .withinWindow, radius: CGFloat = 12) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        effect.material = .hudWindow
        effect.blendingMode = blending
        effect.state = .active
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        effect.wantsLayer = true
        tint.wantsLayer = true
        tint.layer?.addSublayer(highlight)
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
        tint.frame = bounds
        highlight.frame = bounds
        highlight.startPoint = CGPoint(x: 0, y: 0)
        highlight.endPoint = CGPoint(x: 0.65, y: 0.75)
        layer?.borderWidth = 1
        setAccessibilityElement(false)
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.tokens.append((center, token))
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.frame = bounds; highlight.frame = bounds
        CATransaction.commit()
    }
    func refresh(reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) {
        let appearance = fixedVariant.map { NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)! } ?? effectiveAppearance
        style = OrbitFloatingMaterial.style(for: appearance, reduceTransparency: reduceTransparency)
        if let sidebarForeground {
            style = .init(variant: OrbitThemeForeground.isLight(on: sidebarForeground.resolved(for: appearance)) ? .light : .dark,
                          reducesTransparency: reduceTransparency, selectedSidebarSurface: selectedSidebarSurface)
        }
        if let sidebarTheme {
            style.sidebarTintOpacity = OrbitSidebarFrost.opacity(theme: sidebarTheme, appearance: appearance, style: style)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // A Space can choose light ink in a light window (or the reverse). The blur must
        // reinforce that ink polarity before the minimal per-gradient tint is applied.
        effect.appearance = sidebarTheme == nil ? appearance
            : NSAppearance(named: style.variant == .dark ? .darkAqua : .aqua)
        effect.state = reduceTransparency ? .inactive : .active
        effect.isHidden = reduceTransparency
        tint.layer?.backgroundColor = style.tint.withAlphaComponent(style.tintOpacity).cgColor
        highlight.colors = [NSColor.white.withAlphaComponent(style.highlightOpacity).cgColor, NSColor.clear.cgColor]
        highlight.isHidden = reduceTransparency
        layer?.borderColor = style.edge.cgColor
        CATransaction.commit()
    }
}

/// Native popover geometry/animation remain AppKit-owned; the content gets the same
/// material before AppKit begins its presentation.
@MainActor
final class OrbitFrostPopover: NSPopover {
    var usesFrost = true
    override func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        if usesFrost, let content = contentViewController?.view {
            OrbitFloatingMaterial.install(in: content, blending: .behindWindow, radius: 0)
        }
        super.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
    }
}

/// Builds a local panel from public NSAlert content so the shared background is
/// present in the window actually displayed. Button titles, accessory views and response
/// codes still come from NSAlert; AppKit owns modal and sheet presentation.
@MainActor
final class OrbitFrostAlert: NSAlert {
    private var localPanel: OrbitFloatingAlertPanel?
    override var window: NSWindow { localPanel ?? super.window }

    func preparedWindow(for parent: NSWindow? = nil) -> NSWindow {
        if let localPanel { return localPanel }
        super.layout()
        let source = super.window
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 64).isActive = true
        image.heightAnchor.constraint(equalToConstant: 64).isActive = true
        content.addArrangedSubview(image)
        let title = NSTextField(wrappingLabelWithString: messageText)
        title.font = BrandTextStyle.title.font(size: 22)
        title.textColor = OrbitFloatingMaterial.body
        content.addArrangedSubview(title)
        if !informativeText.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: informativeText)
            detail.font = BrandTextStyle.body.font(size: 13)
            detail.textColor = OrbitFloatingMaterial.secondary
            content.addArrangedSubview(detail)
        }
        let accessoryWidth = max(accessoryView?.fittingSize.width ?? 0, accessoryView?.frame.width ?? 0)
        if let accessoryView { content.addArrangedSubview(accessoryView) }
        if showsSuppressionButton, let suppressionButton {
            suppressionButton.font = BrandTextStyle.ui.font(size: 13)
            content.addArrangedSubview(suppressionButton)
        }
        let row = NSStackView(views: Array(buttons.reversed()))
        row.orientation = .horizontal
        row.spacing = 8
        for button in buttons {
            button.font = BrandTextStyle.ui.font(size: 13)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        content.addArrangedSubview(row)
        let width = max(420, accessoryWidth + 40, row.fittingSize.width + 40)
        content.widthAnchor.constraint(equalToConstant: width).isActive = true
        for child in content.arrangedSubviews where child !== image {
            child.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let panel = OrbitFloatingAlertPanel(contentRect: NSRect(origin: .zero, size: size),
                                            styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.animationBehavior = source.animationBehavior
        panel.followAppearance(of: parent, fallback: source.appearance)
        content.frame = NSRect(origin: .zero, size: size)
        panel.contentView = content
        panel.initialFirstResponder = source.initialFirstResponder
        panel.defaultButtonCell = buttons.first?.cell as? NSButtonCell
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.masksToBounds = true
        content.setAccessibilityRole(.group)
        content.setAccessibilitySubrole(.dialog)
        content.setAccessibilityLabel(messageText)
        OrbitFloatingMaterial.install(in: content, blending: .behindWindow)
        for (index, button) in buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(choose(_:))
        }
        buttons.first?.bezelColor = .controlAccentColor
        buttons.first?.contentTintColor = OrbitFloatingMaterial.accentText
        localPanel = panel
        return panel
    }

    override func runModal() -> NSApplication.ModalResponse {
        let panel = preparedWindow()
        panel.center()
        let response = NSApplication.shared.runModal(for: panel)
        panel.orderOut(nil)
        return response
    }

    override func beginSheetModal(for sheetWindow: NSWindow,
                                 completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        sheetWindow.beginSheet(preparedWindow(for: sheetWindow)) { [self] response in
            handler?(response)
            withExtendedLifetime(self) {}
        }
    }

    @objc private func choose(_ sender: NSButton) {
        let panel = window
        let response = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag)
        if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: response) }
        else { NSApplication.shared.stopModal(withCode: response) }
        panel.orderOut(nil)
    }
}

@MainActor
private final class OrbitFloatingAlertPanel: NSPanel {
    private var appearanceObservation: NSKeyValueObservation?

    func followAppearance(of parent: NSWindow?, fallback: NSAppearance?) {
        appearance = parent?.effectiveAppearance ?? fallback
        appearanceObservation = parent?.observe(\.effectiveAppearance, options: [.new]) { [weak self] parent, _ in
            MainActor.assumeIsolated { self?.appearance = parent.effectiveAppearance }
        }
    }

    override var canBecomeKey: Bool { true }
}
