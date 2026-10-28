import AppKit
import BrowserCore
import BrowserEngine
import ChromiumLifecycleStub
import OrbitChromiumBridge

@MainActor
private final class NavigationDelegate: BrowserEngineSurfaceDelegate {
    var actions: [BrowserNavigationAction] = []
    var requests: [BrowserNewSurfaceRequest] = []
    func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidRequestClose(_ surface: ChromiumSurface) {}
    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        actions.append(action)
        decision.decide(.allow)
    }
    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? {
        requests.append(request)
        return make()
    }
    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
}

@main
@MainActor
struct NavigationMetadataTests {
    static func main() {
        var engine: ChromiumBrowserEngine?
        let result = ChromiumRuntime.shared.run(options: .init(rootCachePath: "/private/tmp/orbit-unused-navigation-stub",
            keychainServiceName: "unused-stub", keychainAccountName: "unused-stub", hiddenApplication: true)) {
            engine = ChromiumBrowserEngine(persistence: .ephemeral)
        }
        precondition(result == 0)
        let delegate = NavigationDelegate()
        let source = engine!.makeSurface(profileID: ProfileID(), delegate: delegate)
        let target = "https://navigation.test/target"
        for (transition, method, body, gesture, kind) in [
            (UInt32(7), "POST", true, true, BrowserNavigationKind.formSubmission),
            (UInt32(7), "GET", false, false, .formSubmission),
            (UInt32(0), "GET", false, false, .other),
            (UInt32(0), "GET", false, true, .linkActivation)
        ] {
            method.withCString { ACRStubPopupMetadata(1, transition, $0, body ? 1 : 0) }
            let child = source.decideNewSurface(url: target, disposition: 3, userGesture: gesture, keepsOpener: true)!
            let request = delegate.requests.last!
            precondition(request.kind == kind && request.httpMethod == method && request.hasBody == body)
            precondition(request.isUserGesture == gesture && child.profileID == source.profileID)
            ACRStubAbortCreation(child.token)
        }
        // An older engine and the fresh-request path must keep unknown metadata unknown.
        ACRStubPopupMetadata(0, 7, "POST", 1)
        let unknown = source.decideNewSurface(url: target, disposition: 3, userGesture: false, keepsOpener: true)!
        precondition(delegate.requests.last!.httpMethod == nil && delegate.requests.last!.hasBody == nil)
        ACRStubAbortCreation(unknown.token)
        ACRStubPopupMetadata(1, 7, "POST", 1)
        let fresh = source.decideNewSurface(url: target, disposition: 3, userGesture: false, keepsOpener: false)!
        precondition(delegate.requests.last!.kind == .other && delegate.requests.last!.httpMethod == nil)
        ACRStubAbortCreation(fresh.token)
        for (transition, expected) in [(UInt32(0x0100_0001), BrowserNavigationKind.backForward), (8, .reload)] {
            _ = source.decideNavigation(.init(url: target, isMainFrame: true, userGesture: false,
                isRedirect: false, transitionType: transition, method: "GET", hasBody: false))
            precondition(delegate.actions.last!.kind == expected && delegate.actions.last!.httpMethod == "GET")
        }
        _ = source.decideNavigation(.init(url: target, isMainFrame: true, userGesture: false,
            isRedirect: false, transitionType: 7, method: "POST", hasBody: true))
        precondition(delegate.actions.last!.kind == .formSubmission && delegate.actions.last!.hasBody == true)
        source.dispose()
        print("PASS: original popup POST/GET/form metadata, gesture independence, unknown fallback, history/reload actions")
    }
}
