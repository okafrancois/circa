import AppKit
import BrowserCore

@MainActor
final class SiteControlButton: NSButton {
    var onPress: (() -> Void)?
    var contextMenuBuilder: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenuBuilder?() ?? super.menu(for: event) }
    var usesURLPillStyle = false {
        didSet { wantsLayer = true; layer?.cornerRadius = 6; updatePillHover() }
    }
    private var pillHoverArea: NSTrackingArea?
    private var isPillHovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pillHoverArea { removeTrackingArea(pillHoverArea) }
        guard usesURLPillStyle else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pillHoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { isPillHovered = true; updatePillHover() }
    override func mouseExited(with event: NSEvent) { isPillHovered = false; updatePillHover() }
    override var isHighlighted: Bool { didSet { updatePillHover() } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePillHover()
    }
    private func updatePillHover() {
        guard usesURLPillStyle else { return }
        let fill = isPillHovered || isHighlighted ? OrbitTokens.Color.State.sidebarItemHovered : .clear
        layer?.backgroundColor = fill.resolvedCGColor(for: effectiveAppearance)
    }

    convenience init(_ title: String, identifier: String, onPress: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.target = self
        self.action = #selector(press)
        self.onPress = onPress
        font = SiteControlTokens.body
        setAccessibilityIdentifier(identifier)
    }
    @objc private func press() { onPress?() }
}

@MainActor
private final class SitePermissionPicker: NSPopUpButton {
    var onSelect: ((BrowserSitePermissionSetting) -> Void)?
    init(setting: BrowserSitePermissionSetting, enabled: Bool,
         onSelect: @escaping (BrowserSitePermissionSetting) -> Void) {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: [siteText("setting.ask", "Ask"), siteText("setting.allow", "Allow"), siteText("setting.block", "Block")])
        selectItem(at: BrowserSitePermissionSetting.allCases.firstIndex(of: setting) ?? 0)
        isEnabled = enabled
        font = SiteControlTokens.body
        self.onSelect = onSelect
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func changed() {
        guard BrowserSitePermissionSetting.allCases.indices.contains(indexOfSelectedItem) else { return }
        onSelect?(BrowserSitePermissionSetting.allCases[indexOfSelectedItem])
    }
}

@MainActor
final class BrowserSitePopover: NSObject, NSPopoverDelegate {
    let popover = OrbitFrostPopover()
    var usesOrbitStyle = false
    var onVisibilityChange: (() -> Void)?
    var onClose: (() -> Void)?
    /// The owner invalidates pending asynchronous presentations before dismissal.
    var onWillClose: (() -> Void)?
    /// Alternative/hidden presenters can observe an explicit close without opening a popover.
    var onCloseRequest: (() -> Void)?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Shows `rows` hanging below `anchor` (or `relativeRect` in its coordinates), scrolled to the top so
    /// the origin header is visible, and no taller than the window space below the anchor
    /// (VIS-1 BL-VIS1-SITE-POPOVER).
    func show(rows: [NSView], anchor: NSView, relativeRect: NSRect? = nil, edge: NSRectEdge? = nil) {
        guard let window = anchor.window, window.isVisible else { return }
        let rect = relativeRect ?? anchor.bounds
        let maximumHeight = Self.maximumHeight(anchorRectInWindow: anchor.convert(rect, to: nil))
        let content: NSView
        if rows.count == 1, let prompt = rows.first as? SitePermissionPromptView {
            content = prompt
        } else if rows.count == 1, let center = rows.first as? OrbitSiteControlCenterView {
            if center.frame.height <= maximumHeight {
                content = center
            } else {
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 236, height: maximumHeight))
                scroll.drawsBackground = false
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = true
                scroll.documentView = center
                content = scroll
            }
        } else {
            content = Self.makeContent(rows: rows, maximumHeight: maximumHeight, compact: usesOrbitStyle)
        }
        let controller = NSViewController()
        controller.view = content
        controller.preferredContentSize = content.frame.size
        // Build known content before swapping it; inventory updates never present an empty panel.
        popover.contentViewController = controller
        if !popover.isShown {
            popover.show(relativeTo: rect, of: anchor, preferredEdge: edge ?? (anchor.isFlipped ? .maxY : .minY))
        }
        onVisibilityChange?()
        if let scroll = content as? NSScrollView { Self.scrollToTop(scroll) }
    }

    /// Height available below an anchor (window coordinates, origin at the bottom-left).
    static func maximumHeight(anchorRectInWindow rect: NSRect) -> CGFloat {
        let below = rect.minY - SiteControlTokens.windowMargin - SiteControlTokens.arrowAllowance
        return max(SiteControlTokens.minimumHeight, min(SiteControlTokens.maximumHeight, below))
    }

    /// The scrolling content: a flipped document so the first row (origin, connection) is at the top
    /// and the view opens there; an unflipped stack would open scrolled to its bottom.
    static func makeContent(rows: [NSView], maximumHeight: CGFloat,
                            scrollerStyle: NSScroller.Style? = nil, compact: Bool = false) -> NSScrollView {
        let width: CGFloat = compact ? 236 : SiteControlTokens.width
        let inset: CGFloat = compact ? 10 : SiteControlTokens.inset
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = SiteControlTokens.gap
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * inset).isActive = true
        }
        // Measure at the design width, then let the viewport determine the live width.
        let initialWidth = stack.widthAnchor.constraint(equalToConstant: width)
        initialWidth.isActive = true
        stack.layoutSubtreeIfNeeded()
        let fitting = stack.fittingSize
        initialWidth.isActive = false
        let document = SiteFlippedDocumentView(frame: NSRect(origin: .zero, size: fitting))
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.frame = document.bounds
        stack.autoresizingMask = [.width]
        // Legacy scrollers consume clip width. Let the document and its rows follow it.
        document.autoresizingMask = [.width]
        document.addSubview(stack)
        let scroll = SitePopoverScrollView(frame: NSRect(x: 0, y: 0, width: width,
                                                height: min(maximumHeight, fitting.height)))
        if let scrollerStyle { scroll.scrollerStyle = scrollerStyle }
        // Orbit uses the native popover material. An opaque asset here masks its blur and
        // incorrectly turns dark permission/details panels into solid navy rectangles.
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        // Autoresizing preserves an existing width difference. A legacy scroller can
        // narrow the clip before attachment, so establish equal widths after tiling.
        scroll.tile()
        document.setFrameSize(NSSize(width: scroll.contentSize.width, height: fitting.height))
        document.layoutSubtreeIfNeeded()
        scrollToTop(scroll)
        return scroll
    }

    static func scrollToTop(_ scroll: NSScrollView) {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// An immediate dismissal must not disable the next presentation's native animation.
    func close(animating: Bool? = nil) {
        let previous = popover.animates
        if let animating { popover.animates = animating }
        defer { popover.animates = previous }
        onWillClose?()
        onCloseRequest?()
        popover.close()
    }
    func popoverWillClose(_ notification: Notification) { onWillClose?() }
    func popoverDidClose(_ notification: Notification) { onClose?(); onVisibilityChange?() }

    static func label(_ text: String, secondary: Bool = false, title: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = title ? SiteControlTokens.title : secondary ? SiteControlTokens.caption : SiteControlTokens.body
        field.textColor = secondary ? SiteControlTokens.secondary : SiteControlTokens.primary
        return field
    }

    static func permissionRow(_ permission: BrowserSitePermission, setting: BrowserSitePermissionSetting,
                              enabled: Bool, onSelect: @escaping (BrowserSitePermissionSetting) -> Void) -> NSView {
        let title = label(permission.displayTitle)
        let picker = SitePermissionPicker(setting: setting, enabled: enabled, onSelect: onSelect)
        picker.setAccessibilityLabel(permission.displayTitle)
        picker.setAccessibilityIdentifier("site-permission-" + permission.rawValue)
        let row = NSStackView(views: [title, picker])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: SiteControlTokens.rowHeight).isActive = true
        return row
    }
}

/// Document of the popover's scroll view: flipped, so the scroll origin is the top row.
@MainActor
final class SiteFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}


/// Clip width changes with legacy scrollers, including before AppKit attaches a window.
/// Explicitly synchronize the document and reflow wrapping rows; autoresizing alone can leave
/// the old design width installed and clip permission controls at the right edge.
@MainActor
private final class SitePopoverScrollView: NSScrollView {
    private var isSynchronizing = false
    override func tile() { super.tile(); synchronizeDocument() }
    override func layout() { super.layout(); synchronizeDocument() }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); synchronizeDocument() }

    private func synchronizeDocument() {
        guard !isSynchronizing, let document = documentView,
              let stack = document.subviews.first as? NSStackView, contentView.bounds.width > 0 else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        let width = contentView.bounds.width
        document.setFrameSize(NSSize(width: width, height: document.frame.height))
        stack.setFrameSize(NSSize(width: width, height: stack.frame.height))
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        document.setFrameSize(NSSize(width: width, height: height))
        stack.setFrameSize(NSSize(width: width, height: height))
        stack.layoutSubtreeIfNeeded()
        let origin = NSPoint(x: 0, y: min(max(0, contentView.bounds.minY), max(0, height - contentView.bounds.height)))
        if contentView.bounds.origin != origin { contentView.scroll(to: origin) }
    }
}
