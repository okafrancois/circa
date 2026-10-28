import AppKit
import BrowserCore
import BrowserEngine

extension BrowserWindowController {
    var windowPlacement: BrowserWindowPlacement? {
        guard let window else { return nil }
        let frame = window.styleMask.contains(.fullScreen) || windowShell.isFullScreen
            ? windowedFrame ?? window.frame : window.frame
        return BrowserWindowPlacement(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                                      sidebarWidth: windowShell.preferredSidebarWidth)
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
    }
}
