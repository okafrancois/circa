import AppKit
import BrowserCore

/// A pager-local draft: nothing is persisted until Create. Both pickers are shared with Spaces.
@MainActor
final class SidebarNewSpacePageView: NSView, NSTextFieldDelegate {
    let name = NSTextField()
    let profiles = NSPopUpButton(frame: .zero, pullsDown: false)
    let profileName = NSTextField()
    let iconButton = NSButton(title: "", target: nil, action: nil)
    let themeButton = NSButton(title: uiText("Theme Color"), target: nil, action: nil)
    let createButton = NSButton(title: uiText("Create Space"), target: nil, action: nil)
    let backButton = NSButton(title: uiText("Back"), target: nil, action: nil)
    private let title = NSTextField(labelWithString: uiText("Create a Space"))
    private let profileLabel = NSTextField(labelWithString: uiText("Browsing Profile"))
    private let detail = NSTextField(wrappingLabelWithString: uiText("Separate your tabs for life, work, projects, and more."))
    private(set) var icon: BrowserSpaceIcon = .none
    private(set) var theme = BrowserSpaceThemePresets.default
    private var profileIDs: [ProfileID] = []
    private(set) var iconPicker: SpaceIconPicker?
    private(set) var themePicker: NSPopover?
    private(set) var themeView: OrbitThemeEditorView?
    private var submitted = false
    var onCreate: ((String, ProfileID?, String?, BrowserSpaceIcon, BrowserSpaceTheme) -> Void)?
    var onBack: (() -> Void)?
    var onTheme: ((BrowserSpaceTheme) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: 17, weight: .bold)
        detail.font = .systemFont(ofSize: 12)
        profileLabel.font = .systemFont(ofSize: 11, weight: .medium)
        for field in [title, detail, profileLabel] { field.textColor = OrbitTokens.Color.Text.primary }
        name.placeholderString = uiText("Space Name")
        name.font = .systemFont(ofSize: 17, weight: .medium)
        name.delegate = self
        name.setAccessibilityLabel(uiText("Space Name"))
        name.setAccessibilityIdentifier("space-create-name")
        profileName.placeholderString = uiText("New Profile Name")
        profileName.setAccessibilityLabel(uiText("New Profile Name"))
        profileName.delegate = self
        profiles.setAccessibilityLabel(uiText("Browsing Profile"))
        profiles.target = self; profiles.action = #selector(profileChanged)
        for button in [iconButton, themeButton, createButton, backButton] { button.bezelStyle = .rounded; button.target = self }
        iconButton.action = #selector(chooseIcon)
        iconButton.setAccessibilityLabel(uiText("Change Space Icon or Emoji"))
        themeButton.action = #selector(chooseTheme)
        createButton.action = #selector(create)
        createButton.setAccessibilityIdentifier("space-create-submit")
        backButton.action = #selector(back)
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        backButton.imagePosition = .imageLeading
        for view in [backButton, title, detail, iconButton, name, themeButton, profileLabel, profiles, profileName, createButton] { addSubview(view) }
        setAccessibilityIdentifier("space-pager-create")
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
        themePicker?.performClose(nil); themePicker = nil; themeView = nil
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
        iconButton.image = (SpaceIconImages.view(icon, pointSize: 23) as? NSImageView)?.image
        iconButton.imagePosition = .imageOnly
        iconButton.imageScaling = .scaleProportionallyDown
    }
    @objc func chooseIcon() {
        let picker = SpaceIconPicker(currentChoice: icon, accent: OrbitSpaceThemes.accent(for: OrbitSpaceThemes.rendered(theme)))
        picker.onChooseIcon = { [weak self] in self?.setIcon($0) }
        picker.onClose = { [weak self] in self?.iconPicker = nil }
        iconPicker = picker
        if !picker.show(relativeTo: iconButton) { iconPicker = nil }
    }
    @objc func chooseTheme() {
        let editor = OrbitThemeEditorView(state: OrbitThemeEditorState(theme: theme))
        editor.surfaceScope.stringValue = uiText("New Space")
        let popup = NSPopover()
        popup.behavior = .transient
        popup.contentSize = OrbitThemeEditorMetrics.size
        let controller = NSViewController(); controller.view = editor
        popup.contentViewController = controller
        editor.onChange = { [weak self] state in
            self?.theme = state.theme; self?.onTheme?(state.theme)
        }
        editor.onDismiss = { [weak popup] in popup?.performClose(nil) }
        themePicker = popup; themeView = editor
        popup.show(relativeTo: themeButton.bounds, of: themeButton, preferredEdge: .maxX)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 16, width = max(0, bounds.width - 2 * inset)
        backButton.frame = NSRect(x: inset - 4, y: 12, width: 76, height: 26)
        title.frame = NSRect(x: inset, y: 54, width: width, height: 24)
        detail.frame = NSRect(x: inset, y: 88, width: width, height: 48)
        iconButton.frame = NSRect(x: inset, y: 146, width: 42, height: 38)
        name.frame = NSRect(x: inset + 50, y: 151, width: max(0, width - 50), height: 28)
        themeButton.frame = NSRect(x: inset, y: 200, width: width, height: 30)
        profileLabel.frame = NSRect(x: inset, y: 250, width: width, height: 18)
        profiles.frame = NSRect(x: inset - 3, y: 274, width: width + 6, height: 28)
        profileName.frame = NSRect(x: inset, y: 316, width: width, height: 24)
        createButton.frame = NSRect(x: inset, y: max(358, bounds.height - 58), width: width, height: 34)
    }
}
