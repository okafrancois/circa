import AppKit
import BrowserCore

enum FolderPreviewMetrics {
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 40
    static let faviconSize: CGFloat = 16
    static let headerHeight: CGFloat = 76
    static let bottomInset: CGFloat = 8
    static let cornerRadius: CGFloat = 12
    static let fadeDuration: TimeInterval = 0.11
}

/// Native search and buttons keep AppKit text editing/IME and accessibility semantics.
@MainActor
final class FolderPreviewView: NSVisualEffectView, NSSearchFieldDelegate {
    let title = NSTextField(labelWithString: "")
    let search = NSSearchField()
    let scroll = NSScrollView()
    private let document = SidebarFlippedView()
    private var rows: [NSButton] = []
    private var ids: [TabID] = []
    private var imageResults: [FolderPreviewResult] = []
    private var imageSources: [TabID: NSImage] = [:]
    private var imageProvider: ((FolderPreviewResult) -> NSImage?)?
    private var selected = -1
    private var tracking: NSTrackingArea?
    var isInteractive = true
    var onPointer: ((Bool) -> Void)?
    var onSearch: ((String) -> Void)?
    var onChoose: ((TabID) -> Void)?
    var onEscape: (() -> Void)?
    var onEditingEnded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = FolderPreviewMetrics.cornerRadius
        layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        search.placeholderString = uiText("Search folder")
        search.setAccessibilityLabel(uiText("Search folder"))
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        search.font = .systemFont(ofSize: 13)
        search.controlSize = .small
        search.focusRingType = .none
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.scrollerKnobStyle = .default
        scroll.drawsBackground = false
        for child in [title, search, scroll] { addSubview(child) }
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Folder preview"))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isInteractive ? super.hitTest(point) : nil }

    func animateAppearance() {
        isInteractive = true
        layer?.removeAnimation(forKey: "folderPreview.opacity")
        alphaValue = 1
        guard !OrbitMotionPreferences.prefersReducedMotion else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0; animation.toValue = 1
        animation.duration = FolderPreviewMetrics.fadeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(animation, forKey: "folderPreview.opacity")
    }

    var ownsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === search.currentEditor(), search.currentEditor() != nil { return true }
        return (responder as? NSView).map { $0 === self || $0.isDescendant(of: self) } ?? false
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 14, y: 12, width: max(0, bounds.width - 28), height: 22)
        search.frame = NSRect(x: 12, y: 40, width: max(0, bounds.width - 24), height: 24)
        scroll.frame = NSRect(x: 6, y: FolderPreviewMetrics.headerHeight, width: max(0, bounds.width - 12), height: max(0, bounds.height - FolderPreviewMetrics.headerHeight - FolderPreviewMetrics.bottomInset))
        document.frame.size.width = scroll.contentSize.width
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * FolderPreviewMetrics.rowHeight, width: scroll.contentSize.width, height: FolderPreviewMetrics.rowHeight)
        }
        refreshImages()
    }

    func render(_ results: [FolderPreviewResult], image: @escaping (FolderPreviewResult) -> NSImage?) {
        let scrollOrigin = scroll.contentView.bounds.origin
        let selectedID = ids.indices.contains(selected) ? ids[selected] : nil
        clear()
        ids = results.map { $0.tab.id }
        imageResults = results
        imageProvider = image
        selected = selectedID.flatMap { ids.firstIndex(of: $0) } ?? -1
        for (index, result) in results.enumerated() {
            let button = FolderPreviewRow(title: "", target: self, action: #selector(choose(_:)))
            button.tag = index
            button.isBordered = false
            button.alignment = .left
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            setImage(image(result), for: result, on: button)
            let recency = result.tab.lastActiveAt == nil ? [] : [Self.recency(result.tab.lastActiveAt)]
            let detail = (result.path + (result.split == nil ? [] : [uiText("Split View")]) + recency).joined(separator: " · ")
            let text = NSMutableAttributedString(string: result.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
            if !detail.isEmpty {
                text.append(NSAttributedString(string: "\n" + detail, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            button.attributedTitle = text
            button.cell?.lineBreakMode = .byTruncatingTail
            button.setAccessibilityLabel(result.title + ", " + detail)
            button.toolTip = result.tab.lastActiveAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) }
            rows.append(button); document.addSubview(button)
        }
        if results.isEmpty {
            let empty = NSTextField(labelWithString: uiText("No tabs"))
            empty.frame = NSRect(x: 10, y: 12, width: 260, height: 24)
            empty.textColor = .secondaryLabelColor
            document.addSubview(empty)
        }
        document.frame.size.height = max(FolderPreviewMetrics.rowHeight, CGFloat(results.count) * FolderPreviewMetrics.rowHeight)
        updateSelection()
        needsLayout = true
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(scrollOrigin.y, max(0, document.frame.height - scroll.contentSize.height))))
    }

    /// Refresh the installed button images in place; cache invalidation alone cannot revoke copies.
    /// The owner supplies a live authority check, not an immutable image from an earlier render.
    func refreshImages() {
        guard let imageProvider else { return }
        for (index, result) in imageResults.enumerated() where rows.indices.contains(index) && ids[index] == result.tab.id {
            setImage(imageProvider(result), for: result, on: rows[index])
        }
    }

    private func setImage(_ image: NSImage?, for result: FolderPreviewResult, on button: NSButton) {
        if button.image != nil, image === imageSources[result.tab.id] { return }
        imageSources[result.tab.id] = image
        let icon = image ?? NSImage(systemSymbolName: result.split == nil ? "globe" : "rectangle.split.2x1", accessibilityDescription: nil)
        button.image = icon?.copy() as? NSImage
        button.image?.size = NSSize(width: FolderPreviewMetrics.faviconSize, height: FolderPreviewMetrics.faviconSize)
        button.needsDisplay = true
    }

    static func recency(_ date: Date?, now: Date = Date()) -> String {
        guard let date, date.timeIntervalSince1970.isFinite, date <= now else { return uiText("Last access unavailable") }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
    }

    func clear() {
        imageProvider = nil
        imageResults = []
        imageSources = [:]
        document.subviews.forEach { $0.removeFromSuperview() }
        rows = []; ids = []
    }

    @objc private func choose(_ sender: NSButton) {
        guard ids.indices.contains(sender.tag), rows[sender.tag] === sender else { return }
        onChoose?(ids[sender.tag])
    }
    private func updateSelection() {
        for (index, row) in rows.enumerated() {
            row.state = index == selected ? .on : .off
            row.wantsLayer = true
            row.layer?.cornerRadius = 8
            (row as? FolderPreviewRow)?.isKeyboardSelected = index == selected
        }
        if rows.indices.contains(selected) { document.scrollToVisible(rows[selected].frame) }
    }
    func controlTextDidChange(_ notification: Notification) { onSearch?(search.stringValue) }
    func controlTextDidEndEditing(_ notification: Notification) { onEditingEnded?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onEscape?(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !ids.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            selected = max(0, min(ids.count - 1, selected + delta))
            updateSelection(); return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if ids.indices.contains(selected) { onChoose?(ids[selected]) }
            return true
        }
        return false
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onPointer?(true) }
    override func mouseExited(with event: NSEvent) { onPointer?(false) }
}


/// Viewport clipping works with either native coordinate system.
struct FolderPreviewGeometry {
    static func frame(anchor: NSRect, viewport: NSRect, flipped: Bool, count: Int) -> NSRect {
        let area = viewport.insetBy(dx: min(8, viewport.width / 2), dy: min(8, viewport.height / 2))
        let width = min(FolderPreviewMetrics.width, max(0, area.width))
        let height = min(530, max(0, area.height), FolderPreviewMetrics.headerHeight + FolderPreviewMetrics.bottomInset + max(FolderPreviewMetrics.rowHeight, CGFloat(count) * FolderPreviewMetrics.rowHeight))
        var x = anchor.maxX + 8
        if x + width > area.maxX { x = anchor.minX - width - 8 }
        x = max(area.minX, min(x, area.maxX - width))
        let top = flipped ? anchor.minY : anchor.maxY - height
        let y = max(area.minY, min(top, area.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

/// NSButton retains native click, keyboard and accessibility behavior; its compact content is
/// drawn explicitly so the image cell cannot expand the row into a page-thumbnail layout.
@MainActor
private final class FolderPreviewRow: NSButton {
    var isKeyboardSelected = false { didSet { needsDisplay = true } }
    private var isPointerInside = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isPointerInside || isKeyboardSelected || isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        image?.draw(in: NSRect(x: 10, y: (bounds.height - FolderPreviewMetrics.faviconSize) / 2,
            width: FolderPreviewMetrics.faviconSize, height: FolderPreviewMetrics.faviconSize),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let textHeight: CGFloat = attributedTitle.string.contains("\n") ? 31 : 17
        attributedTitle.draw(in: NSRect(x: 36, y: (bounds.height - textHeight) / 2,
            width: max(0, bounds.width - 48), height: textHeight))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { isPointerInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isPointerInside = false; needsDisplay = true }
}
