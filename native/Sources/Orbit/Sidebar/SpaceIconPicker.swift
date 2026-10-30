import AppKit
import BrowserShell
import BrowserCore

@MainActor
final class SpaceIconPicker: NSViewController, NSSearchFieldDelegate {
    enum Mode: Int { case emoji, icons }
    enum Purpose { case space, tab }
    private let purpose: Purpose

    static let size = NSSize(width: 270, height: 270)
    let popup = SpacePickerPopover()
    let modes = NSSegmentedControl(labels: [uiText("Emoji"), uiText("Icon")], trackingMode: .selectOne, target: nil, action: nil)
    let search = NSSearchField()
    let grid: SpaceIconGridView
    let removeButton = NSButton(title: uiText("Remove Icon"), target: nil, action: nil)
    let paletteButton = NSButton(title: uiText("Emoji & Symbols…"), target: nil, action: nil)
    private let scroll = NSScrollView()
    private let detail = NSTextField(labelWithString: "")
    private var categoryButtons: [NSButton] = []
    private let catalog: SpaceIconPickerCatalog
    private var currentChoice: BrowserSpaceIcon
    private let accent: OrbitTokens.ThemeAccent
    private var finished = false
    private weak var previousResponder: NSResponder?
    private weak var sourceWindow: NSWindow?
    /// Compatibility callback for the grapheme editor. Symbols use the typed callback.
    var onChoose: ((String) -> Void)?
    var onChooseIcon: ((BrowserSpaceIcon) -> Void)?
    var onClose: (() -> Void)?
    private(set) var mode = Mode.emoji

    convenience init(currentIcon: String, accent: OrbitTokens.ThemeAccent, catalog: SpaceIconPickerCatalog = .shared) {
        self.init(currentChoice: BrowserSpaceIcon(legacyIcon: currentIcon), accent: accent, catalog: catalog)
    }

    init(currentChoice: BrowserSpaceIcon, accent: OrbitTokens.ThemeAccent, catalog: SpaceIconPickerCatalog = .shared, purpose: Purpose = .space) {
        self.purpose = purpose
        self.currentChoice = currentChoice
        if case .systemSymbol = currentChoice { mode = .icons }
        self.accent = accent
        self.catalog = catalog
        grid = SpaceIconGridView(accent: accent)
        super.init(nibName: nil, bundle: nil)
        popup.contentViewController = self
        popup.onClose = { [weak self] in
            guard let self else { return }
            finished = true
            if let sourceWindow, sourceWindow.isKeyWindow, let previousResponder {
                sourceWindow.makeFirstResponder(previousResponder)
            }
            onClose?()
        }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let content = SpaceIconPickerContent(frame: NSRect(origin: .zero, size: Self.size))
        content.setAccessibilityRole(.popover)
        content.setAccessibilityLabel(purpose == .tab ? uiText("Change Tab Icon") : uiText("Change Space Icon or Emoji"))
        content.onKey = { [weak self] in self?.handle($0) ?? false }
        let width = Self.size.width, inset: CGFloat = 10

        modes.selectedSegment = mode.rawValue
        modes.segmentStyle = .rounded
        modes.setWidth(57, forSegment: 0)
        modes.setWidth(57, forSegment: 1)
        modes.target = self
        modes.action = #selector(modeChanged(_:))
        modes.frame = NSRect(x: (width - 114) / 2, y: 12, width: 114, height: 24)
        modes.setAccessibilityIdentifier("space-icon-picker-mode")

        search.placeholderString = uiText("Search")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.frame = NSRect(x: inset, y: 46, width: width - 2 * inset, height: 22)
        search.setAccessibilityIdentifier("space-icon-picker-search")

        let categories: [SpaceIconPickerCatalog.Category] = [.smileys, .animals, .food, .activities, .travel, .objects, .symbols, .flags]
        let pitch = (width - 2 * inset) / CGFloat(categories.count)
        for (index, category) in categories.enumerated() {
            let button = NSButton(frame: NSRect(x: inset + CGFloat(index) * pitch, y: 232, width: pitch, height: 26))
            button.isBordered = false
            button.image = OrbitIcon.image(sfName: Self.categorySymbol(category), pointSize: 16, accessibilityDescription: category.title)
            button.contentTintColor = OrbitTokens.Color.Text.secondary
            button.toolTip = category.title
            button.tag = category.rawValue
            button.target = self
            button.action = #selector(jumpToCategory(_:))
            categoryButtons.append(button)
            content.addSubview(button)
        }

        scroll.frame = NSRect(x: inset, y: 74, width: width - 2 * inset, height: 154)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.tile()
        scroll.documentView = grid
        grid.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 10)
        grid.onHover = { [weak self] item in self?.showDetail(item) }
        grid.canPick = { [weak self] in
            guard let self else { return false }
            return !finished &&
                (search.currentEditor() as? NSTextView)?.hasMarkedText() != true
        }
        grid.onPick = { [weak self] choice in self?.choose(choice) }

        removeButton.target = self
        removeButton.action = #selector(removeIcon(_:))
        removeButton.isEnabled = currentChoice != .none
        if purpose == .tab {
            removeButton.title = uiText("Reset Icon")
            removeButton.image = OrbitIcon.image(sfName: "trash", pointSize: 12, accessibilityDescription: uiText("Reset Icon"))
            removeButton.imagePosition = .imageOnly
            removeButton.isBordered = false
            removeButton.frame = NSRect(x: 198, y: 12, width: 24, height: 24)
            removeButton.isHidden = currentChoice == .none
            content.addSubview(removeButton)
        }
        removeButton.setAccessibilityIdentifier("space-icon-picker-remove")
        paletteButton.target = self
        paletteButton.action = #selector(showCharacterPalette(_:))
        let menu = NSMenu()
        menu.autoenablesItems = false
        for button in [paletteButton, removeButton] {
            let item = NSMenuItem(title: button.title, action: button.action, keyEquivalent: "")
            item.target = self
            item.isEnabled = button.isEnabled
            menu.addItem(item)
        }
        grid.menu = menu
        let separator = NSBox(frame: NSRect(x: inset, y: 228, width: width - 2 * inset, height: 1))
        separator.boxType = .separator
        for view in [modes, search, scroll, separator] as [NSView] { content.addSubview(view) }
        view = content
        updateModeControls()
        reload()
    }

    var canPresent: Bool { !finished && popup.window == nil }

    @discardableResult
    func show(relativeTo button: NSView, anchor: NSRect? = nil) -> Bool {
        guard canPresent, let window = button.window, window.isVisible,
              !button.isHiddenOrHasHiddenAncestor else { return false }
        _ = view
        previousResponder = window.firstResponder
        sourceWindow = window
        popup.show(relativeTo: anchor ?? button.bounds, of: button, preferredEdge: .minY)
        guard let panel = popup.window, panel.isVisible, !finished else {
            popup.performClose(nil)
            return false
        }
        popup.window?.makeFirstResponder(search)
        grid.revealSelection()
        return true
    }

    func cancel() {
        finished = true
        popup.performClose(nil)
    }

    /// Shared by Return, mouse and AX. Mode and availability admission precede the single commit.
    func choose(_ choice: BrowserSpaceIcon) {
        guard !finished, choice.isValid, !isComposing else { return }
        switch choice {
        case .none: break
        case .grapheme: guard mode == .emoji else { return }
        case .systemSymbol: guard mode == .icons, SpaceSymbolCatalog.contains(choice) else { return }
        }
        if purpose == .space {
            finished = true
            popup.performClose(nil)
        } else {
            currentChoice = choice
            removeButton.isHidden = choice == .none
            removeButton.isEnabled = choice != .none
            grid.menu?.items.last?.isEnabled = choice != .none
        }
        onChooseIcon?(choice)
        switch choice {
        case .none: onChoose?("")
        case .grapheme(let value): onChoose?(value)
        case .systemSymbol: break
        }
    }

    func choose(_ emoji: String) { choose(BrowserSpaceIcon(legacyIcon: emoji)) }

    @objc func removeIcon(_ sender: Any?) {
        guard currentChoice != .none else { return }
        choose(.none)
    }

    private var isComposing: Bool { (search.currentEditor() as? NSTextView)?.hasMarkedText() == true }

    /// Typing a query filters by English Unicode names; a typed or palette-inserted emoji is offered first.
    func setSearch(_ text: String) {
        _ = view
        search.stringValue = text
        reload()
    }

    var visibleItems: [SpaceIconPickerCatalog.Item] { grid.items }

    func controlTextDidChange(_ notification: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === search, !textView.hasMarkedText() else { return false }
        return handle(selector)
    }

    @discardableResult
    func handle(_ selector: Selector) -> Bool {
        guard !finished, !isComposing else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if purpose == .tab { cancel() }
            else if !search.stringValue.isEmpty { setSearch("") } else { cancel() }
        case #selector(NSResponder.insertNewline(_:)):
            if let choice = grid.selectedItem?.choice { choose(choice) }
        case #selector(NSResponder.moveDown(_:)):
            grid.moveSelection(rows: 1)
        case #selector(NSResponder.moveUp(_:)):
            grid.moveSelection(rows: -1)
        case #selector(NSResponder.moveRight(_:)):
            grid.moveSelection(by: 1)
        case #selector(NSResponder.moveLeft(_:)):
            grid.moveSelection(by: -1)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return false // Keep ordinary key-view traversal to the mode/category/footer controls.
        default: return false
        }
        return true
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard !finished, !isComposing else { sender.selectedSegment = mode.rawValue; return }
        mode = Mode(rawValue: sender.selectedSegment) ?? .emoji
        search.stringValue = ""
        updateModeControls()
        reload() // Replaces the generation even on an Emoji → Icons → Emoji round trip.
        popup.window?.makeFirstResponder(search)
        grid.revealSelection()
    }

    private func updateModeControls() {
        let icons = mode == .icons
        search.placeholderString = uiText("Search")
        search.isEnabled = true
        grid.setAccessibilityLabel(uiText(icons ? "Icons" : "Emoji"))
        for button in categoryButtons { button.isHidden = icons }
        paletteButton.isHidden = icons
        grid.menu?.items.first?.isHidden = icons
        let keyViews: [NSView] = [modes, search] + (icons ? [] : categoryButtons)
        for (index, control) in keyViews.enumerated() {
            control.nextKeyView = keyViews[(index + 1) % keyViews.count]
        }
    }

    @objc private func jumpToCategory(_ sender: NSButton) {
        guard mode == .emoji, !isComposing, let category = SpaceIconPickerCatalog.Category(rawValue: sender.tag) else { return }
        if !search.stringValue.isEmpty { setSearch("") }
        grid.reveal(category: category)
    }

    @objc private func showCharacterPalette(_ sender: Any?) {
        guard !finished, mode == .emoji, !isComposing else { return }
        popup.window?.makeFirstResponder(search)
        NSApp.orderFrontCharacterPalette(sender)
    }

    private func reload() {
        let query = search.stringValue
        if mode == .icons {
            let results = SpaceSymbolCatalog.search(query)
            grid.setSections([(nil, results)], selecting: query.isEmpty ? currentChoice : results.first?.choice)
        } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
            var sections: [(SpaceIconPickerCatalog.Category?, [SpaceIconPickerCatalog.Item])] =
                SpaceIconPickerCatalog.Category.allCases.map { (nil, orderedItems(in: $0)) }
            if case .grapheme(let value) = currentChoice, !catalog.items.contains(where: { $0.choice == currentChoice }) {
                sections.insert((nil, [.init(emoji: value, name: uiText("Current Icon"), category: .symbols)]), at: 0)
            }
            grid.setSections(sections, selecting: currentChoice)
        } else {
            var results = catalog.search(query)
            if let typed = SpaceIconPickerCatalog.typedEmoji(query) {
                results.removeAll { $0.emoji == typed }
                results.insert(.init(emoji: typed, name: uiText("Use typed emoji"), category: .symbols), at: 0)
            }
            grid.setSections([(nil, results)], selecting: results.first?.choice)
        }
        showDetail(grid.selectedItem)
    }

    private static func categorySymbol(_ category: SpaceIconPickerCatalog.Category) -> String {
        switch category {
        case .smileys, .people: "face.smiling.inverse"
        case .animals: "sun.max"
        case .food: "mug"
        case .activities: "rosette"
        case .travel: "box.truck"
        case .objects: "gift"
        case .symbols: "heart"
        case .flags: "flag"
        }
    }

    /// Familiar face order in the initial viewport; the catalog remains the search authority.
    private func orderedItems(in category: SpaceIconPickerCatalog.Category) -> [SpaceIconPickerCatalog.Item] {
        let items = catalog.items(in: category)
        guard category == .smileys else { return items }
        let leading = Array("😀😃😄😁😆😅🤣😂🙂🙃🫠😉😊😇🥰😍🤩😘😗☺️😚😙🥲😋😛😜🤪😝🤑🤗🫢🤭🫣🤫🤔🫡🤐🤨😐😑").map(String.init)
        let first = leading.compactMap { value in items.first { $0.emoji == value } }
        let choices = Set(first.map(\.emoji))
        return first + items.filter { !choices.contains($0.emoji) }
    }

    private func showDetail(_ item: SpaceIconPickerCatalog.Item?) {
        detail.stringValue = item?.name.capitalized ?? ""
    }
}

@MainActor
private final class SpaceIconPickerContent: NSView {
    var onKey: ((Selector) -> Bool)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func doCommand(by selector: Selector) {
        if onKey?(selector) != true { super.doCommand(by: selector) }
    }
}

/// Sectioned typed icon grid drawn in one view; each cell is exposed to accessibility as a button.
@MainActor
final class SpaceIconGridView: NSView {
    static let cell: CGFloat = 31
    static let rowHeight: CGFloat = 33
    static let headerHeight: CGFloat = 24
    private let accent: OrbitTokens.ThemeAccent
    private(set) var items: [SpaceIconPickerCatalog.Item] = []
    private var cellFrames: [NSRect] = []
    private var headers: [(title: String, frame: NSRect, category: SpaceIconPickerCatalog.Category)] = []
    private var columns = 8
    private(set) var selectedIndex: Int?
    private var hoveredIndex: Int?
    private var showsKeyboardSelection = false
    private var tracking: NSTrackingArea?
    private var elements: [NSAccessibilityElement]?
    private var generation: UInt64 = 0
    var choicesEnabled = true {
        didSet {
            if choicesEnabled != oldValue { generation &+= 1; elements = nil }
        }
    }
    var onHover: ((SpaceIconPickerCatalog.Item?) -> Void)?
    var canPick: (() -> Bool)?
    var onPick: ((BrowserSpaceIcon) -> Void)?
    var selectedItem: SpaceIconPickerCatalog.Item? { selectedIndex.map { items[$0] } }

    init(accent: OrbitTokens.ThemeAccent) {
        self.accent = accent
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Emoji"))
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func setSections(_ sections: [(SpaceIconPickerCatalog.Category?, [SpaceIconPickerCatalog.Item])], selecting choice: BrowserSpaceIcon?) {
        generation &+= 1
        let width = max(250, enclosingScrollView?.contentSize.width ?? frame.width)
        columns = 8
        let originX = (width - CGFloat(columns) * Self.cell) / 2
        items = []; cellFrames = []; headers = []
        var y: CGFloat = 0
        for (category, sectionItems) in sections where !sectionItems.isEmpty {
            if let category {
                headers.append((category.title, NSRect(x: originX + 4, y: y + 6, width: width - 2 * originX, height: 16), category))
                y += Self.headerHeight
            }
            for (index, item) in sectionItems.enumerated() {
                let row = index / columns, column = index % columns
                cellFrames.append(NSRect(x: originX + CGFloat(column) * Self.cell, y: y + CGFloat(row) * Self.rowHeight,
                                         width: Self.cell, height: Self.rowHeight))
                items.append(item)
            }
            y += CGFloat((sectionItems.count + columns - 1) / columns) * Self.rowHeight
        }
        setFrameSize(NSSize(width: width, height: max(y + 4, enclosingScrollView?.contentSize.height ?? 0)))
        selectedIndex = choice.flatMap { choice in items.firstIndex { $0.choice == choice } } ?? (items.isEmpty ? nil : 0)
        hoveredIndex = nil
        showsKeyboardSelection = choice != nil && choice != BrowserSpaceIcon.none
        elements = nil
        needsDisplay = true
    }

    func revealSelection() {
        guard let selectedIndex else { return }
        scrollToVisible(cellFrames[selectedIndex].insetBy(dx: 0, dy: -Self.headerHeight))
    }

    func reveal(category: SpaceIconPickerCatalog.Category) {
        guard let index = items.firstIndex(where: { $0.category == category }), let clip = enclosingScrollView?.contentView else { return }
        clip.scroll(to: NSPoint(x: 0, y: min(cellFrames[index].minY, max(0, frame.height - clip.bounds.height))))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func scrollToSection(_ category: SpaceIconPickerCatalog.Category) {
        guard let header = headers.first(where: { $0.category == category }), let clip = enclosingScrollView?.contentView else { return }
        clip.scroll(to: NSPoint(x: 0, y: min(header.frame.minY - 6, max(0, frame.height - clip.bounds.height))))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(items.count - 1, max(0, (selectedIndex ?? 0) + delta))
        select(next)
    }

    /// Moves to the cell in the same column of the next/previous row, across section breaks.
    func moveSelection(rows: Int) {
        guard let current = selectedIndex, !items.isEmpty else { moveSelection(by: 0); return }
        let frame = cellFrames[current]
        let candidates = items.indices.filter { rows > 0 ? cellFrames[$0].minY > frame.minY : cellFrames[$0].minY < frame.minY }
        let rowY = rows > 0 ? candidates.map { cellFrames[$0].minY }.min() : candidates.map { cellFrames[$0].minY }.max()
        guard let rowY else { return }
        let row = candidates.filter { cellFrames[$0].minY == rowY }
        if let best = row.min(by: { abs(cellFrames[$0].minX - frame.minX) < abs(cellFrames[$1].minX - frame.minX) }) { select(best) }
    }

    private func select(_ index: Int) {
        showsKeyboardSelection = true
        selectedIndex = index
        scrollToVisible(cellFrames[index])
        onHover?(items[index])
        needsDisplay = true
    }

    private func index(at point: NSPoint) -> Int? { cellFrames.firstIndex { $0.contains(point) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let hovered = index(at: convert(event.locationInWindow, from: nil))
        guard hovered != hoveredIndex else { return }
        hoveredIndex = hovered
        onHover?(hovered.map { items[$0] } ?? selectedItem)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        onHover?(selectedItem)
        needsDisplay = true
    }

    private var mouseSelection: (index: Int, choice: BrowserSpaceIcon, generation: UInt64)?
    override func mouseDown(with event: NSEvent) {
        guard choicesEnabled, canPick?() != false, let index = index(at: convert(event.locationInWindow, from: nil)) else {
            mouseSelection = nil; return
        }
        mouseSelection = (index, items[index].choice, generation)
    }

    override func mouseUp(with event: NSEvent) {
        let pending = mouseSelection
        mouseSelection = nil
        guard let pending, index(at: convert(event.locationInWindow, from: nil)) == pending.index else { return }
        _ = pressElement(pending.index, choice: pending.choice, generation: pending.generation)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 20)
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: BrandTextStyle.caption.font(size: 11, weight: .semibold), .foregroundColor: OrbitFloatingMaterial.secondary
        ]
        for header in headers where header.frame.intersects(dirtyRect) {
            NSAttributedString(string: header.title, attributes: headerAttributes).draw(in: header.frame)
        }
        for (index, frame) in cellFrames.enumerated() where frame.intersects(dirtyRect) {
            if (index == selectedIndex && showsKeyboardSelection) || index == hoveredIndex {
                (index == selectedIndex ? NSColor.controlAccentColor.withAlphaComponent(0.12) : OrbitTokens.Color.State.sidebarItemHovered).setFill()
                NSBezierPath(roundedRect: frame.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
            }
            switch items[index].choice {
            case .grapheme(let value):
                let text = NSAttributedString(string: value, attributes: [.font: font])
                let size = text.size()
                text.draw(at: NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
            case .systemSymbol(let name):
                if let image = SpaceIconImages.symbol(name, pointSize: 20, tint: OrbitFloatingMaterial.body, active: true, appearance: effectiveAppearance) {
                    image.draw(in: NSRect(x: frame.midX - image.size.width / 2, y: frame.midY - image.size.height / 2,
                                          width: image.size.width, height: image.size.height))
                }
            case .none: break
            }
        }
    }

    override func accessibilityChildren() -> [Any]? {
        guard choicesEnabled else { return [] }
        if let elements { return elements }
        let created = items.enumerated().map { index, item -> NSAccessibilityElement in
            let element = SpaceIconGridElement(index: index, choice: item.choice, generation: generation, grid: self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(item.name.capitalized)
            element.setAccessibilityValue(SpaceIconImages.label(item.choice))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(cellFrames[index])
            return element
        }
        elements = created
        return created
    }

    fileprivate func pressElement(_ index: Int, choice: BrowserSpaceIcon, generation: UInt64) -> Bool {
        guard choicesEnabled, canPick?() != false, generation == self.generation, items.indices.contains(index),
              items[index].choice == choice else { return false }
        onPick?(choice)
        return true
    }
}

@MainActor
private final class SpaceIconGridElement: NSAccessibilityElement {
    private nonisolated let press: @MainActor @Sendable () -> Bool
    init(index: Int, choice: BrowserSpaceIcon, generation: UInt64, grid: SpaceIconGridView) {
        press = { [weak grid] in
            grid?.pressElement(index, choice: choice, generation: generation) ?? false
        }
        super.init()
    }
    override func accessibilityPerformPress() -> Bool {
        guard Thread.isMainThread else { return false }
        let action = press
        return MainActor.assumeIsolated { action() }
    }
}
