import AppKit
import BrowserCore
import BrowserEngine

/// Desktop placement uses the display containing the release, including displays to the left
/// or above the main one. Preserve the source size without introducing a resize transition.
struct SidebarTearOffPlacement: Equatable {
    let frame: NSRect
    let entersFullScreen: Bool

    init(sourceSize: NSSize, dropPoint: NSPoint, displays: [(frame: NSRect, visibleFrame: NSRect)],
         sourceIsFullScreen: Bool) {
        let display = displays.first { $0.frame.contains(dropPoint) }
            ?? displays.min { Self.distance(dropPoint, to: $0.frame) < Self.distance(dropPoint, to: $1.frame) }
        let visible = display?.visibleFrame ?? NSRect(origin: dropPoint, size: sourceSize)
        let inset = visible.insetBy(dx: min(20, max(0, (visible.width - 1) / 2)),
                                    dy: min(20, max(0, (visible.height - 1) / 2)))
        frame = NSRect(x: max(inset.minX, min(dropPoint.x - sourceSize.width / 2, inset.maxX - sourceSize.width)),
                       y: max(inset.minY, min(dropPoint.y - sourceSize.height / 2, inset.maxY - sourceSize.height)),
                       width: sourceSize.width, height: sourceSize.height)
        entersFullScreen = sourceIsFullScreen
    }

    private static func distance(_ point: NSPoint, to rect: NSRect) -> CGFloat {
        let x = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let y = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return x * x + y * y
    }
}

extension BrowserWindowController {
    var windowPlacement: BrowserWindowPlacement? {
        guard let window else { return nil }
        let frame = window.styleMask.contains(.fullScreen) || windowShell.isFullScreen
            ? windowedFrame ?? window.frame : window.frame
        return BrowserWindowPlacement(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                                      sidebarWidth: windowShell.preferredSidebarWidth, isFullScreen: window.styleMask.contains(.fullScreen) || windowShell.isFullScreen)
    }

    func restoreWindowPlacement(_ placement: BrowserWindowPlacement?) {
        guard let placement, placement.isUsable, let window else { return }
        var frame = NSRect(x: placement.x, y: placement.y, width: placement.width, height: placement.height)
        // A removed display must not strand the title bar outside the remaining desktop.
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 28, width: frame.width, height: 28)
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(titleBar) } ?? NSScreen.main
        if let screen {
            let visible = screen.visibleFrame
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: false)
        windowedFrame = frame
        windowShell.setSidebarWidth(placement.sidebarWidth)
        restoresFullScreen = placement.isFullScreen == true
    }
}
