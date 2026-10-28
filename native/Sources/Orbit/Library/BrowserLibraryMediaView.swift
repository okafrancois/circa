import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A projection of completed downloads, never a directory or history-URL scan.
@MainActor
final class BrowserLibraryMediaView: NSView, NSSearchFieldDelegate {
    struct Item: Equatable {
        let snapshot: BrowserDownloadSnapshot
        let url: URL
        let isVideo: Bool
        var title: String { url.lastPathComponent }
    }
    let searchField = BrowserLibrarySearchField()
    let scroll = BrowserGestureScrollView()
    private let grid = LibraryFlippedView()
    private let empty = BrowserLibraryMediaEmptyView()
    private var profileID: ProfileID?
    private var items: [Item] = []
    private(set) var rows: [Item] = []
    private var tiles: [BrowserDownloadKey: BrowserLibraryMediaTile] = [:]
    var onAction: ((BrowserDownloadContext, DownloadRowPresentation.Action) -> Void)?
    var onBack: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = uiText("Search Media…")
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("library-media-search")
        BrowserLibraryStyle.configure(scroll)
        scroll.documentView = grid
        grid.setAccessibilityIdentifier("library-media-grid")
        for view in [searchField, scroll, empty] { addSubview(view) }
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        searchField.frame = NSRect(x: 8, y: 10, width: max(0, bounds.width - 16), height: 36)
        scroll.frame = NSRect(x: 0, y: 52, width: bounds.width, height: max(0, bounds.height - 52))
        let width = max(0, scroll.contentSize.width)
        let side = max(1, (width - 40) / 2)
        grid.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, 8 + ceil(Double(rows.count) / 2) * (side + 8)))
        for (index, item) in rows.enumerated() {
            tiles[item.snapshot.key]?.frame = NSRect(x: 12 + CGFloat(index % 2) * (side + 16),
                y: 8 + CGFloat(index / 2) * (side + 8), width: side, height: side)
        }
        empty.frame = NSRect(x: 16, y: (bounds.height - 186) / 2 + 28, width: max(0, bounds.width - 32), height: 186)
    }
    static func media(_ snapshots: [BrowserDownloadSnapshot], profile: ProfileID) -> [Item] {
        var seen: Set<URL> = []
        return snapshots.compactMap { snapshot in
            guard snapshot.owner.profileID == profile, snapshot.key.profileID == profile,
                  snapshot.state == .complete, snapshot.fileAvailability != .missing,
                  let url = snapshot.destinationURL, url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video),
                  BrowserDownloadPaths.regularFileSize(url) != nil,
                  seen.insert(url.standardizedFileURL).inserted else { return nil }
            return Item(snapshot: snapshot, url: url, isVideo: type.conforms(to: .movie) || type.conforms(to: .video))
        }
    }
    func render(_ snapshots: [BrowserDownloadSnapshot], profile: ProfileID) {
        if profileID != profile { clear(); profileID = profile }
        items = Self.media(snapshots, profile: profile)
        filter()
    }
    func clear() {
        items = []; rows = []; profileID = nil; searchField.stringValue = ""
        for tile in tiles.values { tile.removeFromSuperview() }
        tiles.removeAll()
        needsLayout = true
    }
    func controlTextDidChange(_ notification: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText(), selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelLibrarySearch(searchField, search: { self.filter() }, close: { self.onBack?() })
        return true
    }
    private func filter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = items.filter { query.isEmpty || $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let keys = Set(rows.map { $0.snapshot.key })
        let inventoryKeys = Set(items.map { $0.snapshot.key })
        for key in Array(tiles.keys) where !inventoryKeys.contains(key) { tiles.removeValue(forKey: key)?.removeFromSuperview() }
        for (key, tile) in tiles { tile.isHidden = !keys.contains(key) }
        for item in rows {
            let tile = tiles[item.snapshot.key] ?? BrowserLibraryMediaTile(item: item)
            tile.item = item
            tile.onAction = { [weak self] action in self?.onAction?(item.snapshot.context, action) }
            if tile.superview == nil { grid.addSubview(tile); tiles[item.snapshot.key] = tile }
        }
        scroll.isHidden = rows.isEmpty
        empty.isHidden = !rows.isEmpty
        empty.configure(query: query)
        needsLayout = true
    }
}

@MainActor
final class LibraryFlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class BrowserLibraryMediaTile: NSButton {
    var item: BrowserLibraryMediaView.Item
    var onAction: ((DownloadRowPresentation.Action) -> Void)?
    private var thumbnail: NSImage?
    private var request: QLThumbnailGenerator.Request?
    init(item: BrowserLibraryMediaView.Item) {
        self.item = item
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self; action = #selector(openFile)
        setAccessibilityLabel(item.title)
        setAccessibilityIdentifier("library-media-item")
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: NSSize(width: 240, height: 240), scale: 2, representationTypes: .thumbnail)
        self.request = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.cgImage
            Task { @MainActor [weak self, image] in
                guard let self else { return }
                thumbnail = image.map { NSImage(cgImage: $0, size: .zero) }
                needsDisplay = true
            }
        }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func openFile() { onAction?(.open) }
    @objc private func revealFile() { onAction?(.reveal) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [(uiText("Open"), #selector(openFile)), (uiText("Show in Finder"), #selector(revealFile))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    override func draw(_ dirtyRect: NSRect) {
        BrowserLibraryStyle.foreground.withAlphaComponent(0.04).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        guard let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 else { return }
        let available = bounds.insetBy(dx: 13, dy: 13)
        let scale = min(available.width / thumbnail.size.width, available.height / thumbnail.size.height)
        let size = NSSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
        let imageRect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: imageRect.insetBy(dx: -4, dy: -4), xRadius: 2, yRadius: 2).fill()
        thumbnail.draw(in: imageRect)
    }
}

@MainActor
private final class BrowserLibraryMediaEmptyView: NSView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: uiText("Nothing here yet!"))
    private let detail = NSTextField(wrappingLabelWithString: uiText("Images and videos you download in this profile appear here."))
    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 16, weight: .bold)
        detail.font = .systemFont(ofSize: 14, weight: .medium)
        for label in [title, detail] { label.alignment = .center }
        for view in [icon, title, detail] { addSubview(view) }
        updateColors()
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    func configure(query: String) {
        title.stringValue = query.isEmpty ? uiText("Nothing here yet!") : uiFormat("No results found for\n“%@”", query)
        detail.isHidden = !query.isEmpty
    }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: bounds.midX - 28, y: 0, width: 56, height: 48)
        title.frame = NSRect(x: 0, y: 64, width: bounds.width, height: 40)
        detail.frame = NSRect(x: 0, y: 94, width: bounds.width, height: 76)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        icon.contentTintColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.3)
        title.textColor = BrowserLibraryStyle.foreground
        detail.textColor = BrowserLibraryStyle.foreground.withAlphaComponent(0.65)
    }
}
