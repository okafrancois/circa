import AppKit
import BrowserCore

private typealias Metrics = OrbitTokens.Metrics.Sidebar

/// The sidebar side of the list: selection, commands and drag payloads (`BrowserSidebarView`).
@MainActor
protocol SidebarListHost: AnyObject {
    /// A click on a row; modifiers distinguish activation, ⌘-click and ⇧-click.
    func list(_ list: SidebarListView, activate node: BrowserOrganizationNode, modifiers: NSEvent.ModifierFlags)
    func list(_ list: SidebarListView, close tab: TabID)
    func list(_ list: SidebarListView, resetToPinnedURL tab: TabID)
    func list(_ list: SidebarListView, toggleAudio tab: TabID)
    func list(_ list: SidebarListView, rename node: BrowserOrganizationNode, to title: String)
    func listRenameDidEnd(_ list: SidebarListView)
    func list(_ list: SidebarListView, contextMenuFor node: BrowserOrganizationNode, event: NSEvent, in view: NSView)
    func list(_ list: SidebarListView, dragPayloadFor node: BrowserOrganizationNode, grabOffsetX: CGFloat) -> SidebarDragPayload?
    func list(_ list: SidebarListView, dragDidChange payload: SidebarDragPayload?)
    func list(_ list: SidebarListView, dragLeftWindow payload: SidebarDragPayload)
    func list(_ list: SidebarListView, tearOff payload: SidebarDragPayload, at point: NSPoint) -> Bool
    /// The row Return renames: the anchor of the selection or the selected tab.
    func listCurrentNode(_ list: SidebarListView) -> BrowserOrganizationNode?
    func listCancelSelection(_ list: SidebarListView)
    func listNewTab(_ list: SidebarListView)
    func listClearToday(_ list: SidebarListView)
    /// ⌘Z/⇧⌘Z with the list focused: organization first (`SidebarUndoRouter`).
    func list(_ list: SidebarListView, undo redo: Bool, sender: Any?)
    func list(_ list: SidebarListView, validateUndo item: any NSValidatedUserInterfaceItem) -> Bool
}

extension SidebarListHost {
    func list(_ list: SidebarListView, tearOff payload: SidebarDragPayload, at point: NSPoint) -> Bool { false }
    func list(_ list: SidebarListView, toggleAudio tab: TabID) {}
    func list(_ list: SidebarListView, dragLeftWindow payload: SidebarDragPayload) {}
}

/// Pinned and Today rows of one Space page, the separator, New Tab and Today's Clear control.
/// It is the scroll document of the page.
/// - Identity: rows are keyed by `BrowserOrganizationNode` (logical tab or folder), so updates
///   reuse views, keep hover and press state, and never reload the list.
/// - Virtualisation: only rows near the visible rect have views (a 500-row Space keeps a few
///   dozen); positions come from the pure `SidebarListLayout`.
/// - Motion: slots follow Orbit's finite NSOutlineView update timing; entering rows fade in, leaving rows fade
///   out — folder children slide out of and back into their folder. "Reduce motion" cross-fades;
///   hidden windows and live resize jump.
/// - Responder: as first responder (after a click, a drag or a rename) it handles Return
///   (rename), Escape (clear the multi-selection) and ⌘Z/⇧⌘Z for organization commands; a
///   focused text field keeps its own undo.
@MainActor
final class SidebarListView: SidebarFlippedView, SidebarRowEventHandler, NSDraggingSource, SidebarDropTarget,
                             NSUserInterfaceValidations {
    weak var host: (any SidebarListHost)?
    let separator = SidebarSeparatorView()
    let newTabRow = SidebarNewTabRow()
    let clearButton = SidebarClearButton()
    private let gapPlaceholder = OrbitSurfaceBackgroundView(cornerRadius: OrbitTokens.Radius.tabRow)
    let animator = SidebarListAnimator()

    private(set) var content = SidebarListContent.empty
    private var hasRendered = false
    private(set) var displayedLayout = SidebarListLayout()
    /// Layout without drag gap (hidden rows excluded), the reference of drop resolution.
    private(set) var dropLayout = SidebarListLayout()
    private var indicesByNode: [BrowserOrganizationNode: Int] = [:]
    private var entriesByNode: [BrowserOrganizationNode: SidebarListEntry] = [:]
    private var rowViews: [BrowserOrganizationNode: SidebarListRow] = [:]
    private var leavingRows: [ObjectIdentifier: (row: SidebarListRow, node: BrowserOrganizationNode)] = [:]
    private var tabPool: [SidebarTabRow] = []
    private var folderPool: [SidebarFolderRow] = []
    private var splitPool: [SidebarSplitRow] = []
    private struct PinnedMotion {
        let segment: OrbitTimedSegment
        let expanded: SidebarListLayout
    }
    private var pinnedMotion: PinnedMotion?
    var onPinnedExpansionChange: ((CGFloat) -> Void)?
    var pinnedExpansion: CGFloat {
        pinnedMotion.map { CGFloat($0.segment.value(at: animator.now)) } ?? (content.isPinnedSectionCollapsed ? 0 : 1)
    }
    private var enteringNodes: Set<BrowserOrganizationNode> = []
    var isStandalone = false
    var spaceID: SpaceID?
    var spaceTitleCenterY: CGFloat = 0 { didSet { if spaceTitleCenterY != oldValue { relayout(animated: false) } } }
    var accent = OrbitTokens.ThemeAccent.defaultSpace {
        didSet {
            guard accent != oldValue else { return }
            newTabRow.accent = accent
            clearButton.accent = accent
            for row in rowViews.values { row.accent = accent }
            for entry in leavingRows.values { entry.row.accent = accent }
            for row in tabPool { row.accent = accent }
            for row in folderPool { row.accent = accent }
            for row in splitPool { row.accent = accent }
        }
    }
    private(set) var commandsEnabled = true
    /// Tests drive motion with `animator.advance(to:)` in hidden windows.
    var forcesAnimation = false
    var onLayoutChange: (() -> Void)?
    var onFolderHover: ((SidebarListRow, Bool) -> Void)?
    var onPreviewInvalidated: ((SidebarListRow) -> Void)?

    var prepareDesktopPreview: ((SidebarDragPayload) -> Void)?
    var desktopPreview: NSImage?
    var desktopPreviewBackground = NSColor.windowBackgroundColor
    private var desktopPreviewStart: TimeInterval?
    private var desktopPreviewTimer: Timer?
    private weak var desktopDragSession: NSDraggingSession?
    private var desktopRowImage: NSImage?
    private var desktopTileImage: NSImage?
    private var desktopDragPoint: NSPoint = .zero
    private var dragCancelled = false
    private var dragCancelMonitor: Any?
    private var sourceHidden: Set<BrowserOrganizationNode> = []
    private var hoverHidden: Set<BrowserOrganizationNode> = []
    private var gap: SidebarDropGap?
    private var folderTarget: FolderID?
    private struct PendingCommit {
        let hidden: Set<BrowserOrganizationNode>
        let gap: SidebarDropGap?
        let signature: [SidebarListStructure]
        let timer: any OrbitCancellable
    }
    private var pendingCommit: PendingCommit?
    private var localDrag: SidebarDragPayload?
    private var localDropWasNoOp = false
    private let insertionLine = SidebarInsertionLineView()
    private var isCrossWindowHover = false
    private var sourceOutsideSidebar = false
    private var announcedWindowDeparture = false
    private var dragGhostNodes: Set<BrowserOrganizationNode> = []
    private var dragSelectionToRestore: TabID?

    // Pointer and rename state.
    private struct PointerDown {
        let node: BrowserOrganizationNode
        let location: NSPoint
        let modifiers: NSEvent.ModifierFlags
    }
    private var pointerDown: PointerDown?
    private var isDragging = false
    private(set) var renamingNode: BrowserOrganizationNode?
    /// Reveal and rename requests waiting for their row: commands that expand folders or create
    /// one publish asynchronously, and the document must have grown before it can scroll.
    private struct PendingIntent {
        let node: BrowserOrganizationNode
        let since: TimeInterval
    }
    private var pendingReveal: PendingIntent?
    private var pendingRename: PendingIntent?
    private var renameTimer: (any OrbitCancellable)?
    private var renameGeneration: UInt64 = 0
    static let creationRenameDelay: TimeInterval = 0.25
    var scheduleRename: (TimeInterval, @escaping @MainActor () -> Void) -> any OrbitCancellable = {
        OrbitRunLoopTimer(after: $0, $1)
    }
    private var contextTargets: Set<BrowserOrganizationNode> = []
    private var isTodayHovered = false { didSet { if isTodayHovered != oldValue { refreshClear() } } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gapPlaceholder.fillColor = OrbitTokens.Color.State.dragPlaceholder
        gapPlaceholder.isHidden = true
        // A newly created page starts empty, before its first content/layout pass.
        separator.isHidden = true
        clearButton.target = self
        clearButton.action = #selector(clearToday(_:))
        newTabRow.target = self
        newTabRow.action = #selector(newTab(_:))
        for view in [gapPlaceholder, separator, newTabRow, clearButton] as [NSView] { addSubview(view) }
        addSubview(insertionLine)
        insertionLine.isHidden = true
        animator.onFrame = { [weak self] time in self?.animationFrame(at: time) }
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Content

    /// Applies new content by identity. Unchanged content costs one comparison.
    func apply(_ content: SidebarListContent, animated: Bool) {
        guard content != self.content || !hasRendered else { return }
        // The first content of a page appears in place: nothing to move from.
        let animated = animated && hasRendered
        hasRendered = true
        let previous = self.content
        self.content = content
        indicesByNode = Dictionary(uniqueKeysWithValues: content.entries.enumerated().map { ($0.element.node, $0.offset) })
        entriesByNode = Dictionary(content.entries.map { ($0.node, $0) }, uniquingKeysWith: { first, _ in first })
        if let pending = pendingCommit, pending.signature != content.structure {
            endPendingCommit(relayout: false)
        }
        // Nodes gone from the content stop being hidden or targeted.
        sourceHidden.formIntersection(entriesByNode.keys)
        hoverHidden.formIntersection(entriesByNode.keys)
        if let renamingNode, entriesByNode[renamingNode] == nil { rowViews[renamingNode]?.cancelRename() }
        if let folderTarget, entriesByNode[.folder(folderTarget)] == nil { self.folderTarget = nil }
        if previous.structure == content.structure,
           previous.isPinnedSectionCollapsed == content.isPinnedSectionCollapsed,
           previous.folderStates == content.folderStates {
            let previousByNode = Dictionary(uniqueKeysWithValues: previous.entries.map { ($0.node, $0) })
            for entry in content.entries where previousByNode[entry.node] != entry {
                if let row = rowViews[entry.node] { configure(row, with: entry) }
            }
        } else {
            relayout(animated: animated, previousEntries: previous)
        }
        flushPendingIntents()
    }

    /// Content-only edits preserve row geometry, pending drag state and running motion.
    func applyMetadata(_ entries: [SidebarListEntry]) {
        for entry in entries {
            guard let index = indicesByNode[entry.node], entriesByNode[entry.node] != entry else { continue }
            content.entries[index] = entry
            entriesByNode[entry.node] = entry
            if let row = rowViews[entry.node] { configure(row, with: entry) }
        }
    }

    func setCommandsEnabled(_ enabled: Bool) {
        commandsEnabled = enabled
        newTabRow.isEnabled = enabled
        clearButton.isEnabled = enabled
        for row in rowViews.values { row.commandsEnabled = enabled }
        if !enabled { cancelRename() }
    }

    /// Rows highlighted while their context menu is open.
    func setContextTargets(_ nodes: Set<BrowserOrganizationNode>) {
        contextTargets = nodes
        for (node, row) in rowViews { row.isContextTarget = nodes.contains(node) || dragGhostNodes.contains(node) }
    }

    // MARK: Layout and motion

    private var hiddenNodes: Set<BrowserOrganizationNode> {
        sourceHidden.union(hoverHidden).union(pendingCommit?.hidden ?? [])
    }

    private var effectiveGap: SidebarDropGap? {
        if isCrossWindowHover, let gap, gap.index >= dropLayout.rows(in: gap.section).count { return nil }
        return gap ?? pendingCommit?.gap
    }

    private func resolveLayouts() {
        let hidden = hiddenNodes
        let width = bounds.width
        dropLayout = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: spaceTitleCenterY,
                                               width: width, hidden: hidden)
        displayedLayout = effectiveGap == nil ? dropLayout
            : SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: spaceTitleCenterY,
                                        width: width, hidden: hidden, gap: effectiveGap)
    }

    private func motionStyle(animated: Bool) -> OrbitMotionStyle {
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true && !inLiveResize
        return OrbitMotionStyle.resolve(animated: animated, canAnimate: forcesAnimation || visible,
                                      reducedMotion: OrbitMotionPreferences.prefersReducedMotion)
    }

    private func relayout(animated: Bool,
                          previousEntries: SidebarListContent? = nil) {
        let time = animator.now
        let old = displayedLayout
        resolveLayouts()
        let style = motionStyle(animated: animated)
        let previous = previousEntries ?? content
        let previousByNode = Dictionary(previous.entries.map { ($0.node, $0) }, uniquingKeysWith: { first, _ in first })
        let newNodes = Set(displayedLayout.rows.map(\.node))
        let toggledPinned = previous.isPinnedSectionCollapsed != content.isPinnedSectionCollapsed
        let timing = toggledPinned
            ? (content.isPinnedSectionCollapsed ? SidebarSpaceDisclosure.collapseTiming : SidebarSpaceDisclosure.expandTiming)
            : OrbitAnimationTiming.tabList
        if toggledPinned, style == .spring {
            let from = pinnedMotion.map { $0.segment.value(at: time) } ?? (previous.isPinnedSectionCollapsed ? 0.0 : 1.0)
            let expanded = content.isPinnedSectionCollapsed ? (pinnedMotion?.expanded ?? old) : displayedLayout
            pinnedMotion = PinnedMotion(segment: OrbitTimedSegment(from: from, target: content.isPinnedSectionCollapsed ? 0 : 1,
                                                                   start: time, timing: timing), expanded: expanded)
            // A rapid reversal recovers the same native rows before the pool can rebind them.
            for (key, leaving) in leavingRows where newNodes.contains(leaving.node) {
                rowViews[leaving.node] = leaving.row
                leaving.row.commandsEnabled = commandsEnabled
                leavingRows[key] = nil
            }
        } else if pinnedMotion != nil {
            finishPinnedMotion()
        }
        if style == .spring {
            for placement in displayedLayout.rows {
                let slot = SidebarListSlot.node(placement.node)
                if let current = animator.value(of: slot, at: time) ?? old.centerY(of: slot) {
                    animator.move(slot, from: current, to: placement.centerY, timing: timing, at: time)
                } else if toggledPinned, placement.section == .pinned {
                    // Section rows are revealed by their row-height clips, without a content reload.
                } else if let origin = enteringOrigin(of: placement.node, old: old, time: time, previous: previousByNode) {
                    // A folder child slides out of its folder.
                    animator.move(slot, from: origin, to: placement.centerY, at: time)
                    enteringNodes.insert(placement.node)
                } else if !liftedNodes.contains(placement.node) {
                    // Rows reappearing after a drop land where the drag image settled: no fade.
                    enteringNodes.insert(placement.node)
                }
            }
            for slot in [SidebarListSlot.separator, .newTab] {
                let current = animator.value(of: slot, at: time) ?? old.centerY(of: slot) ?? 0
                animator.move(slot, from: current, to: displayedLayout.centerY(of: slot) ?? 0, timing: timing, at: time)
            }
        } else {
            animator.stopAll()
            enteringNodes.removeAll()
            if style == .crossfade { OrbitTransitions.crossfade(layer) }
        }
        // Rows that left the layout: lifted by a drag (vanish), or removed (fade out).
        let hidden = hiddenNodes
        for row in old.rows where !newNodes.contains(row.node) {
            guard let view = rowViews.removeValue(forKey: row.node) else { continue }
            if toggledPinned, pinnedMotion != nil, row.section == .pinned {
                view.commandsEnabled = false
                leavingRows[ObjectIdentifier(view)] = (view, row.node)
            } else if style == .spring, !hidden.contains(row.node) {
                startLeaving(view, node: row.node, old: old, time: time)
            } else {
                recycle(view)
            }
        }
        if style != .spring {
            for (_, leaving) in leavingRows { recycle(leaving.row) }
            leavingRows.removeAll()
        }
        liftedNodes.formIntersection(hidden)
        refreshGapPlaceholder(animated: style == .spring)
        materialize(at: time)
        enteringNodes.removeAll()
        positionViews(at: time)
        onLayoutChange?()
        if style == .spring {
            if !animator.isAnimating { finishPinnedMotion() }
            animator.run(in: self)
        }
    }

    /// A row entering under a folder that was collapsed starts at that folder's position.
    private func enteringOrigin(of node: BrowserOrganizationNode, old: SidebarListLayout, time: CFTimeInterval,
                                previous: [BrowserOrganizationNode: SidebarListEntry]) -> CGFloat? {
        guard previous[node] == nil, let entry = entriesByNode[node] else { return nil }
        for ancestor in entry.ancestors.reversed() {
            let slot = SidebarListSlot.node(.folder(ancestor))
            if let y = animator.value(of: slot, at: time) ?? old.centerY(of: slot) { return y }
        }
        return nil
    }

    /// Rows hidden by a drag; when they reappear they do not fade in.
    private var liftedNodes: Set<BrowserOrganizationNode> = []

    private func startLeaving(_ row: SidebarListRow, node: BrowserOrganizationNode, old: SidebarListLayout,
                              time: CFTimeInterval) {
        let slot = SidebarListSlot.node(node)
        let current = animator.value(of: slot, at: time) ?? old.centerY(of: slot) ?? row.frame.midY
        // Folder children slide back into their folder when it collapses.
        var target = current
        if let entry = row.leavingEntry {
            for ancestor in entry.ancestors.reversed() {
                if let y = displayedLayout.centerY(of: .node(.folder(ancestor))) { target = y; break }
            }
        }
        animator.stop(slot)
        animator.move(slot, from: current, to: target, at: time)
        leavingRows[ObjectIdentifier(row)] = (row, node)
        row.commandsEnabled = false
        Self.fade(row, to: 0)
        _ = OrbitRunLoopTimer(after: OrbitTokens.Motion.rowCloseFadeDuration) { [weak self, weak row] in
            guard let self, let row, leavingRows.removeValue(forKey: ObjectIdentifier(row)) != nil else { return }
            if rowViews[node] == nil, displayedLayout.centerY(of: slot) == nil { animator.stop(slot) }
            recycle(row)
        }
    }

    /// Orbit requests effectFade in its 120 ms NSOutlineView update group.
    private static func fade(_ row: SidebarListRow, from start: CGFloat? = nil, to end: CGFloat) {
        let from = start ?? CGFloat(row.layer?.presentation()?.opacity ?? Float(row.alphaValue))
        row.alphaValue = end
        guard let layer = row.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.duration = OrbitAnimationTiming.tabList.duration
        animation.timingFunction = OrbitAnimationTiming.tabList.mediaTimingFunction
        animation.fromValue = from
        animation.toValue = end
        layer.add(animation, forKey: "orbit.rowFade")
    }

    private func animationFrame(at time: CFTimeInterval) {
        if let motion = pinnedMotion, motion.segment.isSettled(at: time) { finishPinnedMotion() }
        materialize(at: time)
        positionViews(at: time)
    }

    private func finishPinnedMotion() {
        pinnedMotion = nil
        for row in rowViews.values { restorePinnedRow(row) }
        for (key, leaving) in leavingRows where leaving.row.leavingEntry?.section == .pinned {
            recycle(leaving.row)
            leavingRows[key] = nil
        }
        onPinnedExpansionChange?(content.isPinnedSectionCollapsed ? 0 : 1)
    }

    private func restorePinnedRow(_ row: SidebarListRow) {
        row.layer?.mask = nil
        row.titleLabel.alphaValue = 1
        row.alphaValue = 1
    }

    /// Displayed centre of a slot now: its spring, or its resting layout position.
    func displayedCenterY(of slot: SidebarListSlot, at time: CFTimeInterval? = nil) -> CGFloat? {
        animator.value(of: slot, at: time ?? animator.now) ?? displayedLayout.centerY(of: slot)
    }

    private func rowFrame(centerY: CGFloat) -> NSRect {
        NSRect(x: Metrics.paddingX, y: centerY - Metrics.rowHeight / 2,
               width: max(0, bounds.width - 2 * Metrics.paddingX), height: Metrics.rowHeight)
    }

    /// Creates views for rows near the visible rect and recycles the others.
    private func materialize(at time: CFTimeInterval) {
        let overscan = CGFloat(Metrics.virtualizationOverscanRows) * Metrics.rowPitch
        let clipped = bounds.intersection(visibleRect)
        let visible = clipped.isEmpty ? bounds : clipped
        let band = visible.insetBy(dx: 0, dy: -overscan)
        let half = Metrics.rowHeight / 2
        var placements: [SidebarListLayout.Placement]
        if animator.isAnimating {
            // Moving rows can cross the viewport out of resolved order.
            placements = displayedLayout.rows.filter { placement in
                let y = animator.value(of: .node(placement.node), at: time) ?? placement.centerY
                return y + half >= band.minY && y - half <= band.maxY
            }
        } else {
            placements = Array(displayedLayout.rows(from: band.minY - half, through: band.maxY + half))
        }
        if let renamingNode, !placements.contains(where: { $0.node == renamingNode }),
           let placement = displayedLayout.rows.first(where: { $0.node == renamingNode }) {
            placements.append(placement)
        }
        let needed = Set(placements.map(\.node))
        for (node, row) in rowViews where !needed.contains(node) {
            rowViews[node] = nil
            recycle(row)
        }
        for placement in placements {
            guard let entry = entriesByNode[placement.node] else { continue }
            if let row = rowViews[placement.node] {
                configure(row, with: entry)
                continue
            }
            let row = dequeue(for: entry)
            rowViews[placement.node] = row
            if enteringNodes.remove(placement.node) != nil, motionStyle(animated: true) == .spring {
                Self.fade(row, from: 0, to: 1)
            }
        }
    }

    private func positionViews(at time: CFTimeInterval) {
        for (node, row) in rowViews {
            guard let y = animator.value(of: .node(node), at: time) ?? displayedLayout.centerY(of: .node(node)) else { continue }
            let frame = rowFrame(centerY: y)
            if row.frame != frame { row.frame = frame }
        }
        for (_, leaving) in leavingRows {
            let y = animator.value(of: .node(leaving.node), at: time) ?? leaving.row.frame.midY
            leaving.row.frame = rowFrame(centerY: y)
        }
        if let motion = pinnedMotion {
            let expansion = CGFloat(motion.segment.value(at: time))
            let collapsedY = spaceTitleCenterY + Metrics.newTabCenterFromSpaceTitleWhenEmpty
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for placement in motion.expanded.rows where placement.section == .pinned {
                guard let row = rowViews[placement.node] ?? leavingRows.values.first(where: { $0.node == placement.node })?.row else { continue }
                let y = collapsedY + (placement.centerY - collapsedY) * expansion
                row.frame = rowFrame(centerY: y)
                row.wantsLayer = true
                let mask = row.layer?.mask ?? CALayer()
                mask.backgroundColor = NSColor.black.cgColor
                mask.frame = NSRect(x: 0, y: (1 - expansion) * Metrics.rowHeight / 2,
                                    width: row.bounds.width, height: Metrics.rowHeight * expansion)
                row.layer?.mask = mask
                // Removed text leaves immediately; its icon follows the finite row update.
                row.titleLabel.alphaValue = content.isPinnedSectionCollapsed ? 0 : 1
                row.alphaValue = expansion
            }
            CATransaction.commit()
            onPinnedExpansionChange?(expansion)
        }
        let separatorY = displayedCenterY(of: .separator, at: time) ?? 0
        let newTabY = displayedCenterY(of: .newTab, at: time) ?? 0
        newTabRow.frame = rowFrame(centerY: newTabY)
        let scale = window?.backingScaleFactor ?? 2
        let line = 1 / scale
        let lineY = ((separatorY - line / 2) * scale).rounded() / scale
        let clearWidth = clearButton.preferredWidth
        let textMaxX = bounds.width - Metrics.clearTextRightInset
        clearButton.frame = NSRect(x: textMaxX + Metrics.clearHoverPadding - clearWidth,
                                   y: (separatorY - Metrics.clearButtonHeight / 2).rounded(),
                                   width: clearWidth, height: Metrics.clearButtonHeight)
        let textMinX = clearButton.frame.minX + Metrics.clearHoverPadding
        let lineEnd = clearButton.isRevealed ? textMinX - Metrics.clearSeparatorGap : bounds.width - Metrics.separatorInsetX
        separator.frame = NSRect(x: Metrics.separatorInsetX, y: lineY, width: max(0, lineEnd - Metrics.separatorInsetX), height: line)
        separator.isHidden = isStandalone || !displayedLayout.isSeparatorVisible || pinnedMotion != nil
    }

    override func layout() {
        super.layout()
        // Pure arithmetic, linear in the rows: the width only affects the placeholder.
        resolveLayouts()
        refreshGapPlaceholder(animated: false)
        materialize(at: animator.now)
        positionViews(at: animator.now)
        flushPendingIntents()
    }

    var documentHeight: CGFloat { displayedLayout.documentHeight }

    private func refreshGapPlaceholder(animated: Bool) {
        insertionLine.isHidden = true
        if isCrossWindowHover, effectiveGap == nil, let gap {
            let layout = SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: spaceTitleCenterY,
                width: bounds.width, hidden: hiddenNodes, gap: gap)
            if let frame = layout.gapFrame {
                insertionLine.frame = NSRect(x: frame.minX + 7, y: frame.minY - Metrics.rowSpacing / 2 - 3,
                                             width: max(0, frame.width - 7), height: 6)
                insertionLine.isHidden = false
            }
        }
        if let frame = displayedLayout.gapFrame {
            gapPlaceholder.frame = frame
            if gapPlaceholder.isHidden {
                gapPlaceholder.isHidden = false
                gapPlaceholder.alphaValue = animated ? 0 : 1
                if animated {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = OrbitAnimationTiming.tabList.duration
                        context.timingFunction = OrbitAnimationTiming.tabList.mediaTimingFunction
                        gapPlaceholder.animator().alphaValue = 1
                    }
                }
            }
        } else {
            gapPlaceholder.isHidden = true
        }
        for (node, row) in rowViews { row.isDropTarget = node.folderID != nil && node.folderID == folderTarget }
    }

    // MARK: Row views

    private func dequeue(for entry: SidebarListEntry) -> SidebarListRow {
        let row: SidebarListRow
        switch entry.content {
        case let .split(item, _):
            if let reused = splitPool.popLast() {
                reused.updateSplit(item, node: entry.node, depth: entry.depth)
                row = reused
            } else {
                let created = SidebarSplitRow(item: item, node: entry.node, depth: entry.depth)
                addSubview(created, positioned: .below, relativeTo: separator)
                row = created
            }
        case let .tab(item):
            if let reused = tabPool.popLast() {
                reused.update(item, depth: entry.depth)
                row = reused
            } else {
                let created = SidebarTabRow(item: item, depth: entry.depth)
                addSubview(created, positioned: .below, relativeTo: separator)
                row = created
            }
        case let .folder(item):
            if let reused = folderPool.popLast() {
                reused.update(item, depth: entry.depth)
                row = reused
            } else {
                let created = SidebarFolderRow(item: item, depth: entry.depth)
                addSubview(created, positioned: .below, relativeTo: separator)
                row = created
            }
        }
        row.accent = accent
        row.events = self
        row.onFolderHover = { [weak self] row, inside in self?.onFolderHover?(row, inside) }
        row.onPreviewInvalidated = { [weak self] row in self?.onPreviewInvalidated?(row) }
        row.leavingEntry = entry
        row.commandsEnabled = commandsEnabled
        row.isContextTarget = contextTargets.contains(entry.node) || dragGhostNodes.contains(entry.node)
        row.isDropTarget = entry.node.folderID != nil && entry.node.folderID == folderTarget
        row.alphaValue = 1
        row.isHidden = false
        return row
    }

    private func configure(_ row: SidebarListRow, with entry: SidebarListEntry) {
        BrowserPerformance.count(.rowsConfigured)
        row.isContextTarget = contextTargets.contains(entry.node) || dragGhostNodes.contains(entry.node)
        row.leavingEntry = entry
        switch (row, entry.content) {
        case let (row as SidebarSplitRow, .split(item, _)):
            if row.item != item || row.node != entry.node || row.depth != entry.depth || row.splitAppearanceChanged {
                row.updateSplit(item, node: entry.node, depth: entry.depth)
            }
        case let (row as SidebarTabRow, .tab(item)):
            if row.item != item || row.depth != entry.depth { row.update(item, depth: entry.depth) }
        case let (row as SidebarFolderRow, .folder(item)):
            if row.item != item || row.depth != entry.depth { row.update(item, depth: entry.depth) }
        default:
            break
        }
    }

    private func recycle(_ row: SidebarListRow) {
        row.layer?.removeAnimation(forKey: "orbit.rowFade")
        restorePinnedRow(row)
        row.cancelRename()
        row.resetForReuse()
        row.isHidden = true
        row.alphaValue = 1
        row.isPressed = false
        row.isContextTarget = false
        row.isDropTarget = false
        row.events = nil
        switch row {
        case let row as SidebarSplitRow: splitPool.append(row)
        case let row as SidebarTabRow: tabPool.append(row)
        case let row as SidebarFolderRow: folderPool.append(row)
        default: row.removeFromSuperview()
        }
    }

    // MARK: Lifetime

    /// A page removed (Space switch, window closing) stops its springs and display link at once,
    /// and lands its rows on their resting positions.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        animator.stopAll()
        finishPinnedMotion()
        for (_, leaving) in leavingRows { recycle(leaving.row) }
        leavingRows.removeAll()
        positionViews(at: animator.now)
    }

    // MARK: Scrolling

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func clipBoundsDidChange(_ notification: Notification) {
        materialize(at: animator.now)
        positionViews(at: animator.now)
    }

    /// Scrolls `node`'s row into view (Reveal Tab in Sidebar, rename), now or once a later
    /// publication shows it (e.g. after its folders were expanded).
    func reveal(_ node: BrowserOrganizationNode) {
        pendingReveal = PendingIntent(node: node, since: ProcessInfo.processInfo.systemUptime)
        flushPendingIntents()
    }

    var isRevealPending: Bool { pendingReveal != nil }

    private func flushPendingIntents() {
        let now = ProcessInfo.processInfo.systemUptime
        let lifetime = OrbitTokens.Motion.pendingRowIntentLifetime
        if let intent = pendingReveal, now - intent.since > lifetime { pendingReveal = nil }
        if let intent = pendingRename, now - intent.since > lifetime { pendingRename = nil }
        if let intent = pendingReveal, let y = displayedLayout.centerY(of: .node(intent.node)) {
            let target = rowFrame(centerY: y).insetBy(dx: 0, dy: -Metrics.rowSpacing)
            // The page sizes the document after each publication: scroll once it holds the row.
            if target.maxY <= bounds.maxY + 0.5 {
                pendingReveal = nil
                scrollToVisible(target)
                materialize(at: animator.now)
                positionViews(at: animator.now)
            }
        }
        guard let intent = pendingRename, pendingReveal?.node != intent.node, commandsEnabled, window != nil,
              let entry = entriesByNode[intent.node] else { return }
        if let renamingNode, renamingNode != intent.node { rowViews[renamingNode]?.commitRename() }
        renamingNode = intent.node
        materialize(at: animator.now)
        positionViews(at: animator.now)
        guard let row = rowViews[intent.node] else {
            renamingNode = nil
            return
        }
        pendingRename = nil
        if row.isRenaming { return }
        let font = entry.folder != nil ? OrbitTokens.Typography.sidebarFolderTitle : OrbitTokens.Typography.sidebarRenameField
        row.beginRename(text: entry.title, font: font)
        if !row.isRenaming { renamingNode = nil }
    }

    // MARK: Today hover and Clear (S-PIN@2s)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isTodayHovered = point.y >= displayedLayout.separatorCenterY - Metrics.todayHoverSlop
    }

    override func mouseExited(with event: NSEvent) { isTodayHovered = false }

    private func refreshClear() {
        clearButton.setRevealed(isTodayHovered && content.hasTodayTabs && commandsEnabled)
        positionViews(at: animator.now)
    }

    @objc private func clearToday(_ sender: Any?) {
        guard commandsEnabled, content.hasTodayTabs else { return }
        host?.listClearToday(self)
    }

    @objc private func newTab(_ sender: Any?) {
        guard commandsEnabled else { return }
        host?.listNewTab(self)
    }

    // MARK: Row events

    func rowMouseDown(_ row: SidebarListRow, with event: NSEvent) {
        if renameTimer != nil { cancelRename() }
        window?.makeFirstResponder(self)
        let modifiers = event.modifierFlags.intersection([.command, .shift])
        if event.clickCount == 2, modifiers.isEmpty {
            pointerDown = nil
            if row.node.folderID != nil { host?.list(self, activate: row.node, modifiers: []) }
            beginRename(row.node)
            return
        }
        pointerDown = PointerDown(node: row.node, location: event.locationInWindow, modifiers: modifiers)
        isDragging = false
        if modifiers.isEmpty { row.isPressed = true }
    }

    func rowMouseDragged(_ row: SidebarListRow, with event: NSEvent) {
        guard let down = pointerDown, down.node == row.node, !isDragging, renamingNode != row.node else { return }
        let dx = event.locationInWindow.x - down.location.x, dy = event.locationInWindow.y - down.location.y
        if dx * dx + dy * dy >= 16 {
            row.isPressed = false
            beginDrag(from: row, event: event, grabPoint: row.convert(down.location, from: nil))
            return
        }
        row.isPressed = down.modifiers.isEmpty && row.bounds.contains(row.convert(event.locationInWindow, from: nil))
    }

    func rowMouseUp(_ row: SidebarListRow, with event: NSEvent) {
        row.isPressed = false
        guard let down = pointerDown, down.node == row.node else { return }
        pointerDown = nil
        guard !isDragging, commandsEnabled, row.bounds.contains(row.convert(event.locationInWindow, from: nil)) else { return }
        host?.list(self, activate: row.node, modifiers: down.modifiers)
    }

    func rowRightMouseDown(_ row: SidebarListRow, with event: NSEvent) {
        window?.makeFirstResponder(self)
        host?.list(self, contextMenuFor: row.node, event: event, in: row)
    }

    func rowPerformPress(_ row: SidebarListRow) -> Bool {
        guard commandsEnabled else { return false }
        host?.list(self, activate: row.node, modifiers: [])
        return true
    }

    func rowClose(_ row: SidebarTabRow) {
        window?.makeFirstResponder(self)
        host?.list(self, close: row.item.id)
    }

    func rowResetToPinnedURL(_ row: SidebarTabRow) {
        host?.list(self, resetToPinnedURL: row.item.id)
    }

    func rowToggleAudio(_ row: SidebarTabRow) { host?.list(self, toggleAudio: row.item.id) }


    /// Starts editing `node`'s title; deferred until its row exists (e.g. a folder just created).
    func beginRename(_ node: BrowserOrganizationNode, after delay: TimeInterval = 0) {
        guard commandsEnabled else { return }
        renameGeneration &+= 1
        renameTimer?.cancel(); renameTimer = nil
        if delay > 0 {
            let generation = renameGeneration
            renameTimer = scheduleRename(delay) { [weak self] in
                guard let self, self.renameGeneration == generation, self.entriesByNode[node] != nil else { return }
                self.beginRename(node)
            }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        pendingRename = PendingIntent(node: node, since: now)
        pendingReveal = PendingIntent(node: node, since: now)
        flushPendingIntents()
    }

    func cancelRename() {
        renameGeneration &+= 1
        renameTimer?.cancel(); renameTimer = nil
        pendingRename = nil
        if let renamingNode { rowViews[renamingNode]?.cancelRename() }
    }

    var renameField: NSTextField? { renamingNode.flatMap { rowViews[$0]?.renameField } }

    func rowDidFinishRename(_ row: SidebarListRow, title: String?, initialTitle: String) {
        let node = row.node
        if renamingNode == node { renamingNode = nil }
        if let title, entriesByNode[node] != nil {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only an edited field commits: the title shown when editing began (possibly a web
            // title that has changed since, e.g. while the page loads) is never frozen as custom.
            if trimmed != initialTitle.trimmingCharacters(in: .whitespacesAndNewlines) {
                host?.list(self, rename: node, to: trimmed)
            }
        }
        host?.listRenameDidEnd(self)
    }

    // MARK: Keyboard and undo

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        switch (event.keyCode, modifiers.isEmpty) {
        case (36, true), (76, true):
            if let node = host?.listCurrentNode(self) { beginRename(node) } else { super.keyDown(with: event) }
        case (53, true):
            cancelRename()
            host?.listCancelSelection(self)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancelRename(); host?.listCancelSelection(self) }

    @objc func undo(_ sender: Any?) { if commandsEnabled { host?.list(self, undo: false, sender: sender) } }
    @objc func redo(_ sender: Any?) { if commandsEnabled { host?.list(self, undo: true, sender: sender) } }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)), #selector(redo(_:)): return commandsEnabled && host?.list(self, validateUndo: item) == true
        default: return true
        }
    }


    /// Nodes lifted by dragging `nodes`: themselves and the visible rows inside dragged folders.
    func liftedRows(for nodes: [BrowserOrganizationNode]) -> [SidebarListEntry] {
        let roots = Set(nodes)
        let folders = Set(nodes.compactMap(\.folderID))
        return content.entries.filter { roots.contains($0.node) || $0.ancestors.contains(where: folders.contains) }
    }

    private func beginDrag(from row: SidebarListRow, event: NSEvent, grabPoint: NSPoint) {
        guard commandsEnabled,
              let payload = host?.list(self, dragPayloadFor: row.node, grabOffsetX: grabPoint.x - row.iconX) else { return }
        isDragging = true
        dragCancelled = false
        dragCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dragCancelled = true }
            return event
        }
        pointerDown = nil
        cancelRename()
        let lifted = liftedRows(for: payload.nodes)
        let items: [NSDraggingItem] = lifted.compactMap { entry in
            guard let y = displayedCenterY(of: .node(entry.node)) else { return nil }
            let item = NSDraggingItem(pasteboardWriter: payload.pasteboardItem())
            let frame = rowFrame(centerY: y)
            let image = SidebarDragImage.render(entry, size: frame.size, accent: accent, appearance: effectiveAppearance)
            item.setDraggingFrame(frame, contents: image)
            return item
        }
        guard !items.isEmpty else {
            isDragging = false
            return
        }
        dragSelectionToRestore = lifted.first(where: { $0.tab?.selected == true })?.tab?.id
        localDrag = payload
        desktopPreview = nil
        prepareDesktopPreview?(payload)
        localDropWasNoOp = false
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        desktopDragSession = session
        desktopTileImage = lifted.first.map { SidebarTearOffPreview.tile(title: $0.title, icon: $0.tab?.favicon ?? $0.tab?.activity.favicon ?? OrbitGlyph.faviconPlaceholder) }
        desktopRowImage = lifted.first.map { SidebarDragImage.render($0, size: row.frame.size, accent: accent, appearance: effectiveAppearance) }
        sourceHidden = Set(lifted.map(\.node))
        liftedNodes.formUnion(sourceHidden)
        relayout(animated: true)
        host?.list(self, dragDidChange: payload)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let payload = localDrag, payload.nodes.count == 1, payload.nodes.first?.tabID != nil,
              let window else { return }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let outside = point.x < bounds.minX || point.x > bounds.maxX || !window.frame.contains(screenPoint)
        desktopDragPoint = screenPoint
        if !window.frame.contains(screenPoint), desktopPreviewStart == nil {
            desktopPreviewStart = CACurrentMediaTime()
            desktopPreviewTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDesktopDragImage() }
            }
            if let desktopPreviewTimer { RunLoop.main.add(desktopPreviewTimer, forMode: .common) }
        } else if window.frame.contains(screenPoint), desktopPreviewStart != nil {
            desktopPreviewTimer?.invalidate()
            desktopPreviewTimer = nil
            desktopPreviewStart = nil
        }
        updateDesktopDragImage()
        session.animatesToStartingPositionsOnCancelOrFail = window.frame.contains(screenPoint)
        if !window.frame.contains(screenPoint), !announcedWindowDeparture {
            announcedWindowDeparture = true
            host?.list(self, dragLeftWindow: payload)
        }
        guard sourceOutsideSidebar != outside else { return }
        sourceOutsideSidebar = outside
        sourceHidden = outside ? [] : Set(liftedRows(for: payload.nodes).map(\.node))
        // Keep the source row as a stationary ghost while the system drag crosses windows.
        dragGhostNodes = outside ? Set(payload.nodes) : []
        setContextTargets(contextTargets)
        relayout(animated: true)
    }

    private func updateDesktopDragImage() {
        guard let session = desktopDragSession, let start = desktopPreviewStart,
              let row = desktopRowImage, let tile = desktopTileImage, let document = desktopPreview, let window else { return }
        let image = SidebarTearOffPreview.render(document: document, row: row, tile: tile, elapsed: CACurrentMediaTime() - start, sourceWidth: window.frame.width, background: desktopPreviewBackground)
        let point = convert(window.convertPoint(fromScreen: desktopDragPoint), from: nil)
        session.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            item.setDraggingFrame(NSRect(x: point.x - 12, y: point.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
        }
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        desktopPreviewTimer?.invalidate()
        desktopPreviewTimer = nil
        desktopPreviewStart = nil
        desktopDragSession = nil
        desktopRowImage = nil
        desktopTileImage = nil
        desktopPreview = nil
        if let dragCancelMonitor { NSEvent.removeMonitor(dragCancelMonitor) }
        dragCancelMonitor = nil
        let tornOff: Bool
        if let payload = localDrag, let window,
           SidebarTearOffRelease.accepts(operation: operation, cancelled: dragCancelled,
               mouseIsDown: NSEvent.pressedMouseButtons & 1 != 0,
               sourceFrame: window.frame,
               otherWindowFrames: NSApp.windows.filter { $0 !== window && $0.isVisible && $0.level == .normal }.map(\.frame), point: screenPoint) {
            tornOff = host?.list(self, tearOff: payload, at: screenPoint) == true
        } else { tornOff = false }
        isDragging = false
        sourceOutsideSidebar = false
        announcedWindowDeparture = false
        if operation.isEmpty { dragGhostNodes = [] }
        setContextTargets(contextTargets)
        let payload = localDrag
        localDrag = nil
        let lifted = sourceHidden
        sourceHidden = []
        if operation.isEmpty, !tornOff, let tab = dragSelectionToRestore {
            host?.list(self, activate: .tab(tab), modifiers: [])
        }
        dragSelectionToRestore = nil
        if operation.isEmpty || localDropWasNoOp {
            liftedNodes.subtract(lifted)
            if pendingCommit != nil, localDropWasNoOp { endPendingCommit() }
            relayout(animated: true)
        } else if pendingCommit == nil, let payload {
            // Dropped in another window (or region): keep the rows lifted until the move arrives.
            beginPendingCommit(hidden: lifted, gap: nil, payload: payload)
        }
        localDropWasNoOp = false
        host?.list(self, dragDidChange: nil)
    }


    var dropTargetView: NSView { self }

    func localFileDropProposal(at point: NSPoint, in snapshot: BrowserOrganizationSnapshot, count: Int) -> SidebarDropProposal {
        SidebarDropResolver.resolve(y: point.y, iconX: point.x,
            layout: presentedDropLayout(at: animator.now), entries: content.entries, spaceID: snapshot.spaceID,
            draggedRows: count, isPinnedCollapsed: content.isPinnedSectionCollapsed)
    }

    func dropProposal(for payload: SidebarDragPayload, at point: NSPoint,
                      in snapshot: BrowserOrganizationSnapshot) -> SidebarDropProposal? {
        isCrossWindowHover = payload.nodes.count == 1 && payload.nodes.first?.tabID != nil
            && payload.sourceWindow != SidebarWindowDirectory.id(of: window)
        // A tab already shared by these two windows is hidden only in the receiver.
        let lifted = payload.spaceID == spaceID && localDrag == nil ? Set(liftedRows(for: payload.nodes).map(\.node)) : []
        if lifted != hoverHidden {
            hoverHidden = lifted
            liftedNodes.formUnion(lifted)
            relayout(animated: true)
        }
        return SidebarDropResolver.resolve(y: point.y, iconX: point.x - payload.grabOffsetX,
                                           layout: presentedDropLayout(at: animator.now),
                                           entries: content.entries, spaceID: snapshot.spaceID,
                                           draggedRows: payload.rowCount,
                                           isPinnedCollapsed: content.isPinnedSectionCollapsed)
    }

    /// The rows a drop can target, where they are drawn now: while springs run (a reorder, the
    /// placeholder opening) the pointer aims at what it sees, not at final positions. The open
    /// placeholder needs no correction: the pointer inside it stays between the same two rows.
    func presentedDropLayout(at time: CFTimeInterval) -> SidebarListLayout {
        var layout = dropLayout
        layout.rows = dropLayout.rows.map { row in
            SidebarListLayout.Placement(node: row.node, section: row.section,
                                        centerY: displayedCenterY(of: .node(row.node), at: time) ?? row.centerY,
                                        depth: row.depth)
        }
        layout.separatorCenterY = displayedCenterY(of: .separator, at: time) ?? dropLayout.separatorCenterY
        return layout
    }

    func showDropFeedback(_ proposal: SidebarDropProposal?, isValid: Bool, payload: SidebarDragPayload?) {
        applyDropFeedback(proposal, isValid: isValid, payload: payload, externalFile: false)
    }

    func showLocalFileDropFeedback(_ proposal: SidebarDropProposal?) {
        applyDropFeedback(proposal, isValid: proposal != nil, payload: nil, externalFile: proposal != nil)
    }

    private func applyDropFeedback(_ proposal: SidebarDropProposal?, isValid: Bool, payload: SidebarDragPayload?, externalFile: Bool) {
        if payload == nil, localDrag == nil, pendingCommit == nil, !hoverHidden.isEmpty {
            liftedNodes.subtract(hoverHidden)
            hoverHidden = []
        }
        if payload == nil { isCrossWindowHover = externalFile }
        let nextGap = isValid ? proposal?.gap : nil
        let nextFolder = isValid ? proposal?.folderTarget : nil
        guard nextGap != gap || nextFolder != folderTarget || payload == nil else { return }
        gap = nextGap
        folderTarget = nextFolder
        relayout(animated: true)
    }

    func dropFrame(for proposal: SidebarDropProposal) -> NSRect? {
        if let folder = proposal.folderTarget {
            return displayedCenterY(of: .node(.folder(folder))).map { rowFrame(centerY: $0) }
        }
        if isCrossWindowHover, let gap = proposal.gap {
            return SidebarListLayout.resolve(entries: content.entries, spaceTitleCenterY: spaceTitleCenterY,
                width: bounds.width, hidden: hiddenNodes, gap: gap).gapFrame
        }
        return displayedLayout.gapFrame
    }

    /// The drop was accepted (or was a no-op); the sidebar commits it.
    func didAcceptDrop(_ proposal: SidebarDropProposal, payload: SidebarDragPayload, changesOrganization: Bool) -> Bool {
        let lifted = hiddenNodes
        let external = isCrossWindowHover && effectiveGap == nil
        isCrossWindowHover = false
        if changesOrganization {
            beginPendingCommit(hidden: lifted, gap: external ? nil : gap, payload: payload)
        } else {
            liftedNodes.subtract(lifted)
            if localDrag != nil { localDropWasNoOp = true }
        }
        hoverHidden = []
        if localDrag != nil, changesOrganization { sourceHidden = [] }
        gap = nil
        folderTarget = nil
        relayout(animated: !changesOrganization)
        return false
    }

    private func beginPendingCommit(hidden: Set<BrowserOrganizationNode>, gap: SidebarDropGap?, payload: SidebarDragPayload) {
        pendingCommit?.timer.cancel()
        let timer = OrbitRunLoopTimer(after: OrbitTokens.Motion.dropCommitTimeout) { [weak self] in
            self?.endPendingCommit()
        }
        pendingCommit = PendingCommit(hidden: hidden, gap: gap, signature: content.structure, timer: timer)
    }

    private func endPendingCommit(relayout shouldRelayout: Bool = true) {
        guard let pending = pendingCommit else { return }
        pending.timer.cancel()
        pendingCommit = nil
        if localDrag == nil { dragGhostNodes = [] }
        if shouldRelayout { relayout(animated: true) }
    }

    var isAwaitingDropCommit: Bool { pendingCommit != nil }

    // MARK: Test accessors

    var tabRows: [SidebarTabRow] {
        rowViews.values.compactMap { $0 as? SidebarTabRow }.sorted { $0.frame.minY < $1.frame.minY }
    }

    var folderRows: [SidebarFolderRow] {
        rowViews.values.compactMap { $0 as? SidebarFolderRow }.sorted { $0.frame.minY < $1.frame.minY }
    }

    func row(for node: BrowserOrganizationNode) -> SidebarListRow? { rowViews[node] }
    var materializedRowCount: Int { rowViews.count }
    var insertionLineFrame: NSRect? { insertionLine.isHidden ? nil : insertionLine.frame }
    var gapPlaceholderFrame: NSRect? { gapPlaceholder.isHidden ? nil : gapPlaceholder.frame }
    var isClearRevealed: Bool { clearButton.isRevealed }
    func setTodayHoveredForTesting(_ hovered: Bool) { isTodayHovered = hovered }
}

/// Structural identity of a row (what a move changes), used to tell when a dropped move arrived.
struct SidebarListStructure: Equatable {
    let node: BrowserOrganizationNode
    let section: SidebarListSection
    let ancestors: [FolderID]
}

extension SidebarListContent {
    var structure: [SidebarListStructure] {
        entries.map { SidebarListStructure(node: $0.node, section: $0.section, ancestors: $0.ancestors) }
    }

    /// Collapse state of every visible folder.
    var folderStates: [FolderID: Bool] {
        var states: [FolderID: Bool] = [:]
        for entry in entries { if let folder = entry.folder { states[folder.id] = folder.isCollapsed } }
        return states
    }
}

@MainActor
enum SidebarDragImage {
    static func render(_ entry: SidebarListEntry, size: NSSize, accent: OrbitTokens.ThemeAccent,
                       appearance: NSAppearance, scale: CGFloat = 2) -> NSImage {
        let image = NSImage(size: size)
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        guard let bitmap = NSGraphicsContext(bitmapImageRep: rep) else { return image }
        let cg = bitmap.cgContext
        // NSGraphicsContext already scales bitmap pixels to rep.size's point coordinates.
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let foreground = OrbitSpaceThemes.accent(accent, over: [OrbitTokens.Color.State.tabCurrent])
        appearance.performAsCurrentDrawingAppearance { draw(entry, in: NSRect(origin: .zero, size: size), accent: foreground) }
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
        return image
    }

    private static func draw(_ entry: SidebarListEntry, in rect: NSRect, accent: OrbitTokens.ThemeAccent) {
        let radius = OrbitTokens.Radius.tabRow
        OrbitTokens.Color.State.tabCurrent.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let indent = OrbitSidebarGeometry.contentIndent(depth: entry.depth)
        let iconX = Metrics.rowInsetX + indent
        let titleX = Metrics.titleOriginX - Metrics.paddingX + indent
        let font: NSFont
        switch entry.content {
        case let .tab(item), let .split(item, _):
            font = OrbitTokens.Typography.sidebarTabTitle
            let iconSize = Metrics.faviconSize
            let iconRect = NSRect(x: iconX, y: (rect.height - iconSize) / 2, width: iconSize, height: iconSize)
            if let favicon = SpaceIconImages.tabImage(item.customIcon) ?? item.favicon ?? item.activity.favicon {
                favicon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if let placeholder = OrbitGlyph.faviconPlaceholder {
                OrbitGlyph.drawTemplate(placeholder, centeredIn: iconRect, tint: accent.icon)
            }
        case let .folder(item):
            font = OrbitTokens.Typography.sidebarFolderTitle
            let size = Metrics.folderIconSize
            let center = iconX + Metrics.faviconSize / 2
            SidebarFolderGlyphView.draw(in: NSRect(x: center - size / 2, y: (rect.height - size) / 2, width: size, height: size),
                                        isOpen: !item.isCollapsed, accent: accent)
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: entry.title, attributes: [
            .font: font, .foregroundColor: accent.sidebarText, .paragraphStyle: style
        ])
        let height = ceil(title.size().height)
        title.draw(with: NSRect(x: titleX, y: (rect.height - height) / 2, width: max(0, rect.width - titleX - Metrics.rowInsetX),
                                height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A one-and-a-half-point insertion rule with a hollow five-point leading marker.
@MainActor
private final class SidebarInsertionLineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let color = OrbitTokens.Color.Text.primary
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.appendOval(in: NSRect(x: 0.75, y: 0.75, width: 4.5, height: 4.5))
        path.move(to: NSPoint(x: 5.25, y: 3))
        path.line(to: NSPoint(x: bounds.maxX, y: 3))
        path.stroke()
    }
}
