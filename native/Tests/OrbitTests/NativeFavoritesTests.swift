import AppKit
@testable import BrowserCore
import BrowserEngine
@testable import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class FavoritesHarness {
    let store: BrowserStore
    let engine: SiteSyntheticEngine
    let profileID: ProfileID
    let spaceID: SpaceID
    let router: BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>
    let registry: BrowserCommandRegistry<BrowserWindowController<SiteSyntheticEngine>>
    var window: BrowserWindowController<SiteSyntheticEngine> { router.selectedWindow! }

    init() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        self.store = store
        let engine = SiteSyntheticEngine()
        self.engine = engine
        profileID = await store.createProfile(name: "Synthetic favorites")
        let space = try await store.createSpace(name: "First", profileID: profileID)
        spaceID = space
        router = BrowserWindowRouter(create: { id in
            let controller = BrowserWindowController(id: id, store: store, spaceID: space, engine: engine,
                                                     onClose: {}, onActivate: {})
            controller.session.onError = { _ in }
            await controller.session.waitForPendingCommands()
            return controller
        }, present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
                                              deliver: { $0.performAcceptedCommand($1) })
        BrowserWindowCommands.install(in: registry)
        _ = try await newWindow()
    }
    @discardableResult
    func newWindow() async throws -> BrowserWindowController<SiteSyntheticEngine> {
        let id = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let controller = try #require(router.windows[id])
        await controller.session.waitForPendingCommands()
        controller.favorites.bind(to: registry)
        return controller
    }
    @discardableResult
    func add(_ address: String, to controller: BrowserWindowController<SiteSyntheticEngine>? = nil) async throws -> TabID {
        let controller = controller ?? window
        controller.session.openTab(url: URL(string: address)!)
        await controller.session.waitForPendingCommands()
        let id = try #require(controller.session.organization?.selectedTab?.id)
        controller.session.addToFavorites([id])
        await controller.session.waitForPendingCommands()
        controller.sidebar.frame.size = NSSize(width: 228, height: 640)
        controller.sidebar.layoutSubtreeIfNeeded()
        return id
    }
    func settle() async {
        await router.waitForPendingCommands()
        for controller in router.windows.values { await controller.session.waitForPendingCommands() }
    }
    func close() { router.shutdown() }
}

@MainActor
private func favoriteItem(id: TabID = TabID(), profile: ProfileID = ProfileID(), selected: Bool = false,
                          loaded: Bool = true, title: String? = nil) -> FavoriteTileItem {
    FavoriteTileItem(tab: BrowserOrganizationTabItem(id: id, section: .favorites(profile),
        url: URL(string: "https://alpha.example.test/")!, pinnedURL: URL(string: "https://alpha.example.test/")!,
        pageTitle: title, customTitle: nil, occurrenceID: nil, isLoadedInThisWindow: loaded,
        isSelected: selected, isOpenInAnotherWindow: false), favicon: nil)
}

@MainActor
private func pointer(_ type: NSEvent.EventType, x: CGFloat = 15, y: CGFloat = 15) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: .init(x: x, y: y), modifierFlags: [], timestamp: 0,
                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeFavoritesTests {
    @Test("Favorite tiles use measured height, gap and icon-only letter placeholders")
    func measuredGrid() {
        let profile = ProfileID()
        let grid = FavoritesGridView(frame: .init(x: 0, y: 0, width: 212, height: 160))
        grid.render((0..<7).map { _ in favoriteItem(profile: profile) }, profileID: profile)
        grid.layoutSubtreeIfNeeded()
        #expect(grid.geometry.favoriteColumns == 4)
        #expect(grid.tiles.allSatisfy { $0.frame.height == 47 })
        #expect(grid.tiles[1].frame.minX - grid.tiles[0].frame.maxX == 8)
        #expect(grid.tiles[4].frame.minY - grid.tiles[0].frame.maxY == 8)
        #expect(grid.tiles[0].item.placeholder == "A")
        #expect(grid.tiles[0].subviews.compactMap { $0 as? NSImageView }.first?.frame.size == NSSize(width: 20, height: 20))
    }

    @Test("Sidebar and grid share an adjustable column-width token at minimum and maximum widths")
    func responsiveColumns() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        for index in 0..<7 { try await h.add("https://tile\(index).example.test/") }
        let sidebar = h.window.sidebar
        sidebar.favoriteMinimumTileWidth = 60
        h.window.favorites.render()
        for width: CGFloat in [180, 228, 334, 420] {
            sidebar.frame.size = NSSize(width: width, height: 640)
            sidebar.layoutSubtreeIfNeeded()
            let grid = h.window.favorites.grid
            grid.layoutSubtreeIfNeeded()
            #expect(sidebar.geometry.favoriteColumns == grid.geometry.favoriteColumns)
            #expect(grid.tiles.allSatisfy { $0.frame.maxX <= grid.bounds.width + 0.01 })
            #expect(grid.tiles.last!.frame.maxY == sidebar.geometry.favoritesFrame.height)
        }
    }

    @Test("Empty grid consumes no permanent sidebar row; the drop adapter can reserve and release one")
    func emptyGridDropZone() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let sidebar = h.window.sidebar
        sidebar.frame.size = NSSize(width: 228, height: 640)
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.geometry.favoritesFrame.height == 0)
        h.window.favorites.grid.dropTarget.begin()
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.geometry.favoritesFrame.height == 47)
        h.window.favorites.grid.dropTarget.end()
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.geometry.favoritesFrame.height == 0)
    }

    @Test("Tile fill follows rest, hover, press and selected states; retained identity preserves hover")
    func tileStates() {
        let profile = ProfileID()
        let item = favoriteItem(profile: profile)
        let grid = FavoritesGridView(frame: .init(x: 0, y: 0, width: 212, height: 47))
        grid.render([item], profileID: profile)
        let tile = grid.tiles[0]
        #expect(tile.background.fillColor == OrbitTokens.Color.State.sidebarItem)
        tile.mouseEntered(with: pointer(.mouseMoved))
        #expect(tile.background.fillColor == OrbitTokens.Color.State.sidebarItemHovered)
        tile.mouseDown(with: pointer(.leftMouseDown))
        #expect(tile.isPressed)
        #expect(tile.background.fillColor == OrbitTokens.Color.State.tabPressed)
        grid.render([item], profileID: profile)
        #expect(grid.tiles[0] === tile)
        #expect(tile.isHovering && tile.isPressed)
        tile.cancelPress()
        tile.update(favoriteItem(id: item.tab.id, profile: profile, selected: true))
        #expect(tile.background.fillColor == OrbitTokens.Color.State.tabCurrent)
        #expect(tile.background.outerShadow != nil)
        tile.commandsEnabled = false
        #expect(!tile.accessibilityPerformPress())
    }

    @Test("Dragging past threshold cancels click and press state even if the pointer returns")
    func dragDoesNotSelect() {
        let tile = FavoriteTileView(item: favoriteItem())
        let host = NSView(frame: .init(x: 0, y: 0, width: 200, height: 60))
        tile.frame = .init(x: 0, y: 0, width: 80, height: 47)
        host.addSubview(tile)
        var selected = 0, dragged = 0
        tile.onSelect = { selected += 1 }; tile.onDrag = { _ in dragged += 1 }
        tile.mouseDown(with: pointer(.leftMouseDown))
        tile.mouseDragged(with: pointer(.leftMouseDragged, x: 40))
        tile.mouseUp(with: pointer(.leftMouseUp))
        #expect(dragged == 1 && selected == 0 && !tile.isPressed)
    }

    @Test("Dormant activation creates one local occurrence and repeated clicks retain it")
    func dormantActivation() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let window = h.window
        window.session.closeTabs([id])
        await h.settle()
        #expect(window.favorites.grid.items[0].tab.isLoadedInThisWindow == false)
        #expect(window.favorites.grid.tiles[0].accessibilityPerformPress())
        await h.settle()
        let surface = try #require(window.session.selectedSurface)
        let occurrence = window.session.snapshot?.selectedOccurrenceID
        for _ in 0..<3 { #expect(window.favorites.grid.tiles[0].accessibilityPerformPress()) }
        await h.settle()
        #expect(window.session.selectedSurface === surface)
        #expect(window.session.snapshot?.selectedOccurrenceID == occurrence)
        #expect(window.session.snapshot?.tabs.filter { $0.id == id }.count == 1)
        #expect(window.sidebar.favoriteCount == 1)
        #expect(!window.displayedTabTitles.contains("alpha.example.test"))
        #expect(window.window?.isVisible == false && !NSApp.isActive)
    }

    @Test("Favorites follow the Space profile and keep their live surface across same-profile Spaces")
    func profileSwitch() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let window = h.window
        let surface = try #require(window.session.selectedSurface)
        let same = try await h.store.createSpace(name: "Same profile", profileID: h.profileID)
        let otherProfile = await h.store.createProfile(name: "Other synthetic profile")
        let other = try await h.store.createSpace(name: "Other", profileID: otherProfile)
        window.session.activateSpace(same)
        await h.settle()
        #expect(window.favorites.grid.items.map { $0.tab.id } == [id])
        #expect(window.favorites.grid.items[0].tab.isLoadedInThisWindow)
        #expect(window.favorites.grid.tiles[0].accessibilityPerformPress())
        await h.settle()
        #expect(window.session.selectedSurface === surface)
        window.session.activateSpace(other)
        await h.settle()
        #expect(window.favorites.grid.items.isEmpty)
        let otherID = try await h.add("https://beta.example.test/")
        #expect(window.favorites.grid.items.map { $0.tab.id } == [otherID])
        window.session.activateSpace(h.spaceID)
        await h.settle()
        #expect(window.favorites.grid.items.map { $0.tab.id } == [id])
        #expect(window.favorites.grid.items[0].isAudible == nil)
    }

    @Test("Shared favorites load independent occurrences in two hidden windows")
    func independentWindows() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let first = h.window
        let original = try #require(first.session.selectedSurface)
        let second = try await h.newWindow()
        #expect(second.favorites.grid.items.map { $0.tab.id } == [id])
        #expect(second.favorites.grid.items[0].tab.isOpenInAnotherWindow)
        #expect(second.favorites.grid.tiles[0].accessibilityPerformPress())
        await h.settle()
        #expect(first.session.selectedSurface === original)
        #expect(second.session.selectedSurface !== original)
        #expect(second.session.snapshot?.tabs.filter { $0.id == id }.count == 1)
        #expect(first.window?.isVisible == false && second.window?.isVisible == false)
    }

    @Test("Away favorites preserve home identity and current destination until an explicit reset command")
    func awayAndReset() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let home = URL(string: "https://alpha.example.test/")!
        let id = try await h.add(home.absoluteString)
        let window = h.window
        let surface = try #require(window.session.selectedSurface)
        let away = URL(string: "https://elsewhere.example.test/next")!
        surface.navigate(to: away)
        await h.settle()
        #expect(window.favorites.grid.items[0].tab.isAwayFromPinnedURL)
        #expect(window.favorites.grid.items[0].placeholder == "A")
        #expect(window.favorites.grid.tiles[0].accessibilityPerformPress())
        await h.settle()
        #expect(surface.currentURL == away)
        let menu = try #require(window.favorites.contextMenu(for: id))
        #expect(menu.items.compactMap { $0.identifier?.rawValue } == ["copyFavoriteLink", "renameFavorite", "resetFavorite", "removeFavorite"])
        #expect(menu.items.contains { $0.title == "Move to" && $0.submenu != nil })
        #expect(h.registry.isEnabled(.resetFavorite))
        menu.performActionForItem(at: menu.items.firstIndex { $0.identifier?.rawValue == "resetFavorite" }!)
        await h.settle()
        #expect(window.session.selectedSurface === surface)
        #expect(surface.currentURL == home)
        #expect(!window.favorites.grid.items[0].tab.isAwayFromPinnedURL)
    }

    @Test("Context menu removes its unselected favorite without selecting or removing a different object")
    func exactContextObject() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let first = try await h.add("https://alpha.example.test/")
        let second = try await h.add("https://beta.example.test/")
        let window = h.window
        let menu = try #require(window.favorites.contextMenu(for: first))
        let target = try #require(h.registry.captureTarget())
        #expect(!h.registry.isEnabled(.resetFavorite, target: target))
        menu.performActionForItem(at: menu.items.firstIndex { $0.identifier?.rawValue == "removeFavorite" }!)
        await h.settle()
        #expect(window.favorites.grid.items.map { $0.tab.id } == [second])
        #expect(window.session.organization?.selectedTab?.id == second)
        #expect(window.session.organization?.today.contains { $0.node == .tab(first) } == true)
    }

    @Test("Menus reject changed object metadata and a changed profile without retargeting")
    func staleMenus() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let window = h.window
        _ = try #require(window.favorites.contextMenu(for: id))
        let target = try #require(h.registry.captureTarget())
        window.session.renameTab(id, to: "Changed")
        await h.settle()
        #expect(!h.registry.dispatch(.removeFavorite, origin: .contextMenu, target: target))
        _ = try #require(window.favorites.contextMenu(for: id))
        let secondTarget = try #require(h.registry.captureTarget())
        let profile = await h.store.createProfile(name: "Other")
        let space = try await h.store.createSpace(name: "Other", profileID: profile)
        window.session.activateSpace(space)
        await h.settle()
        #expect(!h.registry.dispatch(.removeFavorite, origin: .contextMenu, target: secondTarget))
        #expect(window.favorites.currentMenuTab == nil)
    }

    @Test("Numbered commands resolve after an earlier reorder and retain rapid input order")
    func numberedCommandOrder() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let first = try await h.add("https://alpha.example.test/")
        let second = try await h.add("https://beta.example.test/")
        let window = h.window
        window.session.moveItems([.tab(second)], to: .init(.favorites(h.profileID), position: .start))
        #expect(h.registry.dispatch(.selectTab1, origin: .keyboard))
        await h.settle()
        #expect(window.session.organization?.selectedTab?.id == second)
        #expect(h.registry.dispatch(.selectTab1, origin: .keyboard))
        #expect(h.registry.dispatch(.selectTab2, origin: .keyboard))
        #expect(h.registry.dispatch(.selectTab1, origin: .keyboard))
        await h.settle()
        #expect(window.session.organization?.selectedTab?.id == second)
        window.favorites.activate(at: 1)
        window.session.selectTab(second)
        await h.settle()
        #expect(window.session.organization?.selectedTab?.id == second)
        #expect(window.session.organization?.favorites.map(\.node) == [.tab(second), .tab(first)])
        #expect(h.registry.isEnabled(.selectTab9))
    }

    @Test("Numbered commands use the profile selected earlier in the same queue")
    func numberedAfterProfileSwitch() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let first = try await h.add("https://alpha.example.test/")
        let profile = await h.store.createProfile(name: "Other")
        let other = try await h.store.createSpace(name: "Other", profileID: profile)
        h.window.session.activateSpace(other)
        await h.settle()
        let second = try await h.add("https://beta.example.test/")
        h.window.session.activateSpace(h.spaceID)
        #expect(h.registry.dispatch(.selectTab1, origin: .keyboard))
        await h.settle()
        #expect(h.window.session.organization?.selectedTab?.id == first)
        #expect(h.window.session.organization?.selectedTab?.id != second)
    }

    @Test("Grid reorder previews are reversible and commits preserve stable tab identity")
    func reorderAndCancel() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let first = try await h.add("https://alpha.example.test/")
        let second = try await h.add("https://beta.example.test/")
        let grid = h.window.favorites.grid
        let payload = FavoritesDragPayload(profileID: h.profileID, nodes: [.tab(first)])
        let destination = NSPoint(x: grid.bounds.width + 1, y: 20)
        #expect(grid.dropTarget.update(payload, at: destination))
        #expect(grid.hasDropPreview)
        grid.layoutSubtreeIfNeeded()
        grid.dropTarget.end()
        grid.layoutSubtreeIfNeeded()
        #expect(!grid.hasDropPreview)
        #expect(h.window.session.organization?.favorites.map(\.node) == [.tab(first), .tab(second)])
        #expect(grid.dropTarget.perform(payload, at: destination))
        await h.settle()
        #expect(h.window.session.organization?.favorites.map(\.node) == [.tab(second), .tab(first)])
        #expect(grid.tiles[0].item.tab.id == second)
    }

    @Test("The list adapter moves a Today tab into an empty Favorites grid without duplicating it")
    func listDrop() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let window = h.window
        window.session.openTab(url: URL(string: "https://incoming.example.test/")!)
        await h.settle()
        let id = try #require(window.session.organization?.selectedTab?.id)
        let occurrence = window.session.snapshot?.selectedOccurrenceID
        let grid = window.favorites.grid
        let payload = FavoritesDragPayload(profileID: h.profileID, nodes: [.tab(id)])
        #expect(grid.dropTarget.update(payload, at: .zero))
        #expect(window.sidebar.showsEmptyFavoritesDropZone)
        #expect(grid.dropTarget.perform(payload, at: .zero))
        await h.settle()
        #expect(window.session.organization?.favorites.map(\.node) == [.tab(id)])
        #expect(window.session.organization?.today.contains { $0.node == .tab(id) } == false)
        #expect(window.session.snapshot?.selectedOccurrenceID == occurrence)
        #expect(!window.sidebar.showsEmptyFavoritesDropZone)
    }

    @Test("Drop validation rejects a foreign profile, missing nodes, folders and duplicate IDs atomically")
    func rejectedDrops() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let target = h.window.favorites.grid.dropTarget
        let bad: [FavoritesDragPayload] = [
            .init(profileID: ProfileID(), nodes: [.tab(id)]),
            .init(profileID: h.profileID, nodes: [.tab(TabID())]),
            .init(profileID: h.profileID, nodes: [.folder(FolderID())]),
            .init(profileID: h.profileID, nodes: [.tab(id), .tab(id)]),
            .init(profileID: h.profileID, nodes: [])
        ]
        for payload in bad {
            #expect(!target.update(payload, at: .zero))
            #expect(!target.perform(payload, at: .zero))
        }
        #expect(h.window.favorites.grid.items.map { $0.tab.id } == [id])
    }

    @Test("Late drop execution cannot move items into another profile")
    func staleDrop() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let window = h.window
        let payload = FavoritesDragPayload(profileID: h.profileID, nodes: [.tab(id)])
        let profile = await h.store.createProfile(name: "Other")
        let space = try await h.store.createSpace(name: "Other", profileID: profile)
        window.session.activateSpace(space)
        // Feedback uses the displayed snapshot; execution revalidates after the pending switch.
        #expect(window.favorites.grid.dropTarget.perform(payload, at: .zero))
        await h.settle()
        #expect(window.favorites.grid.items.isEmpty)
    }

    @Test("SITE media state reaches the tile, preserving unknown audibility as unknown")
    func audioIndicator() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        try await h.add("https://alpha.example.test/")
        let surface = try #require(h.window.session.selectedSurface)
        surface.media = .init(playback: .playing, isAudible: true, isAudioMuted: false)
        h.window.siteControls.refreshMedia(surface)
        for _ in 0..<20 where h.window.favorites.grid.items[0].isAudible != true { await Task.yield() }
        #expect(h.window.favorites.grid.items[0].isAudible == true)
        surface.media = .init(playback: .playing)
        h.window.siteControls.refreshMedia(surface)
        for _ in 0..<20 where h.window.favorites.grid.items[0].isAudible != nil { await Task.yield() }
        #expect(h.window.favorites.grid.items[0].isAudible == nil)
    }

    @Test("Engine favicon events use the injected resolver and retain the home icon when navigating away")
    func faviconEvents() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        try await h.add("https://alpha.example.test/")
        let window = h.window
        let surface = try #require(window.session.selectedSurface)
        let image = NSImage(size: .init(width: 16, height: 16))
        var requests = 0
        window.favorites.icons.resolve = { candidate, url in
            #expect(candidate.profileID == h.profileID)
            #expect(url.host == "icons.example.test")
            requests += 1
            return image
        }
        surface.faviconURL = URL(string: "https://icons.example.test/icon.png")!
        surface.onChange?()
        await h.settle()
        for _ in 0..<20 where window.favorites.grid.items[0].favicon == nil { await Task.yield() }
        #expect(window.favorites.grid.items[0].favicon === image)
        let originalRequests = requests
        window.favorites.render()
        await Task.yield()
        #expect(requests == originalRequests)
        surface.navigate(to: URL(string: "https://away.example.test/")!)
        await h.settle()
        #expect(window.favorites.grid.items[0].favicon === image)
        #expect(requests == originalRequests)
    }

    @Test("Settled undecodable home favicons complete without an exclusivity conflict and retain known pixels")
    func undecodableFavicon() async throws {
        // DAILY-1 P1 (SIGABRT, `_swift_reportExclusivityConflict` in `FavoriteIconPipeline`): the
        // former default resolver decoded inline images only. A nil completion read `entries`
        // inside its own write. Keep that crash witness while retaining the last known home
        // pixels when a later metadata update cannot provide an image.
        let h = try await FavoritesHarness(); defer { h.close() }
        try await h.add("https://alpha.example.test/")
        let window = h.window
        let surface = try #require(window.session.selectedSurface)
        let icons = window.favorites.icons
        var completions = 0
        let render = icons.onChange
        icons.onChange = { completions += 1; render?() }
        let image = NSImage(size: .init(width: 16, height: 16))
        var answers: [NSImage?] = [nil, image, nil]
        icons.resolve = { _, url in
            #expect(FavoriteIconPipeline<SiteSyntheticSurface>.inlineImage(url) == nil)
            return answers.removeFirst()
        }
        for (index, name) in ["first", "second", "third"].enumerated() {
            surface.faviconURL = URL(string: "https://icons.example.test/\(name).png")!
            surface.onChange?()
            await h.settle()
            for _ in 0..<50 where completions <= index { await Task.yield() }
            #expect(completions == index + 1)
            #expect(window.favorites.grid.items[0].favicon === (index >= 1 ? image : nil))
        }
        #expect(answers.isEmpty)
    }

    @Test("Default favicon decoder never reads file or remote URLs and rejects oversized inline data")
    func safeInlineFavicon() {
        typealias Pipeline = FavoriteIconPipeline<SiteSyntheticSurface>
        #expect(Pipeline.inlineImage(URL(string: "https://icons.example.test/icon.png")!) == nil)
        #expect(Pipeline.inlineImage(URL(fileURLWithPath: "/not-read/favicon.png")) == nil)
        #expect(Pipeline.inlineImage(URL(string: "data:text/plain;base64,SGVsbG8=")!) == nil)
        #expect(Pipeline.inlineImage(URL(string: "data:image/png;base64," + String(repeating: "A", count: 262_145))!) == nil)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = bitmap.representation(using: .png, properties: [:])!
        #expect(Pipeline.inlineImage(URL(string: "data:image/png;base64," + data.base64EncodedString())!) != nil)
    }

    @Test("A delayed favicon completion from the former profile cannot populate the new grid")
    func staleFavicon() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        try await h.add("https://alpha.example.test/")
        let window = h.window
        let surface = try #require(window.session.selectedSurface)
        var completion: CheckedContinuation<NSImage?, Never>?
        window.favorites.icons.resolve = { _, _ in await withCheckedContinuation { completion = $0 } }
        surface.faviconURL = URL(string: "https://icons.example.test/stale.png")!
        surface.onChange?()
        await h.settle()
        for _ in 0..<20 where completion == nil { await Task.yield() }
        #expect(completion != nil)
        let profile = await h.store.createProfile(name: "Other")
        let space = try await h.store.createSpace(name: "Other", profileID: profile)
        window.session.activateSpace(space)
        await h.settle()
        completion?.resume(returning: NSImage(size: .init(width: 16, height: 16)))
        for _ in 0..<5 { await Task.yield() }
        #expect(window.favorites.grid.items.isEmpty)
    }

    @Test("Context cancellation clears object authority and palette origin cannot remove a favorite")
    func closedMenuAuthority() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let feature = try #require(h.window.favorites)
        _ = try #require(feature.contextMenu(for: id))
        #expect(h.registry.dispatch(.removeFavorite, origin: .palette))
        await h.settle()
        #expect(feature.grid.items.map { $0.tab.id } == [id])
        feature.menuController?.onClose?()
        #expect(feature.currentMenuTab == nil)
        #expect(!h.registry.dispatch(.removeFavorite, origin: .contextMenu))
    }

    @Test("An accepted context action survives AppKit closing the menu before or after invocation", arguments: [true, false])
    func menuActionLifetime(closeFirst: Bool) async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let feature = try #require(h.window.favorites)
        let menu = try #require(feature.contextMenu(for: id))
        let presenter = try #require(feature.menuController)
        if closeFirst { presenter.menuDidClose(menu) }
        menu.performActionForItem(at: menu.items.firstIndex { $0.identifier?.rawValue == "removeFavorite" }!)
        if !closeFirst { presenter.menuDidClose(menu) }
        await h.settle()
        #expect(feature.grid.items.isEmpty)
        #expect(feature.currentMenuTab == nil)
    }

    @Test("Favorite renaming survives queued page metadata and rejects a removed object at execution")
    func queuedRename() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let window = h.window
        window.session.renameTab(id, to: "Earlier metadata")
        window.session.renameFavorite(id, to: "User title", inProfile: h.profileID, fromSpace: h.spaceID)
        await h.settle()
        #expect(window.session.organization?.tab(id)?.customTitle == "User title")
        window.session.removeFromFavorites([id])
        window.session.renameFavorite(id, to: "Must be ignored", inProfile: h.profileID, fromSpace: h.spaceID)
        await h.settle()
        #expect(window.session.organization?.tab(id)?.customTitle == "User title")
    }

    @Test("A pending metadata update does not flicker or reject drag feedback")
    func dragDuringMetadataUpdate() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        let window = h.window
        window.session.renameTab(id, to: "Updating")
        #expect(window.session.hasPendingCommands)
        let payload = FavoritesDragPayload(profileID: h.profileID, nodes: [.tab(id)])
        #expect(window.favorites.grid.dropTarget.update(payload, at: .zero))
        #expect(window.favorites.grid.hasDropPreview)
        window.favorites.grid.dropTarget.end()
        await h.settle()
    }

    @Test("Disabled tiles do not intercept pointer events and termination freezes Favorites controls")
    func disabledHitTesting() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        try await h.add("https://alpha.example.test/")
        let tile = h.window.favorites.grid.tiles[0]
        #expect(tile.hitTest(NSPoint(x: tile.frame.midX, y: tile.frame.midY)) === tile)
        h.window.freezeCommandsForTermination()
        #expect(!tile.commandsEnabled)
        #expect(tile.hitTest(NSPoint(x: tile.frame.midX, y: tile.frame.midY)) == nil)
        #expect(!tile.accessibilityPerformPress())
    }

    @Test("An ordinal that disappears before execution neither selects nor invokes a focus callback")
    func missingOrdinalCallback() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let id = try await h.add("https://alpha.example.test/")
        var focused = false
        h.window.session.removeFromFavorites([id])
        h.window.session.selectFavorite(at: 0) { _ in focused = true }
        await h.settle()
        #expect(!focused)
    }


    @Test("An incoming list tab reserves its extra grid row and cancellation restores the Space page")
    func dropReservesRows() async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        for index in 0..<4 { try await h.add("https://tile\(index).example.test/") }
        let window = h.window
        window.session.openTab(url: URL(string: "https://incoming.example.test/")!)
        await h.settle()
        let id = try #require(window.session.organization?.selectedTab?.id)
        window.sidebar.layoutSubtreeIfNeeded()
        let initialHeight = window.sidebar.geometry.favoritesFrame.height
        let grid = window.favorites.grid
        let payload = FavoritesDragPayload(profileID: h.profileID, nodes: [.tab(id)])
        #expect(grid.dropTarget.update(payload, at: NSPoint(x: grid.bounds.width, y: 20)))
        window.sidebar.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        #expect(window.sidebar.geometry.favoritesFrame.height > initialHeight)
        #expect(window.sidebar.geometry.favoriteColumns == grid.geometry.favoriteColumns)
        grid.dropTarget.end()
        window.sidebar.layoutSubtreeIfNeeded()
        #expect(window.sidebar.geometry.favoritesFrame.height == initialHeight)
        #expect(window.sidebar.favoritePreviewCount == nil)
    }


    @Test("Router-delayed object commands retain their target and discard same-context rejected invocations", arguments: [false, true])
    func queuedMenuCannotRetarget(dropDuringDelivery: Bool) async throws {
        let h = try await FavoritesHarness(); defer { h.close() }
        let first = try await h.add("https://alpha.example.test/")
        let second = try await h.add("https://beta.example.test/")
        let window = h.window
        var inspectDuringPresentation: (() -> Void)?
        var unblock: CheckedContinuation<Void, Never>?
        let router = BrowserWindowRouter<BrowserWindowController<SiteSyntheticEngine>>(create: { id in
            if id == window.id { return window }
            let next = BrowserWindowController(id: id, store: h.store, spaceID: h.spaceID,
                engine: h.engine, onClose: {}, onActivate: {})
            next.session.onError = { _ in }
            await next.session.waitForPendingCommands()
            return next
        }, present: { candidate, _ in
            if candidate === window { inspectDuringPresentation?() }
        }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        window.favorites.bind(to: registry)
        inspectDuringPresentation = {
            let menu = window.favorites.contextMenu(for: first)!
            menu.performActionForItem(at: menu.items.firstIndex { $0.identifier?.rawValue == "removeFavorite" }!)
            if dropDuringDelivery {
                // Keep a no-op session command pending through the router's delivery check.
                // Its completion preserves the exact context, so context-only cleanup is insufficient.
                window.session.enqueue { _ in await withCheckedContinuation { unblock = $0 } }
            } else {
                // This later menu must not replace the accepted command's object identity.
                _ = window.favorites.contextMenu(for: second)
            }
        }
        let id = try #require(router.newWindow(id: window.id))
        router.perform(in: id) { _ in }
        _ = router.newWindow()
        await router.waitForPendingCommands()
        if dropDuringDelivery {
            for _ in 0..<100 where unblock == nil { await Task.yield() }
            try #require(unblock).resume()
        }
        await window.session.waitForPendingCommands()
        if dropDuringDelivery {
            let menu = try #require(window.favorites.contextMenu(for: second))
            menu.performActionForItem(at: menu.items.firstIndex { $0.identifier?.rawValue == "removeFavorite" }!)
            await window.session.waitForPendingCommands()
            #expect(window.session.organization?.favorites.map(\.node) == [.tab(first)])
        } else {
            #expect(window.session.organization?.favorites.map(\.node) == [.tab(second)])
        }
    }

}
}
