import CoreGraphics

private typealias WindowMetrics = OrbitTokens.Metrics.Window
private typealias ToolbarMetrics = OrbitTokens.Metrics.Toolbar
private typealias SidebarMetrics = OrbitTokens.Metrics.Sidebar
private typealias ContentMetrics = OrbitTokens.Metrics.Content

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
           width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}

struct OrbitShellGeometry: Equatable {
    struct State: Equatable {
        var contentSize: CGSize
        var sidebarWidth: CGFloat = SidebarMetrics.widthDefault
        var dockProgress: CGFloat = 1
        var floatProgress: CGFloat = 0
        /// Keep the floating container's bounds fixed at both endpoints of its native animation.
        var usesFloatingFrame = false
        var isFullScreen = false
        /// Centre spacing of the system window buttons (`OrbitTrafficLights.systemPitch`): 23 on the capture
        /// machine, 20 on older macOS (). The system defines it, not Orbit.
        var trafficLightPitch: CGFloat = WindowMetrics.trafficLightPitch
    }

    /// Leading edge of the docked column (−W when hidden); the card follows its trailing edge.
    var dockedColumnMinX: CGFloat
    /// Distance between the docked column's trailing edge and the card.
    var cardGap: CGFloat
    var sidebarFrame: CGRect
    var cardFrame: CGRect
    var cardRadius: CGFloat
    /// Opacity of the floating panel (fill, shadow, edge) behind the sidebar.
    var floatingChrome: CGFloat
    var floatingRadius: CGFloat
    var trafficLightCenters: [CGPoint]
    var trafficLightsVisible: Bool
    var isSidebarOnScreen: Bool

    static func resolve(_ state: State) -> OrbitShellGeometry {
        let width = state.sidebarWidth
        let size = state.contentSize
        let dock = state.dockProgress
        let float = state.floatProgress
        //  10 with the sidebar;  10 hidden, 0 in full screen.
        let hiddenInset = state.isFullScreen ? ContentMetrics.fullscreenHiddenSidebarInset : ContentMetrics.cardInsetSidebarHidden
        let inset = lerp(hiddenInset, ContentMetrics.cardInset, dock)
        let columnMinX = -width * (1 - dock)
        let gap = hiddenInset * (1 - dock)
        let cardMinX = columnMinX + width + gap
        let card = CGRect(x: cardMinX, y: inset, width: size.width - inset - cardMinX, height: size.height - 2 * inset)
        let hiddenRadius = state.isFullScreen ? ContentMetrics.cardRadiusFullscreenHidden : OrbitTokens.Radius.contentCard
        let docked = CGRect(x: columnMinX, y: 0, width: width, height: size.height)
        let sidebar: CGRect
        if float > 0 || state.usesFloatingFrame {
            let f = SidebarMetrics.floatingInset
            // : 5 from the left and top edges; fully offscreen at 0, shadow included
            // (travel = width + 5 + blur 8).
            let travel = width + f + OrbitTokens.Shadow.floatingSidebar.blur
            let floating = CGRect(x: f - travel * (1 - float), y: f, width: width, height: size.height - 2 * f)
            sidebar = lerp(floating, CGRect(x: 0, y: 0, width: width, height: size.height), dock)
        } else {
            sidebar = docked
        }
        let lights = (0..<3).map { index in
            CGPoint(x: sidebar.minX + WindowMetrics.trafficLightFirstCenterX + CGFloat(index) * state.trafficLightPitch,
                    y: sidebar.minY + WindowMetrics.trafficLightCenterY)
        }
        let onScreen = sidebar.maxX > 0.5 && (dock > 0.001 || float > 0.001)
        return OrbitShellGeometry(
            dockedColumnMinX: columnMinX, cardGap: gap, sidebarFrame: sidebar, cardFrame: card,
            cardRadius: lerp(hiddenRadius, OrbitTokens.Radius.contentCard, dock),
            floatingChrome: float > 0 ? max(0, min(1, 1 - dock)) : 0,
            floatingRadius: OrbitTokens.Radius.floatingSidebar * max(0, 1 - dock),
            trafficLightCenters: lights,
            trafficLightsVisible: onScreen && lights[0].x - WindowMetrics.trafficLightDiameter / 2 > -0.5,
            isSidebarOnScreen: onScreen)
    }

    enum ResizeOutcome: Equatable { case width(CGFloat), collapse }

    /// `pointerX` is the pointer's distance from the window's left edge; it defaults to the proposed
    /// width (the edge is under the pointer while the drag tracks it).
    static func resize(proposedWidth: CGFloat, pointerX: CGFloat? = nil) -> ResizeOutcome {
        if (pointerX ?? proposedWidth) < SidebarMetrics.collapsePointerX { return .collapse }
        return .width(min(SidebarMetrics.widthMax, max(SidebarMetrics.widthMin, proposedWidth.rounded())))
    }
}

struct OrbitSidebarGeometry: Equatable {
    struct Content: Equatable {
        var width: CGFloat = SidebarMetrics.widthDefault
        var height: CGFloat
        var favoriteCount = 0
        var favoriteMinimumTileWidth = SidebarMetrics.favoriteMinimumTileWidth
        var pinnedRowCount = 0
        var todayRowCount = 0
        var spaceCount = 1
        /// The Space shows an icon left of its title (title at 44 instead of 16).
        var spaceHasIcon = false
        var trafficLightPitch: CGFloat = WindowMetrics.trafficLightPitch
        var isFullScreen = false
    }

    struct Toolbar: Equatable {
        var centerY: CGFloat
        var isCompact: Bool
        /// Nil when hidden (compact).
        var sidebarToggleCenterX: CGFloat?
        var backCenterX: CGFloat
        var forwardCenterX: CGFloat
        var reloadCenterX: CGFloat?
        var overflowCenterX: CGFloat?
        var hitWidth: CGFloat

        static func resolve(width: CGFloat, trafficLightPitch: CGFloat = WindowMetrics.trafficLightPitch,
                            isFullScreen: Bool = false) -> Toolbar {
            let hit = ToolbarMetrics.buttonHitSize
            if width < ToolbarMetrics.compactBelowWidth {
                return Toolbar(centerY: ToolbarMetrics.rowCenterY, isCompact: true, sidebarToggleCenterX: nil,
                               backCenterX: width - ToolbarMetrics.compactBackFromRight,
                               forwardCenterX: width - ToolbarMetrics.compactForwardFromRight, reloadCenterX: nil,
                               overflowCenterX: width - ToolbarMetrics.compactOverflowFromRight,
                               hitWidth: min(hit, ToolbarMetrics.compactBackFromRight - ToolbarMetrics.compactForwardFromRight))
            }
            let toggle = isFullScreen ? ToolbarMetrics.fullScreenSidebarToggleCenterX
                : ToolbarMetrics.sidebarToggleCenterX(trafficLightPitch: trafficLightPitch)
            return Toolbar(centerY: ToolbarMetrics.rowCenterY, isCompact: false, sidebarToggleCenterX: toggle,
                           backCenterX: width - ToolbarMetrics.backFromRight, forwardCenterX: width - ToolbarMetrics.forwardFromRight,
                           reloadCenterX: width - ToolbarMetrics.reloadFromRight, overflowCenterX: nil,
                           hitWidth: min(hit, ToolbarMetrics.navPitch))
        }
    }

    struct PageRhythm: Equatable {
        var spaceTitleCenterY: CGFloat
        var pinnedRowCenters: [CGFloat]
        var separatorCenterY: CGFloat
        var isSeparatorVisible: Bool
        var newTabCenterY: CGFloat
        var todayRowCenters: [CGFloat]

        static func resolve(pinnedRowCount: Int, todayRowCount: Int, hasFavorites: Bool = false) -> PageRhythm {
            let title = hasFavorites ? SidebarMetrics.spaceTitleCenterFromFavorites
                : SidebarMetrics.spaceTitleCenterFromAddressWithoutFavorites
            let firstRow = title + SidebarMetrics.firstRowCenterFromSpaceTitle
            let pitch = SidebarMetrics.rowPitch
            let pinned = (0..<max(0, pinnedRowCount)).map { firstRow + CGFloat($0) * pitch }
            let separator = pinned.last.map { $0 + SidebarMetrics.separatorCenterToRowCenter }
                ?? title + SidebarMetrics.separatorCenterFromSpaceTitle
            let visible = !pinned.isEmpty || todayRowCount > 0
            let newTab = visible ? separator + SidebarMetrics.newTabCenterFromSeparator
                : title + SidebarMetrics.newTabCenterFromSpaceTitleWhenEmpty
            let today = (0..<max(0, todayRowCount)).map { newTab + CGFloat($0 + 1) * pitch }
            return PageRhythm(spaceTitleCenterY: title, pinnedRowCenters: pinned, separatorCenterY: separator,
                              isSeparatorVisible: visible, newTabCenterY: newTab, todayRowCenters: today)
        }
    }

    var width: CGFloat
    var toolbar: Toolbar
    var toolbarCenterY: CGFloat
    var sidebarToggleCenterX: CGFloat
    var backCenterX: CGFloat
    var forwardCenterX: CGFloat
    var reloadCenterX: CGFloat
    var toolbarHitWidth: CGFloat

    var addressFrame: CGRect
    /// Seam for the Favorites grid (Organisation lot); zero height without Favorites.
    var favoritesFrame: CGRect
    var favoriteColumns: Int

    /// Scrollable Space page, between the Favorites and the footer.
    var pageFrame: CGRect
    // Page document coordinates (origin at the page top).
    var spaceTitleCenterY: CGFloat
    /// : 16 without a Space icon, 44 with one (S-PIN).
    var spaceTitleOriginX: CGFloat
    var pinnedRowCenters: [CGFloat]
    var separatorCenterY: CGFloat
    var isSeparatorVisible: Bool
    var newTabCenterY: CGFloat
    var todayRowCenters: [CGFloat]
    var documentHeight: CGFloat

    // Footer.
    var footerFrame: CGRect
    var footerCenterY: CGFloat
    var libraryCenterX: CGFloat
    var plusCenterX: CGFloat
    var spaceCenterXs: [CGFloat]

    /// A sidebar row of the page: x 8 → W − 8, 36 high, centred on `centerY`.
    func rowFrame(centerY: CGFloat) -> CGRect {
        CGRect(x: SidebarMetrics.paddingX, y: centerY - SidebarMetrics.rowHeight / 2,
               width: addressFrame.width, height: SidebarMetrics.rowHeight)
    }

    // Seams for the section lots, fed by `BrowserOrganizationSnapshot`.

    /// Favorite tile `index` in `favoritesContainer` coordinates: tiles stretch across the row,
    /// 47 high with 8 pt gaps between tiles and rows (); balanced rows.
    func favoriteTileFrame(index: Int) -> CGRect {
        let columns = CGFloat(max(1, favoriteColumns))
        let gap = SidebarMetrics.favoriteGap
        let width = (favoritesFrame.width - (columns - 1) * gap) / columns
        let column = CGFloat(index % max(1, favoriteColumns)), row = CGFloat(index / max(1, favoriteColumns))
        return CGRect(x: column * (width + gap), y: row * (SidebarMetrics.favoriteTileHeight + gap),
                      width: width, height: SidebarMetrics.favoriteTileHeight)
    }

    /// Visible pinned row `index` (folders and expanded children flattened, as
    /// `BrowserOrganizationRow`) in `pinnedContainer` coordinates. The row box keeps the full
    /// width; only its icon and title move right by `contentIndent(depth:)` ().
    func pinnedRowFrame(index: Int) -> CGRect {
        let top = spaceTitleCenterY + SidebarMetrics.firstRowCenterFromSpaceTitle - SidebarMetrics.rowHeight / 2
        return rowFrame(centerY: top + SidebarMetrics.rowHeight / 2 + CGFloat(index) * SidebarMetrics.rowPitch)
            .offsetBy(dx: 0, dy: -top)
    }

    /// +16 per folder level for the icon and the title, without chevrons ().
    static func contentIndent(depth: Int) -> CGFloat { CGFloat(max(0, depth)) * SidebarMetrics.folderChildIndent }

    static func resolve(_ content: Content) -> OrbitSidebarGeometry {
        let width = content.width
        let padding = SidebarMetrics.paddingX
        let inner = width - 2 * padding

        let toolbar = Toolbar.resolve(width: width, trafficLightPitch: content.trafficLightPitch, isFullScreen: content.isFullScreen)
        let wide = Toolbar.resolve(width: max(width, ToolbarMetrics.compactBelowWidth),
                                   trafficLightPitch: content.trafficLightPitch, isFullScreen: content.isFullScreen)

        let address = CGRect(x: padding, y: SidebarMetrics.addressTop, width: inner, height: SidebarMetrics.addressHeight)
        let columns = SidebarMetrics.favoriteColumns(count: content.favoriteCount, sidebarWidth: width,
                                                     minimumTileWidth: content.favoriteMinimumTileWidth)
        let favoriteRows = content.favoriteCount == 0 ? 0 : (content.favoriteCount + columns - 1) / columns
        let favoritesHeight = favoriteRows == 0 ? 0
            : CGFloat(favoriteRows) * SidebarMetrics.favoriteTileHeight + CGFloat(favoriteRows - 1) * SidebarMetrics.favoriteGap
        let favoritesTop = address.maxY + (favoriteRows == 0 ? 0 : SidebarMetrics.favoritesTopGap)
        let favorites = CGRect(x: padding, y: favoritesTop, width: inner, height: favoritesHeight)

        let footerHeight = SidebarMetrics.footerHeight
        let footer = CGRect(x: 0, y: content.height - footerHeight, width: width, height: footerHeight)
        let page = CGRect(x: 0, y: favorites.maxY, width: width, height: max(0, footer.minY - favorites.maxY))

        let rhythm = PageRhythm.resolve(pinnedRowCount: content.pinnedRowCount, todayRowCount: content.todayRowCount,
                                        hasFavorites: favoriteRows > 0)
        let lastCenter = rhythm.todayRowCenters.last ?? rhythm.newTabCenterY
        let document = lastCenter + SidebarMetrics.rowHeight / 2 + padding

        // Footer:  centre H − 25, side buttons 24 from each edge, Space pitch 34.
        let library = SidebarMetrics.footerSideButtonCenterInset
        let plus = width - SidebarMetrics.footerSideButtonCenterInset
        let spaces = FooterSpaceLayout.resolve(count: content.spaceCount, libraryCenterX: library, plusCenterX: plus).centerXs

        return OrbitSidebarGeometry(
            width: width, toolbar: toolbar,
            toolbarCenterY: toolbar.centerY,
            sidebarToggleCenterX: toolbar.sidebarToggleCenterX ?? wide.sidebarToggleCenterX ?? 0,
            backCenterX: toolbar.backCenterX, forwardCenterX: toolbar.forwardCenterX,
            reloadCenterX: toolbar.reloadCenterX ?? width - ToolbarMetrics.reloadFromRight, toolbarHitWidth: toolbar.hitWidth,
            addressFrame: address, favoritesFrame: favorites, favoriteColumns: columns,
            pageFrame: page, spaceTitleCenterY: rhythm.spaceTitleCenterY,
            spaceTitleOriginX: content.spaceHasIcon ? SidebarMetrics.titleOriginX : SidebarMetrics.spaceTitleOriginXWithoutIcon,
            pinnedRowCenters: rhythm.pinnedRowCenters, separatorCenterY: rhythm.separatorCenterY,
            isSeparatorVisible: rhythm.isSeparatorVisible,
            newTabCenterY: rhythm.newTabCenterY, todayRowCenters: rhythm.todayRowCenters, documentHeight: document,
            footerFrame: footer, footerCenterY: footer.height / 2,
            libraryCenterX: library, plusCenterX: plus, spaceCenterXs: spaces)
    }
}

struct FooterSpaceLayout: Equatable {
    enum Presentation: Equatable { case icons, dots }

    var presentation: Presentation
    /// Horizontal distance between Space centres; also the width of each hit target.
    var pitch: CGFloat
    var dotDiameter: CGFloat
    /// Centres in the footer's coordinate space.
    var centerXs: [CGFloat]

    static func resolve(count: Int, libraryCenterX: CGFloat, plusCenterX: CGFloat,
                        backingScale: CGFloat = 1) -> FooterSpaceLayout {
        let half = SidebarMetrics.footerButtonSize / 2
        // 4 pt clearance from the side buttons' hit squares.
        let leading = libraryCenterX + half + 4, trailing = plusCenterX - half - 4
        let available = max(0, trailing - leading)
        let count = max(0, count)
        guard count > 0 else {
            return .init(presentation: .icons, pitch: 0, dotDiameter: SidebarMetrics.footerSpaceDotDiameter, centerXs: [])
        }
        let share = available / CGFloat(count)
        let iconPitch = min(SidebarMetrics.footerSpaceIconPitch, share)
        let presentation: Presentation = iconPitch >= SidebarMetrics.footerSpaceIconMinimumPitch ? .icons : .dots
        let pitch = presentation == .icons ? iconPitch : min(SidebarMetrics.footerSpaceDotPitch, share)
        let desiredDiameter = presentation == .icons ? SidebarMetrics.footerSpaceDotDiameter
            : min(SidebarMetrics.footerSpaceDotDiameter, max(SidebarMetrics.footerSpaceDotMinimumDiameter, pitch - 3))
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        // A circle never exceeds its own hit cell. Below one physical pixel, omit
        // the decoration rather than paint across adjacent targets; AX targets remain.
        let diameter = floor(min(pitch, desiredDiameter) * scale) / scale
        let mid = (leading + trailing) / 2
        let centers = (0..<count).map { mid + (CGFloat($0) - CGFloat(count - 1) / 2) * pitch }
        return .init(presentation: presentation, pitch: pitch, dotDiameter: diameter, centerXs: centers)
    }
}
