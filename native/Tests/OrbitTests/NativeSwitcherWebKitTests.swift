import AppKit
import BrowserEngine
import Testing
import WebKit
import WebKitEngine
@testable import Orbit

private enum SwitcherWebKitTestError: Error { case timedOut }

@MainActor
private func waitForSwitcherWebKit(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw SwitcherWebKitTestError.timedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
}

extension NativeWebKitTests {
    @Suite(.serialized)
    @MainActor
    struct NativeSwitcherWebKitTests {
        @Test("An outgoing real WebKit page is captured while attached and its detached thumbnail stays valid")
        func outgoingAndDetachedSnapshot() async throws {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let environment = PreviewEnvironment()
            let controller = try await environment.makeWindow()
            defer { controller.window?.close() }
            let surface = try #require(controller.session.selectedSurface)
            let original = try #require(controller.session.snapshot?.selectedOccurrenceID)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            surface.webView.loadHTMLString("""
                <!doctype html><title>Synthetic switcher stripes</title>
                <style>html,body{margin:0;height:100%;background:#c33}div{width:50%;height:100vh;background:#36c}</style>
                <div></div>
                """, baseURL: nil)
            try await waitForSwitcherWebKit { !surface.webView.isLoading && surface.webView.title == "Synthetic switcher stripes" }
            await controller.session.waitForPendingCommands()
            #expect(surface.hostView.window === controller.window)
            #expect(surface.hostView.bounds.width > 0)
            // The selected document changes through the production session/presentation seam.
            controller.session.openTab(url: URL(string: "about:blank")!)
            await controller.session.waitForPendingCommands()
            #expect(controller.session.snapshot?.selectedOccurrenceID != original)
            try await waitForSwitcherWebKit {
                surface.hostView.window == nil && controller.tabSwitcher.snapshots.image(for: surface) != nil
            }
            #expect(controller.window?.isVisible == false)
            let cached = try #require(controller.tabSwitcher.snapshots.image(for: surface))
            var rect = NSRect(origin: .zero, size: cached.size)
            let pixels = try #require(cached.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            #expect(!BrowserSwitcherSnapshots<WebKitSurface>.isBlank(pixels))
            // A cold cache must use the favicon/title fallback for this real detached WKWebView.
            let cold = BrowserSwitcherSnapshots<WebKitSurface>()
            #expect(cold.request(surface, force: true) == nil)
            #expect(cold.image(for: surface) == nil)
            let generation = surface.documentGeneration
            _ = try await surface.webView.evaluateJavaScript("document.body.style.background = '#080'; void 0;")
            #expect(surface.documentGeneration == generation, "SPA mutations do not advance the document generation")
            controller.tabSwitcher.snapshots.invalidate(surface)
            #expect(controller.tabSwitcher.snapshots.request(surface, force: true) == nil)
            #expect(controller.tabSwitcher.snapshots.image(for: surface) == nil)
        }
    }
}
