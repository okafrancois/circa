import AppKit
import BrowserCore

/// Native editing/AX keep the full URL. The resting text, security glyph and optional status
/// share a clipped presentation group; selection replaces known text without a blank frame.
@MainActor
final class OrbitLocationField: NSTextField {
    /// AppKit's optical frame outsets can extend into adjacent address accessories.
    var textCursorRect: NSRect {
        guard let superview else { return visibleRect }
        return visibleRect.intersection(convert(alignmentRect(forFrame: frame), from: superview))
    }

    override func resetCursorRects() {
        if !textCursorRect.isEmpty { addCursorRect(textCursorRect, cursor: .iBeam) }
    }
    let textMask = AddressPresentationView()
    let textGroup = AddressPresentationView()
    let displayLabel = AddressHostLabel(labelWithString: String())
    let securityIcon = NSImageView()
    private let searchIcon = NSImageView()
    private let statusLabel = AddressHostLabel(labelWithString: String())
    private let statusButton = AddressStatusButton()
    private var restingAlignment: NSLayoutConstraint!
    private var statusAlignment: NSLayoutConstraint!
    private var textLeading: NSLayoutConstraint!
    private var statusPosition: NSLayoutConstraint!
    private(set) var hasStatus = false
    private(set) var pendingSpaceID: SpaceID?
    private(set) var security: BrowserSiteControlsModel.Connection = .unavailable
    private(set) var securitySymbol: String?
    var onStatusPress: (() -> Void)?
    var onAddressChange: ((Bool) -> Void)?
    /// Status producers supply their own localized message. No URL/domain heuristic fabricates one.
    var statusForSpace: ((SpaceID?) -> String?)?
    private var replacingSpace = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [textMask, textGroup, displayLabel, securityIcon, searchIcon, statusLabel] {
            view.wantsLayer = true
            view.setAccessibilityElement(false)
        }
        textMask.layer?.masksToBounds = true
        addSubview(textMask)
        statusButton.isBordered = false
        statusButton.isHidden = true
        statusButton.refusesFirstResponder = true
        statusButton.setAccessibilityElement(false)
        statusButton.target = self
        statusButton.action = #selector(pressStatus)
        addSubview(statusButton)
        textMask.addSubview(textGroup)
        textMask.addSubview(searchIcon)
        for view in [displayLabel, securityIcon, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            textGroup.addSubview(view)
        }
        for label in [displayLabel, statusLabel] {
            label.isSelectable = false
            label.cell?.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
        }
        restingAlignment = displayLabel.centerYAnchor.constraint(equalTo: textGroup.centerYAnchor)
        statusAlignment = displayLabel.lastBaselineAnchor.constraint(equalTo: textGroup.centerYAnchor,
                                                                     constant: AddressStatusMotion.baseline)
        textLeading = displayLabel.leadingAnchor.constraint(equalTo: textGroup.leadingAnchor, constant: 2)
        statusPosition = statusLabel.topAnchor.constraint(equalTo: textGroup.centerYAnchor, constant: 18)
        NSLayoutConstraint.activate([
            textLeading, displayLabel.trailingAnchor.constraint(equalTo: textGroup.trailingAnchor, constant: -2),
            restingAlignment,
            securityIcon.leadingAnchor.constraint(equalTo: textGroup.leadingAnchor, constant: 2),
            securityIcon.centerYAnchor.constraint(equalTo: displayLabel.centerYAnchor),
            securityIcon.widthAnchor.constraint(equalToConstant: 13),
            securityIcon.heightAnchor.constraint(equalToConstant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: displayLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: textGroup.trailingAnchor, constant: -2), statusPosition
        ])
        statusLabel.alphaValue = 0
        searchIcon.image = OrbitIcon.image(sfName: "magnifyingglass", pointSize: 14, accessibilityDescription: nil)
        refreshDisplayLabel()
    }

    required init?(coder: NSCoder) { nil }

    override var stringValue: String {
        didSet {
            let wasEmpty = oldValue.isEmpty
            refreshDisplayLabel()
            onAddressChange?(!stringValue.isEmpty)
            if replacingSpace, wasEmpty != stringValue.isEmpty {
                AddressStatusMotion.translate(textGroup, from: wasEmpty ? 22 : -22)
                animateSearchIcon(visible: stringValue.isEmpty)
            }
        }
    }

    func refreshAddress(_ value: String, in space: SpaceID?) {
        guard pendingSpaceID == nil || pendingSpaceID == space else { return }
        stringValue = value
    }

    func finishSpaceTransition(_ value: String, in space: SpaceID?, spaces: [BrowserSpace]) {
        let pending = pendingSpaceID
        pendingSpaceID = nil
        guard pending != nil else { return }
        applyAddress(value, in: space, animated: pending != space)
    }

    func setAddress(_ value: String, from source: SpaceID?, to destination: SpaceID?, spaces: [BrowserSpace],
                    awaitingPublication: Bool = false) {
        if awaitingPublication { pendingSpaceID = destination }
        else if pendingSpaceID == destination { pendingSpaceID = nil }
        else if pendingSpaceID != nil { return }
        applyAddress(value, in: destination, animated: source != nil && source != destination)
    }

    private func applyAddress(_ value: String, in space: SpaceID?, animated: Bool) {
        layoutSubtreeIfNeeded()
        replacingSpace = animated
        stringValue = value
        replacingSpace = false
        if let statusForSpace { setStatus(statusForSpace(space), animated: animated) }
        else if animated || value.isEmpty { setStatus(nil, animated: animated) }
    }

    func setStatus(_ message: String?, animated: Bool = true) {
        if let message { statusLabel.stringValue = message }
        setStatusVisible(message?.isEmpty == false, animated: animated)
    }

    func setStatusVisible(_ visible: Bool, animated: Bool = true) {
        guard visible != hasStatus else { return }
        layoutSubtreeIfNeeded()
        hasStatus = visible
        AddressStatusMotion.animate(self, changes: {
            NSLayoutConstraint.deactivate([restingAlignment, statusAlignment])
            (visible ? statusAlignment : restingAlignment)?.isActive = true
            // The status enters/leaves through the bottom edge of the text mask.
            // Top at centerY when visible; 18 pt below when hidden.
            statusPosition.constant = visible ? 0 : 18
            statusLabel.animator().alphaValue = visible ? 1 : 0
        }, animated: animated)
    }

    var statusAnchorRect: NSRect {
        var rect = statusLabel.convert(statusLabel.bounds, to: self)
        rect.size.width = min(rect.width, statusLabel.attributedStringValue.size().width)
        return rect
    }

    @objc private func pressStatus() { if hasStatus { onStatusPress?() } }

    func statusHitTarget(at point: NSPoint) -> NSView? {
        if currentEditor() == nil, hasStatus, onStatusPress != nil, statusAnchorRect.contains(point) {
            statusButton.frame = statusAnchorRect
            statusButton.isHidden = false
            return statusButton
        }
        statusButton.isHidden = true
        return nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        if let hit = statusHitTarget(at: convert(point, from: superview)) { return hit }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        textMask.frame = NSRect(x: 0, y: (bounds.height - 36) / 2, width: bounds.width, height: 36)
        textGroup.frame = textMask.bounds
        searchIcon.frame = NSRect(x: stringValue.isEmpty ? 2 : -20, y: 10, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        refreshDisplayLabel()
        if currentEditor() != nil { super.draw(dirtyRect) }
    }

    private func animateSearchIcon(visible: Bool) {
        layoutSubtreeIfNeeded()
        AddressStatusMotion.translate(searchIcon, from: visible ? -22 : 22)
        guard window?.isVisible == true, !OrbitMotionPreferences.prefersReducedMotion else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = visible ? 0 : 1
        opacity.toValue = visible ? 1 : 0
        opacity.duration = AddressStatusMotion.duration
        opacity.timingFunction = CAMediaTimingFunction(name: AddressStatusMotion.timingFunction)
        searchIcon.layer?.add(opacity, forKey: "address-loupe-opacity")
    }

    private func refreshDisplayLabel() {
        textMask.isHidden = currentEditor() != nil
        let empty = stringValue.isEmpty
        if let url = URL(string: stringValue) {
            security = BrowserSiteControlsModel(url: url, zoom: 1, permissions: [:], capabilities: [], canClearData: false).connection
        } else { security = .unavailable }
        let symbol: String?
        switch security {
        case .https: symbol = "lock.fill"
        case .insecure: symbol = "lock.slash.fill"
        case .internalPage, .unavailable: symbol = nil
        }
        let label: String
        if empty { label = placeholderAttributedString?.string ?? placeholderString ?? String() }
        else if let url = URL(string: stringValue), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host {
            label = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else { label = stringValue }
        if displayLabel.stringValue != label { displayLabel.stringValue = label }
        let labelFont = font ?? OrbitTokens.Typography.addressField
        if displayLabel.font != labelFont { displayLabel.font = labelFont }
        let statusFont = NSFont.systemFont(ofSize: labelFont.pointSize - 1)
        if statusLabel.font != statusFont { statusLabel.font = statusFont }
        let color = textColor ?? OrbitTokens.Color.Text.baseSecondary
        if displayLabel.textColor != color { displayLabel.textColor = color }
        if statusLabel.textColor != color { statusLabel.textColor = color }
        if securityIcon.contentTintColor != color { securityIcon.contentTintColor = color }
        if searchIcon.contentTintColor != color { searchIcon.contentTintColor = color }
        securityIcon.isHidden = symbol == nil
        if let symbol, securitySymbol != symbol {
            securitySymbol = symbol
            securityIcon.image = OrbitIcon.image(sfName: symbol, pointSize: labelFont.pointSize, accessibilityDescription: nil)
        }
        if symbol == nil { securitySymbol = nil }
        securityIcon.toolTip = security == .https ? uiText("Secure connection") : security == .insecure ? uiText("Connection is not secure") : nil
        textLeading.constant = empty ? 22 : symbol == nil ? 2 : 20
        searchIcon.alphaValue = empty ? 1 : 0
    }
}

@MainActor
final class AddressPresentationView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class AddressHostLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class AddressStatusButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {}
}
