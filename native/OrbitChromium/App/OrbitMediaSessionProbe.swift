import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Synthetic-only qualification of background media session plumbing: a MediaSession page in
/// a tab the user left must report its state and obey play/pause/next/previous. No UI.
@MainActor
enum OrbitMediaSessionProbe {
    static let bundleID = "lab.orbit.orbit.mini-player"

    private static func owns(_ owner: OrbitWindowController) -> Bool {
        guard Bundle.main.bundleIdentifier == bundleID,
              Bundle.main.infoDictionary?["OrbitSyntheticBundle"] as? Bool == true,
              Bundle.main.infoDictionary?["OrbitUseMockKeychain"] as? Bool == true,
              let window = owner.window,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]] else { return false }
        return rows.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
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
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }

    private static func describe(_ entries: [OrbitWindowController.BackgroundMediaEntry]) -> [[String: Any]] {
        entries.map { entry in
            let session = entry.session
            return ["playback": session.playback == .playing ? "playing" : "paused",
                    "title": session.title, "artist": session.artist,
                    "artwork": session.artworkURL?.lastPathComponent ?? "",
                    "actions": session.actions.map(\.rawValue).sorted(),
                    "audible": session.isAudible.map { $0 ? "true" : "false" } ?? "unknown",
                    "muted": session.isAudioMuted.map { $0 ? "true" : "false" } ?? "unknown",
                    "duration": session.duration ?? -1]
        }
    }

    static func run(_ owner: OrbitWindowController, command: [String: String]) async -> [String: Any] {
        _ = await wait { owns(owner) }
        guard owns(owner), let base = command["url"].flatMap(URL.init(string:)) else {
            return ["refused": true, "bundle": Bundle.main.bundleIdentifier == bundleID, "window": owner.window?.isVisible == true]
        }
        var log: [String] = []
        var checks: [String: Any] = [:]
        var changes = 0
        let previousHook = owner.onBackgroundMediaChange
        owner.onBackgroundMediaChange = { changes += 1; previousHook?() }
        defer { owner.onBackgroundMediaChange = previousHook }
        func note(_ line: String) { log.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line) }

        owner.session.openTab(url: base.appendingPathComponent("media"))
        await owner.session.waitForQueuedCommands()
        guard let media = owner.session.selectedSurface, let mediaID = owner.session.snapshot?.selectedOccurrenceID,
              await waitForLoad(media) else { return ["mediaTabLoaded": false] }
        _ = await OrbitPerformanceProbe.evaluate(media, "(()=>{startMedia();return {started:true}})()")
        checks["foregroundPlaying"] = await wait { owner.backgroundMedia.session(for: mediaID)?.playback == .playing }
        func nativeText() -> String {
            guard let state = media.mediaSessionState(), let data = try? JSONEncoder().encode(state) else { return "nil" }
            return String(decoding: data, as: UTF8.self)
        }
        checks["diagnostics"] = ["native": nativeText(), "tabID": owner.session.tabID(for: mediaID) != nil,
                                 "spaceID": owner.session.spaceID(for: mediaID) != nil,
                                 "owned": owner.session.ownedSurfaces.count, "tracked": owner.backgroundMedia.sessions.count]
        checks["foregroundExcluded"] = owner.backgroundMediaSessions.isEmpty
        note("media tab playing in foreground; background list count=\(owner.backgroundMediaSessions.count)")

        owner.session.openTab(url: base.appendingPathComponent("blank"))
        await owner.session.waitForQueuedCommands()
        guard let other = owner.session.selectedSurface, other !== media, await waitForLoad(other) else { return ["otherTabLoaded": false] }
        owner.siteControls.refreshMedia(media)
        _ = await wait(seconds: 2) { owner.backgroundMedia.session(for: mediaID)?.isAudioMuted != nil }
        let background = owner.backgroundMediaSessions
        checks["background"] = describe(background)
        checks["backgroundIsMediaTab"] = background.map(\.occurrenceID) == [mediaID]
        note("switched to another tab; background=\(describe(background))")

        func player() async -> [String: Any] {
            await OrbitPerformanceProbe.evaluate(media, "({paused:audio.paused,next:nextCount,previous:previousCount})") ?? [:]
        }
        checks["pauseResult"] = "\(owner.performBackgroundMediaAction(.pause, on: mediaID))"
        checks["modelPaused"] = await wait { owner.backgroundMediaSessions.first?.session.playback == .paused }
        checks["playerAfterPause"] = await player()
        checks["nativeAfterPause"] = nativeText()
        note("pause from model -> \(checks["pauseResult"]!), model paused=\(checks["modelPaused"]!), page=\(checks["playerAfterPause"]!)")

        checks["playResult"] = "\(owner.performBackgroundMediaAction(.play, on: mediaID))"
        checks["modelPlaying"] = await wait { owner.backgroundMediaSessions.first?.session.playback == .playing }
        checks["playerAfterPlay"] = await player()
        note("play from model -> \(checks["playResult"]!), model playing=\(checks["modelPlaying"]!), page=\(checks["playerAfterPlay"]!)")

        checks["nextResult"] = "\(owner.performBackgroundMediaAction(.next, on: mediaID))"
        checks["previousResult"] = "\(owner.performBackgroundMediaAction(.previous, on: mediaID))"
        try? await Task.sleep(for: .milliseconds(300))
        checks["playerAfterTracks"] = await player()
        note("next/previous -> \(checks["nextResult"]!)/\(checks["previousResult"]!), page=\(checks["playerAfterTracks"]!)")

        owner.session.selectOccurrence(mediaID)
        await owner.session.waitForQueuedCommands()
        checks["selectedExcluded"] = await wait(seconds: 2) { owner.backgroundMediaSessions.isEmpty }
        checks["stillTracked"] = owner.backgroundMedia.session(for: mediaID) != nil
        note("media tab selected again; background count=\(owner.backgroundMediaSessions.count)")

        // Chromium removes the players of a muted tab from its media session.
        try? media.setAudioMuted(true)
        checks["mutedRemoved"] = await wait(seconds: 3) { owner.backgroundMedia.session(for: mediaID) == nil }
        try? media.setAudioMuted(false)
        checks["unmutedRestored"] = await wait(seconds: 3) { owner.backgroundMedia.session(for: mediaID) != nil }
        note("mute removed session=\(checks["mutedRemoved"]!), unmute restored=\(checks["unmutedRestored"]!)")
        _ = await OrbitPerformanceProbe.evaluate(media, "(()=>{audio.pause();audio.src='';audio.load();return {}})()")
        checks["endedRemoved"] = await wait { owner.backgroundMedia.session(for: mediaID) == nil }
        note("page dropped its player; tracked=\(owner.backgroundMedia.session(for: mediaID) != nil)")
        checks["changeNotifications"] = changes
        checks["log"] = log
        return checks
    }
}
