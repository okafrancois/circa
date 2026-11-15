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
        // Manual PiP is validated alone: automatic PiP stays off in this synthetic root only.
        if let settings = owner.settingsPreferences?.runtime {
            try? await settings.store.setAutomaticPictureInPicture(false)
            await settings.refresh()
            checks["automaticPiPOff"] = settings.document.automaticPictureInPicture == false
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
        func pageState(_ surface: ChromiumSurface) async -> [String: Any] {
            await OrbitPerformanceProbe.evaluate(surface, "({time:media.currentTime,paused:media.paused,muted:media.muted})") ?? [:]
        }
        func item(_ id: TabOccurrenceID) -> SidebarMediaPlayerItem? { player.items.first { $0.id == id } }
        // Mute from the card: the card stays, muted, with an unmute toggle while playback goes on.
        mark("mute"); checks["muteClick"] = click(card.muteButton)
        checks["muted"] = await wait { item(id)?.isMuted == true }
        let mutedAt = await pageState(video)
        await pause(1.2)
        let mutedLater = await pageState(video)
        checks["cardStaysMuted"] = player.card(for: id) != nil && item(id)?.isMuted == true
        checks["unmuteOffered"] = card.muteButton.isEnabled && card.muteButton.symbol == "speaker.slash.fill" && card.muteButton.accessibilityValue() as? Int == 1
        checks["playsWhileMuted"] = mutedLater["paused"] as? Bool == false &&
            ((mutedLater["time"] as? Double ?? 0) - (mutedAt["time"] as? Double ?? 0)) > 0.8
        checks["mutedStatus"] = card.audioStatus.stringValue
        hover(player.card(for: id)); await pause(0.1)
        capture("muted"); saveProgress()
        mark("unmute"); checks["unmuteClick"] = click(card.muteButton)
        checks["unmuted"] = await wait { item(id)?.isMuted == false && item(id)?.canToggle == true }
        checks["cardAfterUnmute"] = player.card(for: id) != nil
        saveProgress()
        // Manual PiP: eligibility, entry, engine acknowledgement, exit through the existing route.
        owner.refreshManualPiPCapabilities(force: true)
        checks["pipEligible"] = await wait { card.pipButton.isEnabled }
        mark("pip-request"); checks["pipClick"] = click(card.pipButton)
        checks["pipActive"] = await wait(4) { video.pagePerformance?.lifecycle()?.pictureInPicture == true }
        checks["cardHiddenInPiP"] = await wait(2) { player.card(for: id) == nil }
        mark("pip-active")
        let pipWindows: [NSWindow] = await {
            _ = await wait(2, { NSApp.windows.contains { $0 !== window && $0.isVisible && $0.frame.width >= 150 && $0.level == .floating && !$0.styleMask.contains(.titled) } })
            return NSApp.windows.filter { $0 !== window && $0.isVisible && $0.frame.width >= 150 && $0.level == .floating && !$0.styleMask.contains(.titled) && owns($0.windowNumber) }
        }()
        await pause(0.3)
        capture("pip-active")
        for (index, pip) in pipWindows.enumerated() { capture("pip-window-\(index)", number: pip.windowNumber) }
        checks["pipWindows"] = pipWindows.map { ["window": $0.windowNumber, "x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width, "height": $0.frame.height] }
        saveProgress()
        await pause(1.0)
        // Manual ownership: returning to the tab keeps PiP; the existing exit route ends it.
        owner.session.selectOccurrence(id)
        await owner.session.waitForQueuedCommands()
        await pause(0.6)
        checks["manualSurvivesSelection"] = video.pagePerformance?.lifecycle()?.pictureInPicture == true
        mark("pip-exit")
        video.manualPictureInPicture?.acknowledge(active: video.pagePerformance?.lifecycle()?.pictureInPicture == true)
        await video.manualPictureInPicture?.toggle()
        checks["pipExited"] = await wait { video.pagePerformance?.lifecycle()?.pictureInPicture != true }
        owner.session.selectOccurrence(blankID)
        await owner.session.waitForQueuedCommands()
        checks["cardRestored"] = await wait { player.card(for: id) != nil }
        saveProgress()
        // Live style: a real MediaStream has no finite duration or seek range.
        if let (live, liveID) = await open("live") {
            _ = await OrbitPerformanceProbe.evaluate(live, "(()=>{startMedia();return {}})()")
            _ = await wait { owner.backgroundMedia.session(for: liveID)?.playback == .playing }
            owner.session.selectOccurrence(blankID)
            await owner.session.waitForQueuedCommands()
            _ = await wait { player.card(for: liveID) != nil }
            hover(player.card(for: liveID)); await pause(0.45)
            checks["liveNoTimeline"] = player.card(for: liveID).map { $0.timeline.seek.finiteDuration == nil } ?? false
            mark("live"); capture("live")
            // × stops the media and removes the card; the tab stays.
            checks["closeClick"] = click(player.card(for: liveID)?.closeButton)
            checks["closeRemovesCard"] = await wait { player.card(for: liveID) == nil }
            checks["closePausesPage"] = await wait(2) { owner.backgroundMedia.session(for: liveID)?.playback != .playing }
            checks["closeKeepsTab"] = owner.session.tabID(for: liveID) != nil
        }
        // Two players: the deck expands both cards; a tab muted from its sidebar speaker keeps its card.
        guard let (audio, audioID) = await open("audio") else { return checks }
        _ = await OrbitPerformanceProbe.evaluate(audio, "(()=>{startMedia();return {}})()")
        _ = await wait { owner.backgroundMedia.session(for: audioID)?.playback == .playing }
        owner.session.selectOccurrence(blankID)
        await owner.session.waitForQueuedCommands()
        _ = await wait { player.card(for: audioID) != nil && player.card(for: id) != nil }
        hover(player.card(for: audioID)); await pause(0.5)
        checks["deckCards"] = player.items.count
        checks["deckHeights"] = [id, audioID].compactMap { player.card(for: $0)?.bounds.height }
        checks["audioOnlyPiPUnavailable"] = player.card(for: audioID)?.pipButton.isEnabled == false
        mark("deck"); capture("deck-expanded")
        if let tab = owner.session.tabID(for: audioID) {
            owner.sidebar.onToggleTabAudio?(tab)
            checks["elsewhereMuted"] = await wait { item(audioID)?.isMuted == true }
            await pause(0.8)
            checks["elsewhereCardStays"] = player.card(for: audioID) != nil && item(audioID)?.isMuted == true
            let audioState = await OrbitPerformanceProbe.evaluate(audio, "({paused:media.paused})") ?? [:]
            checks["elsewherePlays"] = audioState["paused"] as? Bool == false
            owner.sidebar.onToggleTabAudio?(tab)
            _ = await wait { item(audioID)?.isMuted == false }
        }
        saveProgress()
        checks["marks"] = marks
        checks["window"] = metadata
        return checks
    }
}
