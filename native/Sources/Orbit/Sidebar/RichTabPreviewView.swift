import AppKit
import BrowserCore
import BrowserShell

struct RichTabPreviewIdentity: Equatable {
    let profile: ProfileID
    let space: SpaceID
    let tab: TabID
    let occurrence: TabOccurrenceID?
    let generation: UInt64?
    let url: URL
    let section: BrowserOrganizationSection
}

struct RichTabPreviewContent {
    let identity: RichTabPreviewIdentity
    let title: String
    let icon: NSImage?
    let snapshot: NSImage?
    var canAsk = false
    var isPinned: Bool { if case .pinned = identity.section { return true }; return false }
    var isFavorite: Bool { if case .favorites = identity.section { return true }; return false }
}

enum RichTabPreviewAction: Int, CaseIterable { case pin, favorite, split, ask }

@MainActor
final class RichTabPreviewView: NSView {
    static let size = NSSize(width: 240, height: 248)
    let title = NSTextField(labelWithString: "")
    let picture = RichTabPreviewImageView()
    let placeholder = NSImageView()
    private(set) var buttons: [OrbitGlyphButton] = []
    var onAction: ((RichTabPreviewAction) -> Void)?
    var onPointer: ((Bool) -> Void)?
    var isInteractive = true
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        OrbitFloatingMaterial.install(in: self, radius: 14)
        wantsLayer = true
        layer?.cornerRadius = 14
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 14
        picture.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        picture.layer?.masksToBounds = true
        placeholder.imageScaling = .scaleProportionallyDown
        title.font = BrandTextStyle.ui.font(size: 15, weight: .medium)
        title.textColor = OrbitFloatingMaterial.body
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        for item in [picture, placeholder, title] { addSubview(item) }
        for (index, symbol) in ["pin", "bookmark", "rectangle.split.2x1", "bubble.left"].enumerated() {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            let button = OrbitGlyphButton(glyph: image, label: "")
            button.tag = index
            button.target = self
            button.action = #selector(invoke(_:))
            button.tint = OrbitFloatingMaterial.secondary
            button.setAccessibilityIdentifier("rich-tab-preview-action-" + String(index))
            buttons.append(button)
            addSubview(button)
        }
        setAccessibilityIdentifier("rich-tab-preview")
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isInteractive ? super.hitTest(point) : nil }

    func configure(_ content: RichTabPreviewContent) {
        title.stringValue = content.title
        picture.image = content.snapshot
        placeholder.image = content.icon
        placeholder.isHidden = content.snapshot != nil
        let labels = [content.isPinned ? uiText("Unpin Tab") : uiText("Pin Tab"),
                      content.isFavorite ? uiText("Remove from Favorites") : uiText("Add to Favorites"),
                      uiText("Open in Split View"), uiText("Ask about this tab")]
        for (index, button) in buttons.enumerated() {
            button.setAccessibilityLabel(labels[index])
            button.toolTip = labels[index]
            button.isEnabled = index == 3 ? content.canAsk : index != 0 || !content.isFavorite
        }
        needsLayout = true
    }

    func clear() {
        picture.image = nil
        placeholder.image = nil
        title.stringValue = ""
        for button in buttons { button.isEnabled = false }
    }

    override func layout() {
        super.layout()
        picture.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 135)
        placeholder.frame = NSRect(x: (bounds.width - 40) / 2, y: 47, width: 40, height: 40)
        title.frame = NSRect(x: 16, y: 151, width: max(0, bounds.width - 32), height: 40)
        let spacing = max(28, (bounds.width - 60) / 3)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 16 + CGFloat(index) * spacing, y: 207, width: 28, height: 28)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        tracking = next
        addTrackingArea(next)
    }
    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }
    @objc private func invoke(_ sender: NSButton) {
        guard isInteractive, sender.isEnabled, let action = RichTabPreviewAction(rawValue: sender.tag) else { return }
        onAction?(action)
    }
}

@MainActor
final class RichTabPreviewImageView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
