import AppKit
import BrowserCore
import BrowserShell
import Testing
import WebKit
@testable import Orbit
import BrowserEngine
import BrowserEngineConformance
import WebKitEngine

@MainActor
private final class NavigationProbe: NSObject, WKNavigationDelegate {}

extension NativeWebKitTests {
@Test("The real WebKit surface is detached and its delegate revoked on tab closure")
@MainActor
func webKitSurfaceClosure() async throws {
    let store = WKWebsiteDataStore.nonPersistent()
    let probe = NavigationProbe()
    var surfaces: [PreviewSurface] = []
    var errors: [any Error] = []
    let session = BrowserWindowSession { profileID, _ in
        let surface = PreviewSurface(profileID: profileID, dataStore: store)
        surface.webView.navigationDelegate = probe
        surfaces.append(surface)
        return surface
    }
    session.onError = { errors.append($0) }
    session.openTab()
    session.openTab()
    await session.waitForPendingCommands()
    let selected = try #require(session.selectedSurface)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    host.addSubview(selected.webView)
    #expect(selected.webView.superview === host)
    #expect(selected.webView.navigationDelegate === probe)
    #expect(!selected.webView.configuration.websiteDataStore.isPersistent)
    #expect(selected.profileID == surfaces[0].profileID)
    session.closeSelectedTab()
    await session.waitForPendingCommands()
    #expect(selected.webView.superview == nil)
    #expect(selected.webView.navigationDelegate == nil)
    #expect(session.selectedSurface === surfaces[0])
    #expect(surfaces[0].webView.navigationDelegate === probe)
    session.close()
    await session.waitForPendingCommands()
    #expect(surfaces[0].webView.navigationDelegate == nil)
    #expect(errors.isEmpty)
}
}

extension NativeWebKitTests {
@Test("The WebKit adapter passes the shared engine conformance checks")
@MainActor
func webKitEngineConformance() async {
    let failures = await BrowserEngineConformance.check(WebKitBrowserEngine())
    #expect(failures.isEmpty, "\(failures)")
}
}

@MainActor
private final class InertWebKitDelegate: BrowserEngineSurfaceDelegate {
    func surfaceDidStartNavigation(_ surface: WebKitSurface) {}
    func surfaceDidCommitNavigation(_ surface: WebKitSurface) {}
    func surfaceDidFinishNavigation(_ surface: WebKitSurface) {}
    func surfaceDidFailNavigation(_ surface: WebKitSurface) {}
    func surface(_ surface: WebKitSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.cancel) }
    func surface(_ surface: WebKitSurface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) { decision.decide(.cancel) }
    func surface(_ surface: WebKitSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> WebKitSurface) -> WebKitSurface? { nil }
    func surfaceDidRequestClose(_ surface: WebKitSurface) {}
    func surface(_ surface: WebKitSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
}

extension NativeWebKitTests {
@Test("WebKit surfaces of one profile share a store and distinct profiles never do")
@MainActor
func webKitProfileIsolation() {
    let engine = WebKitBrowserEngine()
    let delegate = InertWebKitDelegate()
    let first = ProfileID()
    let second = ProfileID()
    let a = engine.makeSurface(profileID: first, delegate: delegate)
    let b = engine.makeSurface(profileID: first, delegate: delegate)
    let c = engine.makeSurface(profileID: second, delegate: delegate)
    defer { for surface in [a, b, c] { surface.dispose() } }
    #expect(a.webView.configuration.websiteDataStore === b.webView.configuration.websiteDataStore)
    #expect(a.webView.configuration.websiteDataStore !== c.webView.configuration.websiteDataStore)
    #expect(!a.webView.configuration.websiteDataStore.isPersistent)
    #expect(engine.profile(for: first).persistence == .ephemeral)
    #expect(a.webView.navigationDelegate != nil && a.webView.uiDelegate != nil)
}
}
