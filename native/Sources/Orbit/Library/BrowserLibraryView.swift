import AppKit
import BrowserCore
import BrowserShell

func libraryText(_ key: String, _ fallback: String) -> String { uiText(fallback) }

/// The Library shares the window's background; only its destination rail adds a tint.
@MainActor
final class BrowserLibraryView: NSView {
    static let railWidth: CGFloat = 112
    let body = NSView()
    let railBackground = NSView()
    private(set) var categoryButtons: [BrowserLibraryCategory: BrowserLibraryCategoryButton] = [:]
    private let rail = NSView()
    var onCategory: ((BrowserLibraryCategory) -> Void)?
    var onBack: (() -> Void)?
    var onGeometryChange: (() -> Void)?
    var acceptsLibraryInput = false
    var isBelowSidebarDuringTransition = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        railBackground.translatesAutoresizingMaskIntoConstraints = false
        railBackground.wantsLayer = true
        addSubview(railBackground)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.wantsLayer = true
        body.layer?.masksToBounds = true
        addSubview(body)
        addSubview(rail)
        for category in BrowserLibraryCategory.railCategories {
            let button = BrowserLibraryCategoryButton(category: category)
            button.target = self
            button.action = #selector(selectCategory(_:))
            categoryButtons[category] = button
            rail.addSubview(button)
        }
        let back = OrbitGlyphButton(glyph: OrbitGlyph.symbol("arrow.left", pointSize: 17, weight: .regular), label: uiText("Exit Library"))
        back.toolTip = uiText("Exit Library")
        back.target = self
        back.action = #selector(goBack)
        back.setAccessibilityIdentifier("library-back")
        back.translatesAutoresizingMaskIntoConstraints = false
        addSubview(back)
        NSLayoutConstraint.activate([
            railBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            railBackground.widthAnchor.constraint(equalToConstant: Self.railWidth),
            railBackground.topAnchor.constraint(equalTo: topAnchor),
            railBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            back.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            back.widthAnchor.constraint(equalToConstant: 32), back.heightAnchor.constraint(equalToConstant: 32),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.railWidth),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor)

        ])
        setAccessibilityIdentifier("browser-library")
        setAccessibilityLabel(uiText("Library"))
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        // Keep the rail out of the window's fitting-size calculation. Otherwise a previously tall
        // window's preferred rail height prevents AppKit from making the window shorter.
        let span = min(580, max(0, bounds.height - 100))
        rail.frame = NSRect(x: 8, y: (bounds.height - span) / 2 + 5, width: 97, height: span)
        let categories = BrowserLibraryCategory.railCategories
        // Orbit spreads six entries (Media, Downloads, Easels, Spaces, Boosts, Archived Tabs) over
        // the rail. Keep Orbit's pitch for the entries Orbit has and centre the group.
        let orbitEntries: CGFloat = 6
        let height = min(80, span / orbitEntries)
        let pitch = (span - height) / (orbitEntries - 1)
        let group = height + pitch * CGFloat(max(0, categories.count - 1))
        let top = span - max(0, span - group) / 2
        for (index, category) in categories.enumerated() {
            categoryButtons[category]?.frame = NSRect(x: 0, y: top - height - CGFloat(index) * pitch, width: 97, height: height)
        }
        onGeometryChange?()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { acceptsLibraryInput ? super.hitTest(point) : nil }
    override func cancelOperation(_ sender: Any?) { onBack?() }

    func select(_ category: BrowserLibraryCategory, theme: OrbitTokens.SpaceTheme) {
        updatePageAppearance()
        for (destination, button) in categoryButtons { button.state = destination == category ? .on : .off }
    }
    @objc private func selectCategory(_ sender: BrowserLibraryCategoryButton) {
        guard acceptsLibraryInput else { return }
        onCategory?(sender.category)
    }
    @objc private func goBack() { onBack?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePageAppearance()
    }

    private func updatePageAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            railBackground.layer?.backgroundColor = BrowserLibraryStyle.railTint.cgColor
        }
    }
}

/// HomeButton Background/Background2, measured statically in navy 7/12%, white 10/15%.
@MainActor
final class BrowserLibraryCategoryButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { .init() }
    let category: BrowserLibraryCategory
    private var hovered = false
    private var tracking: NSTrackingArea?
    init(category: BrowserLibraryCategory) {
        self.category = category
        super.init(frame: .zero)
        title = category.title
        image = NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil)
        imagePosition = .imageAbove
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 11, weight: .bold)
        isBordered = false
        setButtonType(.toggle)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 12
        setAccessibilityIdentifier("library-category-\(category)")
        setAccessibilityLabel(category.title)
    }
    required init?(coder: NSCoder) { nil }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let alpha: CGFloat = state == .on ? (dark ? 0.15 : 0.12) : hovered ? (dark ? 0.10 : 0.07) : 0
        let ink = dark ? NSColor.white : NSColor(srgbRed: 0, green: 0, blue: 0.092, alpha: 1)
        ink.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let foreground = ink.withAlphaComponent(state == .on ? 1 : 0.65)
        let groupTop = (bounds.height - 45) / 2
        let glyphRect = NSRect(x: (bounds.width - 28) / 2, y: isFlipped ? groupTop : bounds.height - groupTop - 28, width: 28, height: 28)
        let glyph = image?.withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
        glyph?.withSymbolConfiguration(.init(paletteColors: [foreground]))?.draw(in: glyphRect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: foreground, .paragraphStyle: paragraph])
        text.draw(with: NSRect(x: 0, y: isFlipped ? groupTop + 32 : bounds.height - groupTop - 45, width: bounds.width, height: 13),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

@MainActor
final class BrowserLibraryPresentation {
    let view = BrowserLibraryView()
    let drawer = BrowserLibraryDrawer()
    var widthConstraint: NSLayoutConstraint?
    var spacesWidthConstraint: NSLayoutConstraint?
    let swipe = BrowserLibrarySwipeController()
    var displayedProfileID: ProfileID? { didSet { if displayedProfileID != oldValue { revokeSelections() } } }
    let history = BrowserLibraryHistoryModel()
    let historyView = BrowserLibraryHistoryView()
    let spacesView = BrowserLibrarySpacesView()
    let mediaView = BrowserLibraryMediaView()
    var spacesTask: Task<Void, Never>?
    var presentationID = UUID() { didSet { if presentationID != oldValue { revokeSelections() } } }
    private var selections: [UUID: CatalogSelectionAdmission] = [:]
    /// Tests inject a response without presenting a sheet or activating a window.
    var historyConfirmation: (@MainActor (NSAlert) async -> NSApplication.ModalResponse)?
    var confirmationTask: Task<Void, Never>?
    var deletionTask: Task<Void, Never>?
    var category: BrowserLibraryCategory = .downloads { didSet { if category != oldValue { revokeSelections() } } }
    var isPresented = false { didSet { if !isPresented { revokeSelections() } } }

    func beginSelection() -> (UUID, CatalogSelectionAdmission) {
        // Only the latest not-yet-admitted inventory click remains pending.
        revokeSelections()
        let id = UUID(), admission = CatalogSelectionAdmission()
        selections[id] = admission
        return (id, admission)
    }
    func finishSelection(_ id: UUID) { selections.removeValue(forKey: id)?.revoke() }
    func revokeSelections() {
        for admission in selections.values { admission.revoke() }
        selections.removeAll()
    }
    deinit { for admission in selections.values { admission.revoke() } }
}
