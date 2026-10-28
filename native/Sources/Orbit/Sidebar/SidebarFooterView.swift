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
        for button in spaceButtons { button.removeFromSuperview() }
        spaceButtons = spaces.enumerated().map { index, space in
            let button = SidebarSpaceButton(space: space, index: index, isActive: space.id == activeSpaceID)
            configureContrast(of: button)
            button.target = self
            button.action = #selector(selectSpace(_:))
            button.isEnabled = commandsEnabled
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
            button.frame = NSRect(x: centerX - spaceLayout.pitch / 2, y: y, width: spaceLayout.pitch, height: size)
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
    let isActive: Bool
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
        setAccessibilityValue(isActive ? OrbitShellText.selected : "")
        customDrawing = { button, bounds in
            if let button = button as? SidebarSpaceButton, button.presentation == .icons,
               case .systemSymbol(let name) = button.iconSelection,
               let image = SpaceIconImages.symbol(name, pointSize: 15, tint: button.tint,
                    active: isActive, appearance: button.effectiveAppearance) {
                image.draw(in: NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                                      width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver,
                           fraction: isActive ? 1 : button.inactiveOpacity(button.effectiveAppearance))
                return
            }
            if let button = button as? SidebarSpaceButton, !button.settingsIcon.isEmpty, button.presentation == .icons {
                if button.emojiImage == nil {
                    let text = NSAttributedString(string: button.settingsIcon, attributes: [.font: NSFont.systemFont(ofSize: 15)])
                    let image = NSImage(size: text.size(), flipped: false) { _ in text.draw(at: .zero); return true }
                    button.emojiImage = image
                    button.inactiveEmojiImage = Self.grayscale(image)
                }
                if let rendered = isActive ? button.emojiImage : button.inactiveEmojiImage {
                    rendered.draw(in: NSRect(x: bounds.midX - rendered.size.width / 2, y: bounds.midY - rendered.size.height / 2,
                                            width: rendered.size.width, height: rendered.size.height))
                }
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
            if !isActive, let space = button as? SidebarSpaceButton {
                context.setAlpha(space.inactiveOpacity(space.effectiveAppearance))
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

    static func grayscale(_ image: NSImage) -> NSImage {
        guard let data = image.tiffRepresentation, let input = CIImage(data: data),
              let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let cgImage = imageContext.createCGImage(output, from: input.extent) else { return image }
        return NSImage(cgImage: cgImage, size: image.size)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

@MainActor
final class SidebarSpaceTooltip: NSView {
    static let appearanceDelay: TimeInterval = 0.45
    private let material = NSVisualEffectView()
    private let tint = NSView()
    private let label = NSTextField(labelWithString: "")
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
        for view in [material, tint, label] { addSubview(view) }
        setAccessibilityIdentifier("space-hover-capsule")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(name: String, shortcut: String?, maximumWidth: CGFloat = 600) -> NSSize {
        self.name = name
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
            key.layer?.backgroundColor = NSColor(white: 0.92, alpha: 0.94).cgColor
            addSubview(key)
            return key
        }
        let keyWidths = keycaps.map { max(18, ceil($0.intrinsicContentSize.width) + 6) }
        let keysWidth = keyWidths.reduce(0, +) + CGFloat(max(0, keycaps.count - 1)) * 3
        let gap: CGFloat = keycaps.isEmpty ? 0 : 8
        // NSTextField's intrinsic width can retain the previous truncated cell width.
        // Measure the complete name so even the first hover has no ellipsis or width jump.
        let nameWidth = ceil((name as NSString).size(withAttributes: [.font: label.font!]).width) + 6
        let textWidth = min(nameWidth, max(12, maximumWidth - 20 - gap - keysWidth))
        label.frame = NSRect(x: 10, y: 6, width: textWidth, height: 17)
        var x = label.frame.maxX + gap
        for (key, width) in zip(keycaps, keyWidths) {
            key.frame = NSRect(x: x, y: 5, width: width, height: 18)
            x += width + 3
        }
        let size = NSSize(width: label.frame.maxX + gap + keysWidth + 10, height: 28)
        material.frame = NSRect(origin: .zero, size: size)
        tint.frame = material.frame
        setAccessibilityLabel(name)
        setAccessibilityValue(shortcut ?? "")
        return size
    }
}
