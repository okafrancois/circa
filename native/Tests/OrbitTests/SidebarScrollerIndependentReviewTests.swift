import AppKit
import Testing
@testable import Orbit
@testable import BrowserCore

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SidebarScrollerIndependentReviewTests {
    @Test("Real sidebar scroller geometry stays small across styles, resizing and content changes")
    func actualGeometryAcrossRetiling() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let preference = NSScroller.preferredScrollerStyle
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 640))
        let synthetic = SyntheticOrganization()
        func render(_ count: Int) {
            sidebar.render(catalog: nil, activeSpaceID: synthetic.spaceID,
                organization: synthetic.snapshot(today: (0..<count).map { synthetic.tab(title: "Synthetic \($0)") }))
            sidebar.layoutSubtreeIfNeeded()
            sidebar.page.layoutSubtreeIfNeeded()
        }
        render(80)
        let scroll = sidebar.page.pageScrollView
        let original = try #require(scroll.verticalScroller)
        for style in [NSScroller.Style.legacy, .overlay, .legacy] {
            scroll.scrollerStyle = style
            for width: CGFloat in [240, 320, 224] {
                sidebar.setFrameSize(NSSize(width: width, height: 540))
                sidebar.layoutSubtreeIfNeeded()
                sidebar.page.layoutSubtreeIfNeeded()
                scroll.tile()
                let scroller = try #require(scroll.verticalScroller)
                #expect(scroller === original)
                #expect(scroller.controlSize == .small)
                let smallWidth = scroller.frame.width
                let smallKnob = scroller.rect(for: .knob)
                scroller.controlSize = .regular
                scroll.tile()
                let regularWidth = scroller.frame.width
                let regularKnob = scroller.rect(for: .knob)
                scroller.controlSize = .small
                scroll.tile()
                print("SCROLLER_METRIC style=\(style.rawValue) sidebar=\(width) smallFrame=\(smallWidth) regularFrame=\(regularWidth) smallKnob=\(smallKnob.width) regularKnob=\(regularKnob.width)")
                #expect(smallWidth < regularWidth)
                #expect(smallKnob.width < regularKnob.width)
                #expect(scroller.frame.width == smallWidth)
                #expect(scroll.documentView === sidebar.page.list)
                #expect(scroll.hasVerticalScroller && scroll.autohidesScrollers && !scroll.hasHorizontalScroller)
                #expect(scroller.target === scroll && scroller.action != nil)
                #expect(scroller.accessibilityRole() == .scrollBar)
                #expect(scroll.horizontalScrollElasticity == .none)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
                scroll.reflectScrolledClipView(scroll.contentView)
                #expect(scroll.contentView.bounds.minY == 200)
                #expect(scroller.doubleValue > 0)
            }
            render(0)
            render(80)
            scroll.tile()
            #expect(scroll.verticalScroller === original)
            #expect(original.controlSize == .small && !original.rect(for: .knob).isEmpty)
        }
        #expect(NSScroller.preferredScrollerStyle == preference)
    }
}
}
