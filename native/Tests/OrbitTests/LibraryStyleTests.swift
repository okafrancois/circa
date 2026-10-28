import AppKit
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Library page surfaces", .serialized)
@MainActor
struct LibraryStyleTests {
    @Test("The outgoing sidebar cannot intercept Library clicks while transparent")
    func outgoingHitTesting() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 417, height: 780))
        let page = BrowserLibraryView(frame: root.bounds)
        page.acceptsLibraryInput = true
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 228, height: 780))
        root.addSubview(page); root.addSubview(sidebar)
        let point = NSPoint(x: 20, y: 100)
        sidebar.alphaValue = 0
        sidebar.isLibraryInputSuppressed = true
        #expect(root.hitTest(point)?.isDescendant(of: page) == true)
        sidebar.isLibraryInputSuppressed = false
        #expect(root.hitTest(point)?.isDescendant(of: sidebar) == true)
    }

    @Test("Only the horizontal Spaces grid exposes a scroller")
    func scrollers() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let views: [NSView] = [BrowserLibraryHistoryView(), BrowserLibrarySpacesView(),
                              BrowserLibraryMediaView(), BrowserDownloadsView(), BrowserArchiveView()]
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        for view in views {
            let scrolls = scrollViews(in: view)
            #expect(!scrolls.isEmpty)
            for scroll in scrolls {
                #expect(!scroll.hasVerticalScroller)
                #expect(scroll.hasHorizontalScroller == (view is BrowserLibrarySpacesView))
                #expect(!scroll.drawsBackground)
            }
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        scroll.documentView = document
        BrowserLibraryStyle.configure(scroll)
        document.scroll(NSPoint(x: 0, y: 200))
        #expect(scroll.contentView.bounds.origin.y == 200)
    }

    @Test("Only the rail lightens the shared window background")
    func colors() throws {
        let color = try #require(BrowserLibraryStyle.railTint.usingColorSpace(.sRGB))
        #expect(color.redComponent == 1 && color.greenComponent == 1 && color.blueComponent == 1)
        #expect(abs(color.alphaComponent - 0.025) < 0.00001)
        let view = BrowserLibraryView(frame: NSRect(x: 0, y: 0, width: 420, height: 780))
        view.select(.media, theme: .default)
        #expect(view.body.layer?.backgroundColor == nil)
        #expect(view.layer?.borderWidth == 0)
        #expect(view.body.layer?.borderWidth == 0)
        #expect(view.railBackground.layer?.backgroundColor != nil)
        #expect(!view.subviews.contains { $0 is OrbitThemeFillView })
    }

    @Test("The destination rail and full-height page keep separate, clipped surfaces")
    func geometry() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 780))
        let view = BrowserLibraryView(frame: root.bounds)
        root.addSubview(view)
        root.layoutSubtreeIfNeeded()
        #expect(view.body.frame.minX == 112)
        #expect(view.body.frame.maxX == 420)
        #expect(view.body.frame.minY == 0)
        #expect(view.body.frame.maxY == 780)
        #expect(view.body.layer?.cornerRadius == 0)
        #expect(view.body.layer?.masksToBounds == true)
    }
}
}
