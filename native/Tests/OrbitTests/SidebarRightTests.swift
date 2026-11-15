import AppKit
import BrowserCore
import Testing
@testable import Orbit

@Suite("Sidebar placement")
@MainActor
struct SidebarRightTests {
    @Test("Docked, hidden and floating frames reflect horizontally, including fullscreen and spaced cards")
    func reflection() {
        for full in [false, true] {
            for spaced in [false, true] {
                for width: CGFloat in [164, 260, 500] {
                    for progress: CGFloat in [0, 0.25, 0.7, 1] {
                        for floating in [false, true] {
                            var state = OrbitShellGeometry.State(contentSize: CGSize(width: 1100, height: 800),
                                sidebarWidth: width, dockProgress: floating ? 0 : progress,
                                floatProgress: floating ? progress : 0, usesFloatingFrame: floating,
                                isFullScreen: full, spaceAroundPages: spaced)
                            let left = OrbitShellGeometry.resolve(state)
                            state.sidebarOnRight = true
                            let right = OrbitShellGeometry.resolve(state)
                            #expect(right.sidebarFrame == OrbitShellGeometry.reflect(left.sidebarFrame, in: 1100))
                            #expect(right.cardFrame == OrbitShellGeometry.reflect(left.cardFrame, in: 1100))
                            #expect(right.cardRadius == left.cardRadius && right.floatingRadius == left.floatingRadius)
                            #expect(right.floatingChrome == left.floatingChrome)
                            // The group moves with the sidebar; macOS button order remains left to right.
                            for index in 0..<3 {
                                #expect(abs((right.trafficLightCenters[index].x - right.sidebarFrame.minX)
                                    - (left.trafficLightCenters[index].x - left.sidebarFrame.minX)) < 0.001)
                            }
                            #expect(right.trafficLightCenters[0].x < right.trafficLightCenters[1].x)
                            #expect(right.trafficLightCenters[1].x < right.trafficLightCenters[2].x)
                        }
                    }
                }
            }
        }
    }

    @Test("Hover trigger, keep zone and resize edge reflect within the window")
    func edges() {
        let size = CGSize(width: 1100, height: 800)
        for width in [OrbitTokens.Motion.sidebarHoverEdgeTrigger, CGFloat(265)] {
            let left = OrbitShellGeometry.edgeRegion(size: size, width: width, onRight: false)
            #expect(OrbitShellGeometry.edgeRegion(size: size, width: width, onRight: true)
                == OrbitShellGeometry.reflect(left, in: size.width))
        }
        let left = OrbitShellGeometry.resizeFrame(size: size, sidebarWidth: 260, onRight: false)
        #expect(OrbitShellGeometry.resizeFrame(size: size, sidebarWidth: 260, onRight: true)
            == OrbitShellGeometry.reflect(left, in: size.width))
        let card = BrowserContentCardView()
        card.isFlushWithWindow = true
        card.sidebarOnRight = true
        #expect(card.pageCorners == [.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
    }

    @Test("Old settings default left and the right-side preference persists")
    func persistence() async throws {
        let old = try JSONDecoder().decode(BrowserInteractionPreferences.self, from: Data("{}".utf8))
        #expect(!old.sidebarOnRight)
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("sidebar-right-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let runtime = BrowserSettingsRuntime(store: try BrowserSettingsStore(destination: file))
        await runtime.refresh()
        try await runtime.setSidebarOnRight(true)
        #expect(runtime.document.interaction.sidebarOnRight)
        #expect(await (try BrowserSettingsStore(destination: file)).snapshot().interaction.sidebarOnRight)
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeSidebarRightTests {
    @Test("Placement applies live to all windows and keeps toolbar and Split View content intact")
    func liveWindows() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let first = try await environment.makeWindow()
        let second = try await environment.makeWindow()
        defer { for item in [first, second] { item.session.close(); item.window?.close() } }
        for item in [first, second] {
            item.submitAddress("https://sidebar.test/page")
            await item.session.waitForPendingCommands()
            item.window?.contentView?.layoutSubtreeIfNeeded()
        }
        let original = try #require(first.shellGeometry)
        first.toggleSidebarSide()
        await first.session.waitForPendingCommands()
        for item in [first, second] {
            await item.session.waitForPendingCommands()
            item.window?.contentView?.layoutSubtreeIfNeeded()
            #expect(item.windowShell.sidebarOnRight)
            let geometry = try #require(item.shellGeometry)
            let size = try #require(item.window?.contentView?.bounds.size)
            #expect(geometry.sidebarFrame.maxX == size.width)
            #expect(abs(item.sidebar.frame.minX - geometry.sidebarFrame.minX) < 0.001)
            #expect(abs(item.contentCard.frame.minX - geometry.cardFrame.minX) < 0.001)
            #expect(abs(item.contentCard.frame.width - geometry.cardFrame.width) < 0.001)
        }
        #expect(first.shellGeometry?.cardFrame.width == original.cardFrame.width)
        try await environment.settings.setShowsToolbar(true)
        #expect(first.isToolbarVisible && second.isToolbarVisible)
        #expect(first.sidebar.navigationContainer.buttons[0].isHidden == false)
        #expect(first.contentCard.header === first.optionalToolbar)
        first.session.addSplitPane(url: URL(string: "https://sidebar.test/second")!)
        await first.session.waitForPendingCommands()
        #expect(first.session.activeSplit != nil && first.contentCard.header == nil)
        first.setSidebarVisible(false, animated: false)
        #expect((first.shellGeometry?.sidebarFrame.minX ?? 0) >= (first.window?.contentView?.bounds.width ?? 0))
        first.windowShell.setFloating(true, animated: false)
        #expect(first.shellGeometry?.sidebarFrame.maxX == (first.window?.contentView?.bounds.width ?? 0) - 5)
        first.setSidebarVisible(true, animated: false)
        try await environment.settings.setSidebarOnRight(false)
        #expect(!first.windowShell.sidebarOnRight && !second.windowShell.sidebarOnRight)
    }
}
}
