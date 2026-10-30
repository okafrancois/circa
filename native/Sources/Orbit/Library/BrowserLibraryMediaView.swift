import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A projection of completed downloads, never a directory or history-URL scan. Files at the
/// tiles in view are checked at once; the others are checked off the main thread. Only tiles near
/// the viewport exist, and their thumbnails come from a bounded cache.
@MainActor
final class BrowserLibraryMediaView: NSView, NSSearchFieldDelegate {
    struct Item: Equatable {
        let snapshot: BrowserDownloadSnapshot
        let url: URL
        let isVideo: Bool
        var title: String { url.lastPathComponent }
    }
    private enum Metrics {
        static let overscanRows = 2
        /// Viewport assumed before the grid has been laid out.
        static let unplacedHeight: CGFloat = 900
        static let minimumSide: CGFloat = 96
    }
    let searchField = BrowserLibrarySearchField()
    let scroll = BrowserGestureScrollView()
    private let grid = LibraryFlippedView()
    private let empty = BrowserLibraryMediaEmptyView()
    private var profileID: ProfileID?
    private var candidates: [Item] = []
    private var present: [URL: Bool] = [:]
    private var items: [Item] = []
    private(set) var rows: [Item] = []
    private var tiles: [BrowserDownloadKey: BrowserLibraryMediaTile] = [:]
    private var pool: [BrowserLibraryMediaTile] = []
    let thumbnails = LibraryThumbnailCache()
    private var checkTask: Task<Void, Never>?
    private var checkGeneration: UInt64 = 0
    var onAction: ((BrowserDownloadContext, DownloadRowPresentation.Action) -> Void)?
    var onBack: (() -> Void)?
    /// Synthetic measurement only: signed changes of resident decoded thumbnail bytes.
    static var thumbnailBytesProbe: ((Int) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        searchField.placeholderString = uiText("Search Media…")
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("library-media-search")
        BrowserLibraryStyle.configure(scroll)
        scroll.documentView = grid
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
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
        materialize()
        empty.frame = NSRect(x: 16, y: (bounds.height - 186) / 2 + 28, width: max(0, bounds.width - 32), height: 186)
    }
    @objc private func clipBoundsDidChange(_ notification: Notification) { materialize() }

    /// Completed local images and videos of the profile, without file-system access.
    static func candidates(_ snapshots: [BrowserDownloadSnapshot], profile: ProfileID) -> [Item] {
        var seen: Set<URL> = []
        return snapshots.compactMap { snapshot in
            guard snapshot.owner.profileID == profile, snapshot.key.profileID == profile,
                  snapshot.state == .complete, snapshot.fileAvailability != .missing,
                  let url = snapshot.destinationURL, url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video),
                  seen.insert(url.standardizedFileURL).inserted else { return nil }
            return Item(snapshot: snapshot, url: url, isVideo: type.conforms(to: .movie) || type.conforms(to: .video))
        }
    }
    func render(_ snapshots: [BrowserDownloadSnapshot], profile: ProfileID) {
        if profileID != profile { clear(); profileID = profile }
        candidates = Self.candidates(snapshots, profile: profile)
        let unchecked = project(checking: checkedTiles())
        let known = Set(candidates.map(\.url))
        present = present.filter { known.contains($0.key) }
        check(unchecked)
        apply()
    }
    func clear() {
        checkTask?.cancel(); checkTask = nil; checkGeneration &+= 1
        candidates = []; present = [:]; items = []; rows = []; profileID = nil; searchField.stringValue = ""
        for tile in Array(tiles.values) + pool { tile.prepareForReuse(); tile.removeFromSuperview() }
        tiles.removeAll(); pool.removeAll()
        thumbnails.removeAll()
        needsLayout = true
    }
    func controlTextDidChange(_ notification: Notification) { filter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText(), selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelLibrarySearch(searchField, search: { self.filter() }, close: { self.onBack?() })
        return true
    }
    private var query: String { searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func matches(_ item: Item, _ query: String) -> Bool {
        query.isEmpty || item.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    private func filter() {
        let query = query
        rows = items.filter { Self.matches($0, query) }
        apply()
    }

    /// Rebuilds the inventory in candidate order. Files at the tile positions in `checking` are
    /// checked now, so the tiles in view are exact; the others keep their last known presence
    /// and are returned for a background check.
    private func project(checking band: Range<Int>) -> [URL] {
        let query = query
        var inventory: [Item] = [], filtered: [Item] = [], unchecked: [URL] = []
        for item in candidates {
            let matches = Self.matches(item, query)
            let exists: Bool
            if matches, band.contains(filtered.count) {
                exists = BrowserDownloadPaths.regularFileSize(item.url) != nil
                present[item.url] = exists
            } else {
                exists = present[item.url] ?? false
                unchecked.append(item.url)
            }
            guard exists else { continue }
            inventory.append(item)
            if matches { filtered.append(item) }
        }
        items = inventory
        rows = filtered
        return unchecked
    }

    private func check(_ urls: [URL]) {
        checkTask?.cancel()
        checkGeneration &+= 1
        let generation = checkGeneration
        guard !urls.isEmpty else { checkTask = nil; return }
        checkTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { () -> [(URL, Bool)] in
                var results: [(URL, Bool)] = []
                for url in urls {
                    if Task.isCancelled { break }
                    results.append((url, BrowserDownloadPaths.regularFileSize(url) != nil))
                }
                return results
            }
            let results = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, checkGeneration == generation else { return }
            checkTask = nil
            for (url, exists) in results { present[url] = exists }
            _ = project(checking: 0..<0)
            apply()
        }
    }

    private func apply() {
        thumbnails.retain(Set(items.map(LibraryThumbnailCache.Key.init)))
        scroll.isHidden = rows.isEmpty
        // A pending background check may still find files: no premature empty state.
        empty.isHidden = !rows.isEmpty || checkTask != nil
        empty.configure(query: query)
        materialize(reconfigure: true)
        needsLayout = true
    }

    private func tileSide(_ width: CGFloat) -> CGFloat { max(1, (width - 40) / 2) }

    /// The tile indices in view and in the overscan rows, by the current scroll position.
    private func tileRange(width: CGFloat, count: Int) -> Range<Int> {
        let pitch = tileSide(width) + 8
        var visible = scroll.contentView.bounds
        if visible.height <= 0 { visible.size.height = max(bounds.height - 52, Metrics.unplacedHeight) }
        let first = max(0, Int(floor((visible.minY - 8) / pitch)) - Metrics.overscanRows)
        let last = max(first, Int(floor((visible.maxY - 8) / pitch)) + Metrics.overscanRows)
        return min(count, first * 2)..<min(count, (last + 1) * 2)
    }

    private func checkedTiles() -> Range<Int> {
        let width = scroll.contentSize.width > 0 ? scroll.contentSize.width : bounds.width
        return tileRange(width: max(width, 2 * Metrics.minimumSide + 40), count: .max)
    }

    /// Gives tiles to the rows near the visible rect and recycles the others.
    private func materialize(reconfigure: Bool = false) {
        let width = scroll.contentSize.width
        guard width > 0, scroll.contentSize.height > 0, !scroll.isHidden else {
            for (key, tile) in tiles { tiles[key] = nil; recycle(tile) }
            return
        }
        let side = tileSide(width)
        var needed: [BrowserDownloadKey: Int] = [:]
        for index in tileRange(width: width, count: rows.count) { needed[rows[index].snapshot.key] = index }
        for (key, tile) in tiles where needed[key] == nil { tiles[key] = nil; recycle(tile) }
        for (key, index) in needed.sorted(by: { $0.value < $1.value }) {
            let item = rows[index]
            let tile: BrowserLibraryMediaTile
            if let existing = tiles[key] {
                tile = existing
                if reconfigure { configure(tile, item) }
            } else {
                tile = pool.popLast() ?? {
                    let created = BrowserLibraryMediaTile()
                    grid.addSubview(created)
                    return created
                }()
                tile.isHidden = false
                configure(tile, item)
                tiles[key] = tile
            }
            let frame = NSRect(x: 12 + CGFloat(index % 2) * (side + 16), y: 8 + CGFloat(index / 2) * (side + 8), width: side, height: side)
            if tile.frame != frame { tile.frame = frame }
        }
    }

    private func configure(_ tile: BrowserLibraryMediaTile, _ item: Item) {
        tile.onAction = { [weak self] action in self?.onAction?(item.snapshot.context, action) }
        tile.show(item, thumbnails: thumbnails)
    }

    private func recycle(_ tile: BrowserLibraryMediaTile) {
        tile.prepareForReuse()
        tile.isHidden = true
        pool.append(tile)
    }

    var materializedTileCount: Int { tiles.count }
    var pendingCheck: Bool { checkTask != nil }
    var displayedTiles: [(item: Item, thumbnail: NSImage?, frame: NSRect)] {
        tiles.values.compactMap { tile in tile.item.map { ($0, tile.displayedThumbnail, tile.frame) } }
    }
}

@MainActor
final class LibraryFlippedView: NSView { override var isFlipped: Bool { true } }

/// Decoded thumbnails of recently shown tiles, bounded by count and bytes and least recently used
/// first out. A file QuickLook cannot render is remembered as such. Entries leave with their item.
@MainActor
final class LibraryThumbnailCache {
    struct Key: Hashable, Sendable {
        let download: BrowserDownloadKey
        let url: URL
        init(_ item: BrowserLibraryMediaView.Item) { download = item.snapshot.key; url = item.url }
    }
    private struct Entry {
        let image: NSImage?
        let bytes: Int
        var lastUse: UInt64
    }
    let countLimit: Int
    let byteLimit: Int
    private var entries: [Key: Entry] = [:]
    private(set) var bytes = 0
    private var clock: UInt64 = 0
    var count: Int { entries.count }

    init(countLimit: Int = 64, byteLimit: Int = 64 << 20) {
        self.countLimit = countLimit
        self.byteLimit = byteLimit
    }

    struct Hit { let image: NSImage? }

    /// `nil` when nothing is known; a hit without an image when QuickLook had none.
    func lookup(_ key: Key) -> Hit? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key]?.lastUse = clock
        return Hit(image: entry.image)
    }

    @discardableResult
    func store(_ image: CGImage?, for key: Key) -> NSImage? {
        let thumbnail = image.map { NSImage(cgImage: $0, size: .zero) }
        let cost = image.map { $0.bytesPerRow * $0.height } ?? 0
        remove(key)
        clock += 1
        entries[key] = Entry(image: thumbnail, bytes: cost, lastUse: clock)
        bytes += cost
        if cost > 0 { BrowserLibraryMediaView.thumbnailBytesProbe?(cost) }
        while entries.count > countLimit || bytes > byteLimit,
              let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key, oldest != key {
            remove(oldest)
        }
        return thumbnail
    }

    func retain(_ keys: Set<Key>) {
        for key in Array(entries.keys) where !keys.contains(key) { remove(key) }
    }

    func removeAll() {
        for key in Array(entries.keys) { remove(key) }
    }

    private func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        bytes -= entry.bytes
        if entry.bytes > 0 { BrowserLibraryMediaView.thumbnailBytesProbe?(-entry.bytes) }
    }
}

@MainActor
private final class BrowserLibraryMediaTile: NSButton {
    private(set) var item: BrowserLibraryMediaView.Item?
    var onAction: ((DownloadRowPresentation.Action) -> Void)?
    private var thumbnail: NSImage?
    private var request: QLThumbnailGenerator.Request?
    private var pending: UInt64?
    private static var nextToken: UInt64 = 0
    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self; action = #selector(openFile)
        setAccessibilityIdentifier("library-media-item")
    }
    required init?(coder: NSCoder) { nil }

    /// A tile showing the same file keeps its thumbnail; another file starts from the cache.
    func show(_ item: BrowserLibraryMediaView.Item, thumbnails: LibraryThumbnailCache) {
        let key = LibraryThumbnailCache.Key(item)
        let unchanged = self.item.map(LibraryThumbnailCache.Key.init) == key
        self.item = item
        setAccessibilityLabel(item.title)
        guard !unchanged || (thumbnail == nil && pending == nil) else { return }
        cancelThumbnail()
        if let cached = thumbnails.lookup(key) {
            thumbnail = cached.image
            needsDisplay = true
            return
        }
        thumbnail = nil
        needsDisplay = true
        Self.nextToken &+= 1
        let token = Self.nextToken
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: NSSize(width: 240, height: 240), scale: 2, representationTypes: .thumbnail)
        self.request = request
        pending = token
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.cgImage
            Task { @MainActor [weak self, image] in
                // A recycled or cancelled tile has another token: its late result is dropped.
                guard let self, pending == token else { return }
                pending = nil
                self.request = nil
                thumbnail = thumbnails.store(image, for: key)
                needsDisplay = true
            }
        }
    }

    private func cancelThumbnail() {
        if let request { QLThumbnailGenerator.shared.cancel(request) }
        request = nil
        pending = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        thumbnail = nil
        item = nil
        onAction = nil
    }
    var displayedThumbnail: NSImage? { thumbnail }
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
        title.font = BrandTextStyle.title.font(size: 16)
        detail.font = BrandTextStyle.ui.font(size: 14, weight: .medium)
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
