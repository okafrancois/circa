import AppKit

/// Orbit Home's plain search input inside a 36-point rounded surface.
@MainActor
final class BrowserLibrarySearchField: NSSearchField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = BrowserLibrarySearchCell(textCell: "")
        isEditable = true
        isSelectable = true
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        font = .systemFont(ofSize: 14, weight: .medium)
        textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.65)
        focusRingType = .none
        isBezeled = false
        drawsBackground = false
        maximumRecents = 0
        recentsAutosaveName = nil
        sendsSearchStringImmediately = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.65)
        needsDisplay = true
    }
}

@MainActor
private final class BrowserLibrarySearchCell: NSSearchFieldCell {
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 14, y: rect.midY - 8, width: 16, height: 16)
    }
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + 44, y: rect.midY - 9, width: max(0, rect.width - 54 - (stringValue.isEmpty ? 0 : 18)), height: 18)
    }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - 24, y: rect.midY - 7, width: 14, height: 14)
    }
    override func draw(withFrame rect: NSRect, in view: NSView) {
        BrowserLibraryStyle.foreground.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        let color = BrowserLibraryStyle.foreground.withAlphaComponent(0.5)
        OrbitIcon.draw(OrbitIcon.image(sfName: "magnifyingglass", pointSize: 16), in: searchButtonRect(forBounds: rect), tint: color)
        if stringValue.isEmpty, let placeholderString {
            // While editing, the field editor draws the placeholder itself; drawing it here too
            // superimposes two slightly offset copies.
            if (view as? NSTextField)?.currentEditor() == nil {
                NSAttributedString(string: placeholderString, attributes: [.font: font ?? .systemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: color]).draw(in: searchTextRect(forBounds: rect))
            }
        } else {
            if (view as? NSTextField)?.currentEditor() == nil {
                NSAttributedString(string: stringValue, attributes: [.font: font ?? .systemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: color]).draw(in: searchTextRect(forBounds: rect))
            }
            cancelButtonCell?.draw(withFrame: cancelButtonRect(forBounds: rect), in: view)
        }
    }
}
