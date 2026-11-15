import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Synthetic-only product walkthrough. The caller holds the GUI slot for the entire run.
@MainActor
enum OrbitMediaAdditionsProbe {
    static let bundleID = "lab.orbit.orbit.media-additions"
    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        func owns(_ number: Int) -> Bool {
            guard Bundle.main.bundleIdentifier == bundleID,
                  Bundle.main.object(forInfoDictionaryKey: "OrbitSyntheticBundle") as? Bool == true,
                  Bundle.main.object(forInfoDictionaryKey: "OrbitUseMockKeychain") as? Bool == true,
                  let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]] else { return false }
            return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        func wait(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            while !condition() {
                if ProcessInfo.processInfo.systemUptime >= until { return false }
                await pause(0.025)
            }
            return true
        }
        guard let window = owner.window, owns(window.windowNumber), let base = command["url"].flatMap(URL.init(string:)),
              let output = command["output"].map({ URL(fileURLWithPath: $0) }),
              let space = owner.session.snapshot?.activeSpaceID, let profile = owner.session.activeProfileID else { return ["refused": true] }
        let dark = command["appearance"] == "dark"
        var checks: [String: Any] = [:]
        var marks: [[String: Any]] = []
        func mark(_ name: String) { marks.append(["state": name, "time": Date().timeIntervalSince1970]) }
        let player = owner.sidebar.mediaPlayer
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        window.level = .floating
        let screen = window.screen ?? NSScreen.main!
        window.setFrame(NSRect(x: screen.frame.minX + 40, y: screen.frame.maxY - 840, width: 1100, height: 800), display: true)
        window.orderFrontRegardless()
        owner.windowShell.setSidebarWidth(190)
        let color = BrowserThemeColor(hexString: dark ? "#3A393A" : "#EDE6DF")!
        let theme = BrowserSpaceTheme(mode: dark ? .dark : .light, colors: [], intensity: 0.78, noise: 0,
            light: .init(stops: [color]), dark: .init(stops: [color]))
        _ = try? await owner.session.setSpaceTheme(theme, for: space, profileID: profile)
        func open(_ path: String) async -> (ChromiumSurface, TabOccurrenceID)? {
            owner.session.openTab(url: base.appendingPathComponent(path))
            await owner.session.waitForQueuedCommands()
            guard let surface = owner.session.selectedSurface, let id = owner.session.snapshot?.selectedOccurrenceID,
                  await wait(5, { surface.isReady && !surface.navigationState.isLoading && surface.navigationState.committedURL != nil }) else { return nil }
            await pause(0.15)
            return (surface, id)
        }
        func capture(_ name: String, number: Int? = nil) {
            let number = number ?? window.windowNumber
            guard owns(number) else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(number), output.appendingPathComponent((dark ? "dark-" : "light-") + name + ".png").path]
            try? task.run(); task.waitUntilExit()
        }
        func hover(_ card: SidebarMediaPlayerCard?) {
            guard owns(window.windowNumber), let card else { return }
            let point = card.convert(NSPoint(x: 87, y: card.bounds.height - 16), to: nil)
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { player.mouseMoved(with: event) }
        }
        func click(_ button: NSButton?) -> Bool {
            guard owns(window.windowNumber), let button, button.window === window, button.isEnabled else { return false }
            button.performClick(nil)
            return true
        }
        guard let (_, blankID) = await open("blank"), let (video, id) = await open("video") else { return ["loaded": false] }
        _ = await OrbitPerformanceProbe.evaluate(video, "(()=>{startMedia();return {}})()")
        guard await wait(4, { owner.backgroundMedia.session(for: id)?.playback == .playing }) else { return ["playing": false] }
        owner.session.selectOccurrence(blankID)
        await owner.session.waitForQueuedCommands()
        guard await wait(3, { player.card(for: id) != nil }) else { return ["card": false] }
        await pause(0.35)
        func saveProgress() {
            try? JSONSerialization.data(withJSONObject: checks).write(to: output.appendingPathComponent((dark ? "dark" : "light") + "-progress.json"))
        }
        let rect = player.convert(player.bounds, to: nil)
        let metadata: [String: Any] = ["pid": getpid(), "window": window.windowNumber, "scale": window.backingScaleFactor,
            "playerX": rect.minX, "playerTop": window.frame.height - rect.maxY, "playerWidth": rect.width, "playerHeight": rect.height]
        try? JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("media-ready.json"))
        _ = await wait(8, { FileManager.default.fileExists(atPath: root.appendingPathComponent("media-go").path) })
        mark("rest"); capture("rest")
        await pause(0.3)
        hover(player.card(for: id)); mark("hover")
        await pause(0.45)
        capture("expanded")
        checks["expandedHeight"] = player.card(for: id)?.bounds.height
        checks["restHeight"] = player.restingHeight
        guard let card = player.card(for: id) else { return checks }
        // Character-based keyboard seek exercises the actual native control route.
        if owns(window.windowNumber), let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 0) {
            let before = card.timeline.seek.displayed ?? 0
            card.timeline.keyDown(with: key)
            await pause(0.25)
            let result = await OrbitPerformanceProbe.evaluate(video, "({time:media.currentTime,volume:media.volume,muted:media.muted})") ?? [:]
            checks["seekBefore"] = before; checks["seekAfter"] = result
        }
        saveProgress()
        mark("mute"); checks["muteClick"] = click(card.muteButton)
        checks["muted"] = await wait { player.items.first(where: { $0.id == id })?.isMuted == true }
        capture("muted"); saveProgress()
        _ = click(card.muteButton)
        await pause(0.25)
        owner.refreshManualPiPCapabilities(force: true)
        checks["pipEligible"] = await wait { card.pipButton.isEnabled }
        mark("pip-request"); checks["pipClick"] = click(card.pipButton)
        checks["pipActive"] = await wait { video.pagePerformance?.lifecycle()?.pictureInPicture == true }
        mark("pip-active"); capture("pip-active"); saveProgress()
        _ = await wait(2, { NSApp.windows.contains { candidate in
            candidate !== window && candidate.isVisible && candidate.frame.width >= 150 && candidate.frame.height >= 100 &&
            candidate.styleMask.contains(.fullSizeContentView) && !candidate.styleMask.contains(.titled) && candidate.level == .floating
        } })
        do {
            let numbers = NSApp.windows.filter { candidate in
                candidate !== window && candidate.isVisible && candidate.frame.width >= 150 && candidate.frame.height >= 100 &&
                candidate.styleMask.contains(.fullSizeContentView) && !candidate.styleMask.contains(.titled) && candidate.level == .floating && owns(candidate.windowNumber)
            }.map(\.windowNumber)
            for (index, number) in numbers.enumerated() { capture("pip-window-\(index)", number: number) }
            checks["pipWindows"] = numbers
            if let number = numbers.first, owns(number) {
                try? JSONSerialization.data(withJSONObject: ["pid": getpid(), "window": number, "wall": Date().timeIntervalSince1970])
                    .write(to: root.appendingPathComponent("pip-ready.json"))
                _ = await wait(3, { FileManager.default.fileExists(atPath: root.appendingPathComponent("pip-go").path) })
            }
        }
        await pause(0.7)
        // Selection must preserve manual ownership, then the existing exit route returns inline.
        owner.session.selectOccurrence(id)
        await owner.session.waitForQueuedCommands()
        await pause(0.25)
        checks["manualSurvivesSelection"] = video.pagePerformance?.lifecycle()?.pictureInPicture == true
        video.manualPictureInPicture?.acknowledge(active: true)
        await video.manualPictureInPicture?.toggle()
        checks["pipExited"] = await wait { video.pagePerformance?.lifecycle()?.pictureInPicture != true }
        owner.session.selectOccurrence(blankID)
        await owner.session.waitForQueuedCommands()
        checks["cardRestored"] = await wait { player.card(for: id) != nil }
        // Live style: a real MediaStream has no finite duration or seek range.
        guard let (live, liveID) = await open("live") else { return checks }
        _ = await OrbitPerformanceProbe.evaluate(live, "(()=>{startMedia();return {}})()")
        _ = await wait { owner.backgroundMedia.session(for: liveID)?.playback == .playing }
        owner.session.selectOccurrence(blankID)
        await owner.session.waitForQueuedCommands()
        _ = await wait { player.card(for: liveID) != nil }
        hover(player.card(for: liveID)); await pause(0.4)
        checks["liveNoTimeline"] = player.card(for: liveID).map { $0.timeline.seek.finiteDuration == nil } ?? false
        capture("live")
        // Audio-only remains controllable, with PiP truthfully unavailable.
        guard let (audio, audioID) = await open("audio") else { return checks }
        _ = await OrbitPerformanceProbe.evaluate(audio, "(()=>{startMedia();return {}})()")
        _ = await wait { owner.backgroundMedia.session(for: audioID)?.playback == .playing }
        owner.session.selectOccurrence(blankID)
        await owner.session.waitForQueuedCommands()
        _ = await wait { player.card(for: audioID) != nil }
        hover(player.card(for: audioID)); await pause(0.4)
        checks["audioOnlyPiPUnavailable"] = player.card(for: audioID)?.pipButton.isEnabled == false
        capture("audio-deck")
        saveProgress()
        checks["marks"] = marks
        checks["window"] = metadata
        return checks
    }
}
