import AppKit
import BrowserCore
import ChromiumEngine

/// Confined, offscreen real-engine fixture. All documents must come from loopback.
@MainActor
enum OrbitPinnedTabProbe {
    private static var ids: [TabID] = []

    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.pinned-tabs",
              let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
              configuration.usesMockKeychain, let window = owner.window,
              NSApp.windows.contains(where: { $0 === window }),
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return windows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
            && ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    static func run(_ owner: OrbitWindowController, root: URL, command: [String: String]) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == "lab.orbit.orbit.pinned-tabs",
              let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
              configuration.usesMockKeychain, let window = owner.window else { return ["refused": true] }
        window.setFrame(NSRect(x: -2000, y: -1200, width: 1280, height: 900), display: false)
        owner.windowShell.setSidebarWidth(484)
        window.appearance = NSAppearance(named: .aqua)
        window.orderBack(nil)
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        guard owns(owner) else { return ["refused": true] }
        let folder = root.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if command["action"] == "seed", let base = command["base"].flatMap(URL.init(string:)),
           base.scheme == "http", base.host == "127.0.0.1" {
            for path in ["alpha", "beta", "gamma"] {
                owner.session.openTab(url: base.appendingPathComponent(path))
                await owner.session.waitForPendingCommands()
                guard let surface = owner.session.selectedSurface else { return ["missingPage": true] }
                await waitForLoad(surface)
                guard let id = owner.session.organization?.selectedTab?.id else { return ["missingTab": true] }
                ids.append(id)
                owner.session.pinTabs([id])
                await owner.session.waitForPendingCommands()
            }
            owner.session.closeTabs([ids[2]])
            await owner.session.waitForPendingCommands()
            owner.session.selectTab(ids[1])
            await owner.session.waitForPendingCommands()
        }
        guard ids.count == 3, owns(owner) else { return ["missingFixture": true] }
        window.contentView?.layoutSubtreeIfNeeded()
        func row(_ index: Int) -> SidebarTabRow? {
            owner.sidebar.page.list.row(for: .tab(ids[index])) as? SidebarTabRow
        }
        var result: [String: Any] = ["pid": getpid(), "window": window.windowNumber, "offscreen": true]
        if command["action"] == "seed" {
            captureSidebar(owner, to: folder.appendingPathComponent("states.png"))
            result["loaded"] = ids.map { owner.session.organization?.tab($0)?.isLoadedInThisWindow == true }
        } else if command["action"] == "hover", let index = Int(command["index"] ?? ""), (0...2).contains(index),
                  let target = row(index), let host = window.contentView {
            guard owns(owner) else { return ["refused": true] }
            let point = target.closeButton.convert(NSPoint(x: 12, y: 12), to: nil)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return [:] }
            guard owns(owner) else { return ["refused": true] }
            target.mouseEntered(with: event)
            guard owns(owner) else { return ["refused": true] }
            target.closeButton.mouseEntered(with: event)
            let prefix = index == 2 ? "archive" : "close"
            let start = ProcessInfo.processInfo.systemUptime
            var times: [Double] = []
            var presented = false
            // Capture the action, dwell and departure at 120 Hz, with monotone sample times.
            for frame in 0..<156 {
                guard owns(owner) else { return ["refused": true] }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if frame == 120 { target.closeButton.mouseExited(with: event); target.mouseExited(with: event) }
                let area = host.convert(target.bounds, from: target).insetBy(dx: -8, dy: -44)
                capture(host, rect: NSRect(x: area.minX, y: area.minY, width: max(area.width, 730), height: area.height),
                        to: folder.appendingPathComponent(String(format: "%@-%03d.png", prefix, frame)))
                presented = presented || target.closeButton.isPillPresented
                times.append(elapsed)
                let wait = Double(frame + 1) / 120 - (ProcessInfo.processInfo.systemUptime - start)
                try? await Task.sleep(for: .seconds(max(0.001, wait)))
            }
            result["sampleTimes"] = times
            result["pillPresented"] = presented
            result["pillDismissed"] = !target.closeButton.isPillPresented
        } else if command["action"] == "navigation", let surface = owner.session.selectedSurface,
                  let home = owner.session.organization?.tab(ids[1])?.pinnedURL {
            surface.navigate(to: home.appendingPathComponent("child"))
            await waitForLoad(surface)
            await owner.session.waitForPendingCommands()
            try? await Task.sleep(for: .milliseconds(250))
            result["away"] = owner.session.organization?.tab(ids[1])?.isAwayFromPinnedURL == true
            captureSidebar(owner, to: folder.appendingPathComponent("away.png"))
            surface.navigate(to: home)
            await waitForLoad(surface)
            await owner.session.waitForPendingCommands()
            try? await Task.sleep(for: .milliseconds(250))
            result["returned"] = owner.session.organization?.tab(ids[1])?.isAwayFromPinnedURL == false
            captureSidebar(owner, to: folder.appendingPathComponent("home.png"))
            surface.navigate(to: home.appendingPathComponent("child"))
            await waitForLoad(surface)
            await owner.session.waitForPendingCommands()
            if let target = row(1), owns(owner) { owner.sidebar.page.list.rowClose(target) }
            await owner.session.waitForPendingCommands()
            result["closedKeptPin"] = owner.session.organization?.tab(ids[1])?.isLoadedInThisWindow == false
            result["closedClearedAway"] = owner.session.organization?.tab(ids[1])?.isAwayFromPinnedURL == false
            if let target = row(2), owns(owner) { owner.sidebar.page.list.rowClose(target) }
            await owner.session.waitForPendingCommands()
            result["archived"] = owner.session.organization?.tab(ids[2]) == nil
            result["archiveRecord"] = await owner.session.archivedTabs().value.contains { $0.id == ids[2] && $0.reason == .removed }
        }
        return result
    }

    private static func waitForLoad(_ surface: ChromiumSurface) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
            try? await Task.sleep(for: .milliseconds(20))
        } while (!surface.isReady || surface.navigationState.isLoading) && ProcessInfo.processInfo.systemUptime < deadline
        try? await Task.sleep(for: .milliseconds(100))
    }

    private static func captureSidebar(_ owner: OrbitWindowController, to file: URL) {
        guard let host = owner.window?.contentView else { return }
        capture(host, rect: host.convert(owner.sidebar.bounds, from: owner.sidebar), to: file)
    }

    private static func capture(_ view: NSView, rect: NSRect? = nil, to file: URL) {
        view.window?.contentView?.layoutSubtreeIfNeeded()
        let area = rect ?? view.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(area.width * 2),
                                             pixelsHigh: Int(area.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = area.size
        // Render the presentation tree: cacheDisplay records final model opacity and would
        // erase an in-flight departure from an offscreen animation capture.
        view.displayIfNeeded()
        CATransaction.flush()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap), let layer = view.layer?.presentation() ?? view.layer {
            let transform = context.cgContext.ctm
            context.cgContext.scaleBy(x: 2 / abs(transform.a), y: 2 / abs(transform.d))
            context.cgContext.translateBy(x: -area.minX, y: -area.minY)
            layer.render(in: context.cgContext)
        } else {
            view.cacheDisplay(in: area, to: bitmap)
        }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
    }
}
