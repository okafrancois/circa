import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
import WebKit
@testable import Orbit
import WebKitEngine

private enum NativeTransferTestError: Error { case timedOut }

@MainActor
private func waitForTransfer(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw NativeTransferTestError.timedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// A Peek-like owner of WebKit surfaces held outside any tab strip.
@MainActor
private final class PanelOwner: BrowserEngineSurfaceDelegate {
    let container = BrowserSurfaceContainer<WebKitSurface>()
    var commits = 0

    func surfaceDidStartNavigation(_ surface: WebKitSurface) {}
    func surfaceDidCommitNavigation(_ surface: WebKitSurface) { commits += 1 }
    func surfaceDidFinishNavigation(_ surface: WebKitSurface) {}
    func surfaceDidFailNavigation(_ surface: WebKitSurface) {}
    func surface(_ surface: WebKitSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        decision.decide(container.owns(surface) ? .allow : .cancel)
    }
    func surface(_ surface: WebKitSurface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        decision.decide(container.owns(surface) ? .allow : .cancel)
    }
    func surface(_ surface: WebKitSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> WebKitSurface) -> WebKitSurface? { nil }
    func surfaceDidRequestClose(_ surface: WebKitSurface) { container.dispose(surface) }
    func surface(_ surface: WebKitSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeSurfaceTransferTests {
    @Test("A live WebKit tab moves to another window with its document, form state, placement and delegate")
    func moveTabBetweenWindows() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let source = try await environment.makeWindow()
        let destination = try await environment.makeWindow()
        defer { source.window?.close(); destination.window?.close() }
        source.submitAddress("http://127.0.0.1:\(port)/first")
        await source.session.waitForPendingCommands()
        let surface = try #require(source.session.selectedSurface)
        try await waitForTransfer { surface.webView.title == "First" && !surface.webView.isLoading }
        #expect(source.window?.firstResponder === surface.webView, "focus goes through focusDocument()")
        _ = try await surface.webView.evaluateJavaScript(
            "document.getElementById('draft').value = 'unsaved form state'; window.liveMarker = 42; void 0;")
        let generation = surface.documentGeneration

        let move = try #require(source.moveSurface(surface, to: destination))
        #expect(surface.delegate === destination)
        let occurrence = try #require(await move.value)
        await source.session.waitForPendingCommands()
        await destination.session.waitForPendingCommands()

        #expect(destination.session.selectedSurface === surface)
        #expect(destination.session.occurrenceID(for: surface) == occurrence)
        let destinationWindowID = try #require(destination.session.snapshot?.id)
        #expect(surface.placement == .tab(windowID: destinationWindowID, occurrenceID: occurrence))
        #expect(!source.session.ownedSurfaces.contains { $0 === surface })
        #expect(source.session.snapshot?.tabs.contains { $0.url.path == "/first" } == false)
        #expect(!surface.isDisposed)
        #expect(surface.documentGeneration == generation)
        #expect(surface.webView.window === destination.window)
        let state = try await surface.webView.evaluateJavaScript(
            "document.getElementById('draft').value + ':' + window.liveMarker") as? String
        #expect(state == "unsaved form state:42")

        // Later navigation policy is answered by the destination, which now holds the surface.
        surface.navigate(to: URL(string: "http://127.0.0.1:\(port)/second")!)
        try await waitForTransfer { surface.webView.title == "Second" && !surface.webView.isLoading }
        #expect(surface.navigationState.committedURL?.path == "/second")
        #expect(destination.session.selectedSurface === surface)
    }

    @Test("Feature hooks observe held surfaces and route new targets into a panel that can promote them")
    func hooksObserveAndRoute() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        var events: [BrowserSurfaceEvent] = []
        let observation = controller.engineEventHooks.observe { _, event in events.append(event) }
        controller.submitAddress("http://127.0.0.1:\(port)/first")
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.selectedSurface)
        try await waitForTransfer { source.webView.title == "First" && !source.webView.isLoading }
        #expect(events.contains(.navigationCommitted))
        #expect(events.contains(.navigationFinished))
        observation.cancel()
        events.removeAll()

        let panel = PanelOwner()
        var routed: WebKitSurface?
        controller.engineEventHooks.routeNewTargets { _, _, make in
            let child = make()
            guard panel.container.claim(child) else { return .handled(nil) }
            child.delegate = panel
            routed = child
            return .handled(child)
        }
        _ = try await source.webView.evaluateJavaScript("window.open('/second','route-fixture');void 0;")
        try await waitForTransfer { routed?.webView.title == "Second" && routed?.webView.isLoading == false }
        let child = try #require(routed)
        #expect(events.isEmpty, "a cancelled observation receives nothing")
        #expect(panel.commits >= 1)
        #expect(controller.session.ownedSurfaces.count == 1, "a routed target is not adopted as a tab")
        let generation = child.documentGeneration

        let transfer = try #require(panel.container.release(child, profileID: child.profileID))
        let promotion = controller.acceptSurface(transfer, activate: true)
        #expect(child.delegate === controller)
        let occurrence = try #require(await promotion.value)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface === child)
        #expect(controller.session.occurrenceID(for: child) == occurrence)
        #expect(child.documentGeneration == generation)
        #expect(child.webView.title == "Second")
        panel.container.close()
        #expect(!child.isDisposed, "a promoted surface no longer belongs to the panel")
    }
}

}
