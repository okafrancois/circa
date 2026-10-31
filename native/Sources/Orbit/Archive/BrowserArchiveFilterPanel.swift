import AppKit
import BrowserCore
import BrowserShell

/// Replaces the search row of the Archive list while filters are being chosen.
/// Measurements come from a recording of the reference panel (points, 2x capture):
/// title row 36, section label to chips 5.5, chip 33 high with 12.5 side padding, 6.5/7 gaps.
@MainActor
final class BrowserArchiveFilterPanel: NSView {
    static let automaticKey = "automatic"
    static let closedKey = "closed"
    static let littleKey = "little"
    static func spaceKey(_ id: SpaceID) -> String { "space:\(id.rawValue.uuidString)" }

    var onChange: ((String, Bool) -> Void)?
    var onDone: (() -> Void)?
    private let reasonFlow = ArchiveChipFlow()
    private let locationFlow = ArchiveChipFlow()
    private var chips: [String: ArchiveFilterChip] = [:]
    private var renderedSpaces: [(SpaceID, String)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: uiText("Filter Archived Tabs"))
        title.font = BrandTextStyle.ui.font(size: 14, weight: .bold)
        title.textColor = ArchiveFilterStyle.ink
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let done = ArchiveFilterDoneButton()
        done.target = self
        done.action = #selector(finish)
        done.setAccessibilityIdentifier("archive-filter-done")
        let titleRow = NSStackView(views: [title, done])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.distribution = .fill
        func section(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = BrandTextStyle.ui.font(size: 13, weight: .bold)
            label.textColor = ArchiveFilterStyle.ink
            return label
        }
        let reasonTitle = section(uiText("How was the tab closed?"))
        let locationTitle = section(uiText("Where was the tab?"))
        let content = NSStackView(views: [titleRow, reasonTitle, reasonFlow, locationTitle, locationFlow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 0
        content.setCustomSpacing(15.5, after: titleRow)
        content.setCustomSpacing(5.5, after: reasonTitle)
        content.setCustomSpacing(15.5, after: reasonFlow)
        content.setCustomSpacing(5.5, after: locationTitle)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            titleRow.heightAnchor.constraint(equalToConstant: 36),
            reasonFlow.widthAnchor.constraint(equalTo: content.widthAnchor),
            locationFlow.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        addChip(uiText("Auto-Closed"), key: Self.automaticKey, to: reasonFlow)
        addChip(uiText("Manually Closed"), key: Self.closedKey, to: reasonFlow)
        addChip(uiText("Little Circa"), key: Self.littleKey, to: locationFlow)
    }
    required init?(coder: NSCoder) { nil }

    func configure(spaces: [SpaceID: String], selected: Set<String>) {
        let sorted = spaces.sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            .map { ($0.key, $0.value) }
        if sorted.map(\.0) != renderedSpaces.map(\.0) || sorted.map(\.1) != renderedSpaces.map(\.1) {
            for (id, _) in renderedSpaces {
                let key = Self.spaceKey(id)
                chips[key]?.removeFromSuperview()
                chips[key] = nil
            }
            renderedSpaces = sorted
            for (id, name) in sorted { addChip(name, key: Self.spaceKey(id), to: locationFlow) }
        }
        for (key, chip) in chips { chip.isSelected = selected.contains(key) }
    }

    private func addChip(_ title: String, key: String, to flow: ArchiveChipFlow) {
        let chip = ArchiveFilterChip(title: title)
        chip.target = self
        chip.action = #selector(toggle(_:))
        chip.identifier = NSUserInterfaceItemIdentifier(key)
        chip.setAccessibilityIdentifier("archive-filter-\(key)")
        chips[key] = chip
        flow.addSubview(chip)
    }

    @objc private func toggle(_ sender: ArchiveFilterChip) {
        guard let key = sender.identifier?.rawValue else { return }
        sender.isSelected.toggle()
        onChange?(key, sender.isSelected)
    }
    @objc private func finish() { onDone?() }
}

@MainActor
enum ArchiveFilterStyle {
    /// Section titles, chip labels and the title row share one ink (about 65 % of the Library foreground).
    static var ink: NSColor { BrowserLibraryStyle.foreground.withAlphaComponent(0.65) }
    static let chipHeight: CGFloat = 33
    static let chipRadius: CGFloat = 12
    static let horizontalSpacing: CGFloat = 6.5
    static let verticalSpacing: CGFloat = 7
}

/// Chips wrap onto further rows when the line is full.
@MainActor
private final class ArchiveChipFlow: NSView {
    private var heightConstraint: NSLayoutConstraint?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        heightConstraint = pinHeight(ArchiveFilterStyle.chipHeight)
    }
    required init?(coder: NSCoder) { nil }
    override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); needsLayout = true }
    override func willRemoveSubview(_ subview: NSView) { super.willRemoveSubview(subview); needsLayout = true }

    private func pinHeight(_ value: CGFloat) -> NSLayoutConstraint {
        let constraint = self.heightAnchor.constraint(equalToConstant: value)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        return constraint
    }

    override func layout() {
        super.layout()
        let height = place(width: bounds.width, apply: true)
        if abs((heightConstraint?.constant ?? 0) - height) > 0.5 { heightConstraint?.constant = height }
    }

    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0
        for chip in subviews.compactMap({ $0 as? ArchiveFilterChip }) {
            let size = chip.preferredSize
            if x > 0, x + size.width > width { x = 0; y += ArchiveFilterStyle.chipHeight + ArchiveFilterStyle.verticalSpacing }
            if apply { chip.frame = NSRect(origin: NSPoint(x: x, y: y), size: size) }
            x += size.width + ArchiveFilterStyle.horizontalSpacing
        }
        return y + ArchiveFilterStyle.chipHeight
    }
}

@MainActor
final class ArchiveFilterChip: NSButton {
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private let label: String
    private var chipFont: NSFont { BrandTextStyle.ui.font(size: 14, weight: .medium) }

    init(title: String) {
        label = title
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }

    var preferredSize: NSSize {
        NSSize(width: ceil((label as NSString).size(withAttributes: [.font: chipFont]).width) + 25, height: ArchiveFilterStyle.chipHeight)
    }
    override var intrinsicContentSize: NSSize { preferredSize }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func accessibilityValue() -> Any? { isSelected ? 1 : 0 }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }

    override func draw(_ dirtyRect: NSRect) {
        let foreground = BrowserLibraryStyle.foreground
        foreground.withAlphaComponent(isSelected ? 0.6 : 0.065).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: ArchiveFilterStyle.chipRadius, yRadius: ArchiveFilterStyle.chipRadius).fill()
        let ink: NSColor = isSelected
            ? NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white }
            : ArchiveFilterStyle.ink
        let text = NSAttributedString(string: label, attributes: [.font: chipFont, .foregroundColor: ink])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

@MainActor
private final class ArchiveFilterDoneButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = uiText("Done")
        isBordered = false
        setAccessibilityLabel(uiText("Done"))
        widthAnchor.constraint(equalToConstant: 58).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        BrowserLibraryStyle.foreground.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let text = NSAttributedString(string: title, attributes: [.font: BrandTextStyle.ui.font(size: 14, weight: .medium), .foregroundColor: ArchiveFilterStyle.ink])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
