import AppKit
import BrowserCore

extension OrbitTokens {
    /// Reconstruction [L]: no calibrated Orbit switcher capture exists yet.
    enum Switcher {
        static let visibleCards = 7
        static let thumbnailWidth: CGFloat = 200
        static let thumbnailHeight: CGFloat = 125
        static let cardWidth: CGFloat = 216
        static let cardHeight: CGFloat = 165
        static let padding: CGFloat = 16
        static let gap: CGFloat = 8
        static let radius: CGFloat = 12
        static let titleSize: CGFloat = 13
        static let border: CGFloat = 2
        static let maximumWidth: CGFloat = 920
        static let revealDelay: UInt64 = 120_000_000
    }
}

@MainActor
final class BrowserSwitcherView: NSView {
    struct Item {
        let id: TabOccurrenceID
        let title: String
        let image: NSImage?
        let icon: NSImage?
    }
    var onHover: ((TabOccurrenceID) -> Void)?
    var onChoose: ((TabOccurrenceID) -> Void)?
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var cards: [SwitcherCard] = []
    private var lastAnnouncedID: TabOccurrenceID?
    private(set) var allocatedCardCount = 0
    var postSelection: (NSView, String) -> Void = { view, title in
        NSAccessibility.post(element: view, notification: .selectedChildrenChanged)
        NSAccessibility.post(element: view, notification: .announcementRequested,
            userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    static func cardsThatFit(width: CGFloat) -> Int {
        let available = min(width - OrbitTokens.Switcher.padding * 2, OrbitTokens.Switcher.maximumWidth)
            - OrbitTokens.Switcher.padding * 2
        return max(1, min(OrbitTokens.Switcher.visibleCards,
            Int((available + OrbitTokens.Switcher.gap) / (OrbitTokens.Switcher.cardWidth + OrbitTokens.Switcher.gap))))
    }

    var cardIdentities: [ObjectIdentifier] { cards.map(ObjectIdentifier.init) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = OrbitTokens.Color.Surface.popover.cgColor
        layer?.cornerRadius = OrbitTokens.Switcher.radius
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = OrbitTokens.Switcher.gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.documentView = stack
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OrbitTokens.Switcher.padding),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OrbitTokens.Switcher.padding),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: OrbitTokens.Switcher.padding),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -OrbitTokens.Switcher.padding)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Tab Switcher"))
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = OrbitTokens.Color.Surface.popover.cgColor
    }

    func render(_ items: [Item], selected: TabOccurrenceID?) {
        while cards.count < items.count {
            let card = SwitcherCard()
            card.onHover = { [weak self, weak card] in
                if let id = card?.itemID { self?.onHover?(id) }
            }
            card.onChoose = { [weak self, weak card] in
                if let id = card?.itemID { self?.onChoose?(id) }
            }
            cards.append(card)
            allocatedCardCount += 1
            stack.addArrangedSubview(card)
        }
        for (index, card) in cards.enumerated() {
            card.isHidden = index >= items.count
            if index < items.count { card.update(items[index], selected: selected == items[index].id) }
        }
        stack.frame.size = stack.fittingSize
        if let selected, let index = items.firstIndex(where: { $0.id == selected }) {
            stack.scrollToVisible(cards[index].frame)
            if lastAnnouncedID != selected {
                lastAnnouncedID = selected
                postSelection(self, items[index].title)
            }
        }

    }
}

@MainActor
private final class SwitcherCard: NSButton {
    var itemID: TabOccurrenceID?
    private let preview = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    var onHover: (() -> Void)?
    var onChoose: (() -> Void)?
    private var hoverArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        target = self
        action = #selector(choose)
        wantsLayer = true
        layer?.cornerRadius = OrbitTokens.Switcher.radius
        layer?.borderWidth = OrbitTokens.Switcher.border
        preview.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: OrbitTokens.Switcher.titleSize, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = OrbitTokens.Color.Text.primary
        for view in [preview, label, icon] { view.setAccessibilityElement(false); addSubview(view) }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: OrbitTokens.Switcher.cardWidth),
            heightAnchor.constraint(equalToConstant: OrbitTokens.Switcher.cardHeight)])
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let gap = OrbitTokens.Switcher.gap
        preview.frame = NSRect(x: gap, y: bounds.height - gap - OrbitTokens.Switcher.thumbnailHeight,
            width: OrbitTokens.Switcher.thumbnailWidth, height: OrbitTokens.Switcher.thumbnailHeight)
        icon.frame = NSRect(x: gap, y: gap, width: OrbitTokens.Switcher.padding, height: OrbitTokens.Switcher.padding)
        label.frame = NSRect(x: icon.frame.maxX + gap, y: gap,
            width: bounds.width - icon.frame.maxX - gap * 2, height: OrbitTokens.Switcher.padding)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    @objc private func choose() { onChoose?() }
    func update(_ item: BrowserSwitcherView.Item, selected: Bool) {
        itemID = item.id
        label.stringValue = item.title
        preview.image = item.image ?? item.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.image = item.icon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        layer?.borderColor = (selected ? NSColor.controlAccentColor : .clear).cgColor
        setAccessibilityLabel(item.title)
        setAccessibilityValue(selected ? uiText("Selected") : "")
    }
}
