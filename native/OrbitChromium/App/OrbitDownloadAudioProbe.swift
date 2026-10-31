import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine

/// Invoked only through the explicitly enabled, synthetic-root performance endpoint.
@MainActor
enum OrbitDownloadAudioProbe {
    private static var openAccepted = false
    private static var revealRequested = false
    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        var result: [String: Any] = [:]
        let step = command["step"] ?? "status"
        if step == "window", let screen = NSScreen.screens.first {
            owner.window?.setFrame(screen.visibleFrame, display: true)
            owner.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return ["frame": NSStringFromRect(screen.visibleFrame)]
        }
        if step == "feedback-hover" {
            owner.downloadHoverChanged(command["inside"] == "true")
            return ["hover": owner.downloadFeedback.isHovering]
        }
        if step == "feedback-status" {
            return ["reducedMotion": OrbitMotionPreferences.prefersReducedMotion, "windowVisible": owner.window?.isVisible == true, "active": owner.downloadFeedback.hasActiveDownloads,
                    "completion": owner.downloadFeedback.completion != nil,
                    "presented": owner.downloadFeedback.isPresented,
                    "rows": owner.sidebar.recentDownloads.items.count,
                    "sidebar": NSStringFromRect(owner.sidebar.frame),
                    "footer": NSStringFromRect(owner.sidebar.footer.frame),
                    "library": NSStringFromRect(owner.sidebar.footer.libraryButton.frame)]
        }
        if step == "feedback-light" {
            OrbitMotionPreferences.overrideReducedMotion = false
            NSApp.appearance = NSAppearance(named: .aqua)
            owner.windowShell.setSidebarWidth(500)
            if let space = owner.session.snapshot?.activeSpaceID, let profile = owner.session.activeProfileID,
               let color = BrowserThemeColor(hexString: "#B6B6B8") {
                let theme = BrowserSpaceTheme(mode: .light, colors: [], intensity: 0.78, noise: 0,
                    light: .init(stops: [color]), dark: .init(stops: [color]))
                _ = try? await owner.session.setSpaceTheme(theme, for: space, profileID: profile)
            }
            return ["light": true]
        }
        if step == "load", let url = command["url"].flatMap(URL.init(string:)) {
            owner.downloads.destinationProvider = { _, filename in root.appendingPathComponent(filename) }
            owner.downloads.openFile = { openAccepted = NSWorkspace.shared.open($0) }
            owner.downloads.revealFile = { NSWorkspace.shared.activateFileViewerSelecting([$0]); revealRequested = true }
            owner.session.openTab(url: url)
            await owner.session.waitForQueuedCommands()
            return ["loaded": true]
        }
        if step == "select", let index = command["index"].flatMap(Int.init),
           let tabs = owner.session.snapshot?.tabs, tabs.indices.contains(index) {
            owner.session.selectOccurrence(tabs[index].occurrenceID)
            await owner.session.waitForQueuedCommands()
            return ["selected": index]
        }
        if step == "automatic-pip", let settings = owner.settingsPreferences?.runtime {
            try? await settings.store.setAutomaticPictureInPicture(command["enabled"] == "true")
            await settings.refresh()
            return ["enabled": settings.document.automaticPictureInPicture]
        }
        if step == "pip-status" {
            var players: [[String: Any]] = []
            for surface in owner.session.ownedSurfaces where surface.isReady {
                if let state = await OrbitPerformanceProbe.evaluate(surface,
                    "({pip:!!document.pictureInPictureElement, playing:[...document.querySelectorAll('video')].some(v=>!v.paused)})") {
                    players.append(state)
                }
            }
            result["players"] = players
            result["windows"] = NSApp.windows.map { window in
                ["number": window.windowNumber, "class": String(describing: type(of: window)),
                 "identifier": window.identifier?.rawValue ?? "", "level": window.level.rawValue,
                 "visible": window.isVisible, "frame": NSStringFromRect(window.frame),
                 "style": window.styleMask.rawValue, "behavior": window.collectionBehavior.rawValue,
                 "title": window.title] as [String: Any]
            }
            return result
        }
        if let surface = owner.session.selectedSurface {
            if step == "evaluate", let expression = command["expression"] {
                result["evaluation"] = await OrbitPerformanceProbe.evaluate(surface, expression) ?? [:]
                return result
            }
            if step == "mute" { try? surface.setAudioMuted(command["muted"] == "true") }
            if step == "toggle-audio", let id = owner.session.organization?.selectedTab?.id {
                owner.sidebar.onToggleTabAudio?(id)
                await owner.session.waitForQueuedCommands()
            }
            let media = await surface.requestMediaState()
            result["audible"] = media.isAudible as Any? ?? NSNull()
            result["audioPlaying"] = media.isAudioPlaying as Any? ?? NSNull()
            result["muted"] = media.isAudioMuted as Any? ?? NSNull()
            result["playback"] = String(describing: media.playback)
            result["allowsSuspension"] = surface.allowsSuspension
            result["archiveProtected"] = BrowserArchiveRuntime<ChromiumSurface>.protects(media)
            if let item = owner.sidebar.listContent.tabs.first(where: { $0.selected }) {
                result["sidebarAudible"] = item.activity.isAudible as Any? ?? NSNull()
                result["sidebarMuted"] = item.activity.isAudioMuted as Any? ?? NSNull()
            }
            if step == "close", let id = owner.session.snapshot?.selectedOccurrenceID {
                owner.session.closeOccurrence(id)
                await owner.session.waitForQueuedCommands()
            }
        }
        if let profile = owner.session.activeProfileID {
            if let action = command["action"], let latest = owner.downloads.snapshots(profileID: profile).last(where: {
                command["filename"] == nil || $0.suggestedFilename == command["filename"]
            }) {
                if let action = BrowserDownloadAction(rawValue: action) {
                    do { try owner.downloads.coordinator.perform(action, in: latest.context) }
                    catch { result["actionError"] = String(describing: error) }
                } else if action == "open" || action == "reveal" {
                    owner.downloads.perform(action == "open" ? .open : .reveal, in: latest.context)
                }
            }
            result["downloads"] = owner.downloads.snapshots(profileID: profile).map { item in
                ["state": item.state.rawValue, "bytes": item.receivedBytes,
                 "total": item.totalBytes as Any? ?? NSNull(), "name": item.suggestedFilename,
                 "availability": item.fileAvailability.rawValue] as [String: Any]
            }
        }
        if step == "library" { owner.showDownloads() }
        if step == "tabs" { owner.hideLibrary() }
        result["openAccepted"] = openAccepted
        result["revealRequested"] = revealRequested
        return result
    }
}
