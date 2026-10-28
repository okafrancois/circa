import AppKit
import BrowserCore

/// Orbit's optional status line uses an AppKit ease-out layout transition, not the pager spring.
/// / : / ; ease-out import .
enum AddressStatusMotion {
    static let duration: TimeInterval = 0.12
    static let baseline: CGFloat = -4
    static let timingFunction = CAMediaTimingFunctionName.easeOut
}

/// Orbit replaces the selected host immediately on a Space switch. Editing and accessibility retain
/// the full URL. Only a separate status-presence change animates the label's baseline.
@MainActor
final class OrbitLocationField: NSTextField {
    private let displayLabel = AddressHostLabel(labelWithString: String())
    private var restingAlignment: NSLayoutConstraint!
    private var statusAlignment: NSLayoutConstraint!
    private(set) var hasStatus = false
    private(set) var pendingSpaceID: SpaceID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayLabel.translatesAutoresizingMaskIntoConstraints = false
        displayLabel.setAccessibilityElement(false)
        displayLabel.isSelectable = false
        displayLabel.cell?.lineBreakMode = .byTruncatingTail
        displayLabel.maximumNumberOfLines = 1
        addSubview(displayLabel)
        restingAlignment = displayLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        statusAlignment = displayLabel.lastBaselineAnchor.constraint(equalTo: centerYAnchor,
                                                                     constant: AddressStatusMotion.baseline)
        NSLayoutConstraint.activate([
            displayLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            displayLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            restingAlignment
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var stringValue: String { didSet { refreshDisplayLabel() } }

    func refreshAddress(_ value: String, in space: SpaceID?) {
        guard pendingSpaceID == nil || pendingSpaceID == space else { return }
        stringValue = value
    }

    func finishSpaceTransition(_ value: String, in space: SpaceID?, spaces: [BrowserSpace]) {
        let pending = pendingSpaceID
        pendingSpaceID = nil
        guard pending != nil else { return }
        stringValue = value
    }

    func setAddress(_ value: String, from source: SpaceID?, to destination: SpaceID?, spaces: [BrowserSpace],
                    awaitingPublication: Bool = false) {
        if awaitingPublication { pendingSpaceID = destination }
        else if pendingSpaceID == destination { pendingSpaceID = nil }
        else if pendingSpaceID != nil { return }
        stringValue = value
    }

    /// The status owner supplies visibility separately from URL publication. This affects only the
    /// label; status controls and the pill's button layout remain owned by their feature.
    func setStatusVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != hasStatus else { return }
        layoutSubtreeIfNeeded()
        hasStatus = visible
        let shouldAnimate = animated && window?.isVisible == true && !OrbitMotionPreferences.prefersReducedMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shouldAnimate ? AddressStatusMotion.duration : 0
            context.timingFunction = CAMediaTimingFunction(name: AddressStatusMotion.timingFunction)
            context.allowsImplicitAnimation = shouldAnimate
            NSLayoutConstraint.deactivate([restingAlignment, statusAlignment])
            (visible ? statusAlignment : restingAlignment)?.isActive = true
            layoutSubtreeIfNeeded()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        refreshDisplayLabel()
        if currentEditor() != nil || stringValue.isEmpty { super.draw(dirtyRect) }
    }

    private func refreshDisplayLabel() {
        displayLabel.isHidden = currentEditor() != nil || stringValue.isEmpty
        guard !displayLabel.isHidden else { return }
        let label: String
        if let url = URL(string: stringValue), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host {
            label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else { label = stringValue }
        if displayLabel.stringValue != label { displayLabel.stringValue = label }
        let labelFont = font ?? OrbitTokens.Typography.addressField
        let labelColor = textColor ?? OrbitTokens.Color.Text.baseSecondary
        if displayLabel.font != labelFont { displayLabel.font = labelFont }
        if displayLabel.textColor != labelColor { displayLabel.textColor = labelColor }
    }
}

@MainActor
private final class AddressHostLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
