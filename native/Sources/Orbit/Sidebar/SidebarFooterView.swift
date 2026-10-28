import AppKit
import BrowserCore
import CoreImage

private typealias Metrics = OrbitTokens.Metrics.Sidebar

@MainActor
final class SidebarFooterView: NSView {
    let libraryButton = OrbitGlyphButton(glyph: OrbitGlyph.library, label: OrbitShellText.library)
    let plusButton = OrbitGlyphButton(glyph: OrbitGlyph.footerPlus, label: OrbitShellText.create)
    private(set) var spaceButtons: [SidebarSpaceButton] = []
    private var spaces: [BrowserSpace] = []
    private let creationDot = NSView()
    var creationProgress: CGFloat = 0 { didSet { needsLayout = true } }
    private var activeSpaceID: SpaceID?
    private var commandsEnabled = true
    private(set) var contextMenu: SidebarSpaceMenu?
    private(set) var iconPicker: SpaceIconPicker?
    private(set) var spaceLayout = FooterSpaceLayout.resolve(count: 0, libraryCenterX: 0, plusCenterX: 0)
    private var authority = UUID()
    var onMenuWillOpen: (() -> Void)?
    var onMenuPresentationChange: (() -> Void)?
    var accent = OrbitTokens.ThemeAccent.defaultSpace {
        didSet { refreshAccent() }
    }
    var onSelectSpace: ((SpaceID) -> Void)?
    var onDeleteSpace: ((SpaceID) -> Void)?
    var onRenameSpace: ((SpaceID) -> Void)?
    var onEditSpaceIcon: ((SpaceID) -> Void)?
    var onEditSpaceTheme: ((SpaceID) -> Void)?
    var onMoveSpace: ((SpaceID, SpaceID?) -> Void)?
    var onHoverSpace: ((SidebarSpaceButton?) -> Void)?
    var onPressSpace: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [libraryButton, plusButton] { addSubview(button) }
        creationDot.wantsLayer = true
        creationDot.layer?.cornerRadius = 4
        creationDot.alphaValue = 0
        addSubview(creationDot)
        refreshAccent()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func setCommandsEnabled(_ enabled: Bool) {
        if !enabled { cancelContextMenu(); cancelIconPicker(); authority = UUID() }
        commandsEnabled = enabled
        libraryButton.isEnabled = enabled
        plusButton.isEnabled = enabled
        for button in spaceButtons { button.isEnabled = enabled }
    }

    func render(spaces: [BrowserSpace], activeSpaceID: SpaceID?) {
        guard spaces != self.spaces || activeSpaceID != self.activeSpaceID || spaceButtons.count != spaces.count else { return }
        cancelContextMenu()
        cancelIconPicker()
        authority = UUID()
        self.spaces = spaces
        self.activeSpaceID = activeSpaceID
        if spaceButtons.map(\.space) == spaces {
            for button in spaceButtons { button.isActive = button.space.id == activeSpaceID }
            return
        }
        for button in spaceButtons { button.removeFromSuperview() }
        spaceButtons = spaces.enumerated().map { index, space in
            let button = SidebarSpaceButton(space: space, index: index, isActive: space.id == activeSpaceID)
            configureContrast(of: button)
            button.target = self
            button.action = #selector(selectSpace(_:))
            button.isEnabled = commandsEnabled
            button.onPress = { [weak self] in self?.onPressSpace?() }
            button.onHoverChange = { [weak self, weak button] hovering in self?.onHoverSpace?(hovering ? button : nil) }
            button.onContextMenu = { [weak self, weak button] in
                guard let button else { return }
                self?.showContextMenu(for: button)
            }
            button.presentation = spaceLayout.presentation
            button.dotDiameter = spaceLayout.dotDiameter
            addSubview(button)
            return button
        }
        needsLayout = true
    }

    private var foregroundAccent: OrbitTokens.ThemeAccent {
        OrbitSpaceThemes.accent(accent, over: [], iconHover: OrbitTokens.Color.State.standaloneButton)
    }

    private func configureContrast(of button: OrbitGlyphButton) {
        let foreground = foregroundAccent
        button.tint = foreground.icon
        if let space = button as? SidebarSpaceButton {
            space.inactiveOpacity = { appearance in
                OrbitSpaceThemes.inactiveSpaceIconOpacity(for: foreground, appearance: appearance,
                    minimum: Metrics.footerInactiveSpaceOpacity)
            }
        }
    }

    private func refreshAccent() {
        // Disabled controls keep their separate tint; enabled inactive dots dim only while legible.
        for button in [libraryButton, plusButton] + spaceButtons { configureContrast(of: button) }
    }

    /// Lays the footer out from the sidebar geometry (centres in footer coordinates).
    func apply(_ geometry: OrbitSidebarGeometry) {
        let size = Metrics.footerButtonSize
        let y = geometry.footerCenterY - size / 2
        libraryButton.frame = NSRect(x: geometry.libraryCenterX - size / 2, y: y, width: size, height: size)
        plusButton.frame = NSRect(x: geometry.plusCenterX - size / 2, y: y, width: size, height: size)
        spaceLayout = FooterSpaceLayout.resolve(count: spaceButtons.count, libraryCenterX: geometry.libraryCenterX,
                                                plusCenterX: geometry.plusCenterX,
                                                backingScale: window?.backingScaleFactor ?? 1)
        let progress = min(1, max(0, creationProgress))
        let group = FooterSpaceLayout.resolve(count: spaceButtons.count + 2, libraryCenterX: geometry.libraryCenterX,
                                              plusCenterX: geometry.plusCenterX,
                                              backingScale: window?.backingScaleFactor ?? 1)
        let libraryX = group.centerXs.first ?? geometry.libraryCenterX
        libraryButton.frame.origin.x += (libraryX - geometry.libraryCenterX) * progress
        plusButton.alphaValue = 1 - progress
        creationDot.frame = NSRect(x: (group.centerXs.last ?? 0) - 4, y: geometry.footerCenterY - 4, width: 8, height: 8)
        effectiveAppearance.performAsCurrentDrawingAppearance { creationDot.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor }
        creationDot.alphaValue = progress
        libraryButton.alphaValue = 1 - progress * 0.5
        for (index, pair) in zip(spaceButtons, spaceLayout.centerXs).enumerated() {
            let (button, sourceX) = pair
            let creationX = group.centerXs.indices.contains(index + 1) ? group.centerXs[index + 1] : sourceX
            let centerX = sourceX + (creationX - sourceX) * progress
            button.alphaValue = 1 - progress * 0.5
            button.frame = NSRect(x: centerX - spaceLayout.pitch / 2, y: geometry.footerCenterY - 16, width: spaceLayout.pitch, height: 32)
            button.presentation = spaceLayout.presentation
            button.dotDiameter = button.fittedDotDiameter(spaceLayout.dotDiameter)
            var fill = OrbitGlyphButton.HoverFill.standalone
            if spaceLayout.pitch < size { fill.side = spaceLayout.pitch; fill.radius = min(fill.radius, spaceLayout.pitch / 3) }
            button.hoverFill = fill
        }
    }

    func setCreationMenuOpen(_ open: Bool) {
        plusButton.glyph = open ? OrbitGlyph.footerClose : OrbitGlyph.footerPlus
    }

    func cancelContextMenu() {
        authority = UUID()
        let menu = contextMenu
        contextMenu = nil
        menu?.cancel()
        if menu != nil { onMenuPresentationChange?() }
    }

    /// Shows `picker` above the Space's footer button; the footer owns it like the context menu.
    @discardableResult
    func presentIconPicker(_ picker: SpaceIconPicker, for id: SpaceID) -> Bool {
        // Ordering the child panel would bring a hidden parent window on screen.
        guard commandsEnabled, let button = spaceButtons.first(where: { $0.space.id == id }),
              let window = button.window, window.isVisible, !button.isHiddenOrHasHiddenAncestor,
              picker.canPresent else { return false }
        let space = button.space
        func isCurrent() -> Bool {
            commandsEnabled && button.window === window && window.isVisible &&
                !button.isHiddenOrHasHiddenAncestor && spaceButtons.contains(where: { $0 === button }) &&
                button.space == space && spaces.contains(space)
        }
        cancelContextMenu()
        cancelIconPicker()
        onMenuWillOpen?()
        onHoverSpace?(nil)
        guard isCurrent(), picker.canPresent else { return false }
        iconPicker = picker
        picker.onClose = { [weak self, weak picker] in
            guard let self, iconPicker === picker else { return }
            iconPicker = nil
            onMenuPresentationChange?()
        }
        onMenuPresentationChange?()
        guard iconPicker === picker, isCurrent(), picker.canPresent else {
            if iconPicker === picker { cancelIconPicker() }
            return false
        }
        guard picker.show(relativeTo: button) else {
            if iconPicker === picker { cancelIconPicker() }
            return false
        }
        return iconPicker === picker
    }

    func cancelIconPicker() {
        let picker = iconPicker
        iconPicker = nil
        picker?.cancel()
        if picker != nil { onMenuPresentationChange?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelContextMenu()
        cancelIconPicker()
        authority = UUID()
    }
    override func viewDidHide() { super.viewDidHide(); cancelContextMenu(); cancelIconPicker(); authority = UUID() }

    func actions(for id: SpaceID) -> [SidebarSpaceAction] {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return [] }
        return [
            .init(kind: .rename, title: OrbitShellText.renameSpace, symbol: "pencil", enabled: commandsEnabled, beforeID: nil),
            .init(kind: .icon, title: uiText("Change Icon or Emoji…"), symbol: "face.smiling", enabled: commandsEnabled, beforeID: nil),
            .init(kind: .theme, title: OrbitThemeEditorText.menuItem, symbol: "paintpalette", enabled: commandsEnabled, beforeID: nil),
            .init(kind: .moveLeft, title: OrbitShellText.moveSpaceLeft, symbol: "arrow.left", enabled: commandsEnabled && index > 0,
                  beforeID: index > 0 ? spaces[index - 1].id : nil),
            .init(kind: .moveRight, title: OrbitShellText.moveSpaceRight, symbol: "arrow.right", enabled: commandsEnabled && index + 1 < spaces.count,
                  beforeID: index + 2 < spaces.count ? spaces[index + 2].id : nil),
            .init(kind: .delete, title: uiText("Delete Space…"), symbol: "trash", enabled: commandsEnabled && spaces.count > 1, beforeID: nil)
        ]
    }

    func showContextMenu(for button: SidebarSpaceButton, present: Bool = true) {
        guard commandsEnabled, spaceButtons.contains(where: { $0 === button }),
              spaces.contains(button.space) else { return }
        cancelContextMenu()
        onMenuWillOpen?()
        onHoverSpace?(nil)
        // Cancelling swipe or another presentation can synchronously rebuild the footer.
        guard commandsEnabled, spaceButtons.contains(where: { $0 === button }), spaces.contains(button.space) else { return }
        let capturedAuthority = authority
        let space = button.space
        let menu = SidebarSpaceMenu(actions: actions(for: space.id), accent: accent)
        contextMenu = menu
        menu.onClose = { [weak self, weak menu] in
            guard let self, contextMenu === menu else { return }
            contextMenu = nil
            onMenuPresentationChange?()
        }
        menu.onAction = { [weak self] action in
            guard let self, commandsEnabled, authority == capturedAuthority,
                  spaces.contains(where: { $0.id == space.id && $0.profileID == space.profileID }),
                  actions(for: space.id).contains(where: { $0.kind == action.kind && $0.enabled && $0.beforeID == action.beforeID }) else { return }
            switch action.kind {
            case .rename: onRenameSpace?(space.id)
            case .icon: onEditSpaceIcon?(space.id)
            case .theme: onEditSpaceTheme?(space.id)
            case .moveLeft, .moveRight: onMoveSpace?(space.id, action.beforeID)
            case .delete: onDeleteSpace?(space.id)
            }
        }
        onMenuPresentationChange?()
        if present {
            guard button.window != nil else { cancelContextMenu(); return }
            menu.show(relativeTo: button)
        }
    }

    @objc private func selectSpace(_ sender: SidebarSpaceButton) {
        guard commandsEnabled, spaceButtons.contains(where: { $0 === sender }) else { return }
        cancelContextMenu()
        onSelectSpace?(sender.space.id)
    }

}

@MainActor
final class SidebarSpaceButton: OrbitGlyphButton {
    let space: BrowserSpace
    let index: Int
    private static let imageContext = CIContext()
    private var emojiImage: NSImage?
    private var inactiveEmojiImage: NSImage?
    var iconSelection: BrowserSpaceIcon = .none {
        didSet {
            if iconSelection != oldValue { emojiImage = nil; inactiveEmojiImage = nil; needsDisplay = true }
        }
    }
    var settingsIcon: String {
        get { if case .grapheme(let value) = iconSelection { value } else { "" } }
        set { iconSelection = BrowserSpaceIcon(legacyIcon: newValue) }
    }
    var isActive: Bool {
        didSet {
            setEmphasis(animated: true)
            setAccessibilityValue(isActive ? OrbitShellText.selected : "")
        }
    }
    static let hoverDuration: TimeInterval = 0.2
    @objc dynamic var hoverAmount: CGFloat = 0 { didSet { needsDisplay = true } }
    @objc dynamic var iconEmphasis: CGFloat = 0 { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "hoverAmount" || key == "iconEmphasis" { return CABasicAnimation() }
        return super.defaultAnimation(forKey: key)
    }

    private func setEmphasis(animated: Bool) {
        let emphasis: CGFloat = isActive || isHovering ? 1 : 0
        guard animated, window?.isVisible == true, !OrbitMotionPreferences.prefersReducedMotion else {
            hoverAmount = isHovering ? 1 : 0
            iconEmphasis = emphasis
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hoverDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().hoverAmount = isHovering ? 1 : 0
            animator().iconEmphasis = emphasis
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, hoverAmount > 0 || isHighlighted {
            hoverFill.color.withAlphaComponent(hoverFill.color.alphaComponent * (isHighlighted ? 1 : hoverAmount)).setFill()
            let rect = hoverFill.side.map { side in
                NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
            } ?? bounds
            NSBezierPath(roundedRect: rect, xRadius: hoverFill.radius, yRadius: hoverFill.radius).fill()
        }
        super.draw(dirtyRect)
    }
    /// `.dots` draws this Space as a dot even when it carries an emoji (crowded footer).
    var presentation: FooterSpaceLayout.Presentation = .icons {
        didSet { if presentation != oldValue { needsDisplay = true } }
    }
    var dotDiameter = Metrics.footerSpaceDotDiameter {
        didSet { if dotDiameter != oldValue { needsDisplay = true } }
    }
    var onHoverChange: ((Bool) -> Void)?
    var onContextMenu: (() -> Void)?
    var inactiveOpacity: (NSAppearance) -> CGFloat = { _ in Metrics.footerInactiveSpaceOpacity } {
        didSet { needsDisplay = true }
    }

    init(space: BrowserSpace, index: Int, isActive: Bool) {
        self.space = space
        self.index = index
        self.isActive = isActive
        super.init(glyph: nil, label: OrbitShellText.space(space.name))
        showsHoverFill = false
        iconEmphasis = isActive ? 1 : 0
        setAccessibilityValue(isActive ? OrbitShellText.selected : "")
        customDrawing = { button, bounds in
            if let button = button as? SidebarSpaceButton, button.presentation == .icons,
               case .systemSymbol(let name) = button.iconSelection,
               let image = SpaceIconImages.symbol(name, pointSize: 15, tint: button.tint,
                    active: button.isActive, appearance: button.effectiveAppearance) {
                image.draw(in: NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                                      width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver,
                           fraction: button.isActive ? 1 : button.inactiveOpacity(button.effectiveAppearance))
                return
            }
            if let button = button as? SidebarSpaceButton, !button.settingsIcon.isEmpty, button.presentation == .icons {
                if button.emojiImage == nil {
                    let text = NSAttributedString(string: button.settingsIcon, attributes: [.font: NSFont.systemFont(ofSize: 12)])
                    let image = NSImage(size: text.size(), flipped: false) { _ in text.draw(at: .zero); return true }
                    button.emojiImage = image
                    button.inactiveEmojiImage = Self.grayscale(image)
                }
                let rect = NSRect(x: bounds.midX - (button.emojiImage?.size.width ?? 0) / 2,
                                  y: bounds.midY - (button.emojiImage?.size.height ?? 0) / 2,
                                  width: button.emojiImage?.size.width ?? 0, height: button.emojiImage?.size.height ?? 0)
                let amount = min(1, max(0, button.iconEmphasis))
                let rendered: NSImage?
                if amount == 0 { rendered = button.inactiveEmojiImage }
                else if amount == 1 { rendered = button.emojiImage }
                else { rendered = button.emojiImage.map { Self.saturated($0, amount: amount) } }
                rendered?.draw(in: rect)
                return
            }
            let diameter = (button as? SidebarSpaceButton).map { $0.fittedDotDiameter($0.dotDiameter) }
                ?? Metrics.footerSpaceDotDiameter
            guard diameter > 0 else { return }
            let dot = button.backingAlignedRect(
                NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter),
                options: .alignAllEdgesNearest)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            if let space = button as? SidebarSpaceButton {
                let inactive = space.inactiveOpacity(space.effectiveAppearance)
                context.setAlpha(space.isActive ? 1 : min(1, inactive * (1 + 0.5 * space.hoverAmount)))
            }
            button.tint.setFill()
            NSBezierPath(ovalIn: dot).fill()
            context.restoreGState()
        }
    }

    /// Fit a centered circle inside the inward-aligned backing cell before final native alignment.
    func fittedDotDiameter(_ proposed: CGFloat) -> CGFloat {
        guard proposed.isFinite, proposed > 0 else { return 0 }
        let usable = backingAlignedRect(bounds, options: .alignAllEdgesInward)
        guard usable.width > 0, usable.height > 0 else { return 0 }
        let radius = max(0, min(min(bounds.midX - usable.minX, usable.maxX - bounds.midX),
                                min(bounds.midY - usable.minY, usable.maxY - bounds.midY)))
        let scale = window?.backingScaleFactor ?? 1
        return floor(min(proposed, radius * 2) * scale) / scale
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) {
        if isEnabled { onContextMenu?() }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        onPress?()
        super.mouseDown(with: event)
    }
    override func accessibilityPerformShowMenu() -> Bool {
        guard isEnabled, onContextMenu != nil else { return false }
        onContextMenu?()
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 110 || (event.keyCode == 99 && event.modifierFlags.contains(.shift)) {
            _ = accessibilityPerformShowMenu()
        } else { super.keyDown(with: event) }
    }

    static func grayscale(_ image: NSImage) -> NSImage { saturated(image, amount: 0) }

    private static func saturated(_ image: NSImage, amount: CGFloat) -> NSImage {
        guard let data = image.tiffRepresentation, let input = CIImage(data: data),
              let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(amount, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let cgImage = imageContext.createCGImage(output, from: input.extent) else { return image }
        return NSImage(cgImage: cgImage, size: image.size)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setEmphasis(animated: true)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setEmphasis(animated: true)
        onHoverChange?(false)
    }
}

@MainActor
final class SidebarSpaceTooltip: NSView {
    static let appearanceDelay: TimeInterval = 0.45
    static let departureDuration: TimeInterval = 0.3
    static let clickDismissalDuration: TimeInterval = 0.1
    private var presentationGeneration = UUID()
    private(set) var isDismissing = false

    func present() {
        presentationGeneration = UUID()
        isDismissing = false
        layer?.removeAllAnimations()
        alphaValue = 1
        isHidden = false
    }

    func dismiss(duration: TimeInterval = 0) {
        presentationGeneration = UUID()
        let generation = presentationGeneration
        guard !isHidden, duration > 0, window?.isVisible == true, !OrbitMotionPreferences.prefersReducedMotion else {
            isDismissing = false
            layer?.removeAllAnimations()
            isHidden = true
            alphaValue = 1
            return
        }
        isDismissing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentationGeneration == generation else { return }
                self.isHidden = true
                self.isDismissing = false
                self.alphaValue = 1
            }
        }
    }
    private let material = NSVisualEffectView()
    private let tint = NSView()
    private let label = NSTextField(labelWithString: "")
    private let profileBadge = NSView()
    private let profileLabel = NSTextField(labelWithString: "")
    private let profileGlyph = SidebarProfileBadgeGlyph()
    private(set) var profileName: String?
    private var keycaps: [NSTextField] = []
    private(set) var name = ""
    private(set) var shortcut: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -2)
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.appearance = NSAppearance(named: .darkAqua)
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.layer?.masksToBounds = true
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.09, blue: 0.11, alpha: 0.84).cgColor
        tint.layer?.cornerRadius = 14
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor(white: 0.96, alpha: 1)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        profileBadge.wantsLayer = true
        profileBadge.layer?.cornerRadius = 11
        profileBadge.layer?.backgroundColor = NSColor(white: 0.9, alpha: 0.96).cgColor
        profileLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        profileLabel.textColor = NSColor(srgbRed: 0.38, green: 0.32, blue: 0.39, alpha: 1)
        profileLabel.lineBreakMode = .byTruncatingTail
        profileBadge.addSubview(profileGlyph)
        profileBadge.addSubview(profileLabel)
        for view in [material, tint, label, profileBadge] { addSubview(view) }
        setAccessibilityIdentifier("space-hover-capsule")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(name: String, shortcut: String?, profileName: String? = nil, maximumWidth: CGFloat = 600) -> NSSize {
        self.name = name
        self.profileName = profileName
        self.shortcut = shortcut
        label.stringValue = name
        keycaps.forEach { $0.removeFromSuperview() }
        keycaps = (shortcut ?? "").map { character in
            let key = NSTextField(labelWithString: String(character))
            key.font = .systemFont(ofSize: 11, weight: .semibold)
            key.textColor = NSColor(white: 0.27, alpha: 1)
            key.alignment = .center
            key.wantsLayer = true
            key.layer?.cornerRadius = 3
            key.layer?.borderWidth = 1.5
            key.layer?.borderColor = NSColor(white: 0.65, alpha: 1).cgColor
            key.layer?.backgroundColor = NSColor(white: 0.92, alpha: 0.94).cgColor
            addSubview(key)
            return key
        }
        let keyWidths = keycaps.map { max(18, ceil($0.intrinsicContentSize.width) + 6) }
        let keysWidth = keyWidths.reduce(0, +) + CGFloat(max(0, keycaps.count - 1)) * 3
        let gap: CGFloat = keycaps.isEmpty ? 0 : 6
        profileLabel.stringValue = profileName ?? ""
        profileBadge.isHidden = profileName == nil
        let profileWidth = profileName.map { ceil(($0 as NSString).size(withAttributes: [.font: profileLabel.font!]).width) + 30 } ?? 0
        let profileGap: CGFloat = profileName == nil ? 0 : 2
        let badgeWidth = min(profileWidth, max(0, maximumWidth - 20 - gap - keysWidth - profileGap - 24))
        // NSTextField's intrinsic width can retain the previous truncated cell width.
        // Measure the complete name so even the first hover has no ellipsis or width jump.
        let nameWidth = ceil((name as NSString).size(withAttributes: [.font: label.font!]).width) + 6
        let textWidth = min(nameWidth, max(12, maximumWidth - 20 - gap - keysWidth - badgeWidth - profileGap))
        label.frame = NSRect(x: 8, y: 6, width: textWidth, height: 17)
        var x = label.frame.maxX + profileGap
        profileBadge.frame = NSRect(x: x, y: 3, width: badgeWidth, height: 22)
        profileGlyph.frame = NSRect(x: 6, y: 4, width: 12, height: 14)
        profileLabel.frame = NSRect(x: 22, y: 3, width: max(0, badgeWidth - 26), height: 16)
        x += badgeWidth + gap
        for (key, width) in zip(keycaps, keyWidths) {
            key.frame = NSRect(x: x, y: 5, width: width, height: 18)
            x += width + 3
        }
        let size = NSSize(width: label.frame.maxX + profileGap + badgeWidth + gap + keysWidth + 10, height: 28)
        material.frame = NSRect(origin: .zero, size: size)
        tint.frame = material.frame
        setAccessibilityLabel(name)
        setAccessibilityValue(shortcut ?? "")
        return size
    }
}


@MainActor
private final class SidebarProfileBadgeGlyph: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.38, green: 0.32, blue: 0.39, alpha: 0.1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 1, width: 12, height: 12)).fill()
        NSColor(srgbRed: 0.38, green: 0.32, blue: 0.39, alpha: 1).setFill()
        for x: CGFloat in [3, 7] {
            NSBezierPath(roundedRect: NSRect(x: x, y: 7, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()
        }
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 2, y: 5))
        smile.curve(to: NSPoint(x: 10, y: 5), controlPoint1: NSPoint(x: 4, y: 2), controlPoint2: NSPoint(x: 8, y: 2))
        smile.lineWidth = 1.25
        NSColor(srgbRed: 0.38, green: 0.32, blue: 0.39, alpha: 1).setStroke()
        smile.stroke()
    }
}
