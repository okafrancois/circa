import AppKit
import Testing
import BrowserCore
import BrowserShell
import WebKitEngine
@testable import Orbit

@Suite("Sidebar tear-off placement")
struct SidebarTearOffPlacementTests {
    private let display = (frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                           visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 949))
    private let size = NSSize(width: 900, height: 750)

    @Test("Desktop placement centres the source size on release and clamps inside the usable display")
    func centringAndClamping() {
        let centre = placement(NSPoint(x: 756, y: 500))
        #expect(centre.frame == NSRect(x: 306, y: 125, width: 900, height: 750))
        let right = placement(NSPoint(x: 1250, y: 532))
        #expect(right.frame == NSRect(x: 592, y: 157, width: 900, height: 750))
        let bottom = placement(NSPoint(x: 1504, y: 17))
        #expect(bottom.frame == NSRect(x: 592, y: 20, width: 900, height: 750))
        #expect(placement(NSPoint(x: 1, y: 981)).frame == NSRect(x: 20, y: 179, width: 900, height: 750))
    }

    @Test("The receiving display's visible frame accounts for menu bar, Dock and negative coordinates")
    func displaysAndVisibleFrame() {
        let other = (frame: NSRect(x: -1600, y: 200, width: 1600, height: 1200),
                     visibleFrame: NSRect(x: -1550, y: 280, width: 1550, height: 1087))
        let result = SidebarTearOffPlacement(sourceSize: size, dropPoint: NSPoint(x: -1590, y: 210),
                                             displays: [display, other], sourceIsFullScreen: false)
        #expect(result.frame == NSRect(x: -1530, y: 300, width: 900, height: 750))
        let above = (frame: NSRect(x: 0, y: 982, width: 1512, height: 982),
                     visibleFrame: NSRect(x: 0, y: 982, width: 1512, height: 949))
        let top = SidebarTearOffPlacement(sourceSize: size, dropPoint: NSPoint(x: 900, y: 1700),
                                          displays: [display, above], sourceIsFullScreen: true)
        #expect(top.frame == NSRect(x: 450, y: 1161, width: 900, height: 750))
        #expect(top.entersFullScreen)
    }

    @Test("Fullscreen is inherited independently of the drop display", arguments: [false, true])
    func fullscreen(_ fullScreen: Bool) {
        #expect(placement(NSPoint(x: 1250, y: 532), fullScreen: fullScreen).entersFullScreen == fullScreen)
    }

    @Test("A smaller display preserves the source size and anchors its origin inside the usable frame")
    func smallerDisplay() {
        let small = (frame: NSRect(x: 1512, y: 0, width: 800, height: 600),
                     visibleFrame: NSRect(x: 1512, y: 40, width: 800, height: 527))
        let result = SidebarTearOffPlacement(sourceSize: size, dropPoint: NSPoint(x: 1800, y: 300),
                                             displays: [display, small], sourceIsFullScreen: false)
        #expect(result.frame == NSRect(x: 1532, y: 60, width: 900, height: 750))
    }

    private func placement(_ point: NSPoint, fullScreen: Bool = false) -> SidebarTearOffPlacement {
        SidebarTearOffPlacement(sourceSize: size, dropPoint: point, displays: [display], sourceIsFullScreen: fullScreen)
    }
}

extension NativeWebKitTests {
@MainActor
@Suite("Standalone live tab transfer", .serialized)
struct SidebarTearOffLiveTests {
    @Test("Reordering a standalone list keeps its documents in the same window")
    func reorderLocalTabs() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let (home, _) = try await environment.initialContext.value
        let window = try await environment.makeWindow(spaceID: home, opensInitialTab: false, standalone: true)
        defer { window.window?.close() }
        for path in ["first", "second", "third"] {
            window.session.openTab(url: URL(string: "https://synthetic.test/" + path)!, activate: true)
            await window.session.waitForPendingCommands()
        }
        let tabs = try #require(window.session.organization?.allTabs)
        let last = try #require(tabs.last)
        let surface = try #require(window.liveSidebarSurface(of: last.id))
        let requests = surface.requestedURLs
        let payload = try #require(window.sidebar.list(window.sidebar.page.list, dragPayloadFor: .tab(last.id), grabOffsetX: 0))
        window.performSidebarDrop(payload, to: .init(.today(home), position: .start), changesOrganization: true)
        await window.session.waitForPendingCommands()
        #expect(window.session.organization?.allTabs.map(\.id) == [last.id] + tabs.dropLast().map(\.id))
        #expect(window.liveSidebarSurface(of: last.id) === surface && surface.requestedURLs == requests)
    }

    @Test("Last-tab tear-off and return retain the live surface, history and unsaved edits without resizing the empty source")
    func liveDocumentAndReturn() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let (home, _) = try await environment.initialContext.value
        let source = try await environment.makeWindow(spaceID: home, opensInitialTab: false)
        defer { source.window?.close() }
        source.session.openTab(url: URL(string: "https://synthetic.test/first")!, activate: true)
        await source.session.waitForPendingCommands()
        let tab = try #require(source.session.organization?.selectedTab?.id)
        let surface = try #require(source.liveSidebarSurface(of: tab))
        surface.navigate(to: URL(string: "https://synthetic.test/edited")!)
        await source.session.waitForPendingCommands()
        let form = NSTextField(string: "Unsaved synthetic edit")
        surface.documentView.addSubview(form)
        let requests = surface.requestedURLs
        let frame = try #require(source.window?.frame)
        let receiver = try await environment.makeWindow(spaceID: home, opensInitialTab: false, standalone: true)
        defer { receiver.window?.close() }
        let move = try #require(source.moveSurface(surface, to: receiver, replacingExisting: true))
        #expect(await move.value != nil)
        await source.session.waitForPendingCommands()
        await receiver.session.waitForPendingCommands()
        #expect(receiver.session.selectedSurface === surface && receiver.session.organization?.selectedTab?.id == tab)
        #expect(source.session.organization?.allTabs.isEmpty == true && source.session.snapshot?.tabs.isEmpty == true)
        #expect(source.window?.frame == frame && source.window != nil)
        #expect(surface.requestedURLs == requests && form.superview === surface.documentView)
        #expect(form.stringValue == "Unsaved synthetic edit" && surface.navigationState.canGoBack)
        let payload = try #require(receiver.sidebar.list(receiver.sidebar.page.list, dragPayloadFor: .tab(tab), grabOffsetX: 0))
        source.performSidebarDrop(payload, to: .init(.today(home)), changesOrganization: true)
        for _ in 0..<5 {
            await source.session.waitForPendingCommands()
            await receiver.session.waitForPendingCommands()
            await Task.yield()
        }
        #expect(source.session.selectedSurface === surface && source.session.organization?.selectedTab?.id == tab)
        #expect(receiver.session.snapshot?.tabs.isEmpty == true && receiver.window != nil)
        #expect(surface.requestedURLs == requests && !surface.isDisposed)
        #expect(surface.goBack()?.path == "/first")
    }

    @Test("Window orchestration inherits fullscreen without invoking native fullscreen in hidden tests", arguments: [false, true])
    func fullscreenOrchestration(_ fullScreen: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: WebKitBrowserEngine())
        var toggles = 0
        let app = OrbitApplication(environment: environment, windowPresenter: { controller, _ in
            controller.toggleNativeFullScreen = { _ in toggles += 1 }
        })
        defer { app.windows.shutdown() }
        _ = app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let source = try #require(app.windows.selectedWindow)
        await source.session.waitForPendingCommands()
        if source.session.selectedSurface == nil {
            source.session.openTab(url: URL(string: "about:blank")!, activate: true)
            await source.session.waitForPendingCommands()
        }
        let tab = try #require(source.session.organization?.selectedTab?.id)
        let surface = try #require(source.liveSidebarSurface(of: tab))
        let frame = try #require(source.window?.frame)
        if fullScreen, let window = source.window {
            source.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification, object: window))
            NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        }
        let payload = try #require(source.sidebar.list(source.sidebar.page.list, dragPayloadFor: .tab(tab), grabOffsetX: 0))
        app.tearOff(payload, from: source, at: NSPoint(x: 1250, y: 450))
        for _ in 0..<200 {
            if app.windows.windows.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let destination = try #require(app.windows.windows.values.first { $0 !== source })
        #expect(destination.session.selectedSurface === surface)
        #expect(destination.window?.frame.size == frame.size)
        #expect(toggles == (fullScreen ? 1 : 0))
        #expect(source.session.organization?.allTabs.isEmpty == true && source.window != nil)
    }

    @Test("Escape, a held button and an accepted in-window drop never become desktop tear-offs")
    func releaseAdmission() {
        let source = NSRect(x: 80, y: 100, width: 900, height: 750)
        let outside = NSPoint(x: 1250, y: 450)
        #expect(SidebarTearOffRelease.accepts(operation: [], cancelled: false, mouseIsDown: false, sourceFrame: source, otherWindowFrames: [], point: outside))
        #expect(!SidebarTearOffRelease.accepts(operation: [], cancelled: true, mouseIsDown: false, sourceFrame: source, otherWindowFrames: [], point: outside))
        #expect(!SidebarTearOffRelease.accepts(operation: [], cancelled: false, mouseIsDown: true, sourceFrame: source, otherWindowFrames: [], point: outside))
        #expect(!SidebarTearOffRelease.accepts(operation: .move, cancelled: false, mouseIsDown: false, sourceFrame: source, otherWindowFrames: [], point: outside))
        #expect(!SidebarTearOffRelease.accepts(operation: [], cancelled: false, mouseIsDown: false, sourceFrame: source, otherWindowFrames: [], point: NSPoint(x: source.midX, y: source.midY)))
        #expect(!SidebarTearOffRelease.accepts(operation: [], cancelled: false, mouseIsDown: false, sourceFrame: source, otherWindowFrames: [NSRect(x: 1100, y: 0, width: 900, height: 750)], point: outside))
    }
}

}
