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
        guard let window = owner.window else { return ["refused": "window"] }
        window.orderFrontRegardless()
        guard await wait(3, { owns(window.windowNumber) }) else { return ["refused": "ownership", "bundle": Bundle.main.bundleIdentifier ?? ""] }
        guard let base = command["url"].flatMap(URL.init(string:)), let output = command["output"].map({ URL(fileURLWithPath: $0) }) else {
            return ["refused": "command"]
        }
        _ = await wait(5) { owner.session.snapshot?.activeSpaceID != nil && owner.session.activeProfileID != nil }
        guard let space = owner.session.snapshot?.activeSpaceID, let profile = owner.session.activeProfileID else { return ["refused": "session"] }
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
        func movePointer(_ point: NSPoint) {
            guard owns(window.windowNumber), window.contentView?.bounds.contains(point) == true else { return }
            let screen = window.convertPoint(toScreen: point)
            let global = CGPoint(x: screen.x, y: NSScreen.screens[0].frame.maxY - screen.y)
            CGWarpMouseCursorPosition(global)
            guard owns(window.windowNumber) else { return }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: global,
                    mouseButton: .left)?.postToPid(getpid())
        }
        func hover(_ card: SidebarMediaPlayerCard?) {
            guard owns(window.windowNumber), let card else { return }
            let point = card.convert(NSPoint(x: 87, y: card.bounds.height - 16), to: nil)
            if command["mode"] == "volume" { movePointer(point) }
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
        if command["mode"] == "volume" {
            func item() -> SidebarMediaPlayerItem? { player.items.first { $0.id == id } }
            guard let card = player.card(for: id) else { return ["card": false] }
            checks["volumeCapability"] = owner.engine.capabilities.contains(.audioVolume)
            checks["initialVolume"] = video.audioVolume
            mark("rest"); capture("rest")
            hover(card); await pause(0.4)
            mark("open"); checks["openClick"] = click(card.volumeButton)
            await pause(0.4); capture("volume-open")
            checks["rowHeight"] = card.volumeHeight
            checks["cardHeight"] = card.bounds.height
            checks["sliderFrame"] = NSStringFromRect(card.volumeSlider.frame)
            var samples: [[String: Any]] = []
            let originalVolume = player.onVolume
            player.onVolume = { target, level in
                originalVolume?(target, level)
                samples.append(["requested": level, "reported": video.audioVolume ?? -1,
                                "muted": video.tabAudioMuted() ?? false])
            }
            defer { player.onVolume = originalVolume }
            func drag(_ levels: [Double]) {
                guard owns(window.windowNumber), card.volumeSlider.window === window else { return }
                let slider = card.volumeSlider
                func event(_ type: NSEvent.EventType, _ level: Double) -> NSEvent? {
                    guard owns(window.windowNumber) else { return nil }
                    let point = slider.convert(NSPoint(x: 10 + (slider.bounds.width - 20) * level, y: 16.5), to: nil)
                    return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                }
                guard let first = levels.first, let last = levels.last, let down = event(.leftMouseDown, first) else { return }
                for level in levels.dropFirst() {
                    if let next = event(.leftMouseDragged, level) { NSApp.postEvent(next, atStart: false) }
                }
                if let up = event(.leftMouseUp, last) { NSApp.postEvent(up, atStart: false) }
                guard owns(window.windowNumber) else { return }
                slider.mouseDown(with: down)
            }
            mark("drag-quarter"); drag([1, 0.8, 0.6, 0.4, 0.25])
            await pause(0.25)
            checks["quarterVolume"] = video.audioVolume
            mark("mute"); checks["muteClick"] = click(card.muteButton)
            checks["muted"] = await wait { item()?.isMuted == true }
            checks["mutedVolume"] = video.audioVolume
            await pause(0.4); capture("volume-muted")
            mark("unmute"); checks["unmuteClick"] = click(card.muteButton)
            checks["unmuted"] = await wait { item()?.isMuted == false }
            checks["restoredVolume"] = video.audioVolume
            checks["sameCardAfterUnmute"] = player.card(for: id) === card
            _ = click(card.muteButton)
            _ = await wait { item()?.isMuted == true }
            mark("drag-zero"); drag([0])
            checks["zeroStaysMuted"] = video.tabAudioMuted() == true && video.audioVolume == 0
            mark("drag-unmutes"); drag([0.15, 0.35, 0.65])
            checks["positiveDragUnmutes"] = await wait { item()?.isMuted == false }
            checks["positiveVolume"] = video.audioVolume
            await pause(0.4)
            checks["sameCardAfterPositiveDrag"] = player.card(for: id) === card
            mark("close"); checks["closeClick"] = click(card.volumeButton)
            await pause(0.4)
            checks["closedRow"] = !card.isVolumeOpen && card.bounds.height == 124
            mark("reopen"); _ = click(card.volumeButton)
            await pause(0.4)
            checks["reopenLevel"] = card.volumeSlider.level
            capture("volume-restored")
            if owns(window.windowNumber) { window.makeFirstResponder(nil) }
            movePointer(NSPoint(x: 600, y: 400))
            mark("collapse"); player.setHovered(false)
            await pause(0.4); capture("volume-collapsed")
            owner.session.selectOccurrence(id)
            await owner.session.waitForQueuedCommands()
            checks["selectedCardHidden"] = await wait { player.card(for: id) == nil }
            owner.session.selectOccurrence(blankID)
            await owner.session.waitForQueuedCommands()
            checks["returnedLevel"] = await wait { player.items.first { $0.id == id }?.volume == 0.65 }
            checks["engineLevelAfterReturn"] = video.audioVolume
            if let (audio, audioID) = await open("audio") {
                _ = await OrbitPerformanceProbe.evaluate(audio, "(()=>{startMedia();return {}})()")
                _ = await wait { owner.backgroundMedia.session(for: audioID)?.playback == .playing }
                owner.session.selectOccurrence(blankID)
                await owner.session.waitForQueuedCommands()
                _ = await wait { player.card(for: audioID) != nil }
                checks["otherTabDefault"] = audio.audioVolume
                owner.setBackgroundMediaVolume(0.4, on: audioID)
                checks["otherTabVolume"] = audio.audioVolume
                checks["firstTabUnchanged"] = video.audioVolume
            }
            checks["liveSamples"] = samples
            checks["marks"] = marks
            checks["window"] = metadata
            return checks
        }
        mark("rest"); capture("rest")
        await pause(0.3)
        hover(player.card(for: id)); mark("hover")
        await pause(0.45)
        capture("expanded")
        checks["expandedHeight"] = player.card(for: id)?.bounds.height
        checks["restHeight"] = player.restingHeight
        guard let card = player.card(for: id) else { return checks }
        func forwardKey() -> NSEvent? {
            guard owns(window.windowNumber) else { return nil }
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{f703}", charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 0)
        }
        // Character-based keyboard seek exercises the actual native control route.
        if let key = forwardKey() {
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
        func pageWait(_ surface: ChromiumSurface, _ seconds: Double = 2, _ test: ([String: Any]) -> Bool) async -> Bool {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < until {
                if test(await pageState(surface)) { return true }
                await pause(0.05)
            }
            return false
        }
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
        // Muted transport: the engine leaves the muted player out of its session; the card drives
        // the media element directly and follows its answer.
        checks["mutedTransportEnabled"] = card.toggleButton.isEnabled && card.timeline.seek.canSeek
        mark("muted-pause"); checks["mutedPauseClick"] = click(card.toggleButton)
        checks["mutedPauseCard"] = await wait { item(id)?.toggle == .play && item(id)?.canToggle == true }
        checks["mutedPausePage"] = await pageWait(video) { $0["paused"] as? Bool == true }
        checks["mutedCardWhilePaused"] = player.card(for: id) != nil && item(id)?.isMuted == true
        await pause(0.5)
        mark("muted-play"); checks["mutedPlayClick"] = click(card.toggleButton)
        checks["mutedPlayCard"] = await wait { item(id)?.toggle == .pause }
        checks["mutedPlayPage"] = await pageWait(video) { $0["paused"] as? Bool == false }
        let progress0 = card.timeline.seek.currentPosition(interpolate: true) ?? 0
        await pause(0.6)
        let progress1 = card.timeline.seek.currentPosition(interpolate: true) ?? 0
        checks["mutedProgressMoves"] = progress1 - progress0 > 0.4
        hover(player.card(for: id))
        let seekFrom = (await pageState(video))["time"] as? Double ?? 0
        mark("muted-seek")
        if let key = forwardKey() { card.timeline.keyDown(with: key) }
        checks["mutedSeekPage"] = await pageWait(video) { ($0["time"] as? Double ?? 0) >= seekFrom + 4 }
        checks["mutedSeekCard"] = await wait { (card.timeline.seek.displayed ?? 0) >= seekFrom + 4 }
        checks["mutedSeek"] = ["from": seekFrom, "page": (await pageState(video))["time"] ?? 0, "card": card.timeline.seek.displayed ?? 0]
        saveProgress()
        await pause(0.8)
        // Manual PiP: eligibility, entry, engine acknowledgement, exit through the existing route.
        owner.refreshManualPiPCapabilities(force: true)
        checks["pipEligible"] = await wait { card.pipButton.isEnabled }
        mark("pip-request"); checks["pipClick"] = click(card.pipButton)
        checks["pipActive"] = await wait(4) { video.pagePerformance?.lifecycle()?.pictureInPicture == true }
        checks["cardHiddenInPiP"] = await wait(2) { player.card(for: id) == nil }
        checks["pipAdapter"] = "\(String(describing: video.manualPictureInPicture?.state)) \(String(describing: video.manualPictureInPicture?.failure))"
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
        checks["cardRestoredMuted"] = await wait { item(id)?.isMuted == true && item(id)?.canToggle == true }
        saveProgress()
        // × on the muted card pauses the element and removes the card; the page playing again
        // brings it back.
        hover(player.card(for: id)); await pause(0.3)
        mark("muted-close"); checks["mutedCloseClick"] = click(player.card(for: id)?.closeButton)
        checks["mutedCloseRemovesCard"] = await wait { player.card(for: id) == nil }
        checks["mutedClosePausesPage"] = await pageWait(video) { $0["paused"] as? Bool == true }
        _ = await OrbitPerformanceProbe.evaluate(video, "(()=>{media.play();return {}})()")
        checks["mutedCardReturnsOnPlay"] = await wait(3) { player.card(for: id) != nil }
        if player.card(for: id) == nil { try? video.setAudioMuted(false); owner.siteControls.refreshMedia(video) }
        _ = await wait(3) { player.card(for: id) != nil }
        guard let card = player.card(for: id) else { return checks }
        hover(card); await pause(0.3)
        if item(id)?.isMuted == true {
            mark("unmute"); checks["unmuteClick"] = click(card.muteButton)
        }
        checks["unmuted"] = await wait { item(id)?.isMuted == false && item(id)?.canToggle == true }
        checks["cardAfterUnmute"] = player.card(for: id) != nil
        checks["cardReplacedOnUnmute"] = player.card(for: id) !== card
        // Unmuted transport goes through the engine session again.
        hover(player.card(for: id)); await pause(0.2)
        mark("unmuted-pause"); checks["unmutedPauseClick"] = click(player.card(for: id)?.toggleButton)
        checks["unmutedPausePage"] = await pageWait(video) { $0["paused"] as? Bool == true }
        checks["unmutedPauseCard"] = await wait { item(id)?.toggle == .play }
        checks["unmutedPlayClick"] = click(player.card(for: id)?.toggleButton)
        checks["unmutedPlayPage"] = await pageWait(video) { $0["paused"] as? Bool == false }
        let unmutedFrom = (await pageState(video))["time"] as? Double ?? 0
        if let key = forwardKey() { player.card(for: id)?.timeline.keyDown(with: key) }
        checks["unmutedSeekPage"] = await pageWait(video) { ($0["time"] as? Double ?? 0) >= unmutedFrom + 4 }
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
