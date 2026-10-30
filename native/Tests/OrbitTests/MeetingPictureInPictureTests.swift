import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@MainActor
private final class MeetingSiteHost: BrowserSiteControlsHost, BrowserEngineSurfaceDelegate {
    let engine = SiteSyntheticEngine()
    let window: NSWindow? = nil
    let engineEventHooks = BrowserSurfaceEventHooks<SiteSyntheticSurface>()
    var siteControlSurface: SiteSyntheticSurface?
    var siteControlSurfaces: [SiteSyntheticSurface] = []
    var siteControlsClosed = false
    var allowsAutomaticPictureInPicture = true
    var isPreparingForTermination = false
    var acceptsCommands = true
    func owns(_ surface: SiteSyntheticSurface) -> Bool { siteControlSurfaces.contains { $0 === surface } }
    func isSitePermissionTarget(_ surface: SiteSyntheticSurface) -> Bool { owns(surface) }
    func surface(_ surface: SiteSyntheticSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> SiteSyntheticSurface) -> SiteSyntheticSurface? { nil }
    func surface(_ surface: SiteSyntheticSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
    func surfaceDidStartNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidCommitNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidFinishNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidFailNavigation(_ surface: SiteSyntheticSurface) {}
    func surfaceDidRequestClose(_ surface: SiteSyntheticSurface) {}
    func surface(_ surface: SiteSyntheticSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func installSiteControlsButton(_ button: NSView) {}
    func presentSiteControls(_ panel: BrowserSitePopover, rows: [NSView], button: NSView) {}
    func openExtensionStore(from surface: SiteSyntheticSurface) {}
}

extension NativeWebKitTests {
@MainActor
struct MeetingPictureInPictureTests {
    @Test("Meeting links leave Little as regular GET tabs; forms and subframes retain their request")
    func littleNavigation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.invalid/")!)
        defer { environment.retireQuickWindows() }
        let surface = try #require(little.surface)
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        var routes: [URL] = []
        little.onMeetingLink = { routes.append($0) }
        var action = BrowserNavigationAction(url: url, isMainFrame: true, kind: .linkActivation,
                                             httpMethod: "GET", hasBody: false, isUserGesture: true)
        func decide() -> BrowserNavigationActionPolicy {
            var policy = BrowserNavigationActionPolicy.allow
            let decision = BrowserPolicyDecision<BrowserNavigationActionPolicy>(canSuspend: false, fallback: .cancel) { policy = $0 }
            little.surface(surface, decidePolicyFor: action, decision: decision)
            decision.endSynchronousTurn()
            return policy
        }
        #expect(decide() == .cancel)
        #expect(routes == [url])
        action.httpMethod = "POST"; action.hasBody = true
        #expect(decide() == .allow)
        action.httpMethod = "GET"; action.hasBody = false; action.isMainFrame = false
        #expect(decide() == .allow)
        #expect(routes == [url])
    }

    @Test("Leaving a meeting requests PiP only when the site and global preferences allow it",
          arguments: [true, false], [true, false])
    func eligibility(site: Bool, global: Bool) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = MeetingSiteHost()
        let profile = ProfileID()
        let meeting = host.engine.makeSurface(profileID: profile)
        meeting.delegate = host
        meeting.navigate(to: URL(string: "https://meet.google.com/abc-defg-hij")!)
        let other = host.engine.makeSurface(profileID: profile)
        host.siteControlSurfaces = [meeting, other]
        host.siteControlSurface = meeting
        host.allowsAutomaticPictureInPicture = global
        let controls = BrowserSiteControls(owner: host)
        var settings = BrowserSitePreferences()
        settings.automaticPictureInPicture = site
        try controls.preferences.set(settings, url: meeting.currentURL, profileID: profile)
        controls.render()
        #expect(meeting.automaticPiPUpdates.last?.selected == true)
        host.siteControlSurface = other
        controls.render()
        #expect(meeting.automaticPiPUpdates.last?.selected == false)
        #expect(meeting.automaticPiPUpdates.last?.allowed == (site && global))
        // A preference change also reconciles the already-backgrounded meeting.
        host.allowsAutomaticPictureInPicture = false
        controls.render()
        #expect(meeting.automaticPiPUpdates.last?.allowed == false)
    }
}
}
