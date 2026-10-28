import AppKit
import Testing
@testable import BrowserCore
@testable import Orbit

extension NativeWebKitTests {
@MainActor
@Suite(.serialized)
struct SidebarWidenTests {
    @Test("Labels and icons paint across widening after floating reveal and a Space switch",
          arguments: [false, true])
    func widthChanges(afterSpaceSwitch: Bool) async throws {
        let window = SidebarWidthWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 780),
                                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = OrbitWindowRootView(), shell = OrbitWindowShell()
        shell.prepare(window: window, root: root)
        let card = BrowserContentCardView(), sidebar = BrowserSidebarView()
        for view in [card, sidebar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        window.contentView = root
        shell.installFloatingBackdrop(in: root)
        shell.installConstraints(root: root, sidebar: sidebar, card: card,
            width: sidebar.widthAnchor.constraint(equalToConstant: 228),
            leading: sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor))
        let first = SyntheticOrganization(), second = SyntheticOrganization()
        let catalog = BrowserCatalogSnapshot(profiles: first.catalog.profiles + second.catalog.profiles,
                                            spaces: first.catalog.spaces + second.catalog.spaces)
        let favorites = FavoritesGridView()
        favorites.autoresizingMask = [.width, .height]
        sidebar.favoritesContainer.addSubview(favorites)
        func render(_ org: SyntheticOrganization) {
            let favorite = BrowserOrganizationTabItem(id: TabID(), section: .favorites(org.profileID),
                url: URL(string: "https://favorite.test/")!, pinnedURL: nil, pageTitle: "Synthetic favorite",
                customTitle: nil, occurrenceID: nil, isLoadedInThisWindow: false, isSelected: false,
                isOpenInAnotherWindow: false)
            favorites.render([FavoriteTileItem(tab: favorite)], profileID: org.profileID)
            sidebar.favoriteCount = 1
            sidebar.render(catalog: catalog, activeSpaceID: org.spaceID,
                organization: org.snapshot(pinned: [
                    org.tab(pinned: true, title: "Pinned synthetic page with a deliberately long title"),
                    org.folder(title: "Synthetic folder", [
                        org.tab(pinned: true, title: "Nested synthetic page with a deliberately long title")])
                ], today: [org.tab(title: "Today synthetic page with a deliberately long title")],
                    favorites: [.tab(favorite)]))
        }
        render(first)
        root.layoutSubtreeIfNeeded()
        favorites.frame = sidebar.favoritesContainer.bounds
        shell.setDocked(false)
        try await Task.sleep(for: .milliseconds(180))
        shell.setFloating(true)
        try await Task.sleep(for: .milliseconds(450))
        shell.setDocked(true)
        try await Task.sleep(for: .milliseconds(180))
        if afterSpaceSwitch { render(second) }
        // Resize while the incoming Space is moving, then inspect both at rest and on every
        // subsequent width update. No production window is ordered on the shared desktop.
        shell.setSidebarWidth(500)
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        for width in [500.0, 400, 280, 228, 164, 228, 343, 500] {
            shell.setSidebarWidth(width)
            root.layoutSubtreeIfNeeded()
            #expect(abs(sidebar.bounds.width - width) < 0.01)
            let list = sidebar.page.list
            #expect(list.tabRows.count == 3 && list.folderRows.count == 1)
            for row in list.tabRows + list.folderRows.map({ $0 as SidebarListRow }) {
                #expect(!row.isHiddenOrHasHiddenAncestor && row.alphaValue == 1)
                #expect(row.visibleRect.contains(row.titleLabel.frame))
                #expect(abs(row.bounds.width - (width - 16)) < 0.01)
                #expect(row.titleLabel.lineBreakMode == .byTruncatingTail)
                // Read pixels from the composed row, not just its title string or view frame.
                let bitmap = try raster(row)
                #expect(opaquePixels(bitmap, in: row.titleLabel.frame) > 20)
                let icon = CGRect(x: row.iconX, y: 8, width: 18, height: 20)
                #expect(opaquePixels(bitmap, in: icon) > 10)
            }
            let tile = try #require(favorites.tiles.first)
            #expect(!tile.isHiddenOrHasHiddenAncestor && !tile.visibleRect.isEmpty)
            let letter = try #require(tile.subviews.compactMap { $0 as? NSTextField }.first)
            #expect(opaquePixels(try raster(letter), in: letter.bounds) > 10)
            #expect(shell.isDocked && !shell.isAnimating)
        }
    }

    private func raster(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(view.bounds.width * 2)), pixelsHigh: Int(ceil(view.bounds.height * 2)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func opaquePixels(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let region = rect.intersection(CGRect(origin: .zero, size: bitmap.size))
        guard !region.isEmpty else { return 0 }
        var count = 0
        for y in Int(ceil(region.minY * scale))..<Int(floor(region.maxY * scale)) {
            for x in Int(ceil(region.minX * scale))..<Int(floor(region.maxX * scale)) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1 }
            }
        }
        return count
    }
}
}

/// Exercise compositor transitions without ordering a test window on the shared desktop.
@MainActor
private final class SidebarWidthWindow: NSWindow {
    override var isVisible: Bool { true }
    override var occlusionState: NSWindow.OcclusionState { .visible }
}
