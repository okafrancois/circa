import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
// The synthetic engine now lives in BrowserEngineConformance so that Orbit tests can drive the
// window controller with it; this re-export keeps every test file of this target unchanged.
@_exported import BrowserEngineConformance

/// Records delegate traffic for assertions.
@MainActor
final class RecordingSurfaceDelegate: BrowserEngineSurfaceDelegate {
    var events: [String] = []
    var acceptsNewTargets = true
    var answersPolicy = true
    var adopted: [SyntheticSurface] = []
    var onEvent: ((String, SyntheticSurface) -> Void)?

    private func record(_ event: String, _ surface: SyntheticSurface) {
        events.append(event)
        onEvent?(event, surface)
    }

    func surfaceDidStartNavigation(_ surface: SyntheticSurface) { record("start", surface) }
    func surfaceDidCommitNavigation(_ surface: SyntheticSurface) { record("commit", surface) }
    func surfaceDidFinishNavigation(_ surface: SyntheticSurface) { record("finish", surface) }
    func surfaceDidFailNavigation(_ surface: SyntheticSurface) { record("fail", surface) }

    func surface(_ surface: SyntheticSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        if answersPolicy { decision.decide(.allow) }
    }

    func surface(_ surface: SyntheticSurface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        decision.decide(.allow)
    }

    func surface(_ surface: SyntheticSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> SyntheticSurface) -> SyntheticSurface? {
        events.append("new-target")
        guard acceptsNewTargets else { return nil }
        let child = make()
        adopted.append(child)
        return child
    }

    func surfaceDidRequestClose(_ surface: SyntheticSurface) { record("close-request", surface) }

    func surface(_ surface: SyntheticSurface, didStartDownload download: any BrowserEngineDownload) {
        download.cancel()
    }
}
