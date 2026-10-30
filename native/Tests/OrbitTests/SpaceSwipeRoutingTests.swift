import AppKit
import BrowserCore
import BrowserShell
import QuartzCore
import Testing
@testable import Orbit

@MainActor
private final class SwipeRoutingWindow: NSWindow {
    // A synthetic responder owner, never ordered on screen or made key.
    override var isKeyWindow: Bool { true }
    override var isVisible: Bool { true }
}

@MainActor
private final class SwipeReviewPaintMarker: NSView {
    let fill: NSColor
    init(frame: NSRect, fill: NSColor) {
        self.fill = fill
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
    }
}

@MainActor private var swipePacketTime: UInt64 = 1_000_000_000

@MainActor
private func rawScroll(_ phase: NSEvent.Phase, x: Int32 = 0, y: Int32 = 0,
                    momentum: NSEvent.Phase = []) throws -> NSEvent {
    let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: y, wheel2: x, wheel3: 0))
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    let scrollPhase: Int64 = phase.contains(.began) ? 1 : phase.contains(.changed) ? 2
        : phase.contains(.ended) ? 4 : phase.contains(.cancelled) ? 8 : phase.contains(.mayBegin) ? 128 : 0
    let momentumPhase: Int64 = momentum.contains(.began) ? 1 : momentum.contains(.changed) ? 2
        : momentum.contains(.ended) ? 3 : 0
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
    // CGEvent's unposted fixture defaults to timestamp zero. Real trackpad packets carry
    // monotonic timestamps, required by the pager's 100 ms velocity buffer.
    swipePacketTime += 20_000_000
    cg.timestamp = swipePacketTime
    let event = try #require(NSEvent(cgEvent: cg))
    #expect(event.phase == phase)
    #expect(event.momentumPhase == momentum)
    return event
}

// Geometry scenarios specify horizontal travel in display points. Raw arbitration/handoff
// scenarios use rawScroll so native vectors and lossless replay assertions remain unchanged.
@MainActor
private func scroll(_ phase: NSEvent.Phase, x: Int32 = 0, y: Int32 = 0,
                    momentum: NSEvent.Phase = []) throws -> NSEvent {
    try rawScroll(phase, x: x * 2, y: y, momentum: momentum)
}

@MainActor
private func copyQueuedScroll(_ event: NSEvent) -> NSEvent {
    let cg = event.cgEvent!.copy()!
    let source = CGEventSource(stateID: .privateState)!
    source.userData = event.cgEvent!.getIntegerValueField(.eventSourceUserData)
    cg.setSource(source)
    return NSEvent(cgEvent: cg)!
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SpaceSwipeRoutingTests {
    private func fixture(crossProfile: Bool = false) async throws -> (SwipeRoutingWindow, BrowserSidebarView, BrowserSessionDocument, SpaceID) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic swipe routing")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let secondProfile = crossProfile ? await store.createProfile(name: "Other synthetic profile") : profile
        _ = try await store.createSpace(name: "Second", profileID: secondProfile)
        let windowID = try await store.createWindow(activeSpaceID: first)
        let context = try await store.captureContext(in: windowID)
        let window = SwipeRoutingWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640),
                                        styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sidebar = BrowserSidebarView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(sidebar)
        sidebar.render(catalog: await store.catalogSnapshot(), activeSpaceID: first,
                       organization: try await store.organizationSnapshot(from: context))
        sidebar.layoutSubtreeIfNeeded()
        let document = await store.sessionDocument()
        sidebar.spaceSwipe.loadDocument = { document }
        sidebar.spaceSwipe.clock = { 10 }
        sidebar.spaceSwipe.automaticallyAdvances = false
        return (window, sidebar, document, first)
    }

    @Test("Unphased wheels bypass pending, owned and retired swipe streams without changing their state")
    func unphasedWheelsBypassSwipeRouting() async throws {
        for inside in [true, false] {
            for state in ["idle", "pending", "horizontal", "settling", "retired", "native", "creation"] {
                let (window, sidebar, _, _) = try await fixture()
                defer { sidebar.spaceSwipe.detach(); window.close() }
                let swipe = sidebar.spaceSwipe
                var posted: [NSEvent] = []
                swipe.scrollInput.postNativeEvent = { posted.append($0) }
                if state == "creation" { swipe.presentCreationPage() }
                else if state != "idle" {
                    _ = swipe.routeScroll(try rawScroll(.began), inside: true)
                    if ["horizontal", "settling", "retired"].contains(state) {
                        _ = swipe.routeScroll(try rawScroll(.changed, x: -80), inside: true)
                    }
                    if state == "settling" { _ = swipe.routeScroll(try rawScroll(.ended), inside: true) }
                    if state == "retired" { swipe.cancel() }
                    if state == "native" { _ = swipe.routeScroll(try rawScroll(.changed, y: -30), inside: true) }
                }
                let offset = swipe.offset
                let active = swipe.isActive
                let owned = swipe.scrollInput.hasOwnedSequence
                let postedCount = posted.count
                for precise in [false, true] {
                    for vector: (Int32, Int32) in [(0, -1), (0, -80), (-80, -1)] {
                        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                            wheelCount: 2, wheel1: vector.1, wheel2: vector.0, wheel3: 0))
                        let event = try #require(NSEvent(cgEvent: cg))
                        #expect(event.phase.isEmpty && event.momentumPhase.isEmpty)
                        #expect(event.hasPreciseScrollingDeltas == precise)
                        #expect(!swipe.routeScroll(event, inside: inside), "Wheel must pass immediately in \(state)")
                        #expect(!swipe.handleScroll(event, inside: inside), "Direct recognition must ignore wheels in \(state)")
                        #expect(swipe.offset == offset && swipe.isActive == active)
                        #expect(swipe.scrollInput.hasOwnedSequence == owned)
                        #expect(posted.count == postedCount)
                    }
                }
                // An independent wheel packet must not retire the phased gesture it interrupts.
                if state == "pending" {
                    #expect(swipe.routeScroll(try rawScroll(.changed, x: -80), inside: true))
                    #expect(swipe.offset == -40)
                    #expect(swipe.routeScroll(try rawScroll(.ended), inside: true))
                    #expect(swipe.routeScroll(try rawScroll([], momentum: .began), inside: true))
                    #expect(swipe.routeScroll(try rawScroll([], momentum: .ended), inside: true))
                }
            }
        }
    }

    @Test("Space swipe small vertical probation keeps original phases until direction is established")
    func spaceSwipeSmallVerticalProbation() async throws {
        for sign: Int32 in [-1, 1] {
            let (window, sidebar, _, _) = try await fixture()
            defer { sidebar.spaceSwipe.detach(); window.close() }
            var queued: [NSEvent] = []
            var sampleTime = 10.0
            var deliveryTimes: [Double] = []
            sidebar.spaceSwipe.clock = { sampleTime }
            sidebar.spaceSwipe.scrollInput.postNativeEvent = {
                queued.insert(copyQueuedScroll($0), at: 0)
                deliveryTimes.append(sampleTime)
            }
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, y: 7 * sign), inside: true)
            #expect(queued.isEmpty)
            for _ in 0..<10 { await Task.yield() }
            #expect(sidebar.swipePreviewCount == 0)
            sampleTime += 0.016
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -20), inside: true)
            #expect(sidebar.spaceSwipe.offset == -20)
            #expect(queued.isEmpty)
            sidebar.spaceSwipe.cancel()
            sampleTime = 11
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, y: 7 * sign), inside: true)
            #expect(queued.isEmpty)
            sampleTime += 0.016
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, y: 7 * sign), inside: true)
            #expect(queued.map(\.phase) == [.began, .changed, .changed])
            #expect(deliveryTimes == [11.016, 11.016, 11.016])
            #expect(queued.reduce(0) { $0 + $1.scrollingDeltaY } == CGFloat(14 * sign))
            for event in queued { #expect(!sidebar.spaceSwipe.routeScroll(event, inside: true)) }
            #expect(!sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true))
            #expect(!sidebar.spaceSwipe.routeScroll(try scroll([], y: 12 * sign, momentum: .changed), inside: true))
            #expect(!sidebar.spaceSwipe.routeScroll(try scroll([], momentum: .ended), inside: true))
            queued.removeAll()
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, y: 30 * sign), inside: true)
            #expect(queued.count == 2) // Large pure vertical motion waits for no extra sample.
        }
    }

    @Test("Space swipe Favorites use the destination profile and move with the list through layout and cancellation")
    func spaceSwipeWholeContentFavorites() async throws {
        let store = BrowserStore()
        let profileA = await store.createProfile(name: "Synthetic A")
        let profileB = await store.createProfile(name: "Synthetic B")
        let first = try await store.createSpace(name: "First", profileID: profileA)
        let second = try await store.createSpace(name: "Second", profileID: profileB)
        let windowID = try await store.createWindow(activeSpaceID: first)
        for space in [first, second] {
            try await store.activateSpace(space, in: windowID)
            let context = try await store.captureContext(in: windowID)
            let count = space == first ? 2 : 5
            var ids: [TabID] = []
            for index in 0..<count {
                let occurrence = try await store.openTab(url: URL(string: "https://synthetic.invalid/favorite/\(space)/\(index)")!, from: context, activate: index == count - 1)
                let document = await store.sessionDocument()
                ids.append(try #require(document.tabs.first { $0.occurrenceID == occurrence }).id)
            }
            _ = try await store.addToFavorites(ids, from: try await store.captureContext(in: windowID))
        }
        try await store.activateSpace(first, in: windowID)
        let document = await store.sessionDocument()
        let source = try #require(SpaceSwipePreview.favorites(document: document, spaceID: first, windowID: windowID))
        let target = try #require(SpaceSwipePreview.favorites(document: document, spaceID: second, windowID: windowID))
        #expect(source.profileID == profileA && target.profileID == profileB)
        #expect(source.items.count == 2 && target.items.count == 5)
        #expect(target.items.filter { $0.tab.isSelected }.count == 1)
        #expect(Set(source.items.map { $0.tab.id }).isDisjoint(with: target.items.map { $0.tab.id }))
        #expect(target.items.allSatisfy { $0.favicon == nil && !$0.tab.isLoadedInThisWindow && $0.tab.occurrenceID == nil })
        let window = SwipeRoutingWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sidebar = BrowserSidebarView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(sidebar)
        defer { sidebar.spaceSwipe.detach(); window.close() }
        sidebar.windowIdentifier = windowID.rawValue
        let grid = FavoritesGridView()
        grid.animatesChanges = false
        grid.autoresizingMask = [.width, .height]
        sidebar.favoritesContainer.addSubview(grid)
        grid.render(source.items, profileID: profileA)
        sidebar.favoriteCount = source.items.count
        sidebar.render(catalog: await store.catalogSnapshot(), activeSpaceID: first,
                       organization: try await store.organizationSnapshot(from: store.captureContext(in: windowID)))
        sidebar.layoutSubtreeIfNeeded()
        grid.frame = sidebar.favoritesContainer.bounds
        grid.layoutSubtreeIfNeeded()
        let sourceTile = try #require(grid.tiles.first)
        let viewport = try #require(sidebar.page.superview)
        let rest = sidebar.favoritesContainer.frame
        let urlFrame = sidebar.addressContainer.frame
        let footerFrame = sidebar.footer.frame
        #expect(sidebar.swipeContains(sidebar.favoritesContainer.convert(NSPoint(x: 30, y: 20), to: nil)))
        #expect(sidebar.swipeContains(sidebar.page.convert(NSPoint(x: 30, y: 20), to: nil)))
        #expect(!sidebar.swipeContains(sidebar.addressContainer.convert(NSPoint(x: 20, y: 10), to: nil)))
        #expect(!sidebar.swipeContains(sidebar.footer.convert(NSPoint(x: 20, y: 10), to: nil)))
        #expect(!sidebar.swipeContains(sidebar.convert(NSPoint(x: 241, y: 200), to: nil)))
        sidebar.spaceSwipe.loadDocument = { document }
        sidebar.spaceSwipe.clock = { 10 }
        sidebar.spaceSwipe.automaticallyAdvances = false
        let favoritesInside = sidebar.swipeContains(sourceTile.convert(NSPoint(x: 5, y: 5), to: nil))
        #expect(favoritesInside)
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: favoritesInside)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, y: 7), inside: favoritesInside)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -20), inside: favoritesInside)
        let incoming = try #require(viewport.subviews.compactMap { $0 as? FavoritesGridView }.first)
        #expect(incoming.items == target.items)
        #expect(!incoming.commandsEnabled && incoming.onSelect == nil && incoming.makeContextMenu == nil)
        // Native bitmap compositing of both real grid geometries, not only model offsets.
        let sourcePaint = SwipeReviewPaintMarker(frame: grid.bounds, fill: .red)
        sourcePaint.autoresizingMask = [.width, .height]
        grid.addSubview(sourcePaint)
        incoming.layoutSubtreeIfNeeded()
        let targetPaint = SwipeReviewPaintMarker(frame: incoming.bounds, fill: .blue)
        targetPaint.autoresizingMask = [.width, .height]
        incoming.addSubview(targetPaint)
        let targetPoint = NSPoint(x: incoming.frame.minX + 2, y: incoming.frame.minY + 10)
        #expect(viewport.bounds.contains(targetPoint))
        let bitmap = try #require(viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds))
        viewport.cacheDisplay(in: viewport.bounds, to: bitmap)
        let scaleX = CGFloat(bitmap.pixelsWide) / viewport.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / viewport.bounds.height
        let sourceColor = try #require(bitmap.colorAt(x: Int(30 * scaleX), y: Int(targetPoint.y * scaleY))?.usingColorSpace(.deviceRGB))
        let targetColor = try #require(bitmap.colorAt(x: Int(targetPoint.x * scaleX), y: Int(targetPoint.y * scaleY))?.usingColorSpace(.deviceRGB))
        #expect(sourceColor.redComponent > 0.8 && sourceColor.blueComponent < 0.2)
        #expect(targetColor.blueComponent > 0.8 && targetColor.redComponent < 0.2)
        sourcePaint.removeFromSuperview(); targetPaint.removeFromSuperview()

        for delta: Int32 in [-208, 108, 120] {
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: delta), inside: favoritesInside)
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            #expect(sidebar.favoritesContainer.frame.minX == rest.minX + sidebar.spaceSwipe.offset)
            #expect(sidebar.page.frame.minX == sidebar.spaceSwipe.offset)
            #expect(sidebar.addressContainer.frame == urlFrame && sidebar.footer.frame == footerFrame)
            #expect(grid.items == source.items && grid.tiles.first === sourceTile)
            #expect(commits == 0)
        }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: favoritesInside)
        sidebar.spaceSwipe.advance(to: 12)
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.favoritesContainer.frame == rest)
        #expect(viewport.subviews.count == 2 && sidebar.swipePreviewCount == 0)
        #expect(grid.tiles.first === sourceTile && grid.commandsEnabled)
        var selected: TabID?
        grid.onSelect = { selected = $0 }
        #expect(sourceTile.accessibilityPerformPress())
        #expect(selected == sourceTile.item.tab.id)
        #expect(await store.sessionDocument() == document)
        #expect(commits == 0)
        sidebar.showSpaceSwipe(offset: -100, space: document.spaces.first { $0.id == second },
                               content: .empty, favorites: target)
        sidebar.adoptSpaceSwipeDestination(second)
        let frozenSource = try #require(viewport.subviews.compactMap { $0 as? FavoritesGridView }.first)
        #expect(frozenSource.items == source.items && !frozenSource.commandsEnabled)
        grid.render(target.items, profileID: profileB)
        sidebar.favoriteCount = target.items.count
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.favoritesContainer.frame.minX == rest.minX + 140)
        #expect(frozenSource.frame.minX == rest.minX - 100)
        #expect(grid.dropTarget.profileID == profileB)
        sidebar.finishSpaceSwipe(committed: second)
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(viewport.subviews.count == 2)
        #expect(grid.items == target.items && grid.commandsEnabled)
        let targetTile = try #require(grid.tiles.first)
        #expect(targetTile.accessibilityPerformPress())
        #expect(selected == targetTile.item.tab.id)
        #expect(await store.sessionDocument() == document)
    }

    @Test("Space swipe independent queued recognition rejects a changed active Space or profile after settlement", arguments: [false, true])
    func spaceSwipeIndependentQueuedContextReplacement(crossProfile: Bool) async throws {
        let (window, sidebar, document, first) = try await fixture(crossProfile: crossProfile)
        defer { sidebar.spaceSwipe.detach(); window.close(); OrbitMotionPreferences.overrideReducedMotion = nil }
        var queue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { queue.insert(copyQueuedScroll($0), at: 0) }
        var complete: (@MainActor (Bool) -> Void)?
        sidebar.spaceSwipe.commit = { _, _, _, _, callback in complete = callback }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 80), inside: true)
        OrbitMotionPreferences.overrideReducedMotion = true
        _ = sidebar.spaceSwipe.advance(to: 12)
        let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
        sidebar.render(catalog: catalog, activeSpaceID: document.spaces.last?.id, organization: nil)
        let accepted = try #require(complete)
        accepted(true)
        for _ in 0..<20 { await Task.yield() }
        #expect(!queue.isEmpty)
        #expect(!sidebar.spaceSwipe.isActive)
        // A separate publication changes the semantic source before queued input is dequeued.
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
        for event in queue { #expect(sidebar.spaceSwipe.scrollInput.replay(event) == .discard) }
    }

    @Test("Space swipe idle queued recognition retires on resize or modal publication", arguments: [false, true])
    func spaceSwipeIdleReplayRevocation(modal: Bool) async throws {
        let (window, sidebar, document, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close(); OrbitMotionPreferences.overrideReducedMotion = nil }
        var queue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { queue.insert(copyQueuedScroll($0), at: 0) }
        var complete: (@MainActor (Bool) -> Void)?
        sidebar.spaceSwipe.commit = { _, _, _, _, callback in complete = callback }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 80), inside: true)
        OrbitMotionPreferences.overrideReducedMotion = true
        _ = sidebar.spaceSwipe.advance(to: 12)
        let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
        let target = document.spaces.last?.id
        sidebar.render(catalog: catalog, activeSpaceID: target, organization: nil)
        let accepted = try #require(complete)
        accepted(true)
        for _ in 0..<20 { await Task.yield() }
        #expect(!queue.isEmpty && !sidebar.spaceSwipe.isActive)
        if modal {
            sidebar.spaceSwipe.allowsInput = { false }
            sidebar.render(catalog: catalog, activeSpaceID: target, organization: nil)
            sidebar.spaceSwipe.allowsInput = { true }
        } else {
            let width = sidebar.frame.size.width
            sidebar.setFrameSize(.init(width: width + 20, height: sidebar.frame.size.height))
            sidebar.layoutSubtreeIfNeeded()
            sidebar.setFrameSize(.init(width: width, height: sidebar.frame.size.height))
            sidebar.layoutSubtreeIfNeeded()
        }
        for event in queue { #expect(sidebar.spaceSwipe.scrollInput.replay(event) == .discard) }
        #expect(sidebar.swipePreviewCount == 0)
    }

    @Test("Space swipe pending metadata and vertical phases never create an adjacent list")
    func spaceSwipePendingMetadataVerticalLayout() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true))
        for _ in 0..<10 { await Task.yield() }
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.superview?.subviews.compactMap { $0 as? SidebarSpacePageView }.count == 1)
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.swipePreviewCount == 0)
        #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.changed, y: -30), inside: true))
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true))
        for _ in 0..<10 { await Task.yield() }
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.layer?.affineTransform() == .identity)
        #expect(sidebar.page.frame.minX == 0)
    }

    @Test("Native Began initializes the pager; only Changed contributes half the raw displacement")
    func nativePhaseDisplacement() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        #expect(sidebar.spaceSwipe.handleScroll(try rawScroll(.began, x: -40), inside: true))
        #expect(sidebar.spaceSwipe.offset == 0)
        #expect(sidebar.spaceSwipe.handleScroll(try rawScroll(.changed, x: -40), inside: true))
        #expect(sidebar.spaceSwipe.offset == -20)
        #expect(sidebar.spaceSwipe.handleScroll(try rawScroll(.ended, x: -40), inside: true))
        #expect(sidebar.spaceSwipe.offset == -20)
    }

    @Test("Space swipe horizontal native geometry remains displaced through a sidebar layout")
    func spaceSwipeHorizontalLayoutGeometry() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -60), inside: true)
        for _ in 0..<10 { await Task.yield() }
        let preview = try #require(sidebar.page.superview?.subviews.compactMap { $0 as? SidebarSpacePageView }.first { $0 !== sidebar.page })
        let before = sidebar.page.layer?.frame.minX
        let previewBefore = preview.layer?.frame.minX
        #expect(before == -60)
        #expect(previewBefore == sidebar.swipeWidth - 60)
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        sidebar.displayIfNeeded()
        #expect(sidebar.page.layer?.frame.minX == before)
        #expect(preview.layer?.frame.minX == previewBefore)
        #expect(sidebar.page.frame.minX == -60)
        #expect(preview.frame.minX == sidebar.swipeWidth - 60)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: 20), inside: true)
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.page.frame.minX == -40)
        #expect(preview.frame.minX == sidebar.swipeWidth - 40)
        sidebar.setFrameSize(NSSize(width: 260, height: 660))
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.frame.minX == 0)
        #expect(sidebar.page.superview?.subviews.compactMap { $0 as? SidebarSpacePageView }.count == 1)

    }

    @Test("Space swipe pending metadata leaves native cached sidebar pixels unchanged")
    func spaceSwipePendingNativePaint() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let viewport = try #require(sidebar.page.superview)
        func paint() throws -> Data {
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            let bitmap = try #require(viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds))
            viewport.cacheDisplay(in: viewport.bounds, to: bitmap)
            return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let before = try paint()
        #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true))
        for _ in 0..<10 { await Task.yield() }
        let after = try paint()
        #expect(before == after)
        #expect(sidebar.swipePreviewCount == 0)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, y: -30), inside: true)
        #expect(try paint() == before)
    }

    @Test("Space swipe independent native scroll painting agrees with clipped page geometry")
    func spaceSwipeIndependentNativeClipPixels() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let source = sidebar.page
        let viewport = try #require(source.superview)
        func color(_ page: SidebarSpacePageView, _ value: NSColor) {
            let documentView = page.pageScrollView.documentView!
            documentView.addSubview(SwipeReviewPaintMarker(frame: documentView.bounds, fill: value))
        }
        func sample(_ x: CGFloat) throws -> NSColor {
            sidebar.layoutSubtreeIfNeeded()
            let bitmap = try #require(viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds))
            viewport.cacheDisplay(in: viewport.bounds, to: bitmap)
            let pixelX = Int(x / viewport.bounds.width * CGFloat(bitmap.pixelsWide))
            return try #require(bitmap.colorAt(x: pixelX, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        }
        func expectRed(_ value: NSColor) {
            // Cache display converts through the display profile; test opaque color dominance.
            #expect(value.alphaComponent > 0.9 && value.redComponent > 0.8 && value.redComponent - max(value.greenComponent, value.blueComponent) > 0.5, "Sample: \(value)")
        }
        func expectBlue(_ value: NSColor) {
            #expect(value.alphaComponent > 0.9 && value.blueComponent > 0.8 && value.blueComponent - max(value.greenComponent, value.redComponent) > 0.5, "Sample: \(value)")
        }
        color(source, NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1))
        expectRed(try sample(20))
        expectRed(try sample(viewport.bounds.width - 20))
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        #expect(sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -60), inside: true))
        for _ in 0..<10 { await Task.yield() }
        let destination = try #require(viewport.subviews.compactMap { $0 as? SidebarSpacePageView }.first { $0 !== source })
        color(destination, NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1))
        for _ in 0..<3 {
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            #expect(source.frame.minX == -60)
            #expect(destination.frame.minX == viewport.bounds.width - 60)
            #expect(viewport.layer?.masksToBounds == true)
            #expect(source.pageScrollView.convert(source.pageScrollView.bounds, to: viewport).minX == -60)
            #expect(destination.pageScrollView.convert(destination.pageScrollView.bounds, to: viewport).minX == viewport.bounds.width - 60)
            #expect(source.layer?.affineTransform() == .identity)
            #expect(destination.layer?.affineTransform() == .identity)
            #expect(source.layer?.animationKeys()?.isEmpty != false)
            #expect(destination.layer?.animationKeys()?.isEmpty != false)
            expectRed(try sample(20))
            expectRed(try sample(viewport.bounds.width - 61))
            expectBlue(try sample(viewport.bounds.width - 59))
            expectBlue(try sample(viewport.bounds.width - 20))
        }
        sidebar.spaceSwipe.cancel()
        #expect(viewport.subviews.compactMap { $0 as? SidebarSpacePageView }.count == 1)
        #expect(viewport.subviews.contains { $0 === sidebar.favoritesContainer })
        #expect(viewport.subviews.count == 2)
        #expect(source.frame == viewport.bounds)
        expectRed(try sample(viewport.bounds.width - 20))
    }

    @Test("Space swipe vertical up and down with mayBegin and diagonal pending intent preserve native list scrolling")
    func spaceSwipeVerticalPhaseMatrix() async throws {
        for delta: Int32 in [-30, 30] {
            let (window, sidebar, document, first) = try await fixture()
            let store = try BrowserStore(restoring: document)
            let windowID = try #require(document.windows.first?.id)
            for index in 0..<24 {
                let context = try await store.captureContext(in: windowID)
                _ = try await store.openTab(url: URL(string: "https://synthetic.invalid/row/\(index)")!, from: context, activate: false)
            }
            let context = try await store.captureContext(in: windowID)
            sidebar.render(catalog: await store.catalogSnapshot(), activeSpaceID: first,
                           organization: try await store.organizationSnapshot(from: context))
            sidebar.layoutSubtreeIfNeeded()
            let before = await store.sessionDocument()
            sidebar.spaceSwipe.loadDocument = { before }
            let list = sidebar.page.pageScrollView
            list.contentView.scroll(to: NSPoint(x: 0, y: 100))
            let origin = list.contentView.bounds.minY
            var commits = 0
            sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
            #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.mayBegin), inside: true))
            let began = try scroll(.began)
            #expect(!sidebar.spaceSwipe.handleScroll(began, inside: true))
            for _ in 0..<10 { await Task.yield() }
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            #expect(sidebar.swipePreviewCount == 0)
            #expect(!sidebar.spaceSwipe.handleScroll(try rawScroll(.changed, x: 4, y: 4), inside: true))
            for _ in 0..<10 { await Task.yield() }
            #expect(sidebar.swipePreviewCount == 0)
            let vertical = try scroll(.changed, y: delta)
            #expect(!sidebar.spaceSwipe.handleScroll(vertical, inside: true))
            // Routing leaves this event for AppKit. Move its viewport here without entering
            // AppKit's concurrent OS-event tracking loop in the hidden test process.
            let scrolledOrigin = origin + CGFloat(delta)
            list.contentView.scroll(to: NSPoint(x: 0, y: scrolledOrigin))
            #expect(list.contentView.bounds.minY == scrolledOrigin)
            let ended = try scroll(.ended)
            #expect(!sidebar.spaceSwipe.handleScroll(ended, inside: true))
            #expect(!sidebar.spaceSwipe.handleScroll(try scroll([], y: delta, momentum: .changed), inside: true))
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            for _ in 0..<10 { await Task.yield() }
            #expect(sidebar.swipePreviewCount == 0)
            #expect(sidebar.page.superview?.subviews.compactMap { $0 as? SidebarSpacePageView }.count == 1)
            #expect(sidebar.page.frame.minX == 0)
            #expect(sidebar.page.spaceID == first)
            #expect(list.contentView.bounds.minY == scrolledOrigin)
            #expect(commits == 0)
            #expect(await store.sessionDocument() == before)
            sidebar.spaceSwipe.detach()
            window.close()
        }
    }

    @Test("Space swipe restored startup and rapid ordinary hidden switches leave one native list")
    func spaceSwipeOrdinarySwitchCleanup() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
        let second = try #require(document.spaces.last?.id)
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: sidebar.organization)
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.page.superview?.subviews.compactMap { $0 as? SidebarSpacePageView }.count == 1)
        for id in [second, first, second] {
            sidebar.render(catalog: catalog, activeSpaceID: id, organization: nil)
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            #expect(!sidebar.isSwitchingSpace)
            #expect(sidebar.page.superview?.subviews.compactMap { $0 as? SidebarSpacePageView }.count == 1)
        }
        #expect(!sidebar.isSwitchingSpace)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.page.spaceID == second)
        #expect(sidebar.page.frame.minX == 0)
        #expect(sidebar.page.superview?.subviews.compactMap { $0 as? SidebarSpacePageView }.count == 1)
    }

    @Test("Space swipe late pending metadata cannot paint after vertical cancellation and ended")
    func spaceSwipeLateVerticalMetadata() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let source = sidebar.page
        var continuation: CheckedContinuation<BrowserSessionDocument, Never>?
        sidebar.spaceSwipe.loadDocument = { await withCheckedContinuation { continuation = $0 } }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true))
        for _ in 0..<10 { await Task.yield() }
        let finish = try #require(continuation)
        #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.changed, y: -30), inside: true))
        #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true))
        finish.resume(returning: document)
        for _ in 0..<10 { await Task.yield() }
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page === source)
        #expect(sidebar.page.spaceID == first)
        #expect(sidebar.page.frame.minX == 0)
        #expect(sidebar.page.superview?.subviews.compactMap { $0 as? SidebarSpacePageView }.count == 1)
        #expect(commits == 0)
        sidebar.spaceSwipe.loadDocument = { document }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try rawScroll(.changed, x: 4, y: 4), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
    }

    @Test("Space swipe neutral-start arbitration reserves Began through metadata pause and owns horizontal Changed")
    func spaceSwipeNeutralStartOwnership() async throws {
        let (window, sidebar, _, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var nativeQueue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { nativeQueue.insert(copyQueuedScroll($0), at: 0) }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        #expect(sidebar.spaceSwipe.routeScroll(try scroll(.mayBegin), inside: true))
        #expect(sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true))
        for _ in 0..<10 { await Task.yield() }
        #expect(nativeQueue.isEmpty)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.spaceSwipe.routeScroll(try scroll(.changed, y: 3), inside: true))
        #expect(nativeQueue.isEmpty)
        #expect(sidebar.swipePreviewCount == 0)
        for (delta, total): (Int32, CGFloat) in [(-20, -20), (-40, -60), (-40, -100)] {
            #expect(sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: delta), inside: true))
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            #expect(sidebar.spaceSwipe.offset == total)
            #expect(sidebar.page.frame.minX == total)
        }
        #expect(nativeQueue.isEmpty)
        #expect(commits == 0)
        #expect(sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true))
        sidebar.spaceSwipe.advance(to: 12)
        #expect(sidebar.page.spaceID == first)
        #expect(sidebar.page.frame.minX == 0)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(commits == 0)
        #expect(sidebar.spaceSwipe.routeScroll(try scroll([], x: -40, momentum: .changed), inside: true))
        #expect(nativeQueue.isEmpty)
    }

    @Test("Space swipe native handoff preserves original phases, exact deltas and target identities in both vertical directions")
    func spaceSwipeNativeVerticalHandoff() async throws {
        for direction: Int32 in [-1, 1] {
            let (window, sidebar, _, _) = try await fixture()
            defer { sidebar.spaceSwipe.detach(); window.close() }
            var nativeQueue: [NSEvent] = []
            sidebar.spaceSwipe.scrollInput.postNativeEvent = { nativeQueue.insert(copyQueuedScroll($0), at: 0) }
            let events = try [scroll(.mayBegin), scroll(.began), rawScroll(.changed, x: 2, y: 2 * direction),
                              scroll(.changed, y: 30 * direction)]
            for event in events {
                #expect(sidebar.spaceSwipe.routeScroll(event, inside: true))
                for _ in 0..<3 { await Task.yield() }
            }
            #expect(nativeQueue.count == events.count)
            for (actual, original) in zip(nativeQueue, events) {
                #expect(actual.phase == original.phase)
                #expect(actual.timestamp == original.timestamp)
                #expect(actual.windowNumber == original.windowNumber)
                #expect(!sidebar.spaceSwipe.routeScroll(actual, inside: true))
                #expect(actual.cgEvent?.getIntegerValueField(.eventSourceUserData) == original.cgEvent?.getIntegerValueField(.eventSourceUserData))
            }
            #expect(nativeQueue.count == events.count)
            #expect(nativeQueue.reduce(0) { $0 + $1.scrollingDeltaY } == CGFloat(32 * direction))
            #expect(nativeQueue.reduce(0) { $0 + $1.scrollingDeltaX } == 2)
            #expect(!sidebar.spaceSwipe.routeScroll(try scroll(.changed, y: 10 * direction), inside: true))
            #expect(!sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true))
            #expect(!sidebar.spaceSwipe.routeScroll(try scroll([], y: 10 * direction, momentum: .changed), inside: true))
            #expect(!sidebar.spaceSwipe.routeScroll(try scroll([], momentum: .ended), inside: true))
            #expect(!sidebar.spaceSwipe.isActive)
            #expect(sidebar.swipePreviewCount == 0)
            #expect(sidebar.page.frame.minX == 0)
        }
    }

    @Test("Space swipe ambiguous terminal streams hand off losslessly and repeated gestures reacquire horizontal ownership")
    func spaceSwipePendingTerminalAndRepeat() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var nativeQueue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { nativeQueue.insert(copyQueuedScroll($0), at: 0) }
        for terminal in [NSEvent.Phase.ended, .cancelled] {
            nativeQueue.removeAll()
            let events = try [scroll(.began), rawScroll(.changed, x: 4, y: 4), scroll(terminal)]
            for event in events { #expect(sidebar.spaceSwipe.routeScroll(event, inside: true)) }
            #expect(nativeQueue.count == events.count)
            #expect(zip(nativeQueue, events).allSatisfy { $0.phase == $1.phase && $0.timestamp == $1.timestamp })
            #expect(sidebar.swipePreviewCount == 0)
            #expect(!sidebar.spaceSwipe.isActive)
            nativeQueue.removeAll()
            #expect(sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true))
            for _ in 0..<10 { await Task.yield() }
            #expect(sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -60), inside: true))
            #expect(sidebar.spaceSwipe.offset == -60)
            #expect(nativeQueue.isEmpty)
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true)
            sidebar.spaceSwipe.advance(to: 12)
        }
    }

    @Test("Space swipe retired native replay cannot restart input after resize, modal or Space replacement")
    func spaceSwipeNativeReplayRevocation() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var nativeQueue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { nativeQueue.insert(copyQueuedScroll($0), at: 0) }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, y: 30), inside: true)
        #expect(nativeQueue.count == 2)
        let stale = nativeQueue
        sidebar.setFrameSize(NSSize(width: 260, height: 650))
        sidebar.layoutSubtreeIfNeeded()
        #expect(sidebar.spaceSwipe.scrollInput.replay(stale[0]) == .discard)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        #expect(sidebar.spaceSwipe.scrollInput.replay(stale[1]) == .discard)
        sidebar.spaceSwipe.allowsInput = { false }
        sidebar.render(catalog: .init(profiles: document.profiles, spaces: document.spaces), activeSpaceID: first,
                       organization: sidebar.organization)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(!sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: false))
    }

    @Test("Space swipe long ambiguous input falls back to native without dropping accumulated movement")
    func spaceSwipeAmbiguousBufferBound() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var nativeQueue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { nativeQueue.insert(copyQueuedScroll($0), at: 0) }
        #expect(sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true))
        for _ in 1..<SidebarScrollInputRouter.maximumPendingEvents {
            #expect(sidebar.spaceSwipe.routeScroll(try rawScroll(.changed, x: 1, y: 1), inside: true))
        }
        #expect(nativeQueue.count == SidebarScrollInputRouter.maximumPendingEvents)
        #expect(nativeQueue.first?.phase == .began)
        let expected = CGFloat(SidebarScrollInputRouter.maximumPendingEvents - 1)
        #expect(nativeQueue.reduce(0) { $0 + $1.scrollingDeltaX } == expected)
        #expect(nativeQueue.reduce(0) { $0 + $1.scrollingDeltaY } == expected)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(!sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true))
    }

    @Test("Space swipe cancellation discards the held stream but a fresh page gesture remains unowned")
    func spaceSwipePendingCancelAndPageBoundary() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var nativeQueue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { nativeQueue.insert(copyQueuedScroll($0), at: 0) }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        sidebar.spaceSwipe.cancel()
        #expect(sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -80), inside: true))
        #expect(sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true))
        #expect(sidebar.spaceSwipe.routeScroll(try scroll([], x: -40, momentum: .changed), inside: true))
        #expect(sidebar.spaceSwipe.routeScroll(try scroll([], momentum: .ended), inside: true))
        #expect(nativeQueue.isEmpty)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(!sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: false))
        #expect(!sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -80), inside: false))
        #expect(!sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: false))
        #expect(nativeQueue.isEmpty)
        #expect(sidebar.swipePreviewCount == 0)
    }

    @Test("Space swipe next neutral gesture is retained across delayed publication and stays reversible before its own Ended")
    func spaceSwipeDelayedPublicationChaining() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let store = try BrowserStore(restoring: document)
        let windowID = try #require(document.windows.first?.id)
        let session = BrowserWindowSession<ReviewSwipeSurface>(store: store, restoringWindowID: windowID) {
            ReviewSwipeSurface(profileID: $0, initialURL: $1)
        }
        await session.waitForPendingCommands()
        typealias Request = (target: SpaceID, catalog: BrowserCatalogSnapshot, lease: SpaceSwipeAdmission,
                             valid: @MainActor () -> Bool, completion: @MainActor (Bool) -> Void)
        var requests: [Request] = []
        var nativeQueue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { nativeQueue.insert(copyQueuedScroll($0), at: 0) }
        sidebar.spaceSwipe.commit = { requests.append(($0, $1, $2, $3, $4)) }
        var nativeDeliveries: [NSEvent] = []
        func drainReplay() {
            var steps = 0
            while !nativeQueue.isEmpty && steps < 1024 {
                let event = nativeQueue.removeFirst()
                if !sidebar.spaceSwipe.routeScroll(event, inside: true) { nativeDeliveries.append(event) }
                steps += 1
            }
            #expect(nativeQueue.isEmpty)
        }
        func publish(_ index: Int) async {
            let request = requests[index]
            session.activateSpaceFromSwipe(request.target, catalog: request.catalog, admission: request.lease,
                                           isCurrent: request.valid) { accepted in
                if accepted { sidebar.render(catalog: session.catalog, activeSpaceID: session.snapshot?.activeSpaceID,
                                              organization: session.organization) }
                request.completion(accepted)
            }
            await session.waitForPendingCommands()
            for _ in 0..<20 { await Task.yield() }
            drainReplay()
        }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        #expect(requests.isEmpty)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        #expect(requests.count == 1)
        #expect(session.snapshot?.activeSpaceID == first)
        // This new stream used to lose its Began while the prior store command was pending.
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 20), inside: true)
        await publish(0)
        #expect(session.snapshot?.activeSpaceID == document.spaces.last?.id)
        #expect(requests.count == 1)
        #expect(!sidebar.spaceSwipe.isSettling)
        let partial = sidebar.spaceSwipe.offset
        #expect(partial > 0)
        let nearlyComplete = sidebar.swipeWidth - 5
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: Int32(nearlyComplete - partial)), inside: true)
        let held = sidebar.spaceSwipe.offset
        for _ in 0..<10 { await Task.yield() }
        #expect(sidebar.spaceSwipe.offset == held)
        #expect(requests.count == 1)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -Int32(held)), inside: true)
        #expect(abs(sidebar.spaceSwipe.offset) < 1)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(requests.count == 1)
        #expect(session.snapshot?.activeSpaceID == document.spaces.last?.id)
        #expect(sidebar.swipePreviewCount == 0)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 100), inside: true)
        #expect(requests.count == 1)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        #expect(requests.count == 2)
        await publish(1)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(session.snapshot?.activeSpaceID == first)
        #expect(requests.count == 2)
        #expect(nativeQueue.isEmpty)
        #expect(nativeDeliveries.isEmpty)
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Space swipe queued vertical gesture delivers zero Began, Ended and momentum once after publication")
    func spaceSwipeQueuedVerticalPhaseDelivery() async throws {
        let (window, sidebar, document, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var replayQueue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { replayQueue.insert(copyQueuedScroll($0), at: 0) }
        var completion: (@MainActor (Bool) -> Void)?
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, callback in commits += 1; completion = callback }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        let held = try [scroll(.began), scroll(.changed, y: 30), scroll(.ended),
                        scroll([], momentum: .began), scroll([], y: 20, momentum: .changed), scroll([], momentum: .ended)]
        for event in held { #expect(sidebar.spaceSwipe.routeScroll(event, inside: true)) }
        #expect(commits == 1)
        #expect(replayQueue.isEmpty)
        sidebar.render(catalog: .init(profiles: document.profiles, spaces: document.spaces),
                       activeSpaceID: document.spaces.last?.id, organization: nil)
        let accepted = try #require(completion)
        accepted(true)
        for _ in 0..<20 { await Task.yield() }
        var native: [NSEvent] = []
        var steps = 0
        while !replayQueue.isEmpty && steps < 32 {
            let event = replayQueue.removeFirst()
            if !sidebar.spaceSwipe.routeScroll(event, inside: true) { native.append(event) }
            steps += 1
        }
        #expect(replayQueue.isEmpty)
        #expect(native.count == held.count)
        #expect(zip(native, held).allSatisfy { $0.phase == $1.phase && $0.momentumPhase == $1.momentumPhase })
        #expect(native.reduce(0) { $0 + $1.scrollingDeltaY } == 50)
        #expect(commits == 1)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.frame.minX == 0)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 60), inside: true)
        #expect(sidebar.spaceSwipe.offset == 60)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(commits == 1)
    }

    @Test("Space swipe phased routing consumes horizontal and momentum, cancels without late activation")
    func spaceSwipeRouteCancellation() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        #expect(sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -30), inside: true))
        for _ in 0..<10 { await Task.yield() }
        #expect(sidebar.swipePreviewCount == 1)
        #expect(sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -55), inside: true))
        #expect(sidebar.spaceSwipe.offset < -30)
        #expect(sidebar.spaceSwipe.handleScroll(try scroll(.cancelled), inside: true))
        sidebar.spaceSwipe.advance(to: 12)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.layer?.affineTransform() == .identity)
        #expect(sidebar.page.frame.minX == 0)
        #expect(commits == 0)
        #expect(sidebar.spaceSwipe.handleScroll(try scroll([], x: -40, momentum: .changed), inside: true))
    }

    @Test("Space swipe second began retakes spring presentation without jumping; resize retires it")
    func spaceSwipeRouteRetakeResize() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true)
        #expect(sidebar.spaceSwipe.isSettling)
        sidebar.spaceSwipe.advance(to: 10.02)
        let presentation = sidebar.spaceSwipe.offset
        sidebar.spaceSwipe.clock = { 10.02 }
        #expect(sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true))
        #expect(!sidebar.spaceSwipe.isSettling)
        #expect(abs(sidebar.spaceSwipe.offset - presentation) < 0.001)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 20), inside: true)
        #expect(sidebar.spaceSwipe.offset > presentation)
        sidebar.setFrameSize(NSSize(width: 260, height: 640))
        sidebar.layoutSubtreeIfNeeded()
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.layer?.affineTransform() == .identity)
        #expect(sidebar.page.frame.minX == 0)
        for _ in 0..<10 { await Task.yield() }
        #expect(commits == 0)
        #expect(sidebar.swipePreviewCount == 0)
    }

    @Test("Space swipe retake between display callbacks starts from the last presented body",
          arguments: [1.0 / 120, 1.0 / 60, 0.06])
    func spaceSwipeRetakeBetweenDisplayCallbacks(callbackGap: Double) async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true)
        _ = sidebar.spaceSwipe.advance(to: 10.02)
        let presented = sidebar.page.frame.minX
        #expect(abs(presented - sidebar.spaceSwipe.offset) < 0.001)
        // Main-thread work may delay the next display callback. Wall-clock spring progress
        // has never been presented and must not become an input discontinuity on retake.
        sidebar.spaceSwipe.clock = { 10.02 + callbackGap }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        #expect(abs(sidebar.spaceSwipe.offset - presented) < 0.001)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 6), inside: true)
        #expect(abs(sidebar.page.frame.minX - (presented + 6)) < 0.001)
        #expect(abs(sidebar.spaceSwipe.offset - (presented + 6)) < 0.001)
    }

    @Test("Independent retake keeps actual body and Favorites frames across callback gaps", arguments: [0.0, 1.0 / 120, 1.0 / 60, 0.06, 0.24])
    func reviewRetakeGeometry(callbackGap: Double) async throws {
        for width: CGFloat in [240, 332] {
            let (window, sidebar, _, _) = try await fixture()
            defer { sidebar.spaceSwipe.detach(); window.close() }
            sidebar.setFrameSize(NSSize(width: width, height: 640))
            sidebar.layoutSubtreeIfNeeded()
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
            for _ in 0..<10 { await Task.yield() }
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true)
            _ = sidebar.spaceSwipe.advance(to: 10.02)
            let body = sidebar.page.frame.minX
            let favorites = sidebar.favoritesContainer.frame.minX
            sidebar.spaceSwipe.clock = { 10.02 + callbackGap }
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
            if width == 240 && callbackGap == 0.06 {
                print("REVIEW_RETAKE_OLD_OR_FIXED_JUMP=\(sidebar.spaceSwipe.offset - body)")
            }
            #expect(abs(sidebar.spaceSwipe.offset - body) < 0.001)
            #expect(abs(sidebar.page.frame.minX - body) < 0.001)
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 6), inside: true)
            #expect(abs(sidebar.page.frame.minX - body - 6) < 0.001)
            #expect(abs(sidebar.favoritesContainer.frame.minX - favorites) < 0.001)
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -12), inside: true)
            #expect(abs(sidebar.page.frame.minX - body + 6) < 0.001)
            _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true)
            _ = sidebar.spaceSwipe.advance(to: 12)
            #expect(sidebar.page.frame.minX == 0)
            #expect(sidebar.swipePreviewCount == 0)
        }
    }

    @Test("Space swipe vertical phases pass through; target deletion and detachment discard overlays")
    func spaceSwipeRouteVerticalDeletion() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.began, x: 1, y: 30), inside: true))
        #expect(!sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -90), inside: true))
        #expect(sidebar.swipePreviewCount == 0)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -80), inside: true)
        for _ in 0..<10 { await Task.yield() }
        sidebar.render(catalog: .init(profiles: document.profiles, spaces: document.spaces.filter { $0.id == first }),
                       activeSpaceID: first, organization: nil)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.layer?.affineTransform() == .identity)
        #expect(sidebar.page.frame.minX == 0)
        sidebar.removeFromSuperview()
        for _ in 0..<10 { await Task.yield() }
        #expect(sidebar.swipePreviewCount == 0)
    }

    @Test("Space swipe detachment rejects late metadata and external selection retires settlement")
    func spaceSwipeLateMetadataAndExternalSelection() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var continuation: CheckedContinuation<BrowserSessionDocument, Never>?
        sidebar.spaceSwipe.loadDocument = { await withCheckedContinuation { continuation = $0 } }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        let resume = try #require(continuation)
        sidebar.removeFromSuperview()
        resume.resume(returning: document)
        for _ in 0..<10 { await Task.yield() }
        #expect(sidebar.swipePreviewCount == 0)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(commits == 0)
        window.contentView!.addSubview(sidebar)
        sidebar.spaceSwipe.loadDocument = { document }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        let second = try #require(document.spaces.first { $0.id != first }?.id)
        sidebar.render(catalog: .init(profiles: document.profiles, spaces: document.spaces),
                       activeSpaceID: second, organization: nil)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.page.spaceID == second)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.layer?.affineTransform() == .identity)
        #expect(sidebar.page.frame.minX == 0)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(commits == 1)
    }

    @Test("Space swipe successful phased release selects on ended while preserving the settling list")
    func spaceSwipeSuccessfulRelease() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let store = try BrowserStore(restoring: document)
        let windowID = try #require(document.windows.first?.id)
        let session = BrowserWindowSession<ReviewSwipeSurface>(store: store, restoringWindowID: windowID) {
            ReviewSwipeSurface(profileID: $0, initialURL: $1)
        }
        await session.waitForPendingCommands()
        let second = try #require(document.spaces.first { $0.id != first }?.id)
        var commits = 0
        var accepted: Bool?
        sidebar.spaceSwipe.commit = { target, catalog, admission, current, completion in
            commits += 1
            session.activateSpaceFromSwipe(target, catalog: catalog, admission: admission, isCurrent: current) { result in
                accepted = result
                if result {
                    sidebar.render(catalog: session.catalog, activeSpaceID: session.snapshot?.activeSpaceID,
                                   organization: session.organization)
                }
                completion(result)
            }
        }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -90), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -10), inside: true)
        #expect(commits == 0)
        #expect(session.snapshot?.activeSpaceID == first)
        let sourcePage = sidebar.page
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        #expect(sidebar.spaceSwipe.isSettling)
        #expect(commits == 1)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll([], x: -50, momentum: .changed), inside: true)
        #expect(commits == 1)
        await session.waitForPendingCommands()
        #expect(accepted == true)
        #expect(session.snapshot?.activeSpaceID == second)
        #expect(sidebar.page.spaceID == second)
        #expect(sidebar.spaceSwipe.isSettling)
        #expect(sidebar.page !== sourcePage)
        #expect(sourcePage.superview != nil)
        #expect((sidebar.page.frame.minX) > 0)
        let destinationPage = sidebar.page
        sidebar.spaceSwipe.advance(to: 12)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page === destinationPage)
        #expect(sourcePage.superview == nil)
        #expect(sidebar.page.layer?.affineTransform() == .identity)
        #expect(sidebar.page.frame.minX == 0)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll([], x: -50, momentum: .ended), inside: true)
        sidebar.spaceSwipe.advance(to: 14)
        #expect(commits == 1)
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Space swipe refuses stale metadata and rejected commitment removes presentation")
    func spaceSwipeMetadataRefusalAndCommitRefusal() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, completion in commits += 1; completion(false) }
        let stale = BrowserSessionDocument(profiles: document.profiles, spaces: Array(document.spaces.dropLast()),
                                           windows: document.windows, tabs: document.tabs)
        sidebar.spaceSwipe.loadDocument = { stale }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(commits == 0)
        #expect(!sidebar.spaceSwipe.isActive)
        sidebar.spaceSwipe.loadDocument = { document }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(commits == 1)
        #expect(sidebar.page.spaceID == first)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.layer?.affineTransform() == .identity)
        #expect(sidebar.page.frame.minX == 0)
    }


    @Test("Space swipe published destination can be retaken without list or theme discontinuity", arguments: [0.0, 0.06, 0.24])
    func spaceSwipePostCommitRetake(callbackGap: Double) async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let second = try #require(document.spaces.first { $0.id != first }?.id)
        var commits = 0
        sidebar.spaceSwipe.resolveTheme = { $0 == first ? .amberCoral : .lavender }
        var blend: SpaceSwipeThemeBlend?
        sidebar.spaceSwipe.onThemeProgress = { blend = $0 }
        sidebar.spaceSwipe.commit = { target, catalog, _, _, completion in
            commits += 1
            sidebar.render(catalog: catalog, activeSpaceID: target, organization: nil)
            completion(true)
        }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(commits == 0)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        #expect(commits == 1)
        #expect(sidebar.page.spaceID == second)
        sidebar.spaceSwipe.advance(to: 10.02)
        let before = sidebar.page.frame.minX
        let themeBefore = try #require(blend).theme
        sidebar.spaceSwipe.clock = { 10.02 + callbackGap }
        #expect(sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true))
        #expect(abs((sidebar.page.frame.minX) - before) < 0.001)
        let appearance = NSAppearance(named: .aqua)!
        let colorsBefore = OrbitThemeGradient.normalizedStops(themeBefore.stops, appearance: appearance)
        let colorsAfter = OrbitThemeGradient.normalizedStops(try #require(blend).theme.stops, appearance: appearance)
        for index in 0..<3 {
            let a = NSColor(cgColor: colorsBefore[index])!.usingColorSpace(.sRGB)!
            let b = NSColor(cgColor: colorsAfter[index])!.usingColorSpace(.sRGB)!
            #expect(abs(a.redComponent - b.redComponent) < 0.001)
        }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -300), inside: true)
        #expect(sidebar.spaceSwipe.offset < 0)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(try #require(blend).theme.stops == OrbitTokens.SpaceTheme.lavender.stops)
        #expect(commits == 1)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(commits == 1)
        #expect(sidebar.page.spaceID == second)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(blend == nil)
    }

    @Test("Space swipe deferred refusal after spatial settlement restores presentation without another activation")
    func spaceSwipeIndependentDeferredRefusal() async throws {
        let (window, sidebar, _, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close(); OrbitMotionPreferences.overrideReducedMotion = nil }
        var completion: (@MainActor (Bool) -> Void)?
        var lease: SpaceSwipeAdmission?
        var nativeQueue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { nativeQueue.insert(copyQueuedScroll($0), at: 0) }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, admission, _, callback in
            commits += 1
            lease = admission
            completion = callback
        }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        #expect(commits == 1)
        #expect(lease?.state == .pending)
        // Change accessibility preference while release motion is already in progress.
        OrbitMotionPreferences.overrideReducedMotion = true
        #expect(!sidebar.spaceSwipe.advance(to: 10.01))
        #expect(sidebar.spaceSwipe.isSettling)
        #expect(sidebar.page.spaceID == first)
        #expect(abs(sidebar.spaceSwipe.offset + sidebar.swipeWidth) < 0.001)
        #expect(sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true))
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        #expect(commits == 1)
        let refuse = try #require(completion)
        refuse(false)
        for _ in 0..<20 { await Task.yield() }
        #expect(lease?.state == .revoked)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.layer?.affineTransform() == .identity)
        #expect(sidebar.page.frame.minX == 0)
        #expect(sidebar.page.spaceID == first)
        #expect(nativeQueue.map(\.phase) == [.began, .ended])
        var deliveries: [NSEvent] = []
        var steps = 0
        while !nativeQueue.isEmpty && steps < 16 {
            let event = nativeQueue.removeFirst()
            if !sidebar.spaceSwipe.routeScroll(event, inside: true) { deliveries.append(event) }
            steps += 1
        }
        #expect(nativeQueue.isEmpty)
        #expect(deliveries.map(\.phase) == [.began, .ended])
        #expect(commits == 1)
        #expect(commits == 1)
    }

    @Test("Space swipe reversing into a missing neighbor restores the source fill")
    func spaceSwipeEdgeReversalTheme() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let shell = OrbitWindowShell()
        shell.apply(theme: .amberCoral, animated: false)
        sidebar.spaceSwipe.resolveTheme = { $0 == first ? .amberCoral : .lavender }
        sidebar.spaceSwipe.onThemeProgress = { shell.applySpaceSwipeBlend($0) }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(shell.themeFill.theme != .amberCoral)
        // First Space has no previous neighbor. Cross zero in one real event-sized update.
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: 120), inside: true)
        #expect(sidebar.spaceSwipe.offset > 0)
        #expect(sidebar.swipePreviewCount == 0)
        // Endpoint paint is appearance-resolved; the shell retains the selected theme model.
        #expect(shell.themeFill.theme.stops == OrbitTokens.SpaceTheme.amberCoral.stops)
        #expect(commits == 0)
        #expect(document.spaces.first?.id == first)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.cancelled), inside: true)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(shell.themeFill.theme == .amberCoral)
    }

    @Test("Space swipe edge repaint retains captured source despite newer semantic theme and resolver")
    func spaceSwipeIndependentCapturedEdgeEndpoint() async throws {
        let (window, sidebar, _, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let shell = OrbitWindowShell()
        shell.apply(theme: .amberCoral, animated: false)
        var sourceTheme = OrbitTokens.SpaceTheme.amberCoral
        sidebar.spaceSwipe.resolveTheme = { $0 == first ? sourceTheme : .lavender }
        sidebar.spaceSwipe.onThemeProgress = { shell.applySpaceSwipeBlend($0) }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        sourceTheme = .lavender
        shell.apply(theme: .lavender, animated: false)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: 120), inside: true)
        #expect(shell.theme == .lavender)
        #expect(shell.spaceSwipeBlend?.progress == 0)
        #expect(shell.themeFill.theme.stops == OrbitTokens.SpaceTheme.amberCoral.stops)
        #expect(shell.floatingBackdrop.fill.theme.stops == OrbitTokens.SpaceTheme.amberCoral.stops)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            shell.themeFill.appearance = appearance
            shell.themeFill.viewDidChangeEffectiveAppearance()
            #expect(shell.themeFill.resolvedStops == OrbitThemeGradient.normalizedStops(OrbitTokens.SpaceTheme.amberCoral.stops,
                                                                                     appearance: appearance))
        }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.cancelled), inside: true)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(shell.themeFill.theme == .lavender)
        #expect(sidebar.page.spaceID == first)
        #expect(commits == 0)
    }

    @Test("Space swipe last-edge reversal and exact zero repaint the captured source in both appearances")
    func spaceSwipeLastEdgeReversalTheme() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let last = try #require(document.spaces.last?.id)
        #expect(last != first)
        sidebar.render(catalog: .init(profiles: document.profiles, spaces: document.spaces),
                       activeSpaceID: last, organization: nil)
        let shell = OrbitWindowShell()
        shell.apply(theme: .lavender, animated: false)
        sidebar.spaceSwipe.resolveTheme = { $0 == last ? .lavender : .amberCoral }
        sidebar.spaceSwipe.onThemeProgress = { shell.applySpaceSwipeBlend($0) }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: 90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(shell.themeFill.theme != .lavender)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -120), inside: true)
        #expect(sidebar.spaceSwipe.offset < 0)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(shell.themeFill.theme.stops == OrbitTokens.SpaceTheme.lavender.stops)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            shell.themeFill.appearance = appearance
            shell.themeFill.viewDidChangeEffectiveAppearance()
            #expect(shell.themeFill.resolvedStops == OrbitThemeGradient.normalizedStops(OrbitTokens.SpaceTheme.lavender.stops,
                                                                                     appearance: appearance))
        }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: 30), inside: true)
        #expect(sidebar.spaceSwipe.offset == 0)
        #expect(shell.themeFill.theme.stops == OrbitTokens.SpaceTheme.lavender.stops)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: 60), inside: true)
        #expect(shell.themeFill.theme != .lavender)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -60), inside: true)
        #expect(sidebar.spaceSwipe.offset == 0)
        #expect(shell.themeFill.theme.stops == OrbitTokens.SpaceTheme.lavender.stops)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -20), inside: true)
        #expect(shell.themeFill.theme.stops == OrbitTokens.SpaceTheme.lavender.stops)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        sidebar.spaceSwipe.advance(to: 12)
        #expect(commits == 0)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.spaceID == last)
        #expect(shell.themeFill.theme == .lavender)
    }

    @Test("Space swipe Peek opening retires stationary tracking and a release pending store admission")
    func spaceSwipePeekInterruption() async throws {
        let (window, sidebar, document, first) = try await fixture()
        let store = try BrowserStore(restoring: document)
        let owner = BrowserWindowController(id: UUID(), store: store, spaceID: first,
            engine: PeekSyntheticEngine(), onClose: {}, onActivate: {})
        await owner.session.waitForPendingCommands()
        let swipe = owner.sidebar.spaceSwipe
        swipe.attach(to: sidebar)
        swipe.clock = { 10 }
        swipe.automaticallyAdvances = false
        defer { swipe.detach(); sidebar.spaceSwipe.detach(); window.close(); owner.window?.close() }
        var commits = 0
        var admission: SpaceSwipeAdmission?
        swipe.commit = { _, _, lease, _, _ in commits += 1; admission = lease }
        _ = swipe.routeScroll(try scroll(.began), inside: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(swipe.isActive)
        _ = try #require(owner.openPeek(URL(string: "https://synthetic.invalid/peek")!))
        #expect(owner.peek.isPresented)
        #expect(!swipe.allowsInput())
        #expect(!swipe.isActive)
        #expect(commits == 0)
        #expect(sidebar.swipePreviewCount == 0)
        owner.dismissPeek()
        _ = swipe.routeScroll(try scroll(.began), inside: true)
        _ = swipe.routeScroll(try scroll(.changed, x: -90), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = swipe.routeScroll(try scroll(.ended), inside: true)
        #expect(commits == 1)
        _ = try #require(owner.openPeek(URL(string: "https://synthetic.invalid/peek-again")!))
        #expect(!swipe.isActive)
        #expect(admission?.state == .revoked)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(owner.session.snapshot?.activeSpaceID == first)
    }


    @Test("Native Site Controls action retires held tracking and revokes unpublished release admission",
          arguments: [0, 1, 2])
    func spaceSwipeSiteControlsAction(stage: Int) async throws {
        let released = stage > 0
        let (window, sidebar, document, first) = try await fixture()
        let owner = BrowserWindowController(id: UUID(), store: try BrowserStore(restoring: document), spaceID: first,
            engine: PeekSyntheticEngine(), onClose: {}, onActivate: {})
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        surface.documentState = "Synthetic preserved form"
        let requests = surface.requestedURLs
        let swipe = owner.sidebar.spaceSwipe
        swipe.attach(to: sidebar)
        swipe.loadDocument = { document }
        swipe.clock = { 10 }
        swipe.automaticallyAdvances = false
        let shell = OrbitWindowShell()
        shell.apply(theme: .amberCoral, animated: false)
        swipe.resolveTheme = { $0 == first ? .amberCoral : .lavender }
        swipe.onThemeProgress = { shell.applySpaceSwipeBlend($0) }
        defer { swipe.detach(); sidebar.spaceSwipe.detach(); window.close(); owner.window?.close() }
        var commits = 0
        var admission: SpaceSwipeAdmission?
        var isCurrent: (@MainActor () -> Bool)?
        var completion: (@MainActor (Bool) -> Void)?
        swipe.commit = { _, _, lease, current, done in
            commits += 1; admission = lease; isCurrent = current; completion = done
        }
        var replay: [NSEvent] = []
        swipe.scrollInput.postNativeEvent = { replay.insert(copyQueuedScroll($0), at: 0) }
        let restPage = sidebar.page.frame
        let restFavorites = sidebar.favoritesContainer.frame
        _ = swipe.routeScroll(try scroll(.began), inside: true)
        for _ in 0..<20 { await Task.yield() }
        _ = swipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        #expect(sidebar.page.frame.minX == restPage.minX - 100)
        #expect(sidebar.swipePreviewCount == 1)
        #expect(shell.spaceSwipeBlend != nil)
        #expect(commits == 0)
        if released {
            _ = swipe.routeScroll(try scroll(.ended), inside: true)
            #expect(commits == 1)
            #expect(isCurrent?() == true)
            // A neutral successor arrives while the predecessor awaits admission/publication.
            _ = swipe.routeScroll(try scroll(.began), inside: true)
            _ = swipe.routeScroll(try scroll(.changed, x: -80), inside: true)
            _ = swipe.routeScroll(try scroll(.ended), inside: true)
            if stage == 2 {
                // Refusal authorizes replay at the retained source. Interrupt after the real
                // scheduler has enqueued its tagged copies, before any dequeue can select.
                completion?(false)
                for _ in 0..<100 where replay.count < 3 { await Task.yield() }
                try #require(replay.count == 3)
            }
        }
        func findButton(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == "site-controls" { return button }
            return view.subviews.lazy.compactMap { findButton($0) }.first
        }
        let button = try #require(findButton(owner.sidebar))
        // The installed native button invokes show(), before its asynchronous model lookup.
        button.performClick(nil)
        #expect(!swipe.isActive)
        #expect(swipe.offset == 0)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.frame == restPage)
        #expect(sidebar.favoritesContainer.frame == restFavorites)
        #expect(shell.spaceSwipeBlend == nil)
        #expect(shell.themeFill.theme == .amberCoral)
        if released { #expect(admission?.state == .revoked); #expect(isCurrent?() == false) }
        for event in replay { #expect(swipe.routeScroll(event, inside: true)) }
        completion?(false)
        completion?(true) // An obsolete callback must not revive settlement or its successor.
        _ = swipe.routeScroll(try scroll(.ended), inside: true)
        _ = swipe.routeScroll(try scroll([], x: -30, momentum: .changed), inside: true)
        for _ in 0..<30 { await Task.yield() }
        #expect(!swipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(sidebar.page.frame == restPage)
        #expect(commits == (released ? 1 : 0))
        #expect(owner.session.snapshot?.activeSpaceID == first)
        #expect(sidebar.swipeContext?.1 == first)
        #expect(owner.session.selectedSurface === surface)
        #expect(surface.documentState == "Synthetic preserved form")
        #expect(surface.requestedURLs == requests)
        #expect(owner.window?.isVisible == false) // No popover/window is ordered by this test.
    }

    @Test("Final Site Controls host presentation retires a newly started swipe and late metadata")
    func spaceSwipeSiteControlsPresentationBoundary() async throws {
        let (window, sidebar, document, first) = try await fixture()
        let owner = BrowserWindowController(id: UUID(), store: try BrowserStore(restoring: document), spaceID: first,
            engine: PeekSyntheticEngine(), onClose: {}, onActivate: {})
        await owner.session.waitForPendingCommands()
        let swipe = owner.sidebar.spaceSwipe
        swipe.attach(to: sidebar)
        var metadata: CheckedContinuation<BrowserSessionDocument, Never>?
        swipe.loadDocument = { await withCheckedContinuation { metadata = $0 } }
        defer { swipe.detach(); sidebar.spaceSwipe.detach(); window.close(); owner.window?.close() }
        var commits = 0
        swipe.commit = { _, _, _, _, _ in commits += 1 }
        let rest = sidebar.page.frame
        _ = swipe.routeScroll(try scroll(.began), inside: true)
        for _ in 0..<30 where metadata == nil { await Task.yield() }
        let pending = try #require(metadata)
        _ = swipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        #expect(sidebar.page.frame.minX == rest.minX - 100)
        // The real host boundary, also shared by permission/data/message popovers. Its hidden
        // anchor prevents visible AppKit UI while exercising cancellation before panel.show.
        owner.presentSiteControls(BrowserSitePopover(), rows: [], button: owner.sidebar.addressContainer)
        #expect(!swipe.isActive)
        #expect(sidebar.page.frame == rest)
        pending.resume(returning: document)
        for _ in 0..<30 { await Task.yield() }
        _ = swipe.routeScroll(try scroll(.ended), inside: true)
        #expect(!swipe.isActive)
        #expect(sidebar.page.frame == rest)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(commits == 0)
        #expect(owner.session.snapshot?.activeSpaceID == first)
    }

    @Test("Space swipe stationary modal/render invalidation and reduced-motion cancellation restore theme")
    func spaceSwipeStationaryInvalidationAndReducedMotion() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close(); OrbitMotionPreferences.overrideReducedMotion = nil }
        let shell = OrbitWindowShell()
        shell.apply(theme: .amberCoral, animated: false)
        sidebar.spaceSwipe.resolveTheme = { $0 == first ? .amberCoral : .lavender }
        sidebar.spaceSwipe.onThemeProgress = { shell.applySpaceSwipeBlend($0) }
        var commits = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -80), inside: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(shell.spaceSwipeBlend != nil)
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: window)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(shell.themeFill.theme == .amberCoral)
        #expect(sidebar.swipePreviewCount == 0)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        #expect(commits == 0)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -80), inside: true)
        for _ in 0..<10 { await Task.yield() }
        sidebar.spaceSwipe.allowsInput = { false }
        sidebar.render(catalog: .init(profiles: document.profiles, spaces: document.spaces),
                       activeSpaceID: first, organization: sidebar.organization)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        #expect(commits == 0)
        sidebar.spaceSwipe.allowsInput = { true }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -80), inside: true)
        for _ in 0..<10 { await Task.yield() }
        #expect(sidebar.spaceSwipe.offset == -80)
        OrbitMotionPreferences.overrideReducedMotion = true
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.cancelled), inside: true)
        #expect(!sidebar.spaceSwipe.isActive)
        #expect(sidebar.page.layer?.affineTransform() == .identity)
        #expect(sidebar.page.frame.minX == 0)
        #expect(shell.themeFill.theme == .amberCoral)
        #expect(shell.spaceSwipeBlend == nil)
        #expect(commits == 0)
    }

}
}

@MainActor
private final class ReviewSwipeSurface: BrowserSurface {
    let profileID: ProfileID
    let initialURL: URL
    var currentURL: URL? { initialURL }
    init(profileID: ProfileID, initialURL: URL) { self.profileID = profileID; self.initialURL = initialURL }
    func dispose() {}
}

// Independent R6 review faults, exercising the production arbitration seam with synthetic input.
extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Space swipe independent terminal packets return small vertical probation losslessly", arguments: [false, true])
    func spaceSwipeR6IndependentTerminalProbation(cancelled: Bool) async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var queue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { queue.insert(copyQueuedScroll($0), at: 0) }
        let terminal: NSEvent.Phase = cancelled ? .cancelled : .ended
        // A single vertical packet, followed by a direction reversal on the terminal packet,
        // must not disappear merely because neither sample confirms vertical ownership.
        let events = [try scroll(.began), try scroll(.changed, y: 7), try scroll(terminal, y: -4)]
        for event in events { #expect(sidebar.spaceSwipe.routeScroll(event, inside: true)) }
        #expect(queue.map(\.phase) == [.began, .changed, terminal])
        #expect(queue.reduce(0) { $0 + $1.scrollingDeltaY } == 3)
        for event in queue { #expect(!sidebar.spaceSwipe.routeScroll(event, inside: true)) }
        #expect(!sidebar.spaceSwipe.isActive && sidebar.swipePreviewCount == 0)
        queue.removeAll()
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -20), inside: true)
        #expect(sidebar.spaceSwipe.offset == -20 && queue.isEmpty)
    }

    @Test("Space swipe independent context replacement revokes a successor after its first dequeue")
    func spaceSwipeR6IndependentPartialDequeueRevocation() async throws {
        let (window, sidebar, document, first) = try await fixture(crossProfile: true)
        defer { sidebar.spaceSwipe.detach(); window.close(); OrbitMotionPreferences.overrideReducedMotion = nil }
        var queue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { queue.insert(copyQueuedScroll($0), at: 0) }
        var loaded = false
        var commits = 0
        sidebar.spaceSwipe.loadDocument = { loaded = true; return document }
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in commits += 1 }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<100 where !loaded { try await Task.sleep(for: .milliseconds(1)) }
        try #require(loaded)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        try #require(commits == 1)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 80), inside: true)
        OrbitMotionPreferences.overrideReducedMotion = true
        _ = sidebar.spaceSwipe.advance(to: 12)
        let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
        sidebar.render(catalog: catalog, activeSpaceID: document.spaces.last?.id, organization: nil)
        for _ in 0..<100 where queue.count < 2 { try await Task.sleep(for: .milliseconds(1)) }
        try #require(queue.count == 2)
        let began = try #require(queue.first)
        #expect(sidebar.spaceSwipe.routeScroll(began, inside: true))
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
        for event in queue.dropFirst() { #expect(sidebar.spaceSwipe.scrollInput.replay(event) == .discard) }
        #expect(sidebar.swipePreviewCount == 0 && !sidebar.spaceSwipe.isActive)
    }

}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Space swipe independent native Favorites bitmap returns exactly after near-full reversal")
    func spaceSwipeR6IndependentFavoritePixels() async throws {
        let (window, sidebar, seed, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let store = try BrowserStore(restoring: seed)
        let windowID = try #require(seed.windows.first?.id)
        var ids: [TabID] = []
        for index in 0..<7 {
            let context = try await store.captureContext(in: windowID)
            let occurrence = try await store.openTab(url: URL(string: "https://synthetic.invalid/independent/\(index)")!, from: context, activate: true)
            let document = await store.sessionDocument()
            ids.append(try #require(document.tabs.first { $0.occurrenceID == occurrence }).id)
        }
        _ = try await store.addToFavorites(ids, from: store.captureContext(in: windowID))
        let document = await store.sessionDocument()
        let favorites = try #require(SpaceSwipePreview.favorites(document: document, spaceID: first, windowID: windowID))
        let grid = FavoritesGridView()
        grid.animatesChanges = false
        grid.autoresizingMask = [.width, .height]
        sidebar.favoritesContainer.addSubview(grid)
        grid.render(favorites.items, profileID: favorites.profileID)
        sidebar.favoriteCount = favorites.items.count
        sidebar.render(catalog: await store.catalogSnapshot(), activeSpaceID: first,
                       organization: try await store.organizationSnapshot(from: store.captureContext(in: windowID)))
        sidebar.spaceSwipe.loadDocument = { document }
        sidebar.layoutSubtreeIfNeeded()
        let viewport = try #require(sidebar.page.superview)
        func pixels() throws -> Data {
            sidebar.layoutSubtreeIfNeeded()
            grid.layoutSubtreeIfNeeded()
            let bitmap = try #require(viewport.bitmapImageRepForCachingDisplay(in: viewport.bounds))
            viewport.cacheDisplay(in: viewport.bounds, to: bitmap)
            return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let baseline = try pixels()
        let restingFavoritesX = sidebar.favoritesContainer.frame.minX
        let tileIDs = grid.tiles.map(ObjectIdentifier.init)
        for tile in grid.tiles {
            #expect(sidebar.swipeContains(tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)))
        }
        // Scan the full eligible strip, including the gaps outside the tiles and list rows.
        for y in stride(from: sidebar.contentViewportFrame.minY + 1, to: sidebar.contentViewportFrame.maxY, by: 7) {
            for x: CGFloat in [1, 120, 239] {
                #expect(sidebar.swipeContains(sidebar.convert(.init(x: x, y: y), to: nil)))
            }
        }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -228), inside: true)
        #expect(try pixels() != baseline)
        #expect(sidebar.favoritesContainer.frame.minX == restingFavoritesX && sidebar.page.frame.minX == -228)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 228), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true)
        _ = sidebar.spaceSwipe.advance(to: 12)
        #expect(try pixels() == baseline)
        #expect(grid.tiles.map(ObjectIdentifier.init) == tileIDs && viewport.subviews.count == 2)
        #expect(await store.sessionDocument() == document)
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Space swipe independent successor rejects replacement before enqueue and after first dequeue", arguments: [false, true], [false, true])
    func spaceSwipeR6IndependentSuccessorPublicationRace(beforeEnqueue: Bool, crossProfile: Bool) async throws {
        let (window, sidebar, document, first) = try await fixture(crossProfile: crossProfile)
        defer { sidebar.spaceSwipe.detach(); window.close(); OrbitMotionPreferences.overrideReducedMotion = nil }
        var queue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { queue.insert(copyQueuedScroll($0), at: 0) }
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 80), inside: true)
        OrbitMotionPreferences.overrideReducedMotion = true
        _ = sidebar.spaceSwipe.advance(to: 12)
        let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
        sidebar.render(catalog: catalog, activeSpaceID: document.spaces.last?.id, organization: nil)
        if beforeEnqueue {
            // Render another semantic source without yielding to the pending replay task.
            sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
            for _ in 0..<20 { await Task.yield() }
            #expect(queue.isEmpty) // Revocation precedes enqueue, not just eventual consumption.
            for event in queue { #expect(sidebar.spaceSwipe.scrollInput.replay(event) == .discard) }
        } else {
            for _ in 0..<20 { await Task.yield() }
            #expect(queue.count == 2)
            let began = try #require(queue.first)
            #expect(sidebar.spaceSwipe.routeScroll(began, inside: true))
            sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
            for event in queue.dropFirst() { #expect(sidebar.spaceSwipe.scrollInput.replay(event) == .discard) }
        }
        #expect(sidebar.swipePreviewCount == 0 && !sidebar.spaceSwipe.isActive)
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Space swipe refusal binds only its retained source before enqueue and across partial dequeue", arguments: [0, 1, 2], [false, true])
    func spaceSwipeRefusalSuccessorAuthority(replacement: Int, crossProfile: Bool) async throws {
        let (window, sidebar, document, first) = try await fixture(crossProfile: crossProfile)
        defer { sidebar.spaceSwipe.detach(); window.close(); OrbitMotionPreferences.overrideReducedMotion = nil }
        var queue: [NSEvent] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { queue.insert(copyQueuedScroll($0), at: 0) }
        var callbacks: [@MainActor (Bool) -> Void] = []
        sidebar.spaceSwipe.commit = { _, _, _, _, callback in callbacks.append(callback) }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        #expect(callbacks.count == 1)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -80), inside: true)
        OrbitMotionPreferences.overrideReducedMotion = true
        _ = sidebar.spaceSwipe.advance(to: 12)
        let refuse = try #require(callbacks.first)
        refuse(false)
        let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
        if replacement == 1 {
            // Refusal authorizes first, never whichever Space renders before the task resumes.
            sidebar.render(catalog: catalog, activeSpaceID: document.spaces.last?.id, organization: nil)
        }
        for _ in 0..<20 { await Task.yield() }
        if replacement == 1 {
            #expect(queue.isEmpty)
        } else {
            #expect(queue.count == 2)
            let began = try #require(queue.first)
            #expect(sidebar.spaceSwipe.routeScroll(began, inside: true))
            if replacement == 2 {
                sidebar.render(catalog: catalog, activeSpaceID: document.spaces.last?.id, organization: nil)
                for event in queue.dropFirst() { #expect(sidebar.spaceSwipe.scrollInput.replay(event) == .discard) }
            } else {
                for event in queue.dropFirst() { #expect(sidebar.spaceSwipe.routeScroll(event, inside: true)) }
                for _ in 0..<10 { await Task.yield() }
                #expect(sidebar.page.spaceID == first && sidebar.spaceSwipe.offset == -80)
                #expect(callbacks.count == 1) // A refused predecessor does not admit its successor early.
                _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
                #expect(callbacks.count == 2)
                _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
                #expect(callbacks.count == 2)
            }
        }
        sidebar.spaceSwipe.cancel()
        // Stale completion must not resurrect the refused release or the later cancelled one.
        for callback in callbacks { callback(false); callback(true) }
        for _ in 0..<20 { await Task.yield() }
        #expect(!sidebar.spaceSwipe.isActive && sidebar.swipePreviewCount == 0)
        #expect(callbacks.count == (replacement == 0 ? 2 : 1))
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Space swipe published destination rejects the old source even without a queued successor", arguments: [false, true])
    func spaceSwipePublishedSourceReplacement(crossProfile: Bool) async throws {
        let (window, sidebar, document, first) = try await fixture(crossProfile: crossProfile)
        defer { sidebar.spaceSwipe.detach(); window.close() }
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
        sidebar.render(catalog: catalog, activeSpaceID: document.spaces.last?.id, organization: nil)
        #expect(sidebar.spaceSwipe.isActive)
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
        #expect(!sidebar.spaceSwipe.isActive && sidebar.swipePreviewCount == 0)
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Space swipe independent authority advances only for its own next release", arguments: [false, true])
    func spaceSwipeR7IndependentOwnedAdvance(crossProfile: Bool) async throws {
        let (window, sidebar, document, first) = try await fixture(crossProfile: crossProfile)
        defer { sidebar.spaceSwipe.detach(); window.close(); OrbitMotionPreferences.overrideReducedMotion = nil }
        let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
        let second = try #require(document.spaces.last?.id)
        var queue: [NSEvent] = []
        var completions: [@MainActor (Bool) -> Void] = []
        var targets: [SpaceID] = []
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { queue.insert(copyQueuedScroll($0), at: 0) }
        sidebar.spaceSwipe.commit = { target, _, _, _, completion in
            targets.append(target); completions.append(completion)
        }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        try await Task.sleep(for: .milliseconds(10))
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        #expect(targets == [second])
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 100), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        OrbitMotionPreferences.overrideReducedMotion = true
        _ = sidebar.spaceSwipe.advance(to: 12)
        sidebar.render(catalog: catalog, activeSpaceID: second, organization: nil)
        for _ in 0..<100 where queue.count < 3 { try await Task.sleep(for: .milliseconds(1)) }
        try #require(queue.count == 3 && completions.count == 1)
        #expect(sidebar.spaceSwipe.routeScroll(try #require(queue.first), inside: true))
        // An old completion cannot refuse the newly retaken gesture.
        completions[0](false); completions[0](true)
        try await Task.sleep(for: .milliseconds(10))
        #expect(sidebar.spaceSwipe.routeScroll(queue[1], inside: true))
        #expect(targets == [second] && sidebar.page.spaceID == second)
        #expect(sidebar.spaceSwipe.routeScroll(queue[2], inside: true))
        try #require(targets == [second, first] && completions.count == 2)
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
        completions[1](true)
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
        _ = sidebar.spaceSwipe.advance(to: 12)
        #expect(sidebar.page.spaceID == first && !sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
        // Resize and terminal packets after retirement must not activate an extra Space.
        sidebar.setFrameSize(NSSize(width: 260, height: 640)); sidebar.layoutSubtreeIfNeeded()
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.cancelled), inside: true)
        #expect(targets == [second, first])
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        try await Task.sleep(for: .milliseconds(10))
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        #expect(targets == [second, first, second])
    }

    @Test("Space swipe independent revoked publication cannot resurrect when expected context returns", arguments: [false, true])
    func spaceSwipeR7IndependentPublicationABA(crossProfile: Bool) async throws {
        let (window, sidebar, document, first) = try await fixture(crossProfile: crossProfile)
        defer { sidebar.spaceSwipe.detach(); window.close(); OrbitMotionPreferences.overrideReducedMotion = nil }
        let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
        let second = try #require(document.spaces.last?.id)
        var queue: [NSEvent] = []
        var commits = 0
        var completion: (@MainActor (Bool) -> Void)?
        sidebar.spaceSwipe.scrollInput.postNativeEvent = { queue.insert(copyQueuedScroll($0), at: 0) }
        sidebar.spaceSwipe.commit = { _, _, _, _, callback in commits += 1; completion = callback }
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: -100), inside: true)
        try await Task.sleep(for: .milliseconds(10))
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 100), inside: true)
        OrbitMotionPreferences.overrideReducedMotion = true
        _ = sidebar.spaceSwipe.advance(to: 12)
        sidebar.render(catalog: catalog, activeSpaceID: second, organization: nil)
        sidebar.render(catalog: catalog, activeSpaceID: first, organization: nil)
        sidebar.render(catalog: catalog, activeSpaceID: second, organization: nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(queue.isEmpty && commits == 1)
        #expect(!sidebar.spaceSwipe.isActive && sidebar.swipePreviewCount == 0)
        completion?(true); completion?(false)
        #expect(queue.isEmpty && !sidebar.spaceSwipe.isActive)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.changed, x: 100), inside: true)
        try await Task.sleep(for: .milliseconds(10))
        _ = sidebar.spaceSwipe.routeScroll(try scroll(.ended), inside: true)
        #expect(commits == 2)
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Click and swipe theme paint starts before selection publication and cancels without a delayed repaint", arguments: [false, true])
    func spaceThemePaintBeforePublication(click: Bool) async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let target = try #require(document.spaces.last?.id)
        let shell = OrbitWindowShell()
        shell.apply(theme: .amberCoral, animated: false)
        sidebar.spaceSwipe.resolveTheme = { $0 == first ? .amberCoral : .lavender }
        sidebar.spaceSwipe.onThemeProgress = { shell.applySpaceSwipeBlend($0) }
        // Retain the selection command without admitting or publishing it.
        var requests = 0
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in requests += 1 }
        if click {
            let catalog = BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces)
            sidebar.spaceSwipe.validate(catalog: catalog, active: first)
            for _ in 0..<20 { await Task.yield() }
            #expect(sidebar.spaceSwipe.switchToSpace(target))
            #expect(sidebar.spaceSwipe.advance(to: 10.008))
        } else {
            _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
            _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -8), inside: true)
        }
        let progress = try #require(shell.spaceSwipeBlend?.progress)
        #expect(progress > 0 && progress < 0.1)
        #expect(shell.themeFill.theme != .amberCoral)
        #expect(!shell.themeFill.isCrossfading)
        #expect(sidebar.page.spaceID == first)
        #expect(requests == (click ? 1 : 0))
        sidebar.spaceSwipe.cancel()
        #expect(shell.spaceSwipeBlend == nil)
        #expect(shell.themeFill.theme == .amberCoral)
        #expect(!sidebar.spaceSwipe.advance(to: 12))
        #expect(shell.themeFill.theme == .amberCoral)
    }

    @Test("Prepared footer clicks slide to a nonadjacent Space without publishing engine work during the spring", arguments: [false, true])
    func preparedFooterClick(crossProfile: Bool) async throws {
        let (window, sidebar, seed, first) = try await fixture(crossProfile: crossProfile)
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let store = try BrowserStore(restoring: seed)
        let profile = try #require(seed.spaces.last?.profileID)
        let target = try await store.createSpace(name: "Third", profileID: profile)
        let document = await store.sessionDocument()
        let catalog = await store.catalogSnapshot()
        sidebar.spaceSwipe.loadDocument = { document }
        let windowID = try #require(document.windows.first?.id)
        sidebar.render(catalog: catalog, activeSpaceID: first,
                       organization: try await store.organizationSnapshot(from: store.captureContext(in: windowID)))
        sidebar.layoutSubtreeIfNeeded()
        for _ in 0..<20 { await Task.yield() }
        var commits: [SpaceID] = []
        var releases: [SpaceID] = []
        sidebar.spaceSwipe.commit = { id, _, _, _, _ in commits.append(id) }
        sidebar.spaceSwipe.onRelease = { _, id, _ in releases.append(id) }
        let favoritesX = sidebar.favoritesContainer.frame.minX
        #expect(sidebar.spaceSwipe.switchToSpace(target))
        #expect(commits == [target] && releases == [target])
        #expect(sidebar.spaceSwipe.isSettling && sidebar.swipePreviewCount == 1)
        let expected = SidebarSlotMotion(from: -0.000001, to: -sidebar.swipeWidth, at: 10,
                                        spring: OrbitTokens.Motion.spaceSwitchSidebar)
        _ = sidebar.spaceSwipe.advance(to: 10.05)
        #expect(abs(sidebar.spaceSwipe.offset - expected.value(at: 10.05)) < 0.001)
        let preview = try #require(sidebar.page.superview?.subviews.compactMap { $0 as? SidebarSpacePageView }.first { $0 !== sidebar.page })
        #expect(preview.spaceID == target)
        if !crossProfile { #expect(sidebar.favoritesContainer.frame.minX == favoritesX) }
        #expect(await store.sessionDocument() == document)
        _ = sidebar.spaceSwipe.advance(to: 12)
    }

    @Test("Detached neighbor reuse invalidates content, paint and geometry and stays bounded")
    func preparedNeighborCacheInvalidation() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        for _ in 0..<20 { await Task.yield() }
        sidebar.appearance = NSAppearance(named: .aqua)
        let neighbor = try #require(document.spaces.last?.id)
        func prepare(_ document: BrowserSessionDocument) {
            sidebar.prepareSpaceSwipeNeighbors(document: document, active: first, resolveTheme: { _ in .default })
        }
        prepare(document)
        let original = try #require(sidebar.preparedSpaceSwipePage(for: neighbor))
        #expect(original.superview == nil)
        prepare(document)
        #expect(sidebar.preparedSpaceSwipePage(for: neighbor) === original)
        sidebar.resolveSpaceIcon = { _ in .grapheme("P") }
        prepare(document)
        let changedIcon = try #require(sidebar.preparedSpaceSwipePage(for: neighbor))
        #expect(changedIcon !== original && changedIcon.iconSelection == .grapheme("P"))
        sidebar.frame.size.width += 20
        sidebar.layoutSubtreeIfNeeded()
        prepare(document)
        let resized = try #require(sidebar.preparedSpaceSwipePage(for: neighbor))
        #expect(resized !== changedIcon)
        sidebar.appearance = NSAppearance(named: .darkAqua)
        prepare(document)
        let dark = try #require(sidebar.preparedSpaceSwipePage(for: neighbor))
        #expect(dark !== resized)
        let store = try BrowserStore(restoring: document)
        try await store.renameSpace(neighbor, name: "Updated neighbor")
        let renamed = await store.sessionDocument()
        prepare(renamed)
        let renamedPage = try #require(sidebar.preparedSpaceSwipePage(for: neighbor))
        #expect(renamedPage !== dark)
        let windowID = try #require(document.windows.first?.id)
        try await store.activateSpace(neighbor, in: windowID)
        _ = try await store.openTab(url: URL(string: "https://fixture.test/preview")!,
            from: store.captureContext(in: windowID), activate: true)
        let populated = await store.sessionDocument()
        prepare(populated)
        let populatedPage = try #require(sidebar.preparedSpaceSwipePage(for: neighbor))
        #expect(populatedPage !== renamedPage)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        sidebar.previewIcon = { _, _ in image }
        prepare(populated)
        #expect(sidebar.preparedSpaceSwipePage(for: neighbor) !== populatedPage)
        for index in 0..<8 { _ = try await store.createSpace(name: "Neighbor \(index)", profileID: document.profiles[0].id) }
        let expanded = await store.sessionDocument()
        for space in expanded.spaces {
            sidebar.prepareSpaceSwipeNeighbors(document: expanded, active: space.id, resolveTheme: { _ in .default })
            #expect(sidebar.preparedSpaceSwipePageCount <= 4)
        }
        prepare(document)
        #expect(sidebar.preparedSpaceSwipePageCount <= 2)
    }

    @Test("Prepared swipe neighbors stay detached through neutral input and reconcile before presentation")
    func spaceSwipePreparedNeighborsAreDetached() async throws {
        let (window, sidebar, document, first) = try await fixture(crossProfile: true)
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let viewport = try #require(sidebar.page.superview)
        sidebar.prepareSpaceSwipeNeighbors(document: document, active: first, resolveTheme: { _ in .default })
        #expect(viewport.subviews.count == 2)
        for _ in 0..<2 {
            _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
            for _ in 0..<10 { await Task.yield() }
            #expect(viewport.subviews.count == 2)
            _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -60), inside: true)
            let preview = try #require(viewport.subviews.compactMap { $0 as? SidebarSpacePageView }.first { $0 !== sidebar.page })
            #expect(preview.spaceID == document.spaces.last?.id)
            #expect(preview.frame.minX == sidebar.swipeWidth - 60)
            #expect(sidebar.page.frame.minX == -60)
            _ = sidebar.spaceSwipe.handleScroll(try scroll(.cancelled), inside: true)
            _ = sidebar.spaceSwipe.advance(to: 12)
            #expect(viewport.subviews.count == 2)
            #expect(sidebar.page.frame.minX == 0)
        }
    }

    @Test("Swipe settlement releases waiting surface work on completion and cancellation", arguments: [false, true])
    func spaceSwipeSettlementReleasesWork(cancel: Bool) async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        #expect(sidebar.spaceSwipe.isSettling)
        var released = false
        let waiter = Task { await sidebar.spaceSwipe.waitForSettlement(); released = true }
        for _ in 0..<10 { await Task.yield() }
        #expect(!released)
        if cancel { sidebar.spaceSwipe.cancel() }
        else { _ = sidebar.spaceSwipe.advance(to: 12) }
        await waiter.value
        #expect(released)
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Prepainted swipe neighbors contain native Retina pixels and restore original child visibility")
    func spaceSwipeRasterRestoresNativeViews() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 60))
        view.wantsLayer = true
        let visible = SwipeReviewPaintMarker(frame: view.bounds, fill: .red)
        let hidden = SwipeReviewPaintMarker(frame: view.bounds, fill: .blue)
        hidden.isHidden = true
        view.addSubview(visible); view.addSubview(hidden)
        let raster = try #require(SpaceSwipeRaster(view: view, scale: 2))
        #expect(view.subviews.isEmpty && visible.superview == nil && hidden.superview == nil)
        let layer = try #require(view.layer?.sublayers?.last)
        let image = try #require(layer.contents) as! CGImage
        #expect(image.width == 160 && image.height == 120)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try #require(bitmap.colorAt(x: 40, y: 40)?.usingColorSpace(.sRGB))
        #expect(color.redComponent > 0.9 && color.blueComponent < 0.1 && color.alphaComponent > 0.9)
        raster.restore()
        #expect(!visible.isHidden && hidden.isHidden)
        #expect(view.subviews.count == 2 && visible.superview === view && hidden.superview === view)
        #expect(layer.superlayer == nil)
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("A fresh contact retakes a presentation-waiting swipe without buffering or jumping")
    func spaceSwipeRetakesWaitingActivation() async throws {
        let (window, sidebar, _, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        var admission: SpaceSwipeAdmission?
        var waiter: Task<Void, Never>?
        sidebar.spaceSwipe.commit = { _, _, captured, _, completion in
            admission = captured
            waiter = Task { await sidebar.spaceSwipe.waitForSettlement(); completion(false) }
        }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.advance(to: 10.04)
        let presented = sidebar.page.frame.minX
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        #expect(admission?.state == .revoked)
        #expect(!sidebar.spaceSwipe.isSettling)
        #expect(sidebar.page.frame.minX == presented)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: 6), inside: true)
        #expect(abs(sidebar.page.frame.minX - presented - 6) < 0.001)
        await waiter?.value
        #expect(sidebar.spaceSwipe.isActive)
        #expect(abs(sidebar.page.frame.minX - presented - 6) < 0.001)
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Late swipe publication cannot leave an ordinary outgoing Favorites grid in the viewport")
    func spaceSwipeLatePublicationCleansFavorites() async throws {
        let (window, sidebar, document, _) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        let grid = FavoritesGridView()
        sidebar.favoritesContainer.addSubview(grid)
        let viewport = try #require(sidebar.page.superview)
        let target = try #require(document.spaces.last?.id)
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        _ = sidebar.spaceSwipe.advance(to: 12)
        // Match the real render order: Chrome adopts, Favorites prepares, then rows publish.
        sidebar.prepareSpaceContentPublication(to: target)
        sidebar.prepareSpaceContentPublication(to: target)
        sidebar.render(catalog: BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces),
                       activeSpaceID: target, organization: nil)
        sidebar.layoutSubtreeIfNeeded()
        #expect(viewport.subviews.count == 2)
        #expect(sidebar.page.spaceID == target)
        #expect(!sidebar.isSwitchingSpace && !sidebar.spaceSwipe.isActive)
        #expect(sidebar.swipePreviewCount == 0)
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("A lost display callback releases settlement without revoking the destination")
    func spaceSwipeLostFramesCannotStallCommands() async throws {
        let (window, sidebar, _, _) = try await fixture(crossProfile: true)
        defer { sidebar.spaceSwipe.detach(); window.close() }
        sidebar.spaceSwipe.settlementWaitLimit = .milliseconds(30)
        var captured: SpaceSwipeAdmission?
        sidebar.spaceSwipe.commit = { _, _, admission, _, _ in captured = admission }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.began), inside: true)
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.changed, x: -100), inside: true)
        for _ in 0..<10 { await Task.yield() }
        _ = sidebar.spaceSwipe.handleScroll(try scroll(.ended), inside: true)
        var released = false
        let waiter = Task { await sidebar.spaceSwipe.waitForSettlement(); released = true }
        let deadline = ContinuousClock.now + .seconds(1)
        while !released, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(released)
        #expect(captured?.state == .pending)
        sidebar.spaceSwipe.cancel()
        await waiter.value
    }
}

extension NativeWebKitTests.SpaceSwipeRoutingTests {
    @Test("Settlement deadline preserves the normal sidebar spring at every frame")
    func deadlinePreservesVisibleSpring() async throws {
        let (window, sidebar, document, first) = try await fixture()
        defer { sidebar.spaceSwipe.detach(); window.close() }
        sidebar.spaceSwipe.commit = { _, _, _, _, _ in }
        sidebar.spaceSwipe.validate(catalog: BrowserCatalogSnapshot(profiles: document.profiles, spaces: document.spaces), active: first)
        for _ in 0..<20 { await Task.yield() }
        #expect(sidebar.spaceSwipe.switchToSpace(try #require(document.spaces.last?.id)))
        let initial = sidebar.spaceSwipe.offset
        let expected = SidebarSlotMotion(from: initial, to: -sidebar.swipeWidth, at: 10,
            spring: OrbitTokens.Motion.spaceSwitchSidebar)
        for elapsed in [0.0, 0.05, 0.1, 0.2, 0.4, 0.8] {
            _ = sidebar.spaceSwipe.advance(to: 10 + elapsed)
            #expect(abs(sidebar.spaceSwipe.offset - expected.value(at: 10 + elapsed)) < 0.001)
        }
        var released = false
        let waiter = Task { await sidebar.spaceSwipe.waitForSettlement(); released = true }
        for _ in 0..<10 { await Task.yield() }
        #expect(released)
        await waiter.value
    }
}
