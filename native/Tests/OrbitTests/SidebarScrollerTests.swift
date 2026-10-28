import AppKit
import Testing
@testable import Orbit
@testable import BrowserCore

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SidebarScrollerTests {
    @Test("Sidebar small native scroller preserves style, scrolling and accessible control geometry")
    func sidebarNativeScroller() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let systemStyle = NSScroller.preferredScrollerStyle
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 640))
        let synthetic = SyntheticOrganization()
        sidebar.render(catalog: nil, activeSpaceID: synthetic.spaceID,
                       organization: synthetic.snapshot(today: (0..<80).map { synthetic.tab(title: "Synthetic row \($0)") }))
        sidebar.layoutSubtreeIfNeeded()
        let scroll = sidebar.page.pageScrollView
        #expect(scroll.scrollerStyle == systemStyle)
        #expect(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller && scroll.autohidesScrollers)
        let native = try #require(scroll.verticalScroller)
        #expect(type(of: native) == NSScroller.self)
        #expect(native.controlSize == .small)
        for style in [NSScroller.Style.overlay, .legacy, .overlay] {
            scroll.scrollerStyle = style // Local instance only, no global preference writes.
            scroll.tile()
            sidebar.page.needsLayout = true
            sidebar.page.layoutSubtreeIfNeeded()
            let scroller = try #require(scroll.verticalScroller)
            #expect(scroller.controlSize == .small && scroll.scrollerStyle == style)
            #expect(NSScroller.scrollerWidth(for: .small, scrollerStyle: style) < NSScroller.scrollerWidth(for: .regular, scrollerStyle: style))
            #expect(scroller.accessibilityRole() == .scrollBar)
            #expect(scroller.target === scroll && scroller.action != nil)
            #expect(!scroller.rect(for: .knob).isEmpty)
            #expect(scroller.frame.width >= NSScroller.scrollerWidth(for: .small, scrollerStyle: style))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(scroll.contentView.bounds.minY == 100 && scroller.doubleValue > 0)
            #expect(scroll.documentView === sidebar.page.list)
        }
        #expect(NSScroller.preferredScrollerStyle == systemStyle)
    }
}
}
