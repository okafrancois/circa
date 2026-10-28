import AppKit
import BrowserCore
import BrowserShell
import Foundation
import Testing
import WebKit
@testable import Orbit
import BrowserEngine
import WebKitEngine

@MainActor
private func loadPageTools(_ controller: PreviewWindowController, port: UInt16, path: String = "/first") async throws -> PreviewSurface {
    controller.submitAddress("http://127.0.0.1:\(port)\(path)")
    await controller.session.waitForPendingCommands()
    let surface = try #require(controller.session.selectedSurface)
    try await waitForNativeState("surface.committedURL?.path == path && !surface.webView.isLoading",
        observed: { nativeWebViewState(surface.webView) + ", generation=\(surface.findDocumentGeneration)" }
    ) { surface.committedURL?.path == path && !surface.webView.isLoading }
    return surface
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativePageToolsTests {
    @Test("A same-surface commit reconciles rejected pending find options before the next search")
    func navigationReconcilesPendingCaseChoice() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        var inputs: [@MainActor (PreviewWindowController) -> Void] = []
        let controller = try await PreviewEnvironment().makeWindow(onInput: { inputs.append($0) })
        defer { controller.window?.close() }
        let surface = try await loadPageTools(controller, port: port)
        controller.showFind()
        await controller.session.waitForPendingCommands()
        controller.findSession.submit("First")
        try await waitForNativeState("controller.findSession.state?.isFinal == true",
            observed: { nativeFindState(controller) }
        ) { controller.findSession.state?.isFinal == true }
        controller.findBar.caseControl.performClick(nil)
        #expect(controller.findBar.pendingOptionsRevision != nil)
        let generation = surface.findDocumentGeneration
        surface.navigate(to: URL(string: "http://127.0.0.1:\(port)/second")!)
        try await waitForNativeState("surface.findDocumentGeneration > generation && !surface.webView.isLoading",
            observed: { nativeWebViewState(surface.webView) + ", generation=\(surface.findDocumentGeneration)" }
        ) { surface.findDocumentGeneration > generation && !surface.webView.isLoading }
        for input in inputs { input(controller) }
        await controller.session.waitForPendingCommands()
        #expect(controller.findBar.pendingOptionsRevision == nil)
        #expect(controller.findBar.caseControl.state == .off)
        #expect(controller.findSession.state?.matchCase == false)
        controller.findNext()
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("controller.findSession.state?.isFinal == true",
            observed: { nativeFindState(controller) }
        ) { controller.findSession.state?.isFinal == true }
        #expect(controller.findSession.state?.query == "First")
        #expect(controller.findSession.state?.matchCase == false)
        #expect(controller.findSession.state?.matchFound == false)
    }

    @Test("Pending case toggles survive cached publications and older option acknowledgements")
    func pendingCaseChoiceSurvivesPublication() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var inputs: [@MainActor (PreviewWindowController) -> Void] = []
        let controller = try await PreviewEnvironment().makeWindow(onInput: { inputs.append($0) })
        defer { controller.window?.close() }
        controller.showFind()
        await controller.session.waitForPendingCommands()
        controller.findBar.caseControl.performClick(nil)
        #expect(controller.findBar.caseControl.state == .on)
        controller.session.renameSpace(try #require(controller.session.snapshot?.activeSpaceID), name: "Synthetic pending case")
        await controller.session.waitForPendingCommands()
        #expect(controller.findBar.caseControl.state == .on)
        controller.findBar.searchField.stringValue = "Synthetic query"
        controller.findBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                           object: controller.findBar.searchField))
        controller.findBar.caseControl.performClick(nil)
        for input in inputs { input(controller) }
        await controller.session.waitForPendingCommands()
        #expect(controller.findSession.state?.matchCase == false)
        #expect(controller.findBar.caseControl.state == .off)
        #expect(controller.findBar.pendingOptionsRevision == nil)
    }

    @Test("Unchanged-document publications preserve an in-progress find-field draft")
    func publicationPreservesFindDraft() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        controller.showFind()
        await controller.session.waitForPendingCommands()
        let editor = try #require(controller.findBar.searchField.currentEditor() as? NSTextView)
        editor.string = "Synthetic in-progress find draft"
        controller.session.renameSpace(try #require(controller.session.snapshot?.activeSpaceID), name: "Synthetic renamed Space")
        await controller.session.waitForPendingCommands()
        #expect(controller.findBar.searchField.currentEditor()?.string == "Synthetic in-progress find draft")
        #expect(controller.findSession.state?.query == "")
    }

    @Test("Public WebKit reports a real match without fabricating a count and rejects count-only requests")
    func webKitFindCapabilities() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let surface = try await loadPageTools(controller, port: port)
        controller.showFind()
        await controller.session.waitForPendingCommands()
        controller.submitFind("first")
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("controller.findSession.state?.isFinal == true",
            observed: { nativeFindState(controller) }
        ) { controller.findSession.state?.isFinal == true }
        #expect(controller.findSession.state?.matchFound == true)
        #expect(controller.findSession.state?.count == nil)
        #expect(controller.findSession.state?.activeOrdinal == nil)
        #expect(controller.findSession.state?.hasExactCount == false)
        controller.findBar.searchField.stringValue = "first"
        try await captureSyntheticWindow(controller)
        controller.findNext()
        controller.findPrevious()
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("controller.findSession.state?.isFinal == true",
            observed: { nativeFindState(controller) }
        ) { controller.findSession.state?.isFinal == true }
        #expect(controller.findSession.state?.matchFound == true)
        controller.submitFind("first", matchCase: true)
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("controller.findSession.state?.isFinal == true",
            observed: { nativeFindState(controller) }
        ) { controller.findSession.state?.isFinal == true }
        #expect(controller.findSession.state?.matchFound == false)
        controller.findSession.submit("First", selectMatch: false)
        #expect(controller.findSession.state?.error == .unsupportedOperation)
        #expect(controller.findSession.state?.matchFound == nil)
        #expect(surface.findDocumentGeneration > 0)
        #expect(!controller.window!.isVisible)
    }

    @Test("Find queries remain per-document across Spaces and stale widget input cannot reach another profile")
    func findOwnershipAcrossSpaces() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let spaceA = try #require(controller.session.snapshot?.activeSpaceID)
        let a = try await loadPageTools(controller, port: port)
        controller.showFind()
        await controller.session.waitForPendingCommands()
        controller.submitFind("First")
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("controller.findSession.state?.isFinal == true",
            observed: { nativeFindState(controller) }
        ) { controller.findSession.state?.isFinal == true }
        let profileB = await environment.store.createProfile(name: "Synthetic find profile")
        let spaceB = try await environment.store.createSpace(name: "Synthetic find Space", profileID: profileB)
        controller.activateSpace(spaceB)
        controller.submitFind("This draft belongs to A")
        await controller.session.waitForPendingCommands()
        let b = try await loadPageTools(controller, port: port, path: "/second")
        #expect(controller.findSession.state?.query == "")
        #expect(controller.findBar.isHidden)
        controller.showFind()
        await controller.session.waitForPendingCommands()
        controller.submitFind("Second")
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("controller.findSession.state?.isFinal == true",
            observed: { nativeFindState(controller) }
        ) { controller.findSession.state?.isFinal == true }
        controller.activateSpace(spaceA)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface === a)
        #expect(controller.findSession.state?.query == "First")
        #expect(controller.findSession.state?.matchFound == true)
        #expect(controller.findSession.state(for: b)?.query == "Second")
        controller.closeSelectedTab()
        await controller.session.waitForPendingCommands()
        #expect(controller.findSession.state(for: a) == nil)
        #expect(controller.findBar.isHidden)
        #expect(controller.findSession.state(for: b)?.query == "Second")
    }

    @Test("A committed document invalidates old find results and the native bar returns focus on Escape")
    func navigationAndFindFocus() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let surface = try await loadPageTools(controller, port: port)
        controller.focusAddress()
        controller.showFind()
        await controller.session.waitForPendingCommands()
        #expect(controller.window?.firstResponder === controller.findBar.searchField.currentEditor())
        controller.submitFind("First")
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("controller.findSession.state?.isFinal == true",
            observed: { nativeFindState(controller) }
        ) { controller.findSession.state?.isFinal == true }
        let editor = try #require(controller.findBar.searchField.currentEditor() as? NSTextView)
        #expect(controller.findBar.control(controller.findBar.searchField, textView: editor,
                                          doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        await controller.session.waitForPendingCommands()
        #expect(controller.findBar.isHidden)
        #expect(controller.window?.firstResponder === controller.addressControl.currentEditor())
        controller.showFind()
        await controller.session.waitForPendingCommands()
        controller.submitFind("First")
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("controller.findSession.state?.isFinal == true",
            observed: { nativeFindState(controller) }
        ) { controller.findSession.state?.isFinal == true }
        let oldGeneration = surface.findDocumentGeneration
        controller.submitAddress("http://127.0.0.1:\(port)/second")
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("surface.findDocumentGeneration > oldGeneration",
            observed: { nativeWebViewState(surface.webView) + ", generation=\(surface.findDocumentGeneration)" }
        ) { surface.findDocumentGeneration > oldGeneration }
        #expect(controller.findSession.state?.matchFound == nil)
        #expect(controller.findSession.state?.query == "First")
        #expect(!controller.window!.isVisible)
    }

    @Test("Page zoom changes layout without losing documents and shares only within the same profile and host")
    func realPageZoomAndProfileScope() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let first = try await environment.makeWindow()
        let second = try await environment.makeWindow()
        defer { first.window?.close(); second.window?.close() }
        let a = try await loadPageTools(first, port: port)
        let spaceA = try #require(first.session.snapshot?.activeSpaceID)
        let shared = try await loadPageTools(second, port: port, path: "/second")
        first.window?.contentView?.layoutSubtreeIfNeeded()
        let widthBefore = try #require(try await a.webView.evaluateJavaScript("window.innerWidth") as? Double)
        let addressWidth = first.addressControl.frame.width
        _ = try await a.webView.evaluateJavaScript("window.syntheticDocument='zoom-document'; document.getElementById('draft').value='Synthetic retained zoom draft';")
        first.changePageZoom(.increase)
        await first.session.waitForPendingCommands()
        #expect(abs(a.webView.pageZoom - 1.1) < 0.000_001)
        #expect(abs(shared.webView.pageZoom - 1.1) < 0.000_001)
        var observedWidth = widthBefore
        try await waitForNativeState("zoom reduces page viewport width", observed: { "before=\(widthBefore), current=\(observedWidth), zoom=\(a.webView.pageZoom)" }) {
            observedWidth = try await a.webView.evaluateJavaScript("window.innerWidth") as? Double ?? widthBefore
            return observedWidth < widthBefore
        }
        #expect(first.addressControl.frame.width <= addressWidth)
        #expect(try await a.webView.evaluateJavaScript("window.syntheticDocument") as? String == "zoom-document")
        #expect(try await a.webView.evaluateJavaScript("document.getElementById('draft').value") as? String == "Synthetic retained zoom draft")
        let laterWindow = try await environment.makeWindow()
        defer { laterWindow.window?.close() }
        let laterSurface = try await loadPageTools(laterWindow, port: port)
        #expect(laterSurface.webView.pageZoom == 1.1)
        laterWindow.submitAddress("http://localhost:\(port)/first")
        await laterWindow.session.waitForPendingCommands()
        try await waitForNativeState("laterSurface.committedURL?.host == \"localhost\" && !laterSurface.webView.isLoading",
            observed: { nativeWebViewState(laterSurface.webView) }
        ) { laterSurface.committedURL?.host == "localhost" && !laterSurface.webView.isLoading }
        #expect(laterSurface.webView.pageZoom == 1)
        _ = try await loadPageTools(laterWindow, port: port)
        #expect(laterSurface.webView.pageZoom == 1.1)
        let profileB = await environment.store.createProfile(name: "Synthetic zoom profile")
        let spaceB = try await environment.store.createSpace(name: "Synthetic zoom Space", profileID: profileB)
        second.activateSpace(spaceB)
        await second.session.waitForPendingCommands()
        let isolated = try await loadPageTools(second, port: port)
        #expect(isolated.webView.pageZoom == 1)
        #expect(shared.webView.pageZoom == 1.1)
        second.changePageZoom(.decrease)
        await second.session.waitForPendingCommands()
        #expect(isolated.webView.pageZoom == 0.9)
        #expect(a.webView.pageZoom == 1.1)
        second.activateSpace(spaceA)
        await second.session.waitForPendingCommands()
        #expect(!second.zoomControl.isHidden)
        second.activateSpace(spaceB)
        second.zoomControl.performClick(nil)
        await second.session.waitForPendingCommands()
        #expect(second.session.selectedSurface === isolated)
        #expect(isolated.webView.pageZoom == 0.9)
        #expect(a.webView.pageZoom == 1.1 && shared.webView.pageZoom == 1.1)
        first.changePageZoom(.reset)
        await first.session.waitForPendingCommands()
        #expect(a.webView.pageZoom == 1 && shared.webView.pageZoom == 1)
        #expect(isolated.webView.pageZoom == 0.9)
        #expect(!first.window!.isVisible && !second.window!.isVisible)
    }
}

}
