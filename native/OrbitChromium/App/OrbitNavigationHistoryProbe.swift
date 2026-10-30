import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Synthetic-only qualification of native menus and indexed Chromium history.
@MainActor
enum OrbitNavigationHistoryProbe {
    static let bundleID = "lab.orbit.orbit.nav-history-menu"
    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.infoDictionary?["OrbitUseMockKeychain"] as? Bool == true,
              let window = owner.window,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }
    private static func loaded(_ surface: ChromiumSurface, at url: URL) async -> Bool {
        for _ in 0..<200 {
            if surface.isReady, !surface.navigationState.isLoading, surface.nativePageServices?.committedURL() == url {
                try? await Task.sleep(for: .milliseconds(200))
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        guard owns(owner), let text = command["url"], let base = URL(string: text),
              base.host == "127.0.0.1", base.scheme == "http", let window = owner.window else { return ["refused": true] }
        var result: [String: Any] = [:]
        let urls = ["first", "second", "third"].map { base.appendingPathComponent($0) }
        owner.session.openTab(url: urls[0])
        await owner.session.waitForQueuedCommands()
        guard let surface = owner.session.selectedSurface else { return ["missingSurface": true] }
        for (index, url) in urls.enumerated() {
            if index > 0 { surface.navigate(to: url) }
            guard await loaded(surface, at: url) else { return ["loadFailed": index] }
        }
        guard let api = surface.nativePageServices else { return ["missingAPI": true] }
        result["history"] = api.navigationHistory().flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        // Capture only owned native menu windows; no desktop or other application's pixels.
        func menu(_ button: BrowserNavigationGlyphButton, name: String, hold: Bool, choose: Int?) -> [String] {
            guard owns(owner) else { return [] }
            let factory = button.navigation.makeMenu
            var presentation: BrowserNavigationHistoryMenu?
            button.navigation.makeMenu = { presentation = factory?(); return presentation }
            defer { button.navigation.makeMenu = factory }
            let timer = Timer(timeInterval: hold ? button.navigation.hold.delay + 0.35 : 0.35, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard owns(owner), let menu = presentation?.menu else { return }
                    let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                    if let row = rows.first(where: {
                        ($0[kCGWindowOwnerPID as String] as? Int32) == getpid()
                            && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0
                            && ($0[kCGWindowNumber as String] as? Int) != window.windowNumber
                    }), let number = row[kCGWindowNumber as String] as? Int {
                        let capture = Process()
                        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        capture.arguments = ["-x", "-o", "-l", String(number), root.appendingPathComponent(name + ".png").path]
                        try? capture.run(); capture.waitUntilExit()
                    }
                    if let choose, menu.items.indices.contains(choose), owns(owner) { menu.performActionForItem(at: choose) }
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .eventTracking)
            RunLoop.main.add(timer, forMode: .common)
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: hold ? .leftMouseDown : .rightMouseDown,
                location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1), owns(owner) else { return [] }
            if hold { button.mouseDown(with: event) } else { button.rightMouseDown(with: event) }
            timer.invalidate()
            return presentation?.menu.items.map(\.title) ?? []
        }
        if command["capture"] == "onscreen", let screen = NSScreen.screens.first {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 140,
                                           y: screen.visibleFrame.maxY - window.frame.height - 80))
        }
        defer { window.setFrameOrigin(NSPoint(x: -2000, y: -1200)) }
        NSApp.appearance = NSAppearance(named: .aqua)
        window.appearance = NSAppearance(named: .aqua)
        owner.refreshNavigation(for: surface)
        result["backLight"] = menu(owner.backButton, name: "back-light", hold: true, choose: 1)
        result["selectedFirst"] = await loaded(surface, at: urls[0])
        owner.refreshNavigation(for: surface)
        result["forwardLight"] = menu(owner.forwardButton, name: "forward-light", hold: false, choose: nil)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.appearance = NSAppearance(named: .darkAqua)
        result["forwardDark"] = menu(owner.forwardButton, name: "forward-dark", hold: true, choose: 1)
        result["selectedThird"] = await loaded(surface, at: urls[2])
        owner.refreshNavigation(for: surface)
        result["backDark"] = menu(owner.backButton, name: "back-dark", hold: false, choose: nil)
        let before = Set(owner.session.snapshot?.tabs.map(\.id) ?? [])
        let point = owner.backButton.convert(NSPoint(x: 5, y: 5), to: nil)
        if owns(owner), let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [.command],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0),
           let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [.command],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            let source = owner.backButton.navigation.nextEvent
            owner.backButton.navigation.nextEvent = { _ in up }
            if owns(owner) { owner.backButton.mouseDown(with: down) }
            owner.backButton.navigation.nextEvent = source
        }
        await owner.session.waitForQueuedCommands()
        let added = owner.session.snapshot?.tabs.filter { !before.contains($0.id) } ?? []
        result["commandOpenedBackground"] = added.count == 1 && added[0].url == urls[1]
            && owner.session.selectedSurface === surface && api.committedURL() == urls[2]
        let order = owner.session.organization?.tabNavigationItems ?? []
        if let source = owner.session.organization?.selectedTab?.id, let index = order.firstIndex(where: { $0.id == source }) {
            result["adjacent"] = order.indices.contains(index + 1) && order[index + 1].id == added.first?.id
        }
        result["pid"] = getpid()
        return result
    }
}
