import AppKit
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct PeekControlGeometryTests {
    @Test func controlsRemainCircularAfterAutoLayout() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let toolbar = BrowserPeekToolbarView()
        root.addSubview(toolbar)
        toolbar.frame = NSRect(x: 900, y: 20, width: 34, height: 121)
        root.layoutSubtreeIfNeeded()
        for button in [toolbar.closeButton, toolbar.openInTabButton, toolbar.splitButton] {
            #expect(button.frame.width == button.frame.height,
                    "The painted button frame must be square, not just its alignment rectangle")
            #expect(button.frame.width == BrowserPeekStyle.buttonSize)
            #expect(button.frame.minX == 0)
        }
    }
}
