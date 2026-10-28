import AppKit

// SB-LIST lot additions to the shared tokens (Pinned/Today list, folders, rename, drag and drop).
// Kept in the Sidebar folder so DESIGN-R2 can move them into OrbitTokens.swift without a merge
// conflict. Every value is an estimate or a reconstruction choice ([L]); the capture items are
// C17 (motion), C18 (hover), C25 (rename), C26 (pinned states), C27 (drag) and C28 (Clear).

extension OrbitTokens.Metrics.Sidebar {
    /// Reconstruction: a trailing audio control shares the close button's 24 pt hit target.
    static let audioControlPitch: CGFloat = 26
    static let audioGlyphSize: CGFloat = 12
    static let loadingRingInset: CGFloat = 2
    static let loadingRingWidth: CGFloat = 1.5
    ///  C26 — "moved away from the pinned URL" slash (asset name `TabCellSlash`):
    /// drawn in the 10 pt gap between the favicon and the title, centred 5 pt after the favicon.
    static let pinnedSlashCenterFromFaviconRight: CGFloat = 5
    static let pinnedSlashHeight: CGFloat = 12
    static let pinnedSlashLineWidth: CGFloat = 1.5
    ///  — trailing glyph of a tab open in another window, centred like the close button.
    static let otherWindowGlyphSize: CGFloat = 11
    ///  C27 — pointer distance from the page edges that scrolls during a drag, and
    /// the scroll step per dragging update at the very edge.
    static let dragAutoScrollEdge: CGFloat = 28
    static let dragAutoScrollMaximumStep: CGFloat = 14
    ///  C27 — fraction of a folder row, at its top and bottom, that inserts before or
    /// after it; the middle drops into the folder.
    static let folderDropEdgeFraction: CGFloat = 0.25
    ///  C28 — hover square of the Today "Clear" control around its text (the text and
    /// the separator's end are THEME-R2's `clearTextRightInset` and `clearSeparatorGap`).
    static let clearHoverPadding: CGFloat = 6
    static let clearButtonHeight: CGFloat = 20
    ///  — the Today zone reveals "Clear" from this distance above the separator.
    static let todayHoverSlop: CGFloat = 10
    ///  — rows materialised beyond the visible rect, in pitches, on each side.
    static let virtualizationOverscanRows: Int = 6
}

extension OrbitTokens.Metrics {
    ///  — folder glyph drawn for the list (no SF Symbol has Orbit's open folder).
    enum FolderGlyph {
        static let lineWidth: CGFloat = 1.25
        static let cornerRadius: CGFloat = 2
        static let tabWidthFraction: CGFloat = 0.42
        static let tabHeight: CGFloat = 2.5
        /// The open glyph's front panel is shifted right by this fraction of its width.
        static let openSkewFraction: CGFloat = 0.18
    }
}

extension OrbitTokens.Color.State {
    ///  C27 — placeholder drawn in the drag gap (the hover overlay).
    static var dragPlaceholder: NSColor { sidebarItem }
    ///  C27 — folder row targeted by a drop ("into"): Orbit's `DragHint` asset.
    static var dragFolderTarget: NSColor { dragHint }
    ///  C25 — row being renamed: lifted like the edited address field.
    static var renamingRow: NSColor { tabCurrent }
}

extension OrbitTokens.Color.Text {
    ///  — title of a tab open in another window and not loaded here.
    static var otherWindowTitle: NSColor { secondary }
}

extension OrbitTokens.Motion {
    /// Reconstruction: one rotation of a tab's loading ring; idle rows schedule no animation.
    static let tabLoadingRotation: TimeInterval = 0.8
    /// Orbit's OutlineViewDiffableDataSource groups insert/remove/reorder effects at 120 ms
    /// . Opacity and neighbour positions share that deadline.
    static let rowFadeDuration: TimeInterval = OrbitAnimationTiming.tabList.duration
    static let rowCloseFadeDuration: TimeInterval = OrbitAnimationTiming.tabList.duration
    ///  C27 — a drop that fails in the store restores the dragged rows after this delay.
    static let dropCommitTimeout: TimeInterval = 1.0
    /// reconstruction — a reveal or rename waiting for its row (folders expanding, folder being
    /// created) is dropped after this delay rather than scrolling much later.
    static let pendingRowIntentLifetime: TimeInterval = 2.0
}

extension OrbitTokens.Typography {
    ///  — the inline rename field uses the row title's font.
    static var sidebarRenameField: NSFont { sidebarTabTitle }
}
