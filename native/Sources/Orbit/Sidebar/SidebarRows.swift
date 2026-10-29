import AppKit
import BrowserCore

private typealias Metrics = OrbitTokens.Metrics.Sidebar

extension OrbitGlyph {
    static var resetPinned: NSImage? { symbol("arrow.uturn.backward", pointSize: 10, weight: .semibold) }
    ///  — trailing mark of a tab open in another window.
    static var otherWindow: NSImage? { symbol("macwindow.on.rectangle", pointSize: OrbitTokens.Metrics.Sidebar.otherWindowGlyphSize, weight: .regular) }

    /// Draws a template glyph centred in `rect` of the current graphics context (no view needed,
    /// e.g. for drag images).
    static func drawTemplate(_ glyph: NSImage, centeredIn rect: NSRect, tint: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = glyph.size
        let target = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        context.beginTransparencyLayer(in: target, auxiliaryInfo: nil)
        glyph.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        tint.set()
        target.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// Receives the pointer and command events of list rows; the list owns selection, drag and
/// rename rules, rows only draw their state.
@MainActor
protocol SidebarRowEventHandler: AnyObject {
    func rowMouseDown(_ row: SidebarListRow, with event: NSEvent)
    func rowMouseDragged(_ row: SidebarListRow, with event: NSEvent)
    func rowMouseUp(_ row: SidebarListRow, with event: NSEvent)
    func rowRightMouseDown(_ row: SidebarListRow, with event: NSEvent)
    func rowPerformPress(_ row: SidebarListRow) -> Bool
    func rowClose(_ row: SidebarTabRow)
    func rowResetToPinnedURL(_ row: SidebarTabRow)
    func rowToggleAudio(_ row: SidebarTabRow)
    /// Nil title: the edit was cancelled. `initialTitle` is the text the field started with: the
    /// web title may have changed meanwhile, and an untouched field must not freeze either one.
    func rowDidFinishRename(_ row: SidebarListRow, title: String?, initialTitle: String)
}

extension SidebarRowEventHandler {
    func rowToggleAudio(_ row: SidebarTabRow) {}
}

@MainActor
class SidebarListRow: NSView, NSTextFieldDelegate {
    let background = OrbitSurfaceBackgroundView(cornerRadius: OrbitTokens.Radius.tabRow)
    let titleLabel = NSTextField(labelWithString: "")
    weak var events: (any SidebarRowEventHandler)?
    var onFolderHover: ((SidebarListRow, Bool) -> Void)?
    var onPreviewInvalidated: ((SidebarListRow) -> Void)?
    private(set) var node: BrowserOrganizationNode
    private(set) var depth = 0
    var commandsEnabled = true { didSet { commandsDidChange() } }
    var isPressed = false { didSet { if isPressed != oldValue { refreshFill() } } }
    var isContextTarget = false { didSet { if isContextTarget != oldValue { refreshFill() } } }
    var isDropTarget = false { didSet { if isDropTarget != oldValue { refreshFill() } } }
    private(set) var isHovering = false { didSet { if isHovering != oldValue { hoverDidChange() } } }
    private var hoverArea: NSTrackingArea?
    /// The Space accent family; its foreground roles are corrected for the row's painted overlay.
    var accent = OrbitTokens.ThemeAccent.defaultSpace { didSet { if accent != oldValue { refreshForeground() } } }
    private(set) var effectiveAccent = OrbitTokens.ThemeAccent.defaultSpace
    private(set) var renameField: NSTextField?
    private var renameInitialText = ""
    private var isEndingRename = false
    /// The entry the row last showed; a removed row keeps it while it fades out.
    var leavingEntry: SidebarListEntry?

    init(node: BrowserOrganizationNode) {
        self.node = node
        super.init(frame: .zero)
        titleLabel.textColor = accent.sidebarText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.setAccessibilityElement(false)
        addSubview(background)
        addSubview(titleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func rebind(node: BrowserOrganizationNode, depth: Int) {
        if self.node != node || self.depth != depth {
            onPreviewInvalidated?(self)
            cancelRename()
            isPressed = false
            isContextTarget = false
            isDropTarget = false
        }
        self.node = node
        if self.depth != depth {
            self.depth = depth
            needsLayout = true
        }
    }

    /// Clears state that must not survive into another row's content.
    func resetForReuse() {
        onPreviewInvalidated?(self)
        isHovering = false
        onFolderHover = nil
        onPreviewInvalidated = nil
        cancelRename()
        isPressed = false
        isContextTarget = false
        isDropTarget = false
        leavingEntry = nil
        setAccessibilityLabel(nil)
    }

    /// Row-local x of the icon's left edge and of the title (window x 18 and 44 at depth 0).
    var iconX: CGFloat { Metrics.rowInsetX + OrbitSidebarGeometry.contentIndent(depth: depth) }
    var titleX: CGFloat { Metrics.titleOriginX - Metrics.paddingX + OrbitSidebarGeometry.contentIndent(depth: depth) }
    /// Trailing end of the title; subclasses stop before their hover controls.
    var titleEnd: CGFloat { bounds.width - Metrics.rowInsetX }
    var isSelected: Bool { false }
    var isMultiSelected: Bool { false }
    var isRenaming: Bool { renameField != nil }

    override func layout() {
        super.layout()
        background.frame = bounds
        let height = ceil(titleLabel.intrinsicContentSize.height)
        let frame = NSRect(x: titleX, y: ((bounds.height - height) / 2).rounded(), width: max(0, titleEnd - titleX), height: height)
        titleLabel.frame = frame
        if let renameField {
            let fieldHeight = ceil(renameField.intrinsicContentSize.height)
            renameField.frame = NSRect(x: titleX - 2, y: ((bounds.height - fieldHeight) / 2).rounded(),
                                       width: max(0, bounds.width - Metrics.rowInsetX - titleX + 2), height: fieldHeight)
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onPreviewInvalidated?(self); isHovering = false }
    }

    override func viewDidHide() {
        super.viewDidHide()
        onPreviewInvalidated?(self)
        isHovering = false
        isPressed = false
    }

    func hoverDidChange() {
        if node.folderID != nil { onFolderHover?(self, isHovering) }
        refreshFill()
        needsLayout = true
    }

    private func refreshForeground() {
        effectiveAccent = OrbitSpaceThemes.accent(accent, over: background.fillColor.map { [$0] } ?? [],
                                                iconHover: OrbitTokens.Color.State.rowCloseButtonHover)
        accentDidChange()
    }

    func accentDidChange() {
        titleLabel.textColor = effectiveAccent.sidebarText
        renameField?.textColor = effectiveAccent.sidebarText
        refreshFieldEditor()
    }

    private func refreshFieldEditor() {
        guard let editor = renameField?.currentEditor() as? NSTextView else { return }
        editor.textColor = effectiveAccent.sidebarText
        editor.insertionPointColor = effectiveAccent.sidebarText
    }

    func controlTextDidBeginEditing(_ notification: Notification) { refreshFieldEditor() }

    func commandsDidChange() {
        if !commandsEnabled { onPreviewInvalidated?(self); isPressed = false }
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) { if commandsEnabled { events?.rowMouseDown(self, with: event) } }
    override func mouseDragged(with event: NSEvent) { if commandsEnabled { events?.rowMouseDragged(self, with: event) } }
    override func mouseUp(with event: NSEvent) { events?.rowMouseUp(self, with: event) }
    override func rightMouseDown(with event: NSEvent) {
        if commandsEnabled { events?.rowRightMouseDown(self, with: event) } else { super.rightMouseDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard commandsEnabled else { return false }
        return events?.rowPerformPress(self) ?? false
    }

    // MARK: Fill

    func refreshFill() {
        defer { refreshForeground() }
        let state = OrbitTokens.Color.State.self
        if isSelected || isRenaming {
            background.fillColor = isRenaming ? state.renamingRow : state.tabCurrent
            background.outerShadow = OrbitTokens.Shadow.tabSelected
            return
        }
        background.outerShadow = nil
        if isDropTarget { background.fillColor = state.dragFolderTarget }
        else if isPressed || isContextTarget { background.fillColor = state.tabPressed }
        else if isMultiSelected { background.fillColor = state.tabMultiselected }
        else if isHovering { background.fillColor = state.sidebarItem }
        else { background.fillColor = nil }
    }


    /// Replaces the title by a field holding `text`, all selected. The field editor handles input
    /// methods: Return and Escape reach the field only once a composition is committed.
    func beginRename(text: String, font: NSFont) {
        guard renameField == nil, let window else { return }
        onPreviewInvalidated?(self)
        let field = NSTextField(string: text)
        field.font = font
        field.textColor = effectiveAccent.sidebarText
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.setAccessibilityLabel(SidebarListStrings.renameField)
        renameField = field
        renameInitialText = text
        titleLabel.isHidden = true
        addSubview(field)
        refreshFill()
        needsLayout = true
        layoutSubtreeIfNeeded()
        window.makeFirstResponder(field)
        refreshFieldEditor()
        field.currentEditor()?.selectAll(nil)
    }

    /// Ends editing without committing (row reused, node removed, sidebar hidden).
    func cancelRename() {
        guard renameField != nil else { return }
        finishRename(commit: false)
    }

    func commitRename() {
        guard renameField != nil else { return }
        finishRename(commit: true)
    }

    private func finishRename(commit: Bool) {
        guard let field = renameField, !isEndingRename else { return }
        isEndingRename = true
        let title = field.stringValue
        let wasEditing = field.currentEditor() != nil
        renameField = nil
        if wasEditing { window?.makeFirstResponder(events as? NSResponder) }
        field.delegate = nil
        field.removeFromSuperview()
        titleLabel.isHidden = false
        isEndingRename = false
        refreshFill()
        needsLayout = true
        events?.rowDidFinishRename(self, title: commit ? title : nil, initialTitle: renameInitialText)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // A composition in progress owns Return and Escape.
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(commit: false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finishRename(commit: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard renameField != nil, !isEndingRename else { return }
        finishRename(commit: true)
    }
}

@MainActor
class SidebarTabRow: SidebarListRow {
    private(set) var item: SidebarTabItem
    let favicon = NSImageView()
    private let slash = SidebarPinnedSlashView()
    let closeButton = OrbitGlyphButton(glyph: OrbitGlyph.close, label: "")
    let resetButton = OrbitGlyphButton(glyph: OrbitGlyph.resetPinned, label: "")
    private let otherWindowMark = NSImageView()
    let audioButton = OrbitGlyphButton(glyph: nil, label: "")
    private let loadingIndicator = SidebarTabLoadingView()
    private let faviconPlaceholder = OrbitGlyph.faviconPlaceholder
    private var audioMuted: Bool?

    init(item: SidebarTabItem, depth: Int = 0) {
        self.item = item
        super.init(node: .tab(item.id))
        favicon.imageScaling = .scaleProportionallyDown
        favicon.setAccessibilityElement(false)
        titleLabel.font = OrbitTokens.Typography.sidebarTabTitle
        closeButton.tint = effectiveAccent.icon
        closeButton.hoverFill = .rowClose
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        closeButton.alphaValue = 0
        audioButton.hoverFill = .rowClose
        audioButton.target = self
        audioButton.action = #selector(toggleAudio(_:))
        audioButton.isHidden = true
        resetButton.tint = effectiveAccent.icon
        resetButton.hoverFill = .rowClose
        resetButton.target = self
        resetButton.action = #selector(resetTab(_:))
        resetButton.isHidden = true
        otherWindowMark.image = OrbitGlyph.otherWindow
        otherWindowMark.contentTintColor = effectiveAccent.icon
        slash.tint = effectiveAccent.icon
        otherWindowMark.setAccessibilityElement(false)
        for view in [favicon, loadingIndicator, slash, otherWindowMark, resetButton, audioButton, closeButton] { addSubview(view) }
        update(item, depth: depth)
    }

    required init?(coder: NSCoder) { nil }

    override var isSelected: Bool { item.selected }
    override var isMultiSelected: Bool { item.isMultiSelected }
    var isCloseButtonVisible: Bool { closeButton.alphaValue > 0 }

    private var titleColor: NSColor {
        // Another-window rows stay secondary until hovered; they are still actionable, not disabled.
        item.isOpenInAnotherWindow && !isHovering ? effectiveAccent.sidebarSecondaryText : effectiveAccent.sidebarText
    }

    override func accentDidChange() {
        super.accentDidChange()
        titleLabel.textColor = titleColor
        closeButton.tint = effectiveAccent.icon
        resetButton.tint = effectiveAccent.icon
        otherWindowMark.contentTintColor = effectiveAccent.icon
        slash.tint = effectiveAccent.icon
        audioButton.tint = effectiveAccent.icon
        loadingIndicator.tint = effectiveAccent.icon
        favicon.contentTintColor = displayedFavicon == nil ? effectiveAccent.icon : nil
    }
    var isResetButtonVisible: Bool { !resetButton.isHidden }
    private var displayedFavicon: NSImage? { item.favicon ?? item.activity.favicon }
    var showsAudio: Bool { item.activity.isAudible == true || item.activity.isAudioMuted == true }

    func update(_ item: SidebarTabItem, depth: Int, node: BrowserOrganizationNode? = nil) {
        rebind(node: node ?? .tab(item.id), depth: depth)
        let changed = item != self.item
        self.item = item
        if titleLabel.stringValue != item.title { titleLabel.stringValue = item.title }
        if titleLabel.textColor != titleColor { titleLabel.textColor = titleColor }
        let image = displayedFavicon ?? faviconPlaceholder
        if favicon.image !== image { favicon.image = image }
        let tint = displayedFavicon == nil ? effectiveAccent.icon : nil
        if favicon.contentTintColor != tint { favicon.contentTintColor = tint }
        loadingIndicator.isLoading = item.activity.isLoading
        let muted = item.activity.isAudioMuted == true
        if audioMuted != muted {
            audioMuted = muted
            audioButton.glyph = OrbitGlyph.symbol(muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                                 pointSize: Metrics.audioGlyphSize, weight: .medium)
        }
        let audioLabel = uiText(muted ? "Unmute Tab" : "Mute Tab")
        audioButton.setAccessibilityLabel(audioLabel)
        audioButton.toolTip = audioLabel
        audioButton.isEnabled = commandsEnabled && item.activity.isAudioMuted != nil
        closeButton.setAccessibilityLabel(SidebarListStrings.close(item.title))
        resetButton.setAccessibilityLabel(SidebarListStrings.reset(item.title))
        resetButton.toolTip = SidebarListStrings.resetPinned
        setAccessibilityLabel(item.title)
        var value: [String] = []
        if item.selected { value.append(SidebarListStrings.selected) }
        if item.isOpenInAnotherWindow { value.append(SidebarListStrings.otherWindow) }
        if item.activity.isLoading { value.append(uiText("Loading")) }
        if muted { value.append(uiText("Muted")) }
        else if item.activity.isAudible == true { value.append(uiText("Playing audio")) }
        setAccessibilityValue(value.joined(separator: ", "))
        setAccessibilitySelected(item.selected || item.isMultiSelected)
        refreshControls()
        refreshFill()
        if changed { needsLayout = true }
    }

    override var titleEnd: CGFloat {
        // The title truncates before the close button only while the button shows (S-SPL@1s).
        if showsAudio { return audioButton.frame.minX - Metrics.titleTrailingGap }
        return isHovering || item.isOpenInAnotherWindow
            ? closeButton.frame.minX - Metrics.titleTrailingGap : bounds.width - Metrics.rowInsetX
    }

    override func layout() {
        let size = Metrics.faviconSize
        favicon.frame = NSRect(x: iconX, y: (bounds.height - size) / 2, width: size, height: size)
        loadingIndicator.frame = favicon.frame
        resetButton.frame = favicon.frame.insetBy(dx: (size - Metrics.closeButtonSize) / 2, dy: (size - Metrics.closeButtonSize) / 2)
        let slashCenter = favicon.frame.maxX + Metrics.pinnedSlashCenterFromFaviconRight
        slash.frame = NSRect(x: slashCenter - Metrics.pinnedSlashHeight / 2, y: (bounds.height - Metrics.pinnedSlashHeight) / 2,
                             width: Metrics.pinnedSlashHeight, height: Metrics.pinnedSlashHeight)
        let closeSize = Metrics.closeButtonSize
        let closeCenter = bounds.width - Metrics.closeCenterFromRowRight
        closeButton.frame = NSRect(x: closeCenter - closeSize / 2, y: (bounds.height - closeSize) / 2, width: closeSize, height: closeSize)
        audioButton.frame = closeButton.frame.offsetBy(dx: isHovering ? -Metrics.audioControlPitch : 0, dy: 0)
        let mark = Metrics.otherWindowGlyphSize + 4
        otherWindowMark.frame = NSRect(x: closeCenter - mark / 2, y: (bounds.height - mark) / 2, width: mark, height: mark)
        super.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }), bounds.contains(local) else { return nil }
        if let renameField, renameField.frame.contains(local) { return renameField.hitTest(local) ?? renameField }
        if isCloseButtonVisible, closeButton.frame.contains(local) { return closeButton }
        if showsAudio, audioButton.frame.contains(local) { return audioButton }
        if isResetButtonVisible, resetButton.frame.contains(local) { return resetButton }
        return self
    }

    override func hoverDidChange() {
        super.hoverDidChange()
        refreshControls()
        titleLabel.textColor = titleColor
        // : the close button fades in over 0.12 s.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isHovering ? OrbitTokens.Motion.hoverControlsRevealDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            closeButton.animator().alphaValue = isHovering && !isRenaming ? 1 : 0
        }
    }

    override func commandsDidChange() {
        super.commandsDidChange()
        closeButton.isEnabled = commandsEnabled
        resetButton.isEnabled = commandsEnabled
        audioButton.isEnabled = commandsEnabled && item.activity.isAudioMuted != nil
    }

    override func resetForReuse() {
        super.resetForReuse()
        closeButton.setAccessibilityLabel(nil)
        resetButton.setAccessibilityLabel(nil)
        closeButton.alphaValue = 0
    }

    private func refreshControls() {
        let away = item.isAwayFromPinnedURL
        slash.isHidden = !away
        resetButton.isHidden = !(away && isHovering && !isRenaming)
        favicon.isHidden = !resetButton.isHidden || item.activity.isLoading
        loadingIndicator.isHidden = !item.activity.isLoading || !resetButton.isHidden
        audioButton.isHidden = !showsAudio || isRenaming
        otherWindowMark.isHidden = !item.isOpenInAnotherWindow || isHovering
        if !isHovering || isRenaming { closeButton.alphaValue = 0 }
    }

    @objc private func closeTab(_ sender: Any?) {
        guard commandsEnabled else { return }
        events?.rowClose(self)
    }

    @objc private func resetTab(_ sender: Any?) {
        guard commandsEnabled else { return }
        events?.rowResetToPinnedURL(self)
    }

    @objc private func toggleAudio(_ sender: Any?) {
        guard commandsEnabled else { return }
        events?.rowToggleAudio(self)
    }
}

/// Selected split pages share an outer row, with a favicon and truncated title per page.
/// Input still targets the group.
@MainActor
final class SidebarSplitRow: SidebarTabRow {
    private(set) var paneCells: [SidebarSplitPaneCell] = []

    init(item: SidebarTabItem, node: BrowserOrganizationNode, depth: Int) {
        OrbitUIWorkCounters.record("splitAllocation")
        super.init(item: item, depth: depth)
        updateSplit(item, node: node, depth: depth)
    }
    required init?(coder: NSCoder) { nil }

    func updateSplit(_ item: SidebarTabItem, node: BrowserOrganizationNode, depth: Int) {
        OrbitUIWorkCounters.record("splitUpdate")
        update(item, depth: depth, node: node)
        let members = item.selected && (2...3).contains(item.splitPanes.count) ? item.splitPanes : []
        titleLabel.isHidden = !members.isEmpty
        if paneCells.count != members.count {
            paneCells.forEach { $0.removeFromSuperview() }
            paneCells = members.map { _ in SidebarSplitPaneCell(frame: .zero) }
            paneCells.forEach { addSubview($0, positioned: .below, relativeTo: closeButton) }
        }
        for (cell, member) in zip(paneCells, members) { cell.present(member, accent: effectiveAccent) }
        needsLayout = true
    }

    override func accentDidChange() {
        super.accentDidChange()
        for (cell, member) in zip(paneCells, item.splitPanes) { cell.present(member, accent: effectiveAccent) }
    }

    override func layout() {
        super.layout()
        guard paneCells.count >= 2 else { return }
        favicon.isHidden = true
        titleLabel.isHidden = true
        let inset: CGFloat = 4, gap: CGFloat = 4
        let width = max(0, (bounds.width - 2 * inset - CGFloat(paneCells.count - 1) * gap) / CGFloat(paneCells.count))
        for (index, cell) in paneCells.enumerated() {
            cell.frame = CGRect(x: inset + CGFloat(index) * (width + gap), y: inset,
                                width: width, height: max(0, bounds.height - inset * 2))
            cell.trailingInset = index == paneCells.count - 1 && isHovering ? 24 : 4
        }
    }
}

@MainActor
final class SidebarSplitPaneCell: NSView {
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    var trailingInset: CGFloat = 4 { didSet { needsLayout = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        icon.imageScaling = .scaleProportionallyDown
        label.font = OrbitTokens.Typography.sidebarTabTitle
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        for view in [icon, label] { view.setAccessibilityElement(false); addSubview(view) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func present(_ item: SidebarSplitPaneItem, accent: OrbitTokens.ThemeAccent) {
        icon.image = item.favicon ?? OrbitGlyph.faviconPlaceholder
        icon.contentTintColor = item.favicon == nil ? accent.icon : nil
        label.stringValue = item.title
        label.textColor = accent.sidebarText
        layer?.backgroundColor = OrbitTokens.Color.State.tabPressed.resolvedCGColor(for: effectiveAppearance)
    }
    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 7, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: 33, y: ((bounds.height - height) / 2).rounded(),
                             width: max(0, bounds.width - 33 - trailingInset), height: height)
    }
}

/// A folder row: an 18 pt folder glyph tinted with the Space accent, a 14 pt semibold title and no
/// chevron; the glyph switches between closed and open. Clicking toggles it.
@MainActor
final class SidebarFolderRow: SidebarListRow {
    private(set) var item: SidebarFolderItem
    let glyph = SidebarFolderGlyphView()

    init(item: SidebarFolderItem, depth: Int = 0) {
        self.item = item
        super.init(node: .folder(item.id))
        titleLabel.font = OrbitTokens.Typography.sidebarFolderTitle
        glyph.accent = effectiveAccent
        addSubview(glyph)
        update(item, depth: depth)
    }

    required init?(coder: NSCoder) { nil }

    override var isMultiSelected: Bool { item.isMultiSelected }

    override func accentDidChange() {
        super.accentDidChange()
        glyph.accent = effectiveAccent
    }

    func update(_ item: SidebarFolderItem, depth: Int) {
        rebind(node: .folder(item.id), depth: depth)
        self.item = item
        titleLabel.stringValue = item.title
        glyph.isOpen = !item.isCollapsed
        setAccessibilityLabel(SidebarListStrings.folder(item.title))
        setAccessibilityValue(item.isCollapsed ? SidebarListStrings.collapsed : SidebarListStrings.expanded)
        setAccessibilityExpanded(!item.isCollapsed)
        setAccessibilitySelected(item.isMultiSelected)
        refreshFill()
        needsLayout = true
    }

    override func layout() {
        let size = Metrics.folderIconSize
        let center = iconX + Metrics.faviconSize / 2
        glyph.frame = NSRect(x: center - size / 2, y: (bounds.height - size) / 2, width: size, height: size)
        super.layout()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }), bounds.contains(local) else { return nil }
        if let renameField, renameField.frame.contains(local) { return renameField.hitTest(local) ?? renameField }
        return self
    }
}

@MainActor
final class SidebarFolderGlyphView: NSView {
    var isOpen = false { didSet { if isOpen != oldValue { needsDisplay = true } } }
    var accent = OrbitTokens.ThemeAccent.defaultSpace { didSet { if accent != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Self.draw(in: bounds, isOpen: isOpen, accent: accent)
    }

    /// Draws the glyph in `bounds` of the current (flipped) graphics context.
    static func draw(in bounds: NSRect, isOpen: Bool, accent: OrbitTokens.ThemeAccent) {
        let glyph = OrbitTokens.Metrics.FolderGlyph.self
        let line = glyph.lineWidth
        let box = bounds.insetBy(dx: line, dy: bounds.height * 0.16 + line / 2)
        let tabWidth = box.width * glyph.tabWidthFraction
        let radius = glyph.cornerRadius
        let body = box.minY + glyph.tabHeight
        // Back panel with its tab, top-left.
        let back = NSBezierPath()
        back.move(to: NSPoint(x: box.minX, y: box.maxY - radius))
        back.line(to: NSPoint(x: box.minX, y: box.minY + radius))
        back.appendArc(from: NSPoint(x: box.minX, y: box.minY), to: NSPoint(x: box.minX + radius, y: box.minY), radius: radius)
        back.line(to: NSPoint(x: box.minX + tabWidth, y: box.minY))
        back.line(to: NSPoint(x: box.minX + tabWidth + glyph.tabHeight, y: body))
        back.line(to: NSPoint(x: box.maxX - radius, y: body))
        back.appendArc(from: NSPoint(x: box.maxX, y: body), to: NSPoint(x: box.maxX, y: body + radius), radius: radius)
        back.line(to: NSPoint(x: box.maxX, y: box.maxY - radius))
        back.appendArc(from: NSPoint(x: box.maxX, y: box.maxY), to: NSPoint(x: box.maxX - radius, y: box.maxY), radius: radius)
        back.line(to: NSPoint(x: box.minX + radius, y: box.maxY))
        back.appendArc(from: NSPoint(x: box.minX, y: box.maxY), to: NSPoint(x: box.minX, y: box.maxY - radius), radius: radius)
        back.close()
        back.lineWidth = line
        back.lineJoinStyle = .round
        accent.iconFill.setFill()
        back.fill()
        accent.icon.setStroke()
        back.stroke()
        // Front panel: a fold line when closed, a panel tilted to the right when open.
        let top = body + box.height * 0.22
        let front = NSBezierPath()
        front.lineWidth = line
        front.lineJoinStyle = .round
        front.lineCapStyle = .round
        if isOpen {
            let skew = box.width * glyph.openSkewFraction
            front.move(to: NSPoint(x: box.minX, y: box.maxY))
            front.line(to: NSPoint(x: box.minX + skew, y: top))
            front.line(to: NSPoint(x: box.maxX + skew * 0.5, y: top))
            front.line(to: NSPoint(x: box.maxX, y: box.maxY))
            front.close()
            accent.iconFill.setFill()
            front.fill()
        } else {
            front.move(to: NSPoint(x: box.minX, y: top))
            front.line(to: NSPoint(x: box.maxX, y: top))
        }
        accent.icon.setStroke()
        front.stroke()
    }
}

@MainActor
final class SidebarPinnedSlashView: NSView {
    var tint = OrbitTokens.ThemeAccent.defaultSpace.icon { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        let inset = bounds.width * 0.3
        path.move(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.minX + inset, y: bounds.maxY))
        path.lineWidth = OrbitTokens.Metrics.Sidebar.pinnedSlashLineWidth
        path.lineCapStyle = .round
        tint.setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class SidebarNewTabRow: NSButton {
    private let background = OrbitSurfaceBackgroundView(cornerRadius: OrbitTokens.Radius.tabRow)
    private let glyph = OrbitGlyphButton(glyph: OrbitGlyph.symbol("plus", pointSize: Metrics.newTabGlyphSize), label: "")
    let label = NSTextField(labelWithString: SidebarListStrings.newTab)
    private let shortcut = NSTextField(labelWithString: "⌘T")
    var accent = OrbitTokens.ThemeAccent.defaultSpace { didSet { refreshAccent() } }
    private var isHovering = false { didSet { if isHovering != oldValue { refresh() } } }
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        title = SidebarListStrings.newTab
        isBordered = false
        imagePosition = .noImage
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel(SidebarListStrings.newTab)
        glyph.showsHoverFill = false
        glyph.isEnabled = true
        label.font = OrbitTokens.Typography.sidebarNewTab
        // : hint typography (13 regular, label colour).
        shortcut.font = OrbitTokens.Typography.menuShortcut
        refreshAccent()
        shortcut.alignment = .right
        shortcut.isHidden = true
        for view in [background, glyph, label, shortcut] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isHighlighted: Bool { didSet { refresh() } }

    override func draw(_ dirtyRect: NSRect) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let local = superview.map({ convert(point, from: $0) }), bounds.contains(local) else { return nil }
        return self
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        let glyphCenter = Metrics.faviconCenterX - Metrics.paddingX
        glyph.frame = NSRect(x: glyphCenter - 10, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let x = Metrics.titleOriginX - Metrics.paddingX
        let height = ceil(label.intrinsicContentSize.height)
        let y = ((bounds.height - height) / 2).rounded()
        let shortcutWidth = ceil(shortcut.intrinsicContentSize.width)
        shortcut.frame = NSRect(x: bounds.width - Metrics.rowInsetX - shortcutWidth, y: y, width: shortcutWidth, height: height)
        label.frame = NSRect(x: x, y: y, width: max(0, bounds.width - x - Metrics.rowInsetX), height: height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func refreshAccent() {
        glyph.tint = accent.foreground
        label.textColor = accent.foreground
        shortcut.textColor = accent.foreground
    }

    private func refresh() {
        background.fillColor = isHighlighted ? OrbitTokens.Color.State.tabPressed : isHovering ? OrbitTokens.Color.State.sidebarItem : nil
        shortcut.isHidden = !isHovering
        refreshAccent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isHovering = false; refresh() }
    }
}

@MainActor
final class SidebarSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = OrbitTokens.Color.Line.sidebarSeparator.resolvedCGColor(for: effectiveAppearance)
    }
}

@MainActor
final class SidebarClearButton: NSButton {
    var accent = OrbitTokens.ThemeAccent.defaultSpace { didSet { needsDisplay = true } }
    private var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        title = SidebarListStrings.clear
        isBordered = false
        setButtonType(.momentaryPushIn)
        setAccessibilityLabel(SidebarListStrings.clear)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    var preferredWidth: CGFloat {
        OrbitUIWorkCounters.record("clearMeasurement")
        return ceil(attributedLabel.size().width) + 2 * OrbitTokens.Metrics.Sidebar.clearHoverPadding
    }
    var isRevealed: Bool { alphaValue > 0 }

    var attributedLabel: NSAttributedString {
        OrbitUIWorkCounters.record("clearLabel")
        let overlays = isEnabled && (isHovering || isHighlighted) ? [OrbitTokens.Color.State.standaloneButton] : []
        let effective = OrbitSpaceThemes.accent(accent, over: overlays)
        return NSAttributedString(string: title, attributes: [
            .font: OrbitTokens.Typography.sidebarClear, .foregroundColor: effective.sidebarSecondaryText
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isRevealed else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, isHovering || isHighlighted {
            OrbitTokens.Color.State.standaloneButton.setFill()
            let radius = OrbitTokens.Radius.toolbarButtonHover
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let label = attributedLabel
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = revealed ? OrbitTokens.Motion.hoverControlsRevealDuration : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = revealed ? 1 : 0
        }
    }
}
