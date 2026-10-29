import AppKit
import BrowserCore

@MainActor
final class FavoritesGridView: NSView, NSDraggingSource, FavoritesLocalDragSource {
    private(set) var items: [FavoriteTileItem] = []
    private(set) var tiles: [FavoriteTileView] = []
    var animatesChanges = true
    var minimumTileWidth = OrbitTokens.Metrics.Sidebar.favoriteMinimumTileWidth { didSet { if minimumTileWidth != oldValue { needsLayout = true } } }
    var onDragWillBegin: (() -> Void)?
    var onSelect: ((TabID) -> Void)?
    var makeContextMenu: ((TabID) -> NSMenu?)?
    var commandsEnabled = true { didSet { for tile in tiles { tile.commandsEnabled = commandsEnabled } } }
    let dropTarget = FavoritesDropTarget()
    private(set) var favoritesDragPayload: FavoritesDragPayload?
    private var preview: (payload: FavoritesDragPayload, index: Int)?
    private let placeholder = OrbitSurfaceBackgroundView(cornerRadius: OrbitTokens.Radius.favoriteTile)
    private var animateNextLayout = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(uiText("Favorites"))
        placeholder.fillColor = OrbitTokens.Color.State.sidebarItemHovered
        placeholder.borderColor = OrbitTokens.Color.Text.tertiary
        placeholder.borderWidth = 1
        placeholder.isHidden = true
        addSubview(placeholder)
        dropTarget.grid = self
        registerForDraggedTypes([FavoritesDragPayload.pasteboardType])
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var geometry: OrbitSidebarGeometry {
        OrbitSidebarGeometry.resolve(.init(width: bounds.width + 2 * OrbitTokens.Metrics.Sidebar.paddingX,
            height: 640, favoriteCount: previewItemCount, favoriteMinimumTileWidth: minimumTileWidth))
    }
    var canAnimate: Bool { animatesChanges && window?.isVisible == true && window?.occlusionState.contains(.visible) == true }

    func applySelection(_ updates: [FavoriteTileItem]) {
        for item in updates {
            guard let index = items.firstIndex(where: { $0.tab.id == item.tab.id }), items[index] != item else { continue }
            items[index] = item
            tiles[index].update(item)
        }
    }

    func render(_ items: [FavoriteTileItem], profileID: ProfileID?) {
        let profileChanged = dropTarget.profileID != profileID
        if profileChanged { dropTarget.end() }
        guard profileChanged || self.items != items else { return }
        let previousIDs = self.items.map { $0.tab.id }
        self.items = items
        dropTarget.profileID = profileID
        var existing = Dictionary(uniqueKeysWithValues: tiles.map { ($0.item.tab.id, $0) })
        if profileChanged {
            for tile in existing.values { tile.removeFromSuperview() }
            existing.removeAll()
        }
        tiles = items.map { item in
            if let tile = existing.removeValue(forKey: item.tab.id) { tile.update(item); return tile }
            let tile = FavoriteTileView(item: item)
            tile.commandsEnabled = commandsEnabled
            tile.onSelect = { [weak self] in self?.onSelect?(item.tab.id) }
            tile.onDrag = { [weak self, weak tile] event in
                if let tile { self?.beginDrag(tile: tile, event: event) }
            }
            tile.makeContextMenu = { [weak self] in self?.makeContextMenu?(item.tab.id) }
            tile.frame = geometry.favoriteTileFrame(index: items.firstIndex(where: { $0.tab.id == item.tab.id }) ?? 0)
            addSubview(tile, positioned: .above, relativeTo: placeholder)
            if canAnimate, !profileChanged {
                let appear = CABasicAnimation(keyPath: "opacity")
                appear.fromValue = 0
                appear.toValue = 1
                appear.duration = OrbitTokens.Motion.reducedMotionCrossfade
                tile.layer?.add(appear, forKey: "favorites.insert")
            }
            return tile
        }
        for tile in existing.values { retire(tile) }
        animateNextLayout = !profileChanged && (animateNextLayout || previousIDs != items.map { $0.tab.id })
        needsLayout = true
    }

    private func retire(_ tile: FavoriteTileView) {
        tile.commandsEnabled = false
        tile.setAccessibilityHidden(true)
        guard canAnimate else { tile.removeFromSuperview(); return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = tile.layer?.presentation()?.opacity ?? 1
        animation.toValue = 0
        animation.duration = OrbitTokens.Motion.hoverControlsRevealDuration
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { tile.removeFromSuperview() } }
        tile.layer?.opacity = 0
        tile.layer?.add(animation, forKey: "favorites.remove")
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let geometry = geometry
        var order: [TabID?] = items.map { $0.tab.id }
        if let preview {
            let before = items.prefix(preview.index).filter { !preview.payload.nodes.contains(.tab($0.tab.id)) }.count
            order.removeAll { id in id.map { preview.payload.nodes.contains(.tab($0)) } ?? false }
            order.insert(contentsOf: Array(repeating: nil, count: preview.payload.nodes.count), at: min(before, order.count))
            placeholder.frame = geometry.favoriteTileFrame(index: before)
            placeholder.isHidden = false
        } else { placeholder.isHidden = true }
        for tile in tiles {
            guard let index = order.firstIndex(where: { $0 == tile.item.tab.id }) else {
                tile.alphaValue = 0.3
                continue
            }
            tile.alphaValue = 1
            let frame = geometry.favoriteTileFrame(index: index)
            let old = tile.layer?.presentation()?.frame ?? tile.frame
            tile.frame = frame
            guard animateNextLayout, old != frame else { continue }
            let style = OrbitMotionStyle.resolve(animated: true, canAnimate: canAnimate,
                reducedMotion: OrbitMotionPreferences.prefersReducedMotion)
            if style == .spring {
                let animation = OrbitTokens.Motion.rowReorder.animation(keyPath: "position")
                // Layer positions in flipped NSViews use the same parent coordinate system.
                animation.fromValue = NSValue(point: NSPoint(x: old.midX, y: old.midY))
                animation.toValue = NSValue(point: NSPoint(x: frame.midX, y: frame.midY))
                tile.layer?.add(animation, forKey: "favorites.reorder")
                let resize = OrbitTokens.Motion.rowReorder.animation(keyPath: "bounds.size")
                resize.fromValue = NSValue(size: old.size)
                resize.toValue = NSValue(size: frame.size)
                tile.layer?.add(resize, forKey: "favorites.resize")
            } else if style == .crossfade { OrbitTransitions.crossfade(tile.layer) }
        }
        animateNextLayout = false
    }

    func insertionIndex(at point: NSPoint) -> Int {
        guard !items.isEmpty else { return 0 }
        let columns = geometry.favoriteColumns
        let gap = OrbitTokens.Metrics.Sidebar.favoriteGap
        let first = geometry.favoriteTileFrame(index: 0)
        let row = max(0, Int(floor(point.y / (first.height + gap))))
        let column = min(columns, max(0, Int(floor((point.x + first.width / 2) / (first.width + gap)))))
        return min(items.count, row * columns + column)
    }
    func showDropPreview(_ payload: FavoritesDragPayload, at point: NSPoint) {
        preview = (payload, insertionIndex(at: point))
        animateNextLayout = true
        needsLayout = true
    }
    func clearDropPreview() {
        preview = nil
        animateNextLayout = true
        needsLayout = true
    }
    var hasDropPreview: Bool { preview != nil }
    var previewItemCount: Int {
        guard let preview else { return items.count }
        return items.filter { !preview.payload.nodes.contains(.tab($0.tab.id)) }.count + preview.payload.nodes.count
    }

    private func beginDrag(tile: FavoriteTileView, event: NSEvent) {
        guard commandsEnabled, let profileID = dropTarget.profileID else { return }
        onDragWillBegin?()
        let payload = FavoritesDragPayload(profileID: profileID, nodes: [.tab(tile.item.tab.id)])
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let writer = NSPasteboardItem()
        writer.setData(data, forType: FavoritesDragPayload.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(size: tile.bounds.size)
        if let bitmap = tile.bitmapImageRepForCachingDisplay(in: tile.bounds) {
            tile.cacheDisplay(in: tile.bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        item.setDraggingFrame(tile.frame, contents: image)
        favoritesDragPayload = payload
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        favoritesDragPayload = nil
        dropTarget.end()
    }
    private func payload(from sender: any NSDraggingInfo) -> FavoritesDragPayload? {
        guard commandsEnabled, let source = sender.draggingSource as? any FavoritesLocalDragSource,
              let local = source.favoritesDragPayload,
              let data = sender.draggingPasteboard.data(forType: FavoritesDragPayload.pasteboardType), data.count < 64_000,
              let decoded = try? JSONDecoder().decode(FavoritesDragPayload.self, from: data), decoded == local else { return nil }
        return decoded
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard commandsEnabled, let payload = payload(from: sender),
              dropTarget.update(payload, at: convert(sender.draggingLocation, from: nil)) else { dropTarget.end(); return [] }
        return .move
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropTarget.end() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { commandsEnabled && payload(from: sender) != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard commandsEnabled, let payload = payload(from: sender) else { dropTarget.end(); return false }
        return dropTarget.perform(payload, at: convert(sender.draggingLocation, from: nil))
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { dropTarget.end() }
}
