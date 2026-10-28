import AppKit

/// Persistent action views keep native popup anchors attached while the URL pill reflows.
@MainActor
final class SidebarExtensionStrip: SidebarFlippedView {
    static let hitSize: CGFloat = 28
    static let gap: CGFloat = 0
    private var pinnedButtons: [NSButton] = []
    private var widthConstraint: NSLayoutConstraint?
    var isAvailable = false {
        didSet {
            guard isAvailable != oldValue else { return }
            if !isAvailable { isHidden = true }
            superview?.superview?.needsLayout = true
        }
    }
    var availableWidth: CGFloat = 0 {
        didSet { if availableWidth != oldValue { updateLayout() } }
    }
    private(set) var visiblePinCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let width = widthAnchor.constraint(equalToConstant: 0)
        width.isActive = true
        widthConstraint = width
        heightAnchor.constraint(equalToConstant: Self.hitSize).isActive = true
    }
    required init?(coder: NSCoder) { nil }

    func setPinnedButtons(_ buttons: [NSButton]) {
        for previous in pinnedButtons where !buttons.contains(where: { $0 === previous }) {
            previous.removeFromSuperview()
        }
        pinnedButtons = buttons
        for button in buttons {
            if button.superview !== self { addSubview(button) }
            (button as? SiteControlButton)?.usesURLPillStyle = true
            button.image?.size = NSSize(width: 16, height: 16)
        }
        updateLayout()
    }

    private func updateLayout() {
        let pitch = Self.hitSize + Self.gap
        visiblePinCount = min(pinnedButtons.count, max(0, Int((availableWidth + Self.gap) / pitch)))
        let width = max(0, CGFloat(visiblePinCount) * pitch - Self.gap)
        if widthConstraint?.constant != width { widthConstraint?.constant = width }
        for (index, button) in pinnedButtons.enumerated() {
            button.isHidden = index >= visiblePinCount
            button.frame = NSRect(x: CGFloat(index) * pitch, y: 0, width: Self.hitSize, height: Self.hitSize)
        }
    }
}
