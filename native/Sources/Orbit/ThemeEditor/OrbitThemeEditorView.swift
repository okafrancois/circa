import AppKit
import BrowserCore
import QuartzCore

private typealias M = OrbitThemeEditorMetrics

@MainActor
private enum OrbitThemeEditorColors {
    static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("Orbit.ThemeEditor." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static let field = dynamic("field", light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 0, alpha: 0.04))
    static let dot = dynamic("dot", light: NSColor(white: 0, alpha: 0.12), dark: NSColor(white: 1, alpha: 0.16))
    static let modeHighlight = dynamic("modeHighlight", light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.15))
    static let track = dynamic("track", light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.07))
    static let waveActive = dynamic("waveActive", light: NSColor(white: 0, alpha: 0.30), dark: NSColor(white: 1, alpha: 0.75))
    static let control = OrbitTokens.Color.Text.secondary
    static let inactive = dynamic("inactive", light: NSColor(white: 0, alpha: 0.16), dark: NSColor(white: 1, alpha: 0.16))
    static let swatchRing = OrbitTokens.Color.Text.primary
}

/// Orbit's theme editor content: a 356 × 508 flipped view laid out from geometry.
/// It renders `state` and reports every user edit through `onChange`; the controller owns the draft.
@MainActor
final class OrbitThemeEditorView: NSView {
    var state: OrbitThemeEditorState { didSet { if state != oldValue { render() } } }
    var onChange: ((OrbitThemeEditorState) -> Void)?
    var onDismiss: (() -> Void)?

    let surfaceScope = NSTextField(labelWithString: uiText("This Space · captured profile"))
    let material = NSVisualEffectView()
    let field = OrbitThemeFieldView()
    let placeholder = NSTextField(labelWithString: "")
    let modeHighlight = CALayer()
    private(set) var modeButtons: [OrbitThemeEditorButton] = []
    let removeButton = OrbitThemeEditorButton(symbol: "minus")
    let addButton = OrbitThemeEditorButton(symbol: "plus")
    let previousButton = OrbitThemeEditorButton(symbol: "chevron.left")
    let nextButton = OrbitThemeEditorButton(symbol: "chevron.right")
    private(set) var swatches: [OrbitThemeSwatchButton] = []
    let intensitySlider = OrbitThemeWaveSlider()
    let grainDial = OrbitThemeGrainDial()
    private(set) var handles: [OrbitThemeHandleView] = []
    static let modes: [BrowserSpaceTheme.Mode] = [.automatic, .light, .dark]

    init(state: OrbitThemeEditorState) {
        self.state = state
        super.init(frame: NSRect(origin: .zero, size: M.size))
        wantsLayer = true
        layer?.cornerRadius = M.cornerRadius
        layer?.masksToBounds = true
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.frame = bounds
        material.autoresizingMask = [.width, .height]
        addSubview(material)

        field.frame = M.field
        field.onPick = { [weak self] unit in self?.edit { $0.pick(at: unit) } }
        field.onDrag = { [weak self] unit in
            self?.edit { state in if let index = state.selectedIndex { state.move(handle: index, to: unit) } }
        }
        field.onNudge = { [weak self] hue, saturation in
            self?.edit { state in
                if let index = state.selectedIndex { state.nudge(handle: index, hueDegrees: hue, saturation: saturation) }
            }
        }
        addSubview(field)

        placeholder.font = M.placeholderFont
        placeholder.alignment = .center
        placeholder.textColor = OrbitTokens.Color.Text.primary
        addSubview(placeholder)

        modeHighlight.cornerRadius = M.modeHighlightRadius
        layer?.addSublayer(modeHighlight)
        let symbols = ["sparkles", "sun.max.fill", "moon.stars"]
        modeButtons = Self.modes.indices.map { index in
            let button = OrbitThemeEditorButton(symbol: symbols[index], pointSize: M.modeGlyphPointSize)
            button.onPress = { [weak self] in self?.edit { $0.setMode(Self.modes[index]) } }
            return button
        }
        for (button, label) in zip(modeButtons, [OrbitThemeEditorText.automatic, OrbitThemeEditorText.light, OrbitThemeEditorText.dark]) {
            button.setAccessibilityLabel(label)
            button.toolTip = label
            addSubview(button)
        }

        removeButton.setAccessibilityLabel(OrbitThemeEditorText.removeColor)
        removeButton.onPress = { [weak self] in self?.edit { $0.removeColor() } }
        addButton.setAccessibilityLabel(OrbitThemeEditorText.addColor)
        addButton.onPress = { [weak self] in self?.edit { $0.addColor() } }
        previousButton.setAccessibilityLabel(OrbitThemeEditorText.previousColors)
        previousButton.onPress = { [weak self] in self?.edit { $0.showFamily(offset: -1) } }
        nextButton.setAccessibilityLabel(OrbitThemeEditorText.nextColors)
        nextButton.onPress = { [weak self] in self?.edit { $0.showFamily(offset: 1) } }
        for button in [removeButton, addButton, previousButton, nextButton] { addSubview(button) }

        swatches = (0..<9).map { index in
            let swatch = OrbitThemeSwatchButton()
            swatch.onPress = { [weak self] in self?.edit { $0.chooseSwatch(index) } }
            addSubview(swatch)
            return swatch
        }

        intensitySlider.setAccessibilityLabel(OrbitThemeEditorText.intensity)
        intensitySlider.onChange = { [weak self] value in self?.edit { $0.setIntensity(value) } }
        grainDial.setAccessibilityLabel(OrbitThemeEditorText.grain)
        grainDial.onChange = { [weak self] value in self?.edit { $0.setNoise(value) } }
        addSubview(intensitySlider)
        addSubview(grainDial)

        surfaceScope.frame = NSRect(x: 20, y: 494, width: 316, height: 18)
        surfaceScope.font = .systemFont(ofSize: 11, weight: .semibold)
        surfaceScope.lineBreakMode = .byTruncatingTail
        surfaceScope.toolTip = surfaceScope.stringValue
        addSubview(surfaceScope)
        setAccessibilityElement(true)
        setAccessibilityRole(.popover)
        setAccessibilityLabel(OrbitThemeEditorText.title)
        layoutControls()
        render()
    }

    /// The compact picker opens at the color controls; the scope label remains scrollable.
    func makePickerViewport() -> NSScrollView {
        // The native popover supplies its own material. Avoid compositing it twice.
        material.isHidden = true
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: M.pickerSize))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = self
        scroll.contentView.scroll(to: .zero)
        return scroll
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    private func edit(_ change: (inout OrbitThemeEditorState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    private func layoutControls() {
        func centered(_ size: NSSize, at center: CGPoint) -> NSRect {
            NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }
        for (button, x) in zip(modeButtons, M.modeCenterXs) {
            button.frame = centered(M.modeHighlight, at: CGPoint(x: x, y: M.modeCenterY))
        }
        removeButton.frame = centered(M.stepperSize, at: CGPoint(x: M.stepperCenterXs[0], y: M.stepperCenterY))
        addButton.frame = centered(M.stepperSize, at: CGPoint(x: M.stepperCenterXs[1], y: M.stepperCenterY))
        previousButton.frame = centered(M.stepperSize, at: CGPoint(x: M.chevronCenterXs[0], y: M.swatchRowCenterY))
        nextButton.frame = centered(M.stepperSize, at: CGPoint(x: M.chevronCenterXs[1], y: M.swatchRowCenterY))
        let swatchSide = M.swatchDiameter + 2 * (M.swatchRing + 1.5)
        for (index, swatch) in swatches.enumerated() {
            swatch.frame = centered(NSSize(width: swatchSide, height: swatchSide), at: M.swatchCenter(index))
        }
        let placeholderHeight = ceil(M.placeholderFont.ascender - M.placeholderFont.descender + M.placeholderFont.leading) + 2
        placeholder.frame = NSRect(x: M.field.minX + 12, y: M.placeholderCenterY - placeholderHeight / 2,
                                   width: M.field.width - 24, height: placeholderHeight)
        intensitySlider.frame = NSRect(x: M.sliderTrackX.lowerBound, y: M.controlRowCenterY - M.sliderThumb.height / 2,
                                       width: M.sliderTrackX.upperBound - M.sliderTrackX.lowerBound, height: M.sliderThumb.height)
        let dialSide = 2 * (M.dialRadius + 4)
        grainDial.frame = centered(NSSize(width: dialSide, height: dialSide), at: CGPoint(x: M.dialCenterX, y: M.controlRowCenterY))
    }

    /// Projects `state`; also called when the appearance changes (layer colours are resolved).
    func render() {
        let appearance = effectiveAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let modeIndex = Self.modes.firstIndex(of: state.theme.mode) ?? 0
        let selected = modeButtons[modeIndex].frame
        modeHighlight.frame = selected
        modeHighlight.backgroundColor = OrbitThemeEditorColors.modeHighlight.resolvedCGColor(for: appearance)
        CATransaction.commit()
        for (index, button) in modeButtons.enumerated() {
            button.state = index == modeIndex ? .on : .off
            button.tint = OrbitThemeEditorColors.control
        }
        placeholder.stringValue = OrbitThemeEditorText.placeholder
        placeholder.isHidden = state.hasColor
        removeButton.isEnabled = state.canRemoveColor
        addButton.isEnabled = state.canAddColor
        previousButton.isEnabled = state.familyIndex > 0
        nextButton.isEnabled = state.familyIndex < BrowserSpaceThemePresets.families.count - 1
        for button in [removeButton, addButton, previousButton, nextButton] {
            button.tint = button.isEnabled ? OrbitThemeEditorColors.control : OrbitThemeEditorColors.inactive
        }
        let family = state.family
        for (index, swatch) in swatches.enumerated() {
            swatch.color = family.swatches.indices.contains(index) ? OrbitSpaceThemes.color(family.swatches[index]) : .clear
            swatch.isSelected = state.selectedSwatch == index
            swatch.setAccessibilityLabel(OrbitThemeEditorText.swatch(family, index + 1))
            swatch.refresh()
        }
        intensitySlider.isActive = state.hasColor
        intensitySlider.value = state.theme.intensity
        grainDial.isActive = state.hasColor
        grainDial.value = state.theme.noise
        field.refresh()
        renderHandles()
    }

    private func renderHandles() {
        let positions = state.handlePositions
        while handles.count > positions.count { handles.removeLast().removeFromSuperview() }
        while handles.count < positions.count {
            let index = handles.count
            let handle = OrbitThemeHandleView()
            handle.onSelect = { [weak self] in self?.edit { $0.select(handle: index) } }
            handle.onDrag = { [weak self] point in
                guard let self else { return }
                let local = field.convert(point, from: nil)
                edit { $0.move(handle: index, to: OrbitThemeFieldView.unit(of: local, in: self.field.bounds)) }
            }
            handle.onNudge = { [weak self] hue, saturation in
                self?.edit { $0.nudge(handle: index, hueDegrees: hue, saturation: saturation) }
            }
            addSubview(handle, positioned: .above, relativeTo: nil)
            handles.append(handle)
        }
        for (index, handle) in handles.enumerated() {
            let unit = positions[index]
            let center = CGPoint(x: M.field.minX + unit.x * M.field.width, y: M.field.minY + unit.y * M.field.height)
            handle.frame = NSRect(x: center.x - M.handleDiameter / 2, y: center.y - M.handleDiameter / 2,
                                  width: M.handleDiameter, height: M.handleDiameter)
            handle.color = state.theme.colors[index]
            handle.isSelected = state.selectedIndex == index
            handle.setAccessibilityLabel(OrbitThemeEditorText.handle(index + 1))
            handle.refresh()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
        for swatch in swatches { swatch.refresh() }
        intensitySlider.refresh()
        grainDial.refresh()
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onDismiss?() } else { super.keyDown(with: event) }
    }
}

// MARK: - Field

/// The dotted colour field. A click places (or moves) the selected handle; arrows nudge it.
@MainActor
final class OrbitThemeFieldView: NSView {
    var onPick: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onNudge: ((_ hueDegrees: Double, _ saturation: Double) -> Void)?
    private let fill = CALayer()
    private let dots = CAShapeLayer()
    private struct DotGeometry: Equatable {
        let size: CGSize
        let pitch: CGFloat
        let diameter: CGFloat
    }
    private var dotGeometry: DotGeometry?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(fill)
        fill.addSublayer(dots)
        fill.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(OrbitThemeEditorText.colorField)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    static func unit(of point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - bounds.minX) / max(1, bounds.width))),
                y: min(1, max(0, (point.y - bounds.minY) / max(1, bounds.height))))
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        let appearance = effectiveAppearance
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.cornerRadius = OrbitThemeEditorMetrics.fieldCornerRadius
        fill.backgroundColor = OrbitThemeEditorColors.field.resolvedCGColor(for: appearance)
        dots.frame = bounds
        let pitch = OrbitThemeEditorMetrics.dotPitch, side = OrbitThemeEditorMetrics.dotDiameter
        let geometry = DotGeometry(size: bounds.size, pitch: pitch, diameter: side)
        if dotGeometry != geometry {
            OrbitUIWorkCounters.record("dotGridBuild")
            let path = CGMutablePath()
            var y = pitch / 2
            while y < bounds.height {
                var x = pitch / 2
                while x < bounds.width {
                    path.addEllipse(in: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
                    x += pitch
                }
                y += pitch
            }
            dots.path = path
            dotGeometry = geometry
        }
        dots.fillColor = OrbitThemeEditorColors.dot.resolvedCGColor(for: appearance)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onPick?(Self.unit(of: convert(event.locationInWindow, from: nil), in: bounds))
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(Self.unit(of: convert(event.locationInWindow, from: nil), in: bounds))
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: onNudge?(-3, 0)
        case .rightArrow?: onNudge?(3, 0)
        case .upArrow?: onNudge?(0, -0.03)
        case .downArrow?: onNudge?(0, 0.03)
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class OrbitThemeHandleView: NSView {
    var color = BrowserThemeColor(hex: 0x808080)
    var isSelected = false
    var onSelect: (() -> Void)?
    /// Window location of the handle's centre while dragging.
    var onDrag: ((CGPoint) -> Void)?
    var onNudge: ((_ hueDegrees: Double, _ saturation: Double) -> Void)?
    private var dragOffset = CGPoint.zero
    private let ring = CALayer()
    private let disc = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(ring)
        ring.addSublayer(disc)
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOffset = .zero
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Only the disc takes the mouse; the rest of the frame falls through to the controls below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        let radius = bounds.width / 2
        return hypot(local.x - bounds.midX, local.y - bounds.midY) <= radius ? self : nil
    }

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.cornerRadius = bounds.width / 2
        ring.backgroundColor = NSColor.white.cgColor
        ring.shadowOpacity = isSelected ? 0.35 : 0.2
        ring.shadowRadius = isSelected ? 6 : 3
        let inset = OrbitThemeEditorMetrics.handleRing
        disc.frame = bounds.insetBy(dx: inset, dy: inset)
        disc.cornerRadius = disc.frame.width / 2
        disc.backgroundColor = OrbitSpaceThemes.color(color).cgColor
        CATransaction.commit()
        setAccessibilityValue(color.hexString)
    }

    var discColor: CGColor? { disc.backgroundColor }

    /// Grabbing a handle keeps the pointer's offset from its centre: a click alone never moves it.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let center = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: nil)
        dragOffset = CGPoint(x: center.x - event.locationInWindow.x, y: center.y - event.locationInWindow.y)
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(CGPoint(x: event.locationInWindow.x + dragOffset.x, y: event.locationInWindow.y + dragOffset.y))
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: onNudge?(-3, 0)
        case .rightArrow?: onNudge?(3, 0)
        case .upArrow?: onNudge?(0, -0.03)
        case .downArrow?: onNudge?(0, 0.03)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { onNudge?(5, 0); return true }
    override func accessibilityPerformDecrement() -> Bool { onNudge?(-5, 0); return true }
}

// MARK: - Buttons

/// Borderless symbol button (modes, −/+, chevrons). Glyph tint follows `tint`.
@MainActor
final class OrbitThemeEditorButton: NSButton {
    var onPress: (() -> Void)?
    var tint: NSColor = OrbitTokens.Color.Text.secondary { didSet { contentTintColor = tint } }

    init(symbol: String, pointSize: CGFloat = 14) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
        contentTintColor = tint
        setButtonType(.momentaryChange)
        target = self
        action = #selector(press(_:))
        focusRingType = .default
    }

    required init?(coder: NSCoder) { nil }

    @objc private func press(_ sender: Any?) { onPress?() }
}

/// One swatch: a 24 pt bordered disc; the one the theme came from gets a 2 pt ring 1.5 pt outside it.
@MainActor
final class OrbitThemeSwatchButton: NSButton {
    var onPress: (() -> Void)?
    var color: NSColor = .clear
    var isSelected = false
    private let disc = CALayer()
    private let ring = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .noImage
        wantsLayer = true
        layer?.addSublayer(ring)
        layer?.addSublayer(disc)
        ring.fillColor = nil
        ring.lineWidth = OrbitThemeEditorMetrics.swatchRing
        target = self
        action = #selector(press(_:))
    }

    required init?(coder: NSCoder) { nil }

    @objc private func press(_ sender: Any?) { onPress?() }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        let side = OrbitThemeEditorMetrics.swatchDiameter
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        disc.cornerRadius = side / 2
        disc.backgroundColor = color.cgColor
        disc.borderWidth = 1.5
        disc.borderColor = color.blended(withFraction: 0.15, of: .black)?.cgColor
        let ringInset = OrbitThemeEditorMetrics.swatchRing / 2
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: ringInset, dy: ringInset), transform: nil)
        ring.strokeColor = OrbitThemeEditorColors.swatchRing.resolvedCGColor(for: effectiveAppearance)
        ring.isHidden = !isSelected
        CATransaction.commit()
        state = isSelected ? .on : .off
    }

    var discFrame: CGRect { disc.frame }
    var isRingVisible: Bool { !ring.isHidden }
}

// MARK: - Wavy slider (intensity) and dial (grain)

@MainActor
final class OrbitThemeWaveSlider: NSView {
    var value: Double = BrowserSpaceTheme.defaultIntensity { didSet { if value != oldValue { refresh() } } }
    var isActive = false { didSet { if isActive != oldValue { refresh() } } }
    var onChange: ((Double) -> Void)?
    private let track = CALayer()
    private let wave = CAShapeLayer()
    private let activeWave = CAShapeLayer()
    private let activeMask = CALayer()
    let thumb = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for sublayer in [track, wave, activeWave, thumb] { layer?.addSublayer(sublayer) }
        for stroke in [wave, activeWave] {
            stroke.fillColor = nil
            stroke.lineWidth = OrbitThemeEditorMetrics.waveLineWidth
            stroke.lineCap = .round
            stroke.lineJoin = .round
        }
        activeWave.mask = activeMask
        activeMask.backgroundColor = NSColor.black.cgColor
        thumb.backgroundColor = NSColor.white.cgColor
        thumb.shadowColor = NSColor.black.cgColor
        thumb.shadowOpacity = 0.2
        thumb.shadowRadius = 4
        thumb.shadowOffset = .zero
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isActive }

    var thumbCenterX: CGFloat { CGFloat(value) * bounds.width }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        let appearance = effectiveAppearance
        let midY = bounds.midY, height = OrbitThemeEditorMetrics.sliderTrackHeight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 0, y: midY - height / 2, width: bounds.width, height: height)
        track.cornerRadius = height / 2
        track.backgroundColor = OrbitThemeEditorColors.track.resolvedCGColor(for: appearance)
        let path = CGMutablePath()
        let amplitude = OrbitThemeEditorMetrics.waveAmplitude, period = OrbitThemeEditorMetrics.wavePeriod
        let start: CGFloat = 8, end = bounds.width - 8
        var x = start
        path.move(to: CGPoint(x: x, y: midY))
        while x < end {
            x = min(end, x + 1)
            path.addLine(to: CGPoint(x: x, y: midY - amplitude * sin((x - start) / period * 2 * .pi)))
        }
        for stroke in [wave, activeWave] {
            stroke.frame = bounds
            stroke.path = path
        }
        wave.strokeColor = OrbitThemeEditorColors.inactive.resolvedCGColor(for: appearance)
        activeWave.strokeColor = OrbitThemeEditorColors.waveActive.resolvedCGColor(for: appearance)
        activeWave.isHidden = !isActive
        activeMask.frame = CGRect(x: 0, y: 0, width: thumbCenterX, height: bounds.height)
        let thumbSize = OrbitThemeEditorMetrics.sliderThumb
        thumb.frame = CGRect(x: thumbCenterX - thumbSize.width / 2, y: midY - thumbSize.height / 2,
                             width: thumbSize.width, height: thumbSize.height)
        thumb.cornerRadius = thumbSize.width / 2
        thumb.isHidden = !isActive
        CATransaction.commit()
        setAccessibilityEnabled(isActive)
        setAccessibilityValue(OrbitThemeEditorText.percent(value))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func set(_ newValue: Double) {
        guard isActive else { return }
        let clamped = min(1, max(0, newValue))
        guard clamped != value else { return }
        value = clamped
        onChange?(clamped)
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        window?.makeFirstResponder(self)
        set(Double(convert(event.locationInWindow, from: nil).x / max(1, bounds.width)))
    }

    override func mouseDragged(with event: NSEvent) {
        set(Double(convert(event.locationInWindow, from: nil).x / max(1, bounds.width)))
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?, .downArrow?: set(value - 0.05)
        case .rightArrow?, .upArrow?: set(value + 0.05)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { set(value + 0.05); return isActive }
    override func accessibilityPerformDecrement() -> Bool { set(value - 0.05); return isActive }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: track.frame, xRadius: track.cornerRadius, yRadius: track.cornerRadius).fill()
    }
    override var focusRingMaskBounds: NSRect { track.frame }
}

@MainActor
final class OrbitThemeGrainDial: NSView {
    var value: Double = 0 { didSet { if value != oldValue { refresh() } } }
    var isActive = false { didSet { if isActive != oldValue { refresh() } } }
    var onChange: ((Double) -> Void)?
    private let dots = CAShapeLayer()
    private let inner = CAShapeLayer()
    let tick = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for sublayer in [dots, inner, tick] { layer?.addSublayer(sublayer) }
        inner.fillColor = nil
        inner.lineWidth = 1
        tick.backgroundColor = NSColor.white.cgColor
        tick.shadowColor = NSColor.black.cgColor
        tick.shadowOpacity = 0.2
        tick.shadowRadius = 2
        tick.shadowOffset = .zero
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isActive }

    /// Clockwise angle of the tick from 12 o'clock, in degrees.
    var tickAngle: CGFloat { CGFloat(value) * OrbitThemeEditorMetrics.dialSweepDegrees }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        let appearance = effectiveAppearance
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = OrbitThemeEditorMetrics.dialRadius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = CGMutablePath()
        for index in 0..<OrbitThemeEditorMetrics.dialDotCount {
            let angle = CGFloat(index) / CGFloat(OrbitThemeEditorMetrics.dialDotCount) * 2 * .pi
            let point = CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
            path.addEllipse(in: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
        }
        dots.frame = bounds
        dots.path = path
        dots.fillColor = OrbitThemeEditorColors.inactive.resolvedCGColor(for: appearance)
        inner.frame = bounds
        let innerRadius = OrbitThemeEditorMetrics.dialInnerRadius
        inner.path = CGPath(ellipseIn: CGRect(x: center.x - innerRadius, y: center.y - innerRadius,
                                              width: 2 * innerRadius, height: 2 * innerRadius), transform: nil)
        inner.strokeColor = OrbitThemeEditorColors.inactive.resolvedCGColor(for: appearance)
        tick.bounds = CGRect(x: 0, y: 0, width: 4, height: 11)
        tick.cornerRadius = 2
        let angle = tickAngle * .pi / 180
        tick.position = CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
        tick.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        tick.isHidden = !isActive
        CATransaction.commit()
        setAccessibilityEnabled(isActive)
        setAccessibilityValue(OrbitThemeEditorText.percent(value))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func set(_ newValue: Double) {
        guard isActive else { return }
        let clamped = min(1, max(0, newValue))
        guard clamped != value else { return }
        value = clamped
        onChange?(clamped)
    }

    /// Value of a pointer position: its clockwise angle from 12 o'clock over the dial's sweep.
    func value(at point: CGPoint) -> Double {
        var degrees = atan2(point.x - bounds.midX, bounds.midY - point.y) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return Double(min(1, degrees / OrbitThemeEditorMetrics.dialSweepDegrees))
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        window?.makeFirstResponder(self)
        set(value(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) { set(value(at: convert(event.locationInWindow, from: nil))) }

    override func scrollWheel(with event: NSEvent) { set(value + Double(event.scrollingDeltaY) * 0.005) }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?, .downArrow?: set(value - 0.05)
        case .rightArrow?, .upArrow?: set(value + 0.05)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { set(value + 0.05); return isActive }
    override func accessibilityPerformDecrement() -> Bool { set(value - 0.05); return isActive }

    override func drawFocusRingMask() { NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}
