import AppKit
import BrowserCore
import BrowserEngine
import ChromiumEngine

/// Invoked only through the explicitly enabled, synthetic-root performance endpoint.
@MainActor
enum OrbitDownloadAudioProbe {
    private static var openAccepted = false
    private static var revealRequested = false
    static func run(_ owner: OrbitWindowController, command: [String: String], root: URL) async -> [String: Any] {
        var result: [String: Any] = [:]
        let step = command["step"] ?? "status"
        if step == "load", let url = command["url"].flatMap(URL.init(string:)) {
            owner.downloads.destinationProvider = { _, filename in root.appendingPathComponent(filename) }
            owner.downloads.openFile = { openAccepted = NSWorkspace.shared.open($0) }
            owner.downloads.revealFile = { NSWorkspace.shared.activateFileViewerSelecting([$0]); revealRequested = true }
            owner.session.openTab(url: url)
            await owner.session.waitForQueuedCommands()
        }
        if let surface = owner.session.selectedSurface {
            if step == "evaluate", let expression = command["expression"] {
                result["evaluation"] = await OrbitPerformanceProbe.evaluate(surface, expression) ?? [:]
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
