import AppKit
import BrowserCore

/// A pager-local draft: nothing is persisted until Create. Both pickers are shared with Spaces.
@MainActor
final class SidebarNewSpacePageView: NSView, NSTextFieldDelegate {
    let name = NSTextField()
    let profiles = NSPopUpButton(frame: .zero, pullsDown: false)
    let profileName = NSTextField()
    let iconButton = NSButton(title: "", target: nil, action: nil)
    let themeButton = SpaceCreationButton(title: uiText("Choose a Theme"), target: nil, action: nil)
    let createButton = SpaceCreationButton(title: uiText("Create Space"), target: nil, action: nil)
    let backButton = SpaceCreationButton(title: uiText("Cancel"), target: nil, action: nil)
    private let title = NSTextField(labelWithString: uiText("Create a Space"))
    private let profileLabel = NSTextField(labelWithString: uiText("Profile"))
    private let detail = NSTextField(wrappingLabelWithString: uiText("Separate your tabs for life,\nwork, projects, and more."))
    private let illustration = SpaceCreationIllustration()
    private let nameRow = NSView()
    private let profileRow = NSView()
    private let profileGlyph = NSImageView()
    private let profileInfo = NSImageView()
    private(set) var icon: BrowserSpaceIcon = .none
    private(set) var theme = BrowserSpaceThemePresets.default
    private var profileIDs: [ProfileID] = []
    private(set) var iconPicker: SpaceIconPicker?
    private(set) var themePicker: NSPopover?
    private(set) var themeView: OrbitThemeEditorView?
    private var themePresentation: SpacePickerPopover?
    private var submitted = false
    var onCreate: ((String, ProfileID?, String?, BrowserSpaceIcon, BrowserSpaceTheme) -> Void)?
    var onBack: (() -> Void)?
    var onTheme: ((BrowserSpaceTheme) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        detail.font = .systemFont(ofSize: 14, weight: .regular)
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        profileLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        for field in [title, detail, profileLabel] { field.textColor = .labelColor }
        name.placeholderString = uiText("Space name…")
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.isBordered = false; name.isBezeled = false; name.drawsBackground = false
        name.focusRingType = .none
        name.delegate = self
        name.setAccessibilityLabel(uiText("Space Name"))
        name.setAccessibilityIdentifier("space-create-name")
        profileName.placeholderString = uiText("New Profile Name")
        profileName.setAccessibilityLabel(uiText("New Profile Name"))
        profileName.delegate = self
        profiles.setAccessibilityLabel(uiText("Browsing Profile"))
        profiles.target = self; profiles.action = #selector(profileChanged)
        profiles.font = .systemFont(ofSize: 12, weight: .semibold)
        profiles.isBordered = false
        profiles.cell = SpaceCreationProfileCell(textCell: "", pullsDown: false)
        profiles.target = self; profiles.action = #selector(profileChanged)
        profiles.font = .systemFont(ofSize: 12, weight: .semibold)
        for button in [iconButton, themeButton, createButton, backButton] {
            button.isBordered = false; button.target = self
            button.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        iconButton.action = #selector(chooseIcon)
        iconButton.setAccessibilityLabel(uiText("Change Space Icon or Emoji"))
        themeButton.action = #selector(chooseTheme)
        themeButton.symbol = "paintbrush.pointed.fill"
        themeButton.alignment = .left
        createButton.action = #selector(create)
        createButton.primary = true
        createButton.setAccessibilityIdentifier("space-create-submit")
        backButton.action = #selector(back)
        backButton.link = true
        backButton.font = .systemFont(ofSize: 12, weight: .semibold)
        backButton.setAccessibilityIdentifier("space-create-cancel")
        profileGlyph.image = NSImage(size: NSSize(width: 12, height: 14), flipped: true) { _ in
            NSColor.secondaryLabelColor.setStroke()
            let face = NSBezierPath()
            for x: CGFloat in [3, 8] { face.move(to: NSPoint(x: x, y: 2)); face.line(to: NSPoint(x: x, y: 6)) }
            face.move(to: NSPoint(x: 2, y: 10)); face.curve(to: NSPoint(x: 10, y: 10), controlPoint1: NSPoint(x: 4, y: 12), controlPoint2: NSPoint(x: 8, y: 12))
            face.lineWidth = 1.7; face.lineCapStyle = .round; face.stroke(); return true
        }
        profileGlyph.contentTintColor = .secondaryLabelColor
        profileInfo.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        profileInfo.contentTintColor = .secondaryLabelColor
        for row in [nameRow, profileRow] { row.wantsLayer = true; row.layer?.cornerRadius = 6 }
        for view in [illustration, title, detail, nameRow, profileRow, themeButton, profileName, createButton, backButton] { addSubview(view) }
        for view in [iconButton, name] { nameRow.addSubview(view) }
        for view in [profileGlyph, profileLabel, profiles, profileInfo] { profileRow.addSubview(view) }
        setAccessibilityIdentifier("space-pager-create")
        updateColors()
        renderIcon()
        refreshValidation()
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func configure(profiles catalog: [BrowserProfile], selected: ProfileID?) {
        profileIDs = catalog.map(\.id)
        profiles.removeAllItems()
        profiles.addItems(withTitles: catalog.map(\.name))
        profiles.addItem(withTitle: uiText("New Profile…"))
        if let selected, let index = profileIDs.firstIndex(of: selected) { profiles.selectItem(at: index) }
        profileChanged()
    }

    func focusName() { window?.makeFirstResponder(name) }
    func closePickers() {
        iconPicker?.popup.performClose(nil); iconPicker = nil
        themePicker?.performClose(nil); themePicker = nil; themeView = nil; themePresentation = nil
    }
    var hasPicker: Bool { iconPicker != nil || themePicker?.isShown == true }

    @objc func profileChanged() {
        profileName.isHidden = profiles.indexOfSelectedItem != profileIDs.count
        refreshValidation(); needsLayout = true
    }
    func controlTextDidChange(_ notification: Notification) { refreshValidation() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { back(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { create(); return true }
        return false
    }
    private func validName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    func refreshValidation() {
        let composing = [name, profileName].contains { ($0.currentEditor() as? NSTextView)?.hasMarkedText() == true }
        createButton.isEnabled = !submitted && !composing && validName(name.stringValue)
            && (profileIDs.indices.contains(profiles.indexOfSelectedItem) || (!profileName.isHidden && validName(profileName.stringValue)))
    }
    func creationFailed() { submitted = false; refreshValidation() }
    @objc func create() {
        refreshValidation()
        guard createButton.isEnabled else { return }
        submitted = true; refreshValidation(); closePickers()
        let index = profiles.indexOfSelectedItem
        onCreate?(name.stringValue, profileIDs.indices.contains(index) ? profileIDs[index] : nil,
                  index == profileIDs.count ? profileName.stringValue : nil, icon, theme)
    }
    @objc private func back() { guard !submitted else { return }; closePickers(); onBack?() }

    func setIcon(_ choice: BrowserSpaceIcon) { guard choice.isValid else { return }; icon = choice; renderIcon() }
    private func renderIcon() {
        iconButton.title = ""
        iconButton.image = icon == .none ? Self.emptyIcon() : (SpaceIconImages.view(icon, pointSize: 17) as? NSImageView)?.image
        iconButton.contentTintColor = .secondaryLabelColor
        iconButton.imagePosition = .imageOnly
        iconButton.imageScaling = .scaleProportionallyDown
    }
    @objc func chooseIcon() {
        closePickers()
        let picker = SpaceIconPicker(currentChoice: icon, accent: OrbitSpaceThemes.accent(for: OrbitSpaceThemes.rendered(theme)))
        picker.onChooseIcon = { [weak self] in self?.setIcon($0) }
        picker.onClose = { [weak self] in self?.iconPicker = nil }
        iconPicker = picker
        if !picker.show(relativeTo: iconButton) { iconPicker = nil }
    }
    @objc func chooseTheme() {
        closePickers()
        let editor = OrbitThemeEditorView(state: OrbitThemeEditorState(theme: theme))
        editor.surfaceScope.stringValue = uiText("New Space")
        let presentation = SpacePickerPopover()
        let popup = presentation.popover
        popup.contentSize = OrbitThemeEditorMetrics.pickerSize
        popup.appearance = effectiveAppearance
        let controller = NSViewController(); controller.view = editor.makePickerViewport()
        presentation.contentViewController = controller
        editor.onChange = { [weak self] state in
            self?.theme = state.theme; self?.onTheme?(state.theme)
            self?.superview?.superview?.needsLayout = true
        }
        editor.onDismiss = { [weak presentation] in presentation?.performClose(nil) }
        presentation.onClose = { [weak self] in
            self?.themePicker = nil; self?.themeView = nil; self?.themePresentation = nil
        }
        themePresentation = presentation
        themePicker = popup; themeView = editor
        presentation.show(relativeTo: themeButton.bounds, of: themeButton, preferredEdge: .maxX)
    }

    private static func emptyIcon() -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            NSColor.secondaryLabelColor.setStroke()
            let box = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 17, height: 17), xRadius: 3, yRadius: 3)
            box.lineWidth = 1; box.setLineDash([2, 2], count: 2, phase: 0); box.stroke()
            let plus = NSBezierPath(); plus.move(to: NSPoint(x: 6, y: 10)); plus.line(to: NSPoint(x: 14, y: 10))
            plus.move(to: NSPoint(x: 10, y: 6)); plus.line(to: NSPoint(x: 10, y: 14)); plus.lineWidth = 1.5; plus.stroke()
            return true
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            for row in [nameRow, profileRow] { row.layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.10) : OrbitTokens.Color.State.sidebarItem).cgColor }
        }
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14, width = max(0, bounds.width - 2 * inset)
        illustration.frame = NSRect(x: (bounds.width - 70) / 2, y: 39, width: 70, height: 44)
        title.frame = NSRect(x: inset, y: 95, width: width, height: 23)
        let detailWidth = min(width, 230)
        detail.frame = NSRect(x: (bounds.width - detailWidth) / 2, y: 129, width: detailWidth, height: 38)
        nameRow.frame = NSRect(x: inset, y: 194, width: width, height: 36)
        iconButton.frame = NSRect(x: 7, y: 7, width: 22, height: 22)
        name.frame = NSRect(x: 34, y: 9, width: max(0, width - 42), height: 21)
        profileRow.frame = NSRect(x: inset, y: 236, width: width, height: 36)
        profileGlyph.frame = NSRect(x: 10, y: 11, width: 12, height: 14)
        profileLabel.frame = NSRect(x: 32, y: 10, width: 48, height: 20)
        let popupWidth = min(max(65, (profiles.titleOfSelectedItem ?? "").size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 32), max(65, width - 115))
        profiles.frame = NSRect(x: 80, y: 7, width: popupWidth, height: 22)
        profileInfo.frame = NSRect(x: width - 22, y: 12, width: 12, height: 12)
        themeButton.frame = NSRect(x: inset, y: 280, width: width, height: 36)
        profileName.frame = NSRect(x: inset, y: 326, width: width, height: 24)
        createButton.frame = NSRect(x: inset, y: max(366, bounds.height - 81), width: width, height: 36)
        backButton.frame = NSRect(x: inset, y: max(412, bounds.height - 35), width: width, height: 24)
    }
}

/// Native vector drawings for the creation page.
@MainActor
final class SpaceCreationIllustration: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for (x, angle, symbol) in [(7.0, -15.0, "leaf.fill"), (40.0, 15.0, "books.vertical.fill"), (24.0, 0.0, "laptopcomputer")] {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: x + 11, yBy: 22); transform.rotate(byDegrees: angle); transform.concat()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: -15, y: -20, width: 30, height: 39), xRadius: 3, yRadius: 3).fill()
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            let color: NSColor = symbol == "laptopcomputer" ? .darkGray : .systemGreen
            let config = NSImage.SymbolConfiguration(pointSize: 23, weight: .regular).applying(.init(paletteColors: [color]))
            image.withSymbolConfiguration(config)?.draw(in: NSRect(x: -12, y: -10, width: 24, height: 20))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

@MainActor
final class SpaceCreationButton: NSButton {
    var primary = false
    var link = false
    var symbol: String?
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if !link {
            // Blue accent in the Display P3 color space.
            let fill = primary ? NSColor(displayP3Red: 49 / 255, green: 57 / 255, blue: 251 / 255, alpha: isEnabled ? 1 : 0.4)
                : (dark ? NSColor.white.withAlphaComponent(0.12) : OrbitTokens.Color.State.sidebarItem)
            fill.withAlphaComponent(fill.alphaComponent * (isHighlighted ? 0.8 : 1)).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: primary ? 8 : 6, yRadius: primary ? 8 : 6).fill()
        }
        let color: NSColor = primary ? NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.4) : link ? .secondaryLabelColor : .labelColor
        let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color])
        let size = text.size(), x = symbol == nil ? (bounds.width - size.width) / 2 : 32
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))?.draw(in: NSRect(x: 10, y: 11, width: 12, height: 14))
        }
    }
}

@MainActor
private final class SpaceCreationProfileCell: NSPopUpButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: cellFrame, xRadius: 11, yRadius: 11).fill()
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor])
        text.draw(at: NSPoint(x: cellFrame.minX + 9, y: cellFrame.midY - text.size().height / 2))
        NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.labelColor]))?.draw(in: NSRect(x: cellFrame.maxX - 18, y: cellFrame.midY - 5, width: 10, height: 10))
    }
}
