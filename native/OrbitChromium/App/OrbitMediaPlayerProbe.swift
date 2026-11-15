import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Synthetic-only walkthrough of the sidebar media player for recorded validation: appearance,
/// hover expansion, play/pause, a two-card stack, a pause from the page, a Space switch, Back to
/// Tab and the close button. Hover reaches the player through its own tracking handlers; clicks
/// go through the window like real input, each after checking the window under the point is ours.
@MainActor
enum OrbitMediaPlayerProbe {
    static let bundleID = "lab.orbit.orbit.mini-player-ui"

    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.infoDictionary?["OrbitUseMockKeychain"] as? Bool == true,
              let window = owner.window,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
    }

    /// The frontmost visible app window (normal or floating level) under a screen point
    /// (top-left origin). Returns its owner name for diagnostics and whether it is this process.
    private static func topWindow(at point: CGPoint) -> (owner: String, isOurs: Bool) {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return ("", false) }
        for row in rows {
            let layer = row[kCGWindowLayer as String] as? Int ?? 0
            let alpha = row[kCGWindowAlpha as String] as? Double ?? 1
            guard (0...Int(CGWindowLevelForKey(.floatingWindow))).contains(layer), alpha > 0,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point) else { continue }
            return (row[kCGWindowOwnerName as String] as? String ?? "", (row[kCGWindowOwnerPID as String] as? Int32) == getpid())
        }
        return ("", false)
    }

    private static func waitForLoad(_ surface: ChromiumSurface) async -> Bool {
        for _ in 0..<300 {
            if surface.isReady, !surface.navigationState.isLoading, surface.navigationState.committedURL != nil {
                try? await Task.sleep(for: .milliseconds(150))
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private static func wait(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(16))
        }
        return true
    }

    private static func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    private static func theme(_ mode: BrowserSpaceTheme.Mode, _ hex: String) -> BrowserSpaceTheme? {
        guard let color = BrowserThemeColor(hexString: hex) else { return nil }
        return BrowserSpaceTheme(mode: mode, colors: [], intensity: 0.78, noise: 0,
                                 light: .init(stops: [color]), dark: .init(stops: [color]))
    }

    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL, store: BrowserStore) async -> [String: Any] {
        _ = await wait { owns(owner) }
        guard owns(owner), let window = owner.window, let base = command["url"].flatMap(URL.init(string:)),
              let profile = owner.session.activeProfileID, let firstSpace = owner.session.snapshot?.activeSpaceID else {
            return ["refused": true]
        }
        let dark = command["appearance"] == "dark"
        let switchesSpace = command["space"] == "switch"
        var checks: [String: Any] = [:]
        var marks: [[String: Any]] = []
        var refusedClicks: [String] = []
        func mark(_ name: String) {
            marks.append(["step": name, "wall": Date().timeIntervalSince1970])
        }
        let player = owner.sidebar.mediaPlayer
        func describe() -> [[String: Any]] {
            player.items.map { ["title": $0.title, "toggle": $0.toggle == .pause ? "pause" : "play",
                                "canToggle": $0.canToggle, "back": $0.canGoBack, "forward": $0.canGoForward,
                                "favicon": $0.favicon != nil] }
        }

        OrbitMotionPreferences.overrideReducedMotion = false
        NSApp.activate(ignoringOtherApps: true)
        let screen = window.screen ?? NSScreen.main!
        window.setFrame(NSRect(x: screen.frame.minX + 60, y: screen.frame.maxY - 60 - 800, width: 1100, height: 800), display: true)
        window.makeKeyAndOrderFront(nil)
        // The synthetic window joins the current Space (even a full-screen one) and stays above
        // other apps' windows while it records.
        // An accessory app's auxiliary window may join another app's full-screen Space.
        NSApp.setActivationPolicy(.accessory)
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.level = .floating
        window.orderFrontRegardless()
        owner.windowShell.setSidebarWidth(190)
        if let model = theme(dark ? .dark : .light, dark ? "#3A393A" : "#EDE6DF") {
            _ = try? await owner.session.setSpaceTheme(model, for: firstSpace, profileID: profile)
        }
        var secondSpace: SpaceID?
        if switchesSpace {
            // The second Space takes the other appearance, so the card restyles on the switch.
            secondSpace = try? await store.createSpace(name: "Synthetic B", profileID: profile)
            owner.session.refreshCatalog()
            await owner.session.waitForQueuedCommands()
            if let secondSpace, let model = theme(dark ? .light : .dark, dark ? "#EDE6DF" : "#3A393A") {
                _ = try? await owner.session.setSpaceTheme(model, for: secondSpace, profileID: profile)
            }
            owner.session.activateSpace(firstSpace)
            await owner.session.waitForQueuedCommands()
        }

        func open(_ path: String) async -> (ChromiumSurface, TabOccurrenceID)? {
            owner.session.openTab(url: base.appendingPathComponent(path))
            await owner.session.waitForQueuedCommands()
            guard let surface = owner.session.selectedSurface, let id = owner.session.snapshot?.selectedOccurrenceID,
                  await waitForLoad(surface) else { return nil }
            return (surface, id)
        }
        guard let (pageC, idC) = await open("blank") else { return ["blankLoaded": false] }
        guard let (pageA, idA) = await open("media-a") else { return ["mediaALoaded": false] }
        _ = await OrbitPerformanceProbe.evaluate(pageA, "(()=>{startMedia();return {}})()")
        _ = await wait { owner.backgroundMedia.session(for: idA)?.playback == .playing }
        _ = pageC
        await pause(0.4)

        // Handshake: the recorder starts once the window geometry is known, and only when this
        // window really covers its whole frame, so the recording never shows another app.
        let frame = window.frame
        let corners = [CGPoint(x: frame.minX + 4, y: screen.frame.maxY - frame.maxY + 4),
                       CGPoint(x: frame.maxX - 4, y: screen.frame.maxY - frame.maxY + 4),
                       CGPoint(x: frame.minX + 4, y: screen.frame.maxY - frame.minY - 4),
                       CGPoint(x: frame.maxX - 4, y: screen.frame.maxY - frame.minY - 4),
                       CGPoint(x: frame.midX, y: screen.frame.maxY - frame.midY)]
        var covered = true
        for _ in 0..<16 where covered {
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            covered = !(await wait(seconds: 0.5, { corners.allSatisfy { topWindow(at: $0).isOurs } }))
        }
        guard !covered else {
            let own = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]])?.first
            return ["windowCovered": corners.map { topWindow(at: $0).owner },
                    "onActiveSpace": window.isOnActiveSpace, "visible": window.isVisible,
                    "occlusionVisible": window.occlusionState.contains(.visible), "level": window.level.rawValue,
                    "appActive": NSApp.isActive, "activationPolicy": NSApp.activationPolicy().rawValue,
                    "cgOnScreen": own?[kCGWindowIsOnscreen as String] as? Bool ?? false,
                    "cgLayer": own?[kCGWindowLayer as String] as? Int ?? -1,
                    "cgBounds": (own?[kCGWindowBounds as String] as? NSDictionary)?.description ?? ""]
        }
        let geometry: [String: Any] = ["x": frame.minX, "y": screen.frame.maxY - frame.maxY, "width": frame.width, "height": frame.height,
                                       "scale": window.backingScaleFactor, "screenHeight": screen.frame.height]
        try? JSONSerialization.data(withJSONObject: geometry).write(to: root.appendingPathComponent("window.json"))
        let go = root.appendingPathComponent("go")
        _ = await wait(seconds: 15) { FileManager.default.fileExists(atPath: go.path) }
        await pause(1.0)

        func cardPoint(_ id: TabOccurrenceID, _ view: KeyPath<SidebarMediaPlayerCard, SidebarMediaPlayerButton>? = nil) -> NSPoint? {
            guard let card = player.card(for: id) else { return nil }
            let target: NSView = view.map { card[keyPath: $0] } ?? card
            return target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        }
        func hover(at point: NSPoint) {
            guard owns(owner), let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            player.mouseMoved(with: event)
        }
        func leave() {
            guard owns(owner), let event = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil) else { return }
            player.mouseExited(with: event)
        }
        func click(_ point: NSPoint) -> Bool {
            guard owns(owner) else { return false }
            window.orderFrontRegardless()
            let screenPoint = window.convertPoint(toScreen: point)
            let topLeft = CGPoint(x: screenPoint.x, y: screen.frame.maxY - screenPoint.y)
            let top = topWindow(at: topLeft)
            guard owns(owner), top.isOurs else { refusedClicks.append(top.owner); return false }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
                NSApp.sendEvent(event)
            }
            return true
        }
        func page(_ surface: ChromiumSurface) async -> [String: Any] {
            await OrbitPerformanceProbe.evaluate(surface, "({paused:audio.paused})") ?? [:]
        }

        // 1. Leaving the playing tab shows one card at once.
        mark("appear-one")
        owner.session.selectOccurrence(idC)
        await owner.session.waitForQueuedCommands()
        checks["appearOne"] = await wait(seconds: 2) { player.items.map(\.id) == [idA] }
        checks["appearOneItems"] = describe()
        await pause(1.2)

        // 2. Hover grows the card; pause and play from it; leaving collapses it.
        guard let restA = cardPoint(idA) else { return checks.merging(["noCard": true]) { $1 } }
        mark("hover-in-one"); hover(at: restA)
        await pause(1.2)
        if let toggle = cardPoint(idA, \.toggleButton) {
            hover(at: toggle)
            if let card = player.card(for: idA), let event = NSEvent.enterExitEvent(with: .mouseEntered, location: toggle, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil) { card.toggleButton.mouseEntered(with: event) }
            await pause(0.8)
            mark("pause-from-card"); checks["pauseClick"] = click(toggle)
            checks["pausedFromCard"] = await wait { player.items.first?.toggle == .play }
            checks["pageAfterCardPause"] = await page(pageA)
            await pause(1.2)
            mark("play-from-card"); checks["playClick"] = click(toggle)
            checks["playingFromCard"] = await wait { player.items.first?.toggle == .pause && player.items.first?.canToggle == true }
            await pause(1.0)
            if let card = player.card(for: idA), let event = NSEvent.enterExitEvent(with: .mouseExited, location: toggle, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, trackingNumber: 0, userData: nil) { card.toggleButton.mouseExited(with: event) }
        }
        mark("hover-out-one"); leave()
        await pause(1.1)

        // 3. A second player makes a deck; hover fans it out, newest on top.
        guard let (pageB, idB) = await open("media-b") else { return checks.merging(["mediaBLoaded": false]) { $1 } }
        _ = await OrbitPerformanceProbe.evaluate(pageB, "(()=>{startMedia();return {}})()")
        _ = await wait { owner.backgroundMedia.session(for: idB)?.playback == .playing }
        await pause(0.6)
        mark("appear-two")
        owner.session.selectOccurrence(idC)
        await owner.session.waitForQueuedCommands()
        checks["appearTwo"] = await wait(seconds: 2) { player.items.map(\.id) == [idA, idB] }
        await pause(1.2)
        if let front = cardPoint(idA) {
            mark("hover-in-two"); hover(at: front)
            await pause(1.3)
            checks["stackExpanded"] = player.progress == 1
            mark("hover-out-two"); leave()
            await pause(1.1)
        }

        // 4. The page pauses itself: the card stays, its transport greyed out.
        mark("pause-from-page")
        _ = await OrbitPerformanceProbe.evaluate(pageA, "(()=>{audio.pause();return {}})()")
        checks["pageGreyed"] = await wait { player.items.first.map { !$0.canToggle && !$0.canGoBack && !$0.canGoForward && $0.toggle == .pause } == true }
        checks["pageGreyedItems"] = describe()
        await pause(1.3)

        // 5. The stack follows into another Space and takes its appearance at once.
        if let secondSpace {
            mark("space-switch")
            owner.session.activateSpace(secondSpace)
            await owner.session.waitForQueuedCommands()
            checks["followsSpace"] = await wait(seconds: 2) { player.items.count == 2 && !player.isHidden }
            checks["secondSpaceDark"] = OrbitAppearance.isDark(player.effectiveAppearance)
            await pause(1.3)
            mark("space-back")
            owner.session.activateSpace(firstSpace)
            await owner.session.waitForQueuedCommands()
            await pause(1.1)
        }

        // 6. The icon returns to its tab; the tab's card leaves while it is shown.
        if let icon = cardPoint(idA, \.faviconButton) {
            hover(at: icon)
            await pause(0.8)
            mark("back-to-tab"); checks["backClick"] = click(icon)
            checks["backToTab"] = await wait(seconds: 2) { owner.session.snapshot?.selectedOccurrenceID == idA && player.items.map(\.id) == [idB] }
            await pause(1.1)
            leave()
        }

        // 7. The close button removes the card and stops the sound; the tab stays.
        mark("reselect-other")
        owner.session.selectOccurrence(idC)
        await owner.session.waitForQueuedCommands()
        _ = await wait(seconds: 2) { player.items.count == 2 }
        await pause(1.0)
        if let front = cardPoint(idA) {
            hover(at: front)
            await pause(1.0)
            if let close = cardPoint(idB, \.closeButton) {
                hover(at: close)
                await pause(0.6)
                mark("close-card"); checks["closeClick"] = click(close)
                checks["closedCard"] = await wait(seconds: 2) { player.items.map(\.id) == [idA] }
                checks["pageAfterClose"] = await page(pageB)
                checks["tabStays"] = owner.session.tabID(for: idB) != nil
            }
            await pause(1.0)
            mark("hover-out-end"); leave()
            await pause(1.1)
        }
        mark("end")
        checks["marks"] = marks
        checks["refusedClicks"] = refusedClicks
        checks["window"] = geometry
        checks["reducedMotion"] = OrbitMotionPreferences.prefersReducedMotion
        return checks
    }
}
