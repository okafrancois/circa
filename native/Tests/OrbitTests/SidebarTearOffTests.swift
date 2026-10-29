import AppKit
import Testing
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
