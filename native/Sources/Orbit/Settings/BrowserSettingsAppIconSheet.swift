import AppKit
import BrowserShell
import SwiftUI

@MainActor
final class BrowserSettingsAppIconRow: NSView {
    let icon: OrbitAppIcon
    let radio = AppIconRadioButton(radioButtonWithTitle: "", target: nil, action: nil)
    let artwork = NSImageView()
    let nameLabel: NSTextField
    let currentLabel = NSTextField(labelWithString: uiText("Current icon"))
    let detailLabel: NSTextField
    var onSelect: (() -> Void)?
    override var isFlipped: Bool { true }

    init(icon: OrbitAppIcon, current: OrbitAppIcon) {
        self.icon = icon
        nameLabel = NSTextField(labelWithString: icon.name)
        detailLabel = NSTextField(labelWithString: icon.description)
        super.init(frame: NSRect(x: 0, y: 0, width: 516, height: 70))
        radio.target = self; radio.action = #selector(selectIcon)
        radio.setAccessibilityLabel(icon.name)
        radio.setAccessibilityIdentifier("app-icon-radio-" + icon.id)
        artwork.image = icon.preview; artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.setAccessibilityElement(false)
        nameLabel.font = BrandFonts.ui(13, weight: .semibold)
        currentLabel.font = BrandFonts.mono(10); currentLabel.textColor = .controlAccentColor
        currentLabel.isHidden = icon != current
        detailLabel.font = BrandFonts.ui(12); detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 1; detailLabel.lineBreakMode = .byTruncatingTail
        [radio, artwork, nameLabel, currentLabel, detailLabel].forEach { addSubview($0) }
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(selectIcon)))
        setAccessibilityIdentifier("app-icon-row-" + icon.id)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func selectIcon() { onSelect?() }
    override func layout() {
        super.layout()
        radio.frame = NSRect(x: 6, y: 26, width: 18, height: 18)
        artwork.frame = NSRect(x: 32, y: 4, width: 62, height: 62)
        nameLabel.sizeToFit(); currentLabel.sizeToFit()
        nameLabel.frame.origin = NSPoint(x: 104, y: 16)
        currentLabel.frame.origin = NSPoint(x: nameLabel.frame.maxX + 8, y: 19)
        detailLabel.frame = NSRect(x: 104, y: 37, width: max(0, bounds.width - 110), height: 18)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }
}

@MainActor
final class BrowserSettingsAppIconSheet: NSWindowController {
    let icons: OrbitAppIconController
    private(set) var selection: OrbitAppIcon
    private(set) var rows: [BrowserSettingsAppIconRow] = []
    let useButton = NSButton(title: uiText("Use Icon"), target: nil, action: nil)
    let restoreButton = NSButton(title: uiText("Restore Default"), target: nil, action: nil)
    private var originalParentFrame: NSRect?
    private weak var parent: NSWindow?
    var onClose: (() -> Void)?
    static let size = NSSize(width: 560, height: 498)

    init(icons: OrbitAppIconController) {
        self.icons = icons; selection = icons.current
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = OrbitSettingsStyle.windowColor
        window.identifier = NSUserInterfaceItemIdentifier("settings-app-icon-sheet")
        super.init(window: window)
        let root = AppIconSheetBackground(frame: NSRect(origin: .zero, size: Self.size))
        window.contentView = root
        let title = NSTextField(labelWithString: uiText("App Icon"))
        title.font = BrandTextStyle.ui.font(size: 22, weight: .semibold)
        title.frame = NSRect(x: 22, y: 451, width: 516, height: 30)
        let subtitle = NSTextField(labelWithString: uiText("Choose how Circa looks in the Dock and the Finder."))
        subtitle.font = BrandFonts.ui(13); subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 22, y: 428, width: 516, height: 20)
        root.addSubview(title); root.addSubview(subtitle)
        let scroll = NSScrollView(frame: NSRect(x: 22, y: 62, width: 516, height: 352))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let list = AppIconListView(frame: NSRect(x: 0, y: 0, width: 516, height: 490))
        for (index, icon) in OrbitAppIcon.allCases.enumerated() {
            let row = BrowserSettingsAppIconRow(icon: icon, current: icons.current)
            row.frame.origin.y = CGFloat(index) * 70
            row.onSelect = { [weak self] in self?.select(icon) }
            list.addSubview(row); rows.append(row)
        }
        scroll.documentView = list; root.addSubview(scroll)
        let cancel = NSButton(title: uiText("Cancel"), target: self, action: #selector(cancelSheet))
        restoreButton.target = self; restoreButton.action = #selector(restoreDefault)
        useButton.target = self; useButton.action = #selector(useIcon)
        for button in [restoreButton, cancel, useButton] {
            button.bezelStyle = .rounded; button.font = BrandFonts.ui(13)
            // Secondary controls remain neutral, independent of the selected accent.
            button.contentTintColor = .labelColor
            root.addSubview(button)
        }
        restoreButton.frame = NSRect(x: 22, y: 16, width: 128, height: 32)
        cancel.frame = NSRect(x: 369, y: 16, width: 76, height: 32)
        useButton.frame = NSRect(x: 451, y: 16, width: 87, height: 32)
        useButton.contentTintColor = nil; useButton.bezelColor = .controlAccentColor
        useButton.keyEquivalent = "\r"; cancel.keyEquivalent = "\u{1b}"
        useButton.setAccessibilityIdentifier("app-icon-use")
        cancel.setAccessibilityIdentifier("app-icon-cancel")
        restoreButton.setAccessibilityIdentifier("app-icon-restore")
        syncSelection()
    }
    required init?(coder: NSCoder) { nil }

    func present(on parent: NSWindow) {
        guard parent.attachedSheet == nil, let window else { return }
        self.parent = parent; originalParentFrame = parent.frame
        window.appearance = parent.appearance
        var frame = parent.frame
        let height = parent.frameRect(forContentRect: NSRect(x: 0, y: 0, width: frame.width, height: 530)).height
        frame.origin.y -= max(0, height - frame.height); frame.size.height = max(height, frame.height)
        resize(parent, to: frame)
        parent.beginSheet(window) { [weak self] _ in
            guard let self else { return }
            if let frame = self.originalParentFrame { self.resize(parent, to: frame) }
            self.onClose?()
        }
    }
    private func resize(_ parent: NSWindow, to frame: NSRect) {
        guard !OrbitMotionPreferences.prefersReducedMotion else { parent.setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BrowserSettingsMotion.resizeDuration
            context.timingFunction = BrowserSettingsMotion.timingFunction
            parent.animator().setFrame(frame, display: true)
        }
    }
    func select(_ icon: OrbitAppIcon) { selection = icon; syncSelection() }
    private func syncSelection() {
        rows.forEach { $0.radio.state = $0.icon == selection ? .on : .off }
        useButton.isEnabled = selection != icons.current
        restoreButton.isEnabled = icons.current != .defaultIcon || selection != .defaultIcon
    }
    @objc func useIcon() { if icons.apply(selection) { dismiss() } }
    @objc func restoreDefault() { icons.restoreDefault(); dismiss() }
    @objc func cancelSheet() { dismiss() }
    private func dismiss() {
        if let parent, let window { parent.endSheet(window) }
        else { onClose?() }
    }
}

@MainActor
final class AppIconRadioButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        if state == .on {
            NSColor.controlAccentColor.setFill(); circle.fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5)).fill()
        } else {
            NSColor.controlBackgroundColor.setFill(); circle.fill()
            NSColor.tertiaryLabelColor.setStroke(); circle.lineWidth = 1; circle.stroke()
        }
    }
}

private final class AppIconSheetBackground: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackground()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }
    private func updateBackground() {
        layer?.backgroundColor = OrbitSettingsStyle.windowColor.resolvedCGColor(for: effectiveAppearance)
    }
}

private final class AppIconListView: NSView {
    override var isFlipped: Bool { true }
}

struct BrowserSettingsAppIconButton: NSViewRepresentable {
    let icons: OrbitAppIconController
    func makeCoordinator() -> Coordinator { Coordinator(icons: icons) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: uiText("App Icon…"), target: context.coordinator, action: #selector(Coordinator.open(_:)))
        button.bezelStyle = .rounded; button.font = BrandFonts.ui(13); button.contentTintColor = .labelColor
        button.setAccessibilityIdentifier("settings-app-icon")
        return button
    }
    func updateNSView(_ nsView: NSButton, context: Context) {}
    @MainActor final class Coordinator: NSObject {
        let icons: OrbitAppIconController
        var sheet: BrowserSettingsAppIconSheet?
        init(icons: OrbitAppIconController) { self.icons = icons }
        @objc func open(_ sender: NSButton) {
            guard let parent = sender.window, sheet == nil else { return }
            let sheet = BrowserSettingsAppIconSheet(icons: icons)
            self.sheet = sheet
            sheet.onClose = { [weak self] in self?.sheet = nil }
            sheet.present(on: parent)
        }
    }
}
