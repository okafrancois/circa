import AppKit


extension OrbitTokens.Metrics.Sidebar {
    static let audioControlPitch: CGFloat = 26
    static let audioGlyphSize: CGFloat = 12
    static let loadingRingInset: CGFloat = 2
    static let loadingRingWidth: CGFloat = 1.5
    static let pinnedSlashCenterFromFaviconRight: CGFloat = 5
    static let pinnedSlashHeight: CGFloat = 12
    static let pinnedSlashLineWidth: CGFloat = 1.5
    ///  — trailing glyph of a tab open in another window, centred like the close button.
    static let otherWindowGlyphSize: CGFloat = 11
    static let dragAutoScrollEdge: CGFloat = 28
    static let dragAutoScrollMaximumStep: CGFloat = 14
    static let folderDropEdgeFraction: CGFloat = 0.25
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
    static var dragPlaceholder: NSColor { sidebarItem }
    static var dragFolderTarget: NSColor { dragHint }
    static var renamingRow: NSColor { tabCurrent }
}

extension OrbitTokens.Color.Text {
    ///  — title of a tab open in another window and not loaded here.
    static var otherWindowTitle: NSColor { secondary }
}

extension OrbitTokens.Motion {
    static let tabLoadingRotation: TimeInterval = 0.8
    /// Orbit's OutlineViewDiffableDataSource groups insert/remove/reorder effects at 120 ms
    /// . Opacity and neighbour positions share that deadline.
    static let rowFadeDuration: TimeInterval = OrbitAnimationTiming.tabList.duration
    static let rowCloseFadeDuration: TimeInterval = OrbitAnimationTiming.tabList.duration
    static let dropCommitTimeout: TimeInterval = 1.0
    static let pendingRowIntentLifetime: TimeInterval = 2.0
}

extension OrbitTokens.Typography {
    ///  — the inline rename field uses the row title's font.
    static var sidebarRenameField: NSFont { sidebarTabTitle }
}
