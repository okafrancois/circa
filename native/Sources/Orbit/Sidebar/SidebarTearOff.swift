import AppKit
import BrowserCore

@MainActor
final class SidebarTearOffRequest {
    weak var source: OrbitWindowController?
    let payload: SidebarDragPayload
    let placement: SidebarTearOffPlacement
    let sidebarWidth: CGFloat
    let presentationTime = ProcessInfo.processInfo.systemUptime + 0.59

    func waitForPresentation() async {
        let remaining = presentationTime - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
    }

    init(source: OrbitWindowController, payload: SidebarDragPayload, point: NSPoint) {
        self.source = source
        self.payload = payload
        let fullScreen = source.window?.styleMask.contains(.fullScreen) == true || source.windowShell.isFullScreen
        let size = fullScreen ? source.windowedFrame?.size ?? source.window!.frame.size : source.window!.frame.size
        placement = SidebarTearOffPlacement(sourceSize: size, dropPoint: point,
            displays: NSScreen.screens.map { ($0.frame, $0.visibleFrame) }, sourceIsFullScreen: fullScreen)
        sidebarWidth = source.windowShell.preferredSidebarWidth
    }
}

extension OrbitApplication {
    func tearOff(_ payload: SidebarDragPayload, from source: OrbitWindowController, at point: NSPoint) {
        guard !isPreparingToQuit, source.acceptsCommands, source.window != nil,
              payload.sourceWindow == source.id, payload.nodes.count == 1,
              let tab = payload.nodes.first?.tabID, source.liveSidebarSurface(of: tab) != nil else { return }
        let request = SidebarTearOffRequest(source: source, payload: payload, point: point)
        Task { [weak self, weak source] in
            guard let self, let source, source.acceptsCommands else { return }
            let id = UUID()
            if let privateSource = privateWindows[source.id] {
                do {
                    let lease = try await privateSource.scope.acquire()
                    privateWindows[id] = OrbitPrivateWindow(scope: privateSource.scope, lease: lease, environment: privateSource.environment)
                } catch { return }
            } else if source.isPrivateWindow { return }
            tearOffRequests[id] = request
            if windows.newWindow(id: id) == nil {
                tearOffRequests[id] = nil
                releasePrivateWindow(id)
            }
        }
    }
}

/// A desktop release and a cancellation both report an empty AppKit operation. Escape or a
/// still-held mouse button distinguishes cancellation before the later physical mouse-up.
struct SidebarTearOffRelease {
    static func accepts(operation: NSDragOperation, cancelled: Bool, mouseIsDown: Bool,
                        sourceFrame: NSRect, otherWindowFrames: [NSRect], point: NSPoint) -> Bool {
        operation.isEmpty && !cancelled && !mouseIsDown && !sourceFrame.contains(point)
            && !otherWindowFrames.contains { $0.contains(point) }
    }
}
