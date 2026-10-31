import AppKit
import BrowserCore
import BrowserEngine
@testable import BrowserShell
import Testing
@testable import Orbit

@Suite("Split geometry")
struct SplitGeometryTests {
    @Test("Both orientations fill their bounds without overlaps or negative extents",
          arguments: [BrowserSplitOrientation.horizontal, .vertical], [2,3,4])
    func fillsBounds(_ orientation: BrowserSplitOrientation, count: Int) {
        for extent: CGFloat in [0, 5, 100, 1024] {
            let bounds = CGRect(x: 3, y: 7, width: extent, height: extent)
            let ratios = (1...count).map(Double.init)
            let result = BrowserSplitGeometry.layout(in: bounds, orientation: orientation, ratios: ratios)
            #expect(result.panes.count == count)
            #expect(result.dividers.count == count - 1)
            #expect(result.panes.allSatisfy { $0.width >= 0 && $0.height >= 0 })
            #expect(abs(result.panes.last!.maxX - bounds.maxX) < 0.000_001)
            #expect(abs(result.panes.last!.maxY - bounds.maxY) < 0.000_001)
            for index in 0..<(count - 1) {
                if orientation == .horizontal {
                    #expect(result.panes[index].maxX <= result.panes[index + 1].minX)
                } else { #expect(result.panes[index].maxY <= result.panes[index + 1].minY) }
            }
        }
    }

    @Test("A divider changes only adjacent ratios, clamps minimums and follows pointer delta")
    func resizing() {
        let original = [0.25,0.25,0.5]
        let result = BrowserSplitGeometry.resized(original, divider: 0, delta: 30, available: 1000)
        #expect(abs(result[0] - 0.28) < 0.000_001)
        #expect(result[2] == original[2])
        #expect(abs(result.reduce(0,+) - 1) < 0.000_001)
        let clamped = BrowserSplitGeometry.resized(original, divider: 1, delta: -1000, available: 1000)
        #expect(abs(clamped[1] - 0.12) < 0.000_001)
        #expect(BrowserSplitGeometry.resized(original, divider: 3, delta: 20, available: 1000) == original)
        #expect(BrowserSplitGeometry.resized(original, divider: 0, delta: 20, available: 0) == original)
    }

    @Test("Side-by-side panes keep a 220-point minimum and overflow the trailing edge when four cannot fit") @MainActor
    func minimumPaneWidth() {
        let bounds = CGRect(x: 0, y: 0, width: 590, height: 400)
        let result = BrowserSplitGeometry.layout(in: bounds, orientation: .horizontal, ratios: [0.25, 0.25, 0.25, 0.25],
                                                 gap: 10, minimum: BrowserSplitTokens.minimumPaneWidth)
        #expect(result.panes.map(\.width) == [220, 220, 220, 220])
        #expect(result.panes[1].minX == 230 && result.panes[3].maxX > bounds.maxX)
        let wide = BrowserSplitGeometry.layout(in: CGRect(x: 0, y: 0, width: 1010, height: 400), orientation: .horizontal,
                                               ratios: [0.5, 0.5], gap: 10, minimum: BrowserSplitTokens.minimumPaneWidth)
        #expect(wide.panes.map(\.width) == [500, 500])
        // At four equal panes in 590 points the divider cannot move.
        let ratios = [0.25, 0.25, 0.25, 0.25]
        #expect(BrowserSplitGeometry.resized(ratios, divider: 1, delta: 80, available: 560,
                                             minimum: BrowserSplitTokens.minimumPane(.horizontal)) == ratios)
        let two = BrowserSplitGeometry.resized([0.5, 0.5], divider: 0, delta: -1000, available: 1000,
                                               minimum: BrowserSplitTokens.minimumPane(.horizontal))
        #expect(abs(two[0] - 0.22) < 0.000_001)
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeSplitTests {
    private typealias Window = BrowserWindowController<PeekSyntheticEngine>

    private func makeWindow() async throws -> (BrowserEnvironment<PeekSyntheticEngine>, Window, PeekSyntheticSurface) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let window = try await environment.makeWindow()
        window.submitAddress("https://split.test/left")
        await window.session.waitForPendingCommands()
        return (environment, window, try #require(window.session.selectedSurface))
    }

    private func settle(_ window: Window) async {
        await window.session.waitForPendingCommands()
        await Task.yield()
        await window.session.waitForPendingCommands()
        window.window?.contentView?.layoutSubtreeIfNeeded()
    }

    @Test("Focused pane header routes site controls and separation without replacing live documents")
    func focusedHeaderActions() async throws {
        let (_, window, left) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        window.session.addSplitPane(url: URL(string: "https://right.split.test/page")!)
        await settle(window)
        let right = try #require(window.session.selectedSurface)
        let group = try #require(window.session.activeSplit)
        let leftID = group.group.tabIDs[0], rightID = group.group.tabIDs[1]
        for focused in [leftID, rightID] {
            window.split.view.onFocus?(focused)
            await settle(window)
            for (id, pane) in window.split.view.panes {
                let inactive = id != focused
                #expect(pane.reload.isHidden == inactive)
                #expect(pane.siteControls.isHidden == inactive)
                #expect(pane.splitToggle.isHidden == inactive)
                #expect(!pane.back.isHidden && !pane.forward.isHidden && !pane.close.isHidden)
                if !inactive {
                    #expect(pane.splitToggle.frame.midX - pane.siteControls.frame.midX == 36)
                    #expect(pane.close.frame.midX - pane.splitToggle.frame.midX == 32)
                    #expect(pane.address.frame.maxX < pane.siteControls.frame.minX)
                    #expect(pane.siteControls.contentTintColor == pane.close.contentTintColor)
                }
            }
        }
        let active = try #require(window.split.view.panes[rightID])
        var origin: BrowserSiteOrigin?
        var settings: CheckedContinuation<[BrowserSitePermission: BrowserSitePermissionSetting], Never>?
        window.siteControls.presentationSettings = { requested, _ in
            origin = requested
            return await withCheckedContinuation { settings = $0 }
        }
        defer {
            window.siteControls.cancelPermission()
            settings?.resume(returning: [:])
        }
        active.siteControls.performClick(nil)
        await settle(window)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while settings == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try #require(origin).value == "https://right.split.test")
        #expect(settings != nil)
        window.siteControls.cancelPermission()
        settings?.resume(returning: [:]); settings = nil
        let menu = window.makeSplitPaneMenu(rightID)
        #expect(menu.items.map(\.title) == [uiText("Move Left"), uiText("Move Right"), "", uiText("Add Right Split"),
            uiText("Add Left Split"), "", uiText("Separate Tab from Split"), uiText("Convert to Vertical Split View"), "", uiText("Share Split View…")])
        #expect(menu.items[0].isEnabled && !menu.items[1].isEnabled)
        let separate = menu.items[6]
        _ = (separate.target as? NSObject)?.perform(separate.action, with: separate)
        await settle(window)
        #expect(window.session.activeSplit == nil)
        #expect(window.session.ownedSurfaces.contains { $0 === left })
        #expect(window.session.ownedSurfaces.contains { $0 === right })
        #expect(left.requestedURLs.count == 1 && right.requestedURLs.count == 1)
        #expect(window.session.selectedSurface === right)
    }

    @Test("Three equal columns preserve documents through focus and closing a pane")
    func threePaneClose() async throws {
        let (_, window, first) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        for path in ["middle", "right"] {
            window.session.addSplitPane(url: URL(string: "https://split.test/" + path)!)
            await settle(window)
        }
        let split = try #require(window.session.activeSplit)
        #expect(split.group.orientation == .horizontal)
        let equalRatios = Array(repeating: 1.0 / 3.0, count: 3)
        #expect(split.group.ratios == equalRatios)
        let ids = split.group.tabIDs
        let middle = try #require(window.session.surface(for: split.tabs[1].occurrenceID!))
        let right = try #require(window.session.selectedSurface)
        window.split.view.onFocus?(ids[1])
        await settle(window)
        #expect(window.session.selectedSurface === middle)
        let view = window.split.view
        window.session.closeSplitPane(ids[1])
        await settle(window)
        #expect(window.split.view === view)
        #expect(window.session.activeSplit?.group.tabIDs == [ids[0], ids[2]])
        #expect(!first.isDisposed && !right.isDisposed && middle.isDisposed)
        #expect(first.requestedURLs.count == 1 && right.requestedURLs.count == 1)
        window.session.closeSplitPane(ids[2])
        await settle(window)
        #expect(window.session.activeSplit == nil)
        #expect(window.session.selectedSurface === first)
    }

    private func payload(_ window: Window, _ id: TabID) throws -> SidebarDragPayload {
        let organization = try #require(window.session.organization)
        return SidebarDragPayload(sourceWindow: window.id, spaceID: organization.spaceID, profileID: organization.profileID,
                                  nodes: [.tab(id)], rowCount: 1, grabOffsetX: 0)
    }

    @Test("A Pinned tab dropped on a Today tab's leading half splits in the target's place and section")
    func sidebarTabDropSplitsInTargetSection() async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        let source = try #require(window.session.organization?.selectedTab?.id)
        window.session.openTab(url: URL(string: "https://split.test/target")!)
        await settle(window)
        let target = try #require(window.session.organization?.selectedTab?.id)
        window.session.pinTabs([source])
        await settle(window)
        let spaceID = try #require(window.session.organization?.spaceID)
        #expect(window.sidebarSplitDropVerdict(try payload(window, source), target: target) == .accepted)
        #expect(window.sidebarSplitDropVerdict(try payload(window, source), target: source) == nil)
        window.dropSidebarTab(try payload(window, source), onto: target, leading: true)
        await settle(window)
        let split = try #require(window.session.organization?.split(containing: target))
        #expect(split.group.tabIDs == [source, target])
        #expect(window.session.organization?.tab(source)?.section == .today(spaceID))
        #expect(window.session.organization?.tab(target)?.section == .today(spaceID))
        #expect(window.session.organization?.pinned.isEmpty == true)
        // Separating it is undoable as one edit.
        _ = window.session.undoOrganization()
        await settle(window)
        #expect(window.session.organization?.split(containing: target) == nil)
        #expect(window.session.organization?.tab(source)?.section == .pinned(spaceID))
    }

    @Test("A trailing drop puts the source second; a split target appends it last and a full split refuses with the bubble")
    func sidebarTabDropOnSplitAppendsUntilFull() async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        var ids = [try #require(window.session.organization?.selectedTab?.id)]
        for index in 1...4 {
            window.session.openTab(url: URL(string: "https://split.test/\(index)")!)
            await settle(window)
            ids.append(try #require(window.session.organization?.selectedTab?.id))
        }
        window.dropSidebarTab(try payload(window, ids[1]), onto: ids[0], leading: false)
        await settle(window)
        #expect(window.session.organization?.split(containing: ids[0])?.group.tabIDs == [ids[0], ids[1]])
        for source in ids[2...3] {
            #expect(window.sidebarSplitDropVerdict(try payload(window, source), target: ids[0]) == .accepted)
            window.dropSidebarTab(try payload(window, source), onto: ids[1], leading: true)
            await settle(window)
        }
        #expect(window.session.organization?.split(containing: ids[0])?.group.tabIDs == Array(ids[0...3]))
        #expect(window.sidebarSplitDropVerdict(try payload(window, ids[4]), target: ids[0]) == .full)
        // A pane of a split is not a draggable source for this gesture.
        #expect(window.sidebarSplitDropVerdict(try payload(window, ids[0]), target: ids[4]) == nil)
        window.dropSidebarTab(try payload(window, ids[4]), onto: ids[2], leading: false)
        await settle(window)
        #expect(window.session.organization?.split(containing: ids[0])?.tabs.count == 4)
        #expect(window.session.organization?.split(containing: ids[4]) == nil)
        let bubble = try #require(window.window?.contentView?.subviews.first {
            $0.accessibilityIdentifier() == BrowserSplitLimitBubble.identifier })
        let root = try #require(window.window?.contentView)
        #expect(abs(bubble.frame.maxX - (root.bounds.maxX - 4.5)) < 0.01)
        #expect(bubble.frame.height == 41.5)
        #expect(bubble.accessibilityLabel() == uiText("Cannot Add New Pane"))
    }

    @Test("The sidebar drop zone covers the hovered half, or a split row's whole pitch")
    func sidebarDropZoneGeometry() async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        window.session.openTab(url: URL(string: "https://split.test/zone")!)
        await settle(window)
        let list = window.sidebar.page.list
        let id = try #require(window.session.organization?.selectedTab?.id)
        let row = try #require(list.row(for: .tab(id)))
        let center = NSPoint(x: row.frame.midX, y: row.frame.midY)
        #expect(list.splitDropCandidate(at: NSPoint(x: center.x, y: center.y + 11)) == nil)
        let target = try #require(list.splitDropCandidate(at: center))
        #expect(target.tabID == id && !target.isSplit)
        list.showSplitDropFeedback(target, leading: true)
        let leading = try #require(list.splitDropFeedbackFrame)
        #expect(leading.minX == row.frame.minX + 4 && leading.maxX == row.frame.midX && leading.height == row.frame.height)
        #expect((row as? SidebarTabRow)?.splitPreviewShift == row.frame.width / 2 + 1)
        list.showSplitDropFeedback(target, leading: false)
        let trailing = try #require(list.splitDropFeedbackFrame)
        #expect(trailing.minX == row.frame.midX + 5.75)
        #expect((row as? SidebarTabRow)?.splitPreviewShift == 0)
        list.clearSplitDropFeedback()
        #expect(list.splitDropFeedbackFrame == nil)
        window.session.addSplitPane(url: URL(string: "https://split.test/zone-right")!)
        await settle(window)
        let split = try #require(window.session.activeSplit)
        let splitRow = try #require(list.row(for: .split(split.group.id)))
        let band = try #require(list.splitDropCandidate(at: NSPoint(x: splitRow.frame.midX, y: splitRow.frame.midY)))
        #expect(band.isSplit)
        list.showSplitDropFeedback(band, leading: true)
        let frame = try #require(list.splitDropFeedbackFrame)
        #expect(frame.width == list.bounds.width && frame.height == 41)
        list.clearSplitDropFeedback()
    }

    @Test("The Peek Split button keeps its fill, lifts on hover and shrinks while pressed")
    func peekSplitButtonMotion() throws {
        let button = BrowserPeekToolbarButton(symbol: "rectangle.split.2x1", label: "", identifier: "t", feedback: .motion)
        #expect(button.motionState.lift == 0 && button.motionState.scale == 1)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        button.mouseEntered(with: enter)
        #expect(button.motionState.lift == 1 && button.motionState.scale == 1)
        let close = BrowserPeekToolbarButton(symbol: "xmark", label: "", identifier: "c")
        close.mouseEntered(with: enter)
        #expect(close.motionState.lift == 0)
    }

    @Test("The pane menu inserts on either side of its target and old menu actions expire")
    func menuInsertion() async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        window.session.addSplitPane(url: URL(string: "https://split.test/right")!)
        await settle(window)
        let original = try #require(window.session.activeSplit).group.tabIDs
        let menu = window.makeSplitPaneMenu(original[1])
        let addLeft = menu.items[4]
        _ = (addLeft.target as? NSObject)?.perform(addLeft.action, with: addLeft)
        await settle(window)
        let group = try #require(window.session.activeSplit)
        #expect(group.tabs.count == 3)
        #expect(group.group.tabIDs.first == original[0] && group.group.tabIDs.last == original[1])
        #expect(group.tabs[1].url.absoluteString == "about:blank")
        let oldMove = menu.items[0]
        _ = (oldMove.target as? NSObject)?.perform(oldMove.action, with: oldMove)
        await settle(window)
        #expect(window.session.activeSplit?.group == group.group)
    }

    @Test("An empty focused pane keeps only back, forward, address and close controls")
    func emptyPaneHeader() {
        let pane = BrowserSplitPaneView(id: TabID())
        pane.frame = CGRect(x: 0, y: 0, width: 410, height: 760)
        pane.present(NSView(), address: "about:blank")
        pane.setActive(true, accent: .defaultPurple)
        pane.layoutSubtreeIfNeeded()
        #expect(pane.reload.isHidden && pane.siteControls.isHidden && pane.splitToggle.isHidden)
        #expect(!pane.back.isHidden && !pane.forward.isHidden && !pane.close.isHidden)
    }

    @Test("Hidden split surfaces retain their documents and commands follow the focused pane")
    func focusRouting() async throws {
        let (_, window, left) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        window.session.addSplitPane(url: URL(string: "https://split.test/right")!)
        await settle(window)
        let right = try #require(window.session.selectedSurface)
        let group = try #require(window.session.activeSplit)
        #expect(left !== right)
        #expect(window.split.view.panes.count == 2)
        #expect(left.hostView.window === window.window)
        #expect(right.hostView.window === window.window)
        let leftTab = try #require(group.tabs.first { $0.occurrenceID == window.session.occurrenceID(for: left) })
        window.split.view.onFocus?(leftTab.id)
        await settle(window)
        #expect(window.session.selectedSurface === left)
        #expect(window.pageCommandSurface() === left)
        #expect(window.findSession.selectedSurface === left)
        #expect(window.window?.firstResponder === left.documentView)
        window.changePageZoom(.increase)
        await settle(window)
        #expect(abs(left.pageZoom - 1.1) < 0.000_001)
        #expect(right.pageZoom == 1)
        #expect(window.addressField.stringValue == "https://split.test/left")
        #expect(left.requestedURLs.count == 1)
        #expect(right.requestedURLs.count == 1)
        #expect(window.window?.isVisible == false)
    }

    @Test("Peek handoff keeps the exact live surface, its document state, profile and load count")
    func peekHandoff() async throws {
        let (_, window, source) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        let peek = try #require(window.openPeek(URL(string: "https://split.test/peek")!))
        peek.documentState = "synthetic form state"
        let count = peek.requestedURLs.count
        #expect(window.peek.splitHandoff != nil)
        #expect(window.openPeekInSplit())
        await settle(window)
        #expect(window.session.activeSplit?.tabs.count == 2)
        #expect(window.session.selectedSurface === peek)
        #expect(window.session.ownedSurfaces.contains { $0 === source })
        #expect(peek.documentState == "synthetic form state")
        #expect(peek.requestedURLs.count == count)
        #expect(peek.profileID == source.profileID)
        #expect(!window.isPeekPresented)
        #expect(!peek.isDisposed)
    }

    @Test("A full split refuses Peek handoff synchronously and keeps Peek's surface")
    func refusedHandoff() async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        for _ in 0..<3 { window.session.addSplitPane(); await settle(window) }
        let peek = try #require(window.openPeek(URL(string: "https://split.test/peek")!))
        #expect(!window.openPeekInSplit())
        #expect(window.isPeekPresented)
        #expect(window.peek.owns(peek))
        #expect(!peek.isDisposed)
    }

    @Test("Registry uses Orbit's add/close shortcuts and enables orientation/swap/separation")
    func commands() async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        let router = BrowserWindowRouter<Window>(create: { _ in window }, present: { _,_ in }, dispose: { _ in })
        _ = router.newWindow(id: window.id)
        await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        #expect(registry.resolve(.init(key: "=", modifiers: [.control,.shift])) == .addSplitView)
        #expect(registry.dispatch(.addSplitView, origin: .keyboard))
        await settle(window)
        #expect(registry.isEnabled(.closeThisSplitPane))
        #expect(registry.dispatch(.toggleSplitOrientation, origin: .menu))
        await settle(window)
        #expect(window.session.activeSplit?.group.orientation == .vertical)
        #expect(registry.dispatch(.swapSplitPanes, origin: .menu))
        await settle(window)
        #expect(registry.dispatch(.unsplitAllPanes, origin: .menu))
        await settle(window)
        #expect(window.session.activeSplit == nil)
        #expect(!registry.isEnabled(.closeThisSplitPane))
    }

    @Test("One grouped sidebar row renders every addressable pane and accepts edge drops only in its Space")
    func sidebarAndDrops() async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        let left = try #require(window.session.organization?.selectedTab?.id)
        window.session.openTab(url: URL(string: "https://split.test/right")!)
        await settle(window)
        let right = try #require(window.session.organization?.selectedTab?.id)
        let organization = try #require(window.session.organization)
        let payload = SidebarDragPayload(sourceWindow: window.id, spaceID: organization.spaceID, profileID: organization.profileID,
                                         nodes: [.tab(left)], rowCount: 1, grabOffsetX: 0)
        #expect(window.canDropIntoSplit(payload))
        window.dropIntoSplit(payload, orientation: .vertical, leading: true)
        await settle(window)
        let split = try #require(window.session.activeSplit)
        #expect(split.group.tabIDs == [left,right])
        let content = SidebarListContent(snapshot: window.session.organization)
        #expect(content.entries.count == 1)
        if case let .split(_, ids) = content.entries[0].content { #expect(ids == [left,right]) }
        else { Issue.record("Expected one grouped split row") }
        let foreign = SidebarDragPayload(sourceWindow: window.id, spaceID: SpaceID(), profileID: organization.profileID,
                                         nodes: [.tab(left)], rowCount: 1, grabOffsetX: 0)
        #expect(!window.canDropIntoSplit(foreign))
    }

    @Test("Reduced motion sets focus immediately and split view never reloads a host")
    func reducedMotion() throws {
        let old = OrbitMotionPreferences.overrideReducedMotion
        OrbitMotionPreferences.overrideReducedMotion = true
        defer { OrbitMotionPreferences.overrideReducedMotion = old }
        let pane = BrowserSplitPaneView(id: TabID())
        let host = NSView()
        pane.present(host, address: "https://split.test/")
        pane.setActive(true, accent: .defaultPurple)
        pane.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        pane.layoutSubtreeIfNeeded()
        #expect(pane.layer?.sublayers?.last?.opacity == 1)
        #expect(pane.layer?.sublayers?.last?.animation(forKey: "splitFocus") == nil)
        #expect(host.superview === pane.page)
        #expect(abs(pane.page.frame.height - 268) < 0.000_001)
    }
}
}

extension NativeWebKitTests.NativeSplitTests {
    @Test("A grouped sidebar drop transfers both live pages across hidden windows without replay")
    func crossWindowGroupTransfer() async throws {
        let (environment, source, left) = try await makeWindow()
        let destination = try await environment.makeWindow()
        defer {
            source.session.close(); source.window?.close()
            destination.session.close(); destination.window?.close()
        }
        source.session.addSplitPane(url: URL(string: "https://split.test/right")!)
        await settle(source)
        let right = try #require(source.session.selectedSurface)
        left.documentState = "left form"; right.documentState = "right form"
        let split = try #require(source.session.activeSplit)
        destination.session.synchronizeOrganization()
        await settle(destination)
        let organization = try #require(destination.session.organization)
        let peer = try await environment.makeWindow()
        defer { peer.session.close(); peer.window?.close() }
        let peerID = try #require(peer.session.snapshot?.id)
        let destinationID = try #require(destination.session.snapshot?.id)
        let madeBefore = environment.engine.surfaces.count
        let oldSourceMembership = source.session.onSurfaceMembershipChange
        let oldDestinationMembership = destination.session.onSurfaceMembershipChange
        var released = 0, recorded = 0
        source.session.onSurfaceMembershipChange = { surface, membership in
            oldSourceMembership?(surface, membership)
            if membership == nil {
                released += 1
                if released == 1 { splitNativePeerMutation(environment.store, window: peerID, space: organization.spaceID) }
            }
        }
        destination.session.onSurfaceMembershipChange = { surface, membership in
            oldDestinationMembership?(surface, membership)
            if membership != nil {
                recorded += 1
                #expect(destination.session.occurrenceID(for: left) != nil)
                #expect(destination.session.occurrenceID(for: right) != nil)
                if recorded == 1 { splitNativePeerMutation(environment.store, window: peerID, space: organization.spaceID) }
            }
        }
        let payload = SidebarDragPayload(sourceWindow: source.id, spaceID: organization.spaceID,
            profileID: organization.profileID, nodes: [.split(split.group.id)], rowCount: 1, grabOffsetX: 0)
        destination.performSidebarDrop(payload, to: .init(.today(organization.spaceID)), changesOrganization: false)
        await settle(source); await settle(destination)
        #expect(destination.session.ownedSurfaces.contains { $0 === left })
        #expect(destination.session.ownedSurfaces.contains { $0 === right })
        #expect(!source.session.ownedSurfaces.contains { $0 === left || $0 === right })
        #expect(left.documentState == "left form")
        #expect(right.documentState == "right form")
        #expect(left.requestedURLs.count == 1)
        #expect(right.requestedURLs.count == 1)
        #expect(destination.session.activeSplit?.group == split.group)
        #expect(destination.session.selectedSurface === right)
        #expect(environment.engine.surfaces.count == madeBefore)
        #expect(released == 2 && recorded == 2)
        let moved = await environment.store.sessionDocument().tabs.filter { $0.windowID == destinationID && split.group.tabIDs.contains($0.id) }
        #expect(moved.count == 2 && Set(moved.map(\.id)) == Set(split.group.tabIDs))
        #expect(!left.isDisposed && !right.isDisposed)
    }

    @Test("A context command on another grouped row never changes the active split")
    func capturedContextGroup() async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        window.session.addSplitPane()
        await settle(window)
        let first = try #require(window.session.activeSplit)
        window.session.openTab(url: URL(string: "https://split.test/third")!)
        await settle(window)
        window.session.addSplitPane()
        await settle(window)
        let second = try #require(window.session.activeSplit)
        window.session.selectSplit(first.group.id)
        await settle(window)
        _ = window.sidebar.prepareContextMenu(for: .split(second.group.id))
        defer { window.sidebar.endContextMenu() }
        let router = BrowserWindowRouter<Window>(create: { _ in window }, present: { _,_ in }, dispose: { _ in })
        _ = router.newWindow(id: window.id)
        await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        #expect(registry.dispatch(.toggleSplitOrientation, origin: .contextMenu))
        await settle(window)
        #expect(window.session.activeSplit?.group.id == first.group.id)
        #expect(window.session.activeSplit?.group.orientation == .horizontal)
        guard case let .split(target)? = window.session.organization?.item(for: .split(second.group.id)) else {
            Issue.record("Context split vanished"); return
        }
        #expect(target.group.orientation == .vertical)
    }
}

extension NativeWebKitTests.NativeSplitTests {
    @Test("Split presentation retains whole outgoing roots until capture and invalidates superseded receipts")
    func splitCaptureReceipts() async throws {
        let card = BrowserContentCardView()
        let a = BrowserSplitView(), b = BrowserSplitView(), returnedA = BrowserSplitView()
        let host = NSView()
        a.presentSingle(host)
        var retirements: [@MainActor () -> Void] = []
        card.scheduleCaptureRetirement = { retirements.append($0) }
        let gate = SplitCaptureGate()
        let capture = Task { await gate.wait() }
        card.present(a, isSplit: true)
        card.present(b, isSplit: true, retainingPreviousUntil: capture)
        #expect(a.superview != nil)
        #expect(host.isDescendant(of: a))
        card.prepareToReparent(host)
        #expect(a.superview == nil)
        returnedA.presentSingle(host)
        card.present(returnedA, isSplit: true)
        retirements.forEach { $0() }
        await gate.release()
        await capture.value
        await Task.yield()
        #expect(returnedA.superview != nil)
        #expect(host.isDescendant(of: returnedA))
        #expect(b.superview == nil)
    }

    @Test("Focus within a split reuses its root and outgoing roots lose every interaction callback")
    func stableRootAndSuspension() async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        window.session.addSplitPane()
        await settle(window)
        let root = window.split.view
        let group = try #require(window.session.activeSplit)
        root.onFocus?(group.group.tabIDs[0])
        await settle(window)
        #expect(window.split.view === root)
        window.session.openTab()
        await settle(window)
        #expect(window.split.view !== root)
        #expect(root.onFocus == nil && root.onClose == nil && root.onResize == nil)
        #expect(root.onDrop == nil && root.canDrop == nil)
    }
}

private actor SplitCaptureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}


private func splitNativePeerMutation(_ store: BrowserStore, window: WindowID, space: SpaceID) {
    let signal = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            _ = try await store.createFolder(title: "Synthetic peer", at: .init(.pinned(space)),
                from: store.captureContext(in: window))
        } catch { Issue.record("Peer mutation failed: \(error)") }
        signal.signal()
    }
    #expect(signal.wait(timeout: .now() + 5) == .success)
}

extension NativeWebKitTests.NativeSplitTests {
    @Test("An in-transit focused surface keeps every split slot visible and returns without reloading")
    func missingSelectedSurfaceKeepsLayout() async throws {
        let (_, window, left) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        window.session.addSplitPane(url: URL(string: "https://split.test/transit")!)
        await settle(window)
        let right = try #require(window.session.selectedSurface)
        let group = try #require(window.session.activeSplit?.group)
        let transfer = try #require(window.session.releaseSurface(right))
        window.renderSplit()
        #expect(window.split.view.panes.count == 2)
        #expect(window.split.view.panes[group.tabIDs[1]]?.isShowingPlaceholder == true)
        #expect(left.hostView.isDescendant(of: window.split.view))
        transfer.cancel()
        await settle(window)
        #expect(window.split.view.panes[group.tabIDs[1]]?.isShowingPlaceholder == false)
        #expect(window.session.selectedSurface === right)
        #expect(left.requestedURLs.count == 1 && right.requestedURLs.count == 1)
    }

    @Test("Sidebar multi-selection archives a grouped row and a single row in the same command")
    func groupedMultiSelectionArchive() async throws {
        let (environment, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        window.session.addSplitPane()
        await settle(window)
        let group = try #require(window.session.activeSplit?.group)
        window.session.openTab(url: URL(string: "https://split.test/single")!)
        await settle(window)
        let single = try #require(window.session.organization?.selectedTab?.id)
        window.sidebar.list(window.sidebar.page.list, activate: .split(group.id), modifiers: .command)
        #expect(window.sidebar.selection.nodes == [.split(group.id), .tab(single)])
        window.archiveSelectedTabs()
        await settle(window)
        let archived = await environment.store.sessionDocument().organization.archive
        #expect(Set(archived.map { $0.tab.id }) == Set(group.tabIDs + [single]))
        #expect(window.session.organization?.today.isEmpty == true)
    }
}

extension NativeWebKitTests.NativeSplitTests {
    @Test("A fully rescued group requests its original Space and rehomes without making or loading another surface")
    func rescueIntoExactSpace() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let wrongSpace = try await environment.makeWindow()
        let profile = try #require(wrongSpace.session.activeProfileID)
        let space = try await environment.store.createSpace(name: "Synthetic rescue Space", profileID: profile)
        let source = try await environment.makeWindow(spaceID: space)
        let destination = try await environment.makeWindow(spaceID: space)
        defer {
            for window in environment.liveControllers { window.session.close(); window.window?.close() }
        }
        source.submitAddress("https://split.test/rescue-a")
        await settle(source)
        let left = try #require(source.session.selectedSurface)
        source.session.addSplitPane(url: URL(string: "https://split.test/rescue-b")!)
        await settle(source)
        let right = try #require(source.session.selectedSurface)
        let group = try #require(source.session.activeSplit?.group)
        let requests = AsyncStream<(ProfileID, SpaceID)>.makeStream()
        var count = 0
        environment.onRescueSplitNeedsWindow = { profile, space in
            count += 1; requests.continuation.yield((profile, space)); requests.continuation.finish()
        }
        let made = environment.engine.surfaces.count
        let handoff = try #require(source.moveSplitGroup(group, to: destination))
        source.session.close(); destination.session.close()
        #expect(await handoff.value == nil)
        var requested: (ProfileID, SpaceID)?
        for await request in requests.stream { requested = request; break }
        #expect(requested?.0 == profile && requested?.1 == space)
        #expect(count == 1)
        #expect(environment.rescue.owns(left) && environment.rescue.owns(right))
        #expect(environment.engine.surfaces.count == made)
        #expect(!wrongSpace.session.ownedSurfaces.contains { $0 === left || $0 === right })
        let recovered = try await environment.makeWindow(spaceID: space)
        await environment.settleTransfers()
        await settle(recovered)
        #expect(environment.rescue.surfaces.isEmpty)
        #expect(recovered.session.activeSplit?.group == group)
        #expect(recovered.session.ownedSurfaces.contains { $0 === left })
        #expect(recovered.session.ownedSurfaces.contains { $0 === right })
        #expect(environment.engine.surfaces.count == made)
        #expect(left.requestedURLs.count == 1 && right.requestedURLs.count == 1)
    }

    @Test("Changed rescue metadata falls back to live standalone tabs and termination completes", arguments: [false, true])
    func incompatibleRescueMetadata(ratiosOnly: Bool) async throws {
        let (environment, source, left) = try await makeWindow()
        let destination = try await environment.makeWindow()
        let peer = try await environment.makeWindow()
        defer { for window in environment.liveControllers { window.session.close(); window.window?.close() } }
        source.session.addSplitPane(url: URL(string: "https://split.test/rescue-b")!)
        await settle(source)
        let right = try #require(source.session.selectedSurface)
        let group = try #require(source.session.activeSplit?.group)
        let profile = try #require(source.session.activeProfileID)
        let otherSpace = try await environment.store.createSpace(name: "Moved group", profileID: profile)
        let peerID = try #require(peer.session.snapshot?.id)
        let made = environment.engine.surfaces.count
        let initialTabCount = await environment.store.sessionDocument().organization.tabs.count
        let handoff = try #require(source.moveSplitGroup(group, to: destination))
        source.session.close(); destination.session.close()
        if ratiosOnly {
            _ = try await environment.store.resizeSplit(group.id, ratios: [0.25, 0.75],
                from: environment.store.captureContext(in: peerID))
        } else {
            _ = try await environment.store.moveItems([.split(group.id)], to: .init(.today(otherSpace)),
                from: environment.store.captureContext(in: peerID))
        }
        #expect(await handoff.value == nil)
        try await waitForRehome(environment, surfaces: [left, right])
        #expect(environment.rescue.groupedRescueIDs.isEmpty)
        #expect(environment.engine.surfaces.count == made)
        #expect(left.requestedURLs.count == 1 && right.requestedURLs.count == 1)
        let saved = await environment.store.sessionDocument()
        #expect(saved.organization.splits.isEmpty)
        #expect(Set(saved.organization.tabs.map(\.id)).isSuperset(of: Set(group.tabIDs)))
        #expect(saved.organization.tabs.count == initialTabCount)
        try await environment.prepareToSaveForTermination()
        try await environment.finalize()
        try await environment.store.sessionDocument().validate()
        #expect(!left.isDisposed && !right.isDisposed)
    }

    @Test("An archived member with no remaining source transit is rescued separately while its sibling returns, then Quit succeeds")
    func incompleteRescueAfterPeerArchive() async throws {
        let (environment, source, left) = try await makeWindow()
        let destination = try await environment.makeWindow()
        let peer = try await environment.makeWindow()
        defer { for window in environment.liveControllers { window.session.close(); window.window?.close() } }
        source.session.addSplitPane(url: URL(string: "https://split.test/archived-live-document")!)
        await settle(source)
        let right = try #require(source.session.selectedSurface)
        let group = try #require(source.session.activeSplit?.group)
        let sourceID = try #require(source.session.snapshot?.id)
        let peerID = try #require(peer.session.snapshot?.id)
        let made = environment.engine.surfaces.count
        let store = environment.store
        let transfers = try #require(source.session.releaseSurfaces([left, right]))
        var didMutate = false
        let adoption = destination.session.acceptSplitGroupTransfers(transfers, group: group, activating: group.tabIDs.first) { surface in
            destination.bindSurface(surface)
            guard !didMutate else { return }
            didMutate = true
            let signal = SplitNativeStateSignal()
            Task.detached {
                do {
                    _ = try await store.closeTabs([group.tabIDs[1]], from: store.captureContext(in: peerID))
                    signal.finish(try await store.captureWindowState(in: sourceID))
                } catch { signal.finish(nil) }
            }
            if let state = signal.wait() { source.session.install(state) }
            else { Issue.record("Peer archive did not return its source state") }
        }
        #expect(await adoption.value == nil)
        #expect(transfers[0].state == .returned && transfers[1].state == .rescued)
        try await waitForRehome(environment, surfaces: [left, right])
        let saved = await environment.store.sessionDocument()
        #expect(saved.organization.archive.contains { $0.tab.id == group.tabIDs[1] })
        #expect(saved.organization.splits.isEmpty)
        #expect(environment.engine.surfaces.count == made)
        #expect(right.requestedURLs.count == 1 && !right.isDisposed)
        try await environment.prepareToSaveForTermination()
        try await environment.finalize()
        try await environment.store.sessionDocument().validate()
    }

    @Test("Quit preserves an intact rescued group without a receiver window and retries do not duplicate its logical tabs")
    func rescueWithoutWindowDuringQuit() async throws {
        let (environment, source, left) = try await makeWindow()
        let destination = try await environment.makeWindow()
        defer { for window in environment.liveControllers { window.session.close(); window.window?.close() } }
        source.session.addSplitPane(url: URL(string: "https://split.test/no-window")!)
        await settle(source)
        let right = try #require(source.session.selectedSurface)
        let group = try #require(source.session.activeSplit?.group)
        let initialTabCount = await environment.store.sessionDocument().organization.tabs.count
        let handoff = try #require(source.moveSplitGroup(group, to: destination))
        source.session.close(); destination.session.close()
        #expect(await handoff.value == nil)
        try await environment.prepareToSaveForTermination()
        let first = await environment.store.sessionDocument()
        #expect(first.organization.tabs.count == initialTabCount)
        #expect(first.organization.splits.contains { $0 == group })
        #expect(environment.rescue.groupedRescueIDs == [group.id])
        #expect(environment.rescue.owns(left) && environment.rescue.owns(right))
        #expect(!left.isDisposed && !right.isDisposed)
        try await environment.prepareToSaveForTermination()
        let second = await environment.store.sessionDocument()
        #expect(second.organization.tabs.map(\.id) == first.organization.tabs.map(\.id))
        try second.validate()
        try await environment.finalize()
    }

    private func waitForRehome(_ environment: BrowserEnvironment<PeekSyntheticEngine>, surfaces: [PeekSyntheticSurface]) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !surfaces.allSatisfy({ surface in
            environment.liveControllers.contains { $0.session.occurrenceID(for: surface) != nil }
        }) {
            guard ContinuousClock.now < deadline else { throw SplitRehomeTestError.timedOut }
            await environment.settleTransfers(timeout: .milliseconds(100))
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("A failed final save reissues the abandoned Space request and rehomes the exact group without duplicate tabs or loads")
    func finalSaveFailureRetriesRescue() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: "/private/tmp/orbit-split-save-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("Session")
        let file = parent.appendingPathComponent("session.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try await BrowserEnvironment.open(engine: PeekSyntheticEngine(), sessionFile: file)
        let source = try await environment.makeWindow()
        let destination = try await environment.makeWindow()
        let profile = try #require(source.session.activeProfileID)
        let space = try #require(source.session.snapshot?.activeSpaceID)
        let otherSpace = try await environment.store.createSpace(name: "Other rescue Space", profileID: profile)
        let other = try await environment.makeWindow(spaceID: otherSpace)
        var recovered: Window?
        defer {
            for window in environment.liveControllers { window.session.close(); window.window?.close() }
        }
        source.submitAddress("https://split.test/save-failure-a")
        await settle(source)
        let left = try #require(source.session.selectedSurface)
        source.session.addSplitPane(url: URL(string: "https://split.test/save-failure-b")!)
        await settle(source)
        let right = try #require(source.session.selectedSurface)
        let group = try #require(source.session.activeSplit?.group)
        let initialTabCount = await environment.store.sessionDocument().organization.tabs.count
        let made = environment.engine.surfaces.count
        var requests = 0, fulfill = false
        let firstRequest = AsyncStream<Void>.makeStream()
        environment.onRescueSplitNeedsWindow = { _, requestedSpace in
            #expect(requestedSpace == space)
            requests += 1
            if !fulfill { firstRequest.continuation.yield(()); firstRequest.continuation.finish(); return }
            Task {
                do { recovered = try await environment.makeWindow(spaceID: requestedSpace) }
                catch { Issue.record("Synthetic recovery window failed: \(error)") }
            }
        }
        let handoff = try #require(source.moveSplitGroup(group, to: destination))
        source.session.close(); destination.session.close()
        #expect(await handoff.value == nil)
        for await _ in firstRequest.stream { break }
        #expect(requests == 1)
        try await environment.prepareToSaveForTermination()
        // A regular file in place of the synthetic parent guarantees failure without relying on
        // the user's permissions, Keychain or a real session destination.
        if FileManager.default.fileExists(atPath: parent.path) { try FileManager.default.removeItem(at: parent) }
        try Data("synthetic save blocker".utf8).write(to: parent)
        var failed = false
        do { try await environment.finalize() } catch { failed = true }
        #expect(failed)
        for controller in environment.liveControllers { controller.cancelTerminationPreparation() }
        fulfill = true
        environment.terminationDidCancel()
        try await waitForRehome(environment, surfaces: [left, right])
        #expect(requests == 2)
        #expect(recovered?.session.activeSplit?.group == group)
        #expect(!other.session.ownedSurfaces.contains { $0 === left || $0 === right })
        #expect(environment.engine.surfaces.count == made)
        #expect(left.requestedURLs.count == 1 && right.requestedURLs.count == 1)
        #expect(await environment.store.sessionDocument().organization.tabs.count == initialTabCount)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try await environment.prepareToSaveForTermination()
        try await environment.finalize()
        let saved = try BrowserSessionDocument.decode(Data(contentsOf: file))
        #expect(saved.organization.tabs.count == initialTabCount)
    }

    @Test("Two rescued occurrences of one logical group preserve four distinct documents across repeated Quit")
    func overlappingRescueIdentities() async throws {
        let (environment, source, left) = try await makeWindow()
        source.session.addSplitPane(url: URL(string: "https://split.test/original-b")!)
        await settle(source)
        let right = try #require(source.session.selectedSurface)
        let group = try #require(source.session.activeSplit?.group)
        let secondSource = try await environment.makeWindow()
        let destination = try await environment.makeWindow()
        let secondDestination = try await environment.makeWindow()
        defer { for window in environment.liveControllers { window.session.close(); window.window?.close() } }
        secondSource.session.selectSplit(group.id)
        await settle(secondSource)
        let other = try group.tabIDs.map { id in
            let occurrence = try #require(secondSource.session.organization?.tab(id)?.occurrenceID)
            return try #require(secondSource.session.surface(for: occurrence))
        }
        other[0].navigate(to: URL(string: "https://split.test/independent-c")!)
        other[1].navigate(to: URL(string: "https://split.test/independent-d")!)
        await settle(secondSource)
        let documents = [left, right] + other
        let urls = Set(documents.compactMap(\.currentURL))
        #expect(urls.count == 4)
        let before = await environment.store.sessionDocument()
        let first = try #require(source.moveSplitGroup(group, to: destination))
        let second = try #require(secondSource.moveSplitGroup(group, to: secondDestination))
        for window in [source, secondSource, destination, secondDestination] { window.session.close() }
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        try await environment.prepareToSaveForTermination()
        let saved = await environment.store.sessionDocument()
        #expect(saved.organization.tabs.count == before.organization.tabs.count + 2)
        #expect(Set(saved.organization.tabs.map(\.url)).isSuperset(of: urls))
        #expect(documents.allSatisfy { environment.rescue.owns($0) && !$0.isDisposed })
        try saved.validate()
        try await environment.prepareToSaveForTermination()
        let retried = await environment.store.sessionDocument()
        #expect(retried.organization.tabs == saved.organization.tabs)
        #expect(retried.organization.splits == saved.organization.splits)
        try await environment.finalize()
    }

    @Test("A refused rescue adoption retries as standalone tabs without requiring a cancelled Quit")
    func rescueAdoptionRetries() async throws {
        let (environment, source, left) = try await makeWindow()
        let destination = try await environment.makeWindow()
        let rejecting = try await environment.makeWindow()
        let recovered = try await environment.makeWindow()
        defer { for window in environment.liveControllers { window.session.close(); window.window?.close() } }
        rejecting.freezeCommandsForTermination()
        recovered.freezeCommandsForTermination()
        source.session.addSplitPane(url: URL(string: "https://split.test/retry-rescue")!)
        await settle(source)
        let right = try #require(source.session.selectedSurface)
        let group = try #require(source.session.activeSplit?.group)
        let ready = AsyncStream<Void>.makeStream()
        environment.onRescueSplitNeedsWindow = { _, _ in ready.continuation.yield(()); ready.continuation.finish() }
        let handoff = try #require(source.moveSplitGroup(group, to: destination))
        source.session.close(); destination.session.close()
        #expect(await handoff.value == nil)
        for await _ in ready.stream { break }
        environment.rescue.onRescue = nil
        environment.rescue.onRescueReadinessChange = nil
        var rejected = false
        left.onDelegateChange = {
            guard !rejected else { return }
            rejected = true
            rejecting.session.close()
            recovered.cancelTerminationPreparation()
        }
        rejecting.cancelTerminationPreparation()
        environment.rehomeRescuedSurfaces()
        try await waitForRehome(environment, surfaces: [left, right])
        left.onDelegateChange = nil
        #expect(rejected)
        #expect(recovered.session.occurrenceID(for: left) != nil && recovered.session.occurrenceID(for: right) != nil)
        #expect(recovered.session.activeSplit == nil)
        #expect(environment.rescue.surfaces.isEmpty)
        #expect(left.requestedURLs.count == 1 && right.requestedURLs.count == 1)
        try await environment.prepareToSaveForTermination()
        try await environment.finalize()
    }

}

private enum SplitRehomeTestError: Error { case timedOut }
private final class SplitNativeStateSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var state: BrowserWindowState?
    func finish(_ state: BrowserWindowState?) { lock.withLock { self.state = state }; signal.signal() }
    func wait() -> BrowserWindowState? {
        guard signal.wait(timeout: .now() + 5) == .success else { return nil }
        return lock.withLock { state }
    }
}

extension NativeWebKitTests.NativeSplitTests {
    @Test("Option-click duplicates the current tab, joins another sidebar tab, and separates a grouped row")
    func optionSidebar() async throws {
        let (_, window, first) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        let firstID = try #require(window.session.organization?.selectedTab?.id)
        window.sidebar.list(window.sidebar.page.list, activate: .tab(firstID), modifiers: [.option])
        await settle(window)
        let group = try #require(window.session.activeSplit)
        #expect(group.tabs.count == 2 && group.tabs.allSatisfy { $0.url == first.currentURL })
        #expect(window.session.selectedSurface !== first)
        window.sidebar.list(window.sidebar.page.list, activate: .split(group.group.id), modifiers: [.option])
        await settle(window)
        #expect(window.session.activeSplit == nil)
        #expect(window.session.organization?.allTabs.count == 2)
        window.sidebar.list(window.sidebar.page.list, activate: .tab(firstID), modifiers: [.option])
        await settle(window)
        #expect(window.session.activeSplit?.tabs.count == 2)
        #expect(window.session.ownedSurfaces.contains { $0 === first })
    }

    @Test("Option-clicked links use both engine routes and refuse a fifth pane without navigation or orphan targets")
    func optionLinksAndLimit() async throws {
        let (environment, window, first) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        first.clickLink(to: URL(string: "https://split.test/navigation")!, modifiers: [.option])
        await settle(window)
        #expect(first.currentURL?.path == "/left")
        #expect(window.session.activeSplit?.tabs.count == 2)
        let second = try #require(window.session.selectedSurface)
        let child = try #require(second.openNewTarget(URL(string: "https://split.test/target")!, modifiers: [.option]))
        await settle(window)
        #expect(window.session.activeSplit?.tabs.count == 3)
        #expect(window.session.selectedSurface === child && child.requestedURLs.count == 1)
        window.addSplitFromSelection()
        await settle(window)
        window.palette.dismiss(returnFocus: false)
        let current = try #require(window.session.selectedSurface)
        let made = environment.engine.surfaces.count
        let url = current.currentURL
        current.clickLink(to: URL(string: "https://split.test/refused")!, modifiers: [.option])
        #expect(current.openNewTarget(URL(string: "https://split.test/refused-target")!, modifiers: [.option]) == nil)
        window.sidebar.list(window.sidebar.page.list, activate: .tab(window.session.organization!.selectedTab!.id), modifiers: [.option])
        await settle(window)
        #expect(window.session.activeSplit?.tabs.count == 4)
        #expect(current.currentURL == url && environment.engine.surfaces.count == made)
        let paneMenu = window.makeSplitPaneMenu(window.session.organization!.selectedTab!.id)
        #expect(paneMenu.items.filter { [uiText("Add Right Split"), uiText("Add Left Split")].contains($0.title) }.allSatisfy { !$0.isEnabled })
        let request = BrowserContextMenuRequest(location: .zero, pageURL: current.currentURL,
            linkURL: URL(string: "https://split.test/context-refused")!, documentGeneration: current.documentGeneration)
        window.pageInteraction.menu = .init(surface: current, surfaceKey: ObjectIdentifier(current), request: request)
        window.performPageContextCommand(.pageOpenLinkInSplitView)
        await settle(window)
        #expect(window.session.activeSplit?.tabs.count == 4 && environment.engine.surfaces.count == made)
        #expect(!window.canAddSplitPane)
    }

    @Test("All existing content-edge drop directions retain a pinned source and reject a fifth pane",
          arguments: [BrowserSplitOrientation.horizontal, .vertical], [false, true])
    func pinnedEdgeDrop(_ orientation: BrowserSplitOrientation, leading: Bool) async throws {
        let (_, window, _) = try await makeWindow()
        defer { window.session.close(); window.window?.close() }
        let source = try #require(window.session.organization?.selectedTab?.id)
        window.session.pinTabs([source])
        await settle(window)
        window.session.openTab(url: URL(string: "https://split.test/target")!)
        await settle(window)
        let target = try #require(window.session.organization?.selectedTab?.id)
        let organization = try #require(window.session.organization)
        let payload = SidebarDragPayload(sourceWindow: window.id, spaceID: organization.spaceID,
            profileID: organization.profileID, nodes: [.tab(source)], rowCount: 1, grabOffsetX: 0)
        #expect(window.canDropIntoSplit(payload))
        window.dropIntoSplit(payload, orientation: orientation, leading: leading)
        await settle(window)
        let group = try #require(window.session.activeSplit)
        #expect(group.group.tabIDs == (leading ? [source,target] : [target,source]))
        #expect(group.group.orientation == orientation)
        #expect(window.session.organization?.pinned.map(\.node) == [.split(group.group.id)])
        for _ in 0..<2 { window.session.addSplitPane(); await settle(window) }
        window.session.openTab(url: URL(string: "https://split.test/extra")!)
        await settle(window)
        let extra = try #require(window.session.organization?.selectedTab?.id)
        window.session.selectSplit(group.group.id)
        await settle(window)
        let fifth = SidebarDragPayload(sourceWindow: window.id, spaceID: organization.spaceID,
            profileID: organization.profileID, nodes: [.tab(extra)], rowCount: 1, grabOffsetX: 0)
        #expect(!window.canDropIntoSplit(fifth))
        window.dropIntoSplit(fifth, orientation: orientation, leading: leading)
        await settle(window)
        #expect(window.session.activeSplit?.tabs.count == 4)
    }
}

struct SplitLinkRoutingTests {
    @Test("Only sole-Option user links qualify; forms, scripts, subframes and other gestures keep their route")
    func excludesOtherRequests() {
        var request = BrowserPeekLinkRequest(kind: .navigation, sourceRole: .unpinned,
            sourceURL: URL(string: "https://split.test/source"), destinationURL: URL(string: "https://split.test/link"),
            modifiers: [.option], buttonNumber: 0, isMainFrame: true, isUserLinkActivation: true, isReplayableRequest: true)
        #expect(BrowserSplitLinkRouting.accepts(request))
        request.isReplayableRequest = false
        #expect(!BrowserSplitLinkRouting.accepts(request))
        request.kind = .newTarget
        #expect(BrowserSplitLinkRouting.accepts(request))
        request.isUserLinkActivation = false
        #expect(!BrowserSplitLinkRouting.accepts(request))
        request.isUserLinkActivation = true
        for modifiers: BrowserModifierKeys in [[], [.shift], [.option, .command], [.option, .shift], [.option, .control]] {
            request.modifiers = modifiers
            #expect(!BrowserSplitLinkRouting.accepts(request))
        }
        request.modifiers = [.option]; request.isMainFrame = false
        #expect(!BrowserSplitLinkRouting.accepts(request))
        request.isMainFrame = true; request.buttonNumber = 1
        #expect(!BrowserSplitLinkRouting.accepts(request))
    }
}
