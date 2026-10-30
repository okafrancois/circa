import AppKit
import BrowserShell
import BrowserCore

/// Catalog tiles use stored organization metadata and cached icons, without creating surfaces.
@MainActor
final class BrowserLibrarySpacesView: NSView, NSSearchFieldDelegate {
    struct Item: Equatable {
        let space: BrowserSpace
        let profileName: String
        let iconSelection: BrowserSpaceIcon
        var icon: String? { if case .grapheme(let value) = iconSelection { value } else { nil } }
    }
    let searchField = BrowserLibrarySearchField()
    let scroll = BrowserGestureScrollView()
    private let grid = LibraryFlippedView()
    private(set) var tiles: [BrowserLibrarySpaceTile] = []
    private var items: [Item] = []
    private(set) var rows: [Item] = []
    private(set) var selectedIndex = -1
    private var catalog: BrowserCatalogSnapshot?
    private var presentation: UUID?
    private var sourceProfile: ProfileID?
    private var contents: [SpaceID: SidebarListContent] = [:]
    private var themes: [SpaceID: OrbitTokens.SpaceTheme] = [:]
    var onOpen: ((SpaceID, BrowserCatalogSnapshot, UUID) -> Void)?
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = uiText("Search Spaces…")
        searchField.maximumRecents = 0
        searchField.recentsAutosaveName = nil
        searchField.delegate = self
        searchField.isHidden = true
        searchField.setAccessibilityIdentifier("library-spaces-search")
        addSubview(searchField)
        BrowserLibraryStyle.configure(scroll)
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.documentView = grid
        grid.setAccessibilityIdentifier("library-spaces-grid")
        grid.setAccessibilityLabel(uiText("Spaces"))
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        searchField.frame = NSRect(x: 8, y: 10, width: max(0, bounds.width - 16), height: 36)
        let height = max(0, scroll.contentSize.height)
        grid.frame = NSRect(x: 0, y: 0, width: max(scroll.contentSize.width, 24 + CGFloat(tiles.count) * 264), height: height)
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: 24 + CGFloat(index) * 264, y: 48, width: 240, height: max(0, height - 104))
        }
    }
    func render(catalog: BrowserCatalogSnapshot, activeSpaceID: SpaceID?, sourceProfile: ProfileID,
                icons: [SpaceID: BrowserSpaceIcon], presentation: UUID,
                themes: [SpaceID: OrbitTokens.SpaceTheme] = [:]) {
        if self.presentation != presentation || self.sourceProfile != sourceProfile {
            searchField.stringValue = ""
            selectedIndex = -1
        }
        if self.sourceProfile != sourceProfile { contents = [:] }
        self.presentation = presentation
        self.sourceProfile = sourceProfile
        self.catalog = catalog
        self.themes = themes
        let profiles = Dictionary(uniqueKeysWithValues: catalog.profiles.map { ($0.id, $0.name) })
        items = catalog.spaces.compactMap { space in
            guard let profile = profiles[space.profileID] else { return nil }
            return Item(space: space, profileName: profile, iconSelection: icons[space.id] ?? .none)
        }
        filter()
    }
    func renderContents(document: BrowserSessionDocument, windowID: WindowID?, icon: (ProfileID, URL) -> NSImage?) {
        guard document.spaces == catalog?.spaces, document.profiles == catalog?.profiles else { return }
        for item in items {
            contents[item.space.id] = SpaceSwipePreview.content(document: document, spaceID: item.space.id, windowID: windowID, icon: icon)
        }
        updateTiles()
    }
    func clear() {
        catalog = nil; presentation = nil; sourceProfile = nil
        items = []; rows = []; contents = [:]; themes = [:]; searchField.stringValue = ""; selectedIndex = -1
        for tile in tiles { tile.removeFromSuperview() }
        tiles = []
    }
    func controlTextDidChange(_ notification: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelOperation(nil); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { openSelected(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !rows.isEmpty else { return true }
            selectItem(at: selector == #selector(NSResponder.moveDown(_:)) ? min(rows.count - 1, selectedIndex + 1) : max(0, selectedIndex - 1))
            return true
        }
        return false
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: selectItem(at: max(0, selectedIndex - 1))
        case 124, 125: selectItem(at: min(rows.count - 1, selectedIndex + 1))
        case 36, 76: openSelected()
        case 53: cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) {
        if !searchField.stringValue.isEmpty { searchField.stringValue = ""; filter() }
        else { onBack?() }
    }
    func selectItem(at index: Int) {
        selectedIndex = rows.indices.contains(index) ? index : -1
        if tiles.indices.contains(selectedIndex) { grid.scrollToVisible(tiles[selectedIndex].frame) }
    }
    private func filter() {
        let selected = rows.indices.contains(selectedIndex) ? rows[selectedIndex].space.id : nil
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = items.filter { query.isEmpty || ($0.space.name + " " + $0.profileName)
            .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        selectedIndex = selected.flatMap { id in rows.firstIndex(where: { $0.space.id == id }) } ?? -1
        updateTiles()
    }
    private func updateTiles() {
        let previous = Dictionary(uniqueKeysWithValues: tiles.map { ($0.item.space.id, $0) })
        tiles = rows.map { item in
            let tile = previous[item.space.id] ?? BrowserLibrarySpaceTile(item: item)
            tile.configure(item: item, theme: themes[item.space.id] ?? OrbitSpaceThemes.theme(forSpace: item.space.id, in: catalog), content: contents[item.space.id] ?? .empty)
            tile.onOpen = { [weak self] in
                guard let self, let index = rows.firstIndex(where: { $0.space.id == item.space.id }) else { return }
                selectItem(at: index); openSelected()
            }
            if tile.superview == nil { grid.addSubview(tile) }
            return tile
        }
        for tile in previous.values where !tiles.contains(where: { $0 === tile }) { tile.removeFromSuperview() }
        needsLayout = true
    }
    @objc func openSelected() {
        guard rows.indices.contains(selectedIndex), let catalog, let presentation else { return }
        onOpen?(rows[selectedIndex].space.id, catalog, presentation)
    }
}

@MainActor
final class BrowserLibrarySpaceTile: NSButton {
    private(set) var item: BrowserLibrarySpacesView.Item
    private let fill = OrbitThemeFillView()
    private(set) var iconView: NSView
    private var content = SidebarListContent.empty
    private var ink = NSColor.labelColor
    var onOpen: (() -> Void)?
    init(item: BrowserLibrarySpacesView.Item) {
        self.item = item
        iconView = SpaceIconImages.view(item.iconSelection)
        super.init(frame: .zero)
        title = ""; isBordered = false; wantsLayer = true
        layer?.cornerRadius = 12; layer?.masksToBounds = true
        fill.autoresizingMask = [.width, .height]
        addSubview(fill)
        addSubview(iconView)
        target = self; action = #selector(openSpace)
        setAccessibilityIdentifier("library-space-tile")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func configure(item: BrowserLibrarySpacesView.Item, theme: OrbitTokens.SpaceTheme, content: SidebarListContent) {
        if self.item.iconSelection != item.iconSelection {
            iconView.removeFromSuperview(); iconView = SpaceIconImages.view(item.iconSelection); addSubview(iconView)
        }
        self.item = item; self.content = content
        appearance = OrbitAppearance.windowAppearance(for: theme.mode, override: nil)
        fill.apply(theme)
        ink = BrowserLibraryStyle.foreground
        setAccessibilityLabel(item.space.name + ", " + item.profileName)
        setAccessibilityHelp(content.entries.map(\.title).joined(separator: ", "))
        overlay.needsDisplay = true
    }
    @objc private func openSpace() { onOpen?() }
    override func layout() {
        super.layout(); fill.frame = bounds
        iconView.frame = NSRect(x: 18, y: 17, width: 16, height: 16)
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if overlay.superview == nil { addSubview(overlay) }
        overlay.owner = self
        overlay.frame = bounds; overlay.autoresizingMask = [.width, .height]
    }
    private let overlay = LibrarySpaceTileForeground()
    fileprivate func drawForeground() {
        let color = ink.resolved(for: effectiveAppearance)
        func text(_ value: String, _ rect: NSRect, size: CGFloat = 14, bold: Bool = false, opacity: CGFloat = 1) {
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (value as NSString).draw(in: rect, withAttributes: [.font: BrandTextStyle.ui.font(size: size, weight: bold ? .semibold : .regular), .foregroundColor: color.withAlphaComponent(opacity), .paragraphStyle: style])
        }
        text(item.space.name, NSRect(x: 44, y: 17, width: 82, height: 20), size: 13, bold: true, opacity: 0.55)
        let badge = NSRect(x: 119, y: 14, width: 74, height: 22)
        color.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: badge, xRadius: 11, yRadius: 11).fill()
        OrbitIcon.draw(OrbitIcon.image(sfName: "face.smiling", pointSize: 12),
                       in: NSRect(x: 125, y: 18, width: 12, height: 12), tint: color.withAlphaComponent(0.4))
        text(item.profileName, NSRect(x: 142, y: 17, width: 45, height: 16), size: 11, bold: true, opacity: 0.4)
        func glyph(_ name: String, x: CGFloat, y: CGFloat, size: CGFloat) {
            OrbitIcon.draw(OrbitIcon.image(sfName: name, pointSize: size),
                           in: NSRect(x: x, y: y, width: size, height: size), tint: color.withAlphaComponent(0.45))
        }
        glyph("paintbrush.fill", x: 207, y: 20, size: 14)
        glyph("arrow.up.and.down.and.arrow.left.and.right", x: 15, y: bounds.height - 29, size: 15)
        glyph("ellipsis", x: 212, y: bounds.height - 28, size: 12)
        var y: CGFloat = 54
        var previousSection: SidebarListSection?
        for entry in content.entries {
            if previousSection == .pinned && entry.section == .today {
                color.withAlphaComponent(0.15).setFill(); NSRect(x: 18, y: y - 2, width: 156, height: 0.5).fill()
                glyph("arrow.down", x: 182, y: y - 7, size: 12)
                text(uiText("Clear"), NSRect(x: 194, y: y - 7, width: 34, height: 16), size: 10, bold: true, opacity: 0.4)
                y += 20
            }
            previousSection = entry.section
            guard y + 30 < bounds.height - 40 else { break }
            let x = 18 + CGFloat(entry.depth) * 16
            if let favicon = entry.tab?.favicon { favicon.draw(in: NSRect(x: x, y: y + 4, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            else if entry.folder != nil {
                OrbitIcon.draw(OrbitIcon.image(sfName: "folder", pointSize: 22),
                               in: NSRect(x: x - 2, y: y + 2, width: 22, height: 20), tint: color.withAlphaComponent(0.65))
            } else {
                color.withAlphaComponent(0.15).setFill(); NSBezierPath(roundedRect: NSRect(x: x + 1, y: y + 5, width: 14, height: 14), xRadius: 3, yRadius: 3).fill()
            }
            text(entry.title, NSRect(x: x + 26, y: y + 3, width: 198 - x, height: 24), bold: entry.folder != nil)
            y += 41
        }
    }
}

@MainActor
private final class LibrarySpaceTileForeground: NSView {
    weak var owner: BrowserLibrarySpaceTile?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawForeground() }
}
