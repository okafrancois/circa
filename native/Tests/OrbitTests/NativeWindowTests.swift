import AppKit
import BrowserCore
import Foundation
import Network
import Testing
import WebKit
@testable import Orbit
import BrowserEngine
import WebKitEngine

final class LocalFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var requestCounts: [String: Int] = [:]
    private let queue = DispatchQueue(label: "Orbit.NativeWindowTests.HTTP")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        let queue = queue
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            self?.receive(connection, buffer: Data())
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let listener = listener
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    func matchingRequests(path: String) -> Int { lock.withLock { requestCounts[path, default: 0] } }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
            var buffer = buffer
            buffer.append(data ?? Data())
            guard buffer.count < 16384 else { connection.cancel(); return }
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !complete && error == nil { receive(connection, buffer: buffer) }
                else { connection.cancel() }
                return
            }
            let path = request.split(separator: " ").dropFirst().first ?? "/"
            lock.withLock { requestCounts[String(path), default: 0] += 1 }
            if path == "/drop" { connection.cancel(); return }
            let title = path == "/first" ? "First" : path == "/second" ? "Second" : "Other"
            let body = "<!doctype html><title>\(title)</title><h1>\(title)</h1><input id='draft'><a href='/second'>Next</a>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@MainActor
private final class WindowLifetimeProbe {
    weak var controller: PreviewWindowController?
    weak var webView: WKWebView?

    init(_ controller: PreviewWindowController, _ webView: WKWebView) {
        self.controller = controller
        self.webView = webView
    }
}

@MainActor
private func createAndRetireWindow(in environment: PreviewEnvironment) async throws -> WindowLifetimeProbe {
    let controller = try await environment.makeWindow()
    await controller.session.waitForPendingCommands()
    let view = try #require(controller.session.selectedSurface?.webView)
    let probe = WindowLifetimeProbe(controller, view)
    controller.window?.close()
    await controller.session.waitForPendingCommands()
    return probe
}

@MainActor
func captureSyntheticWindow(_ controller: PreviewWindowController) async throws {
    guard let directory = ProcessInfo.processInfo.environment["ORBIT_NATIVE_EVIDENCE_DIR"],
          let content = controller.window?.contentView else { return }
    if let mode = ProcessInfo.processInfo.environment["ORBIT_NATIVE_CAPTURE_APPEARANCE"],
       ["light", "dark"].contains(mode) {
        controller.window?.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
    }
    content.layoutSubtreeIfNeeded()
    guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
    content.cacheDisplay(in: content.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("native-window-offscreen.png"))
    if let webView = controller.session.selectedSurface?.webView {
        let page = try await webView.takeSnapshot(configuration: nil)
        if let tiff = page.tiffRepresentation,
           let pageBitmap = NSBitmapImageRep(data: tiff),
           let pagePNG = pageBitmap.representation(using: .png, properties: [:]) {
            try pagePNG.write(to: URL(fileURLWithPath: directory).appendingPathComponent("synthetic-page-webkit.png"))
        }
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeWindowTests {
    @Test("Real hidden AppKit windows keep documents and history independent within a shared profile")
    func independentWindowsAndHistory() async throws {
        // This test process never orders a window on screen or activates itself.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let first = try await environment.makeWindow()
        let second = try await environment.makeWindow()
        defer { first.window?.close(); second.window?.close() }
        await first.session.waitForPendingCommands()
        await second.session.waitForPendingCommands()
        let firstView = try #require(first.session.selectedSurface?.webView)
        let secondView = try #require(second.session.selectedSurface?.webView)
        #expect(firstView !== secondView)
        #expect(first.session.snapshot?.id != second.session.snapshot?.id)
        #expect(first.session.selectedSurface?.profileID == second.session.selectedSurface?.profileID)
        #expect(!first.window!.isVisible && !second.window!.isVisible)
        let secondURL = URL(string: "http://127.0.0.1:\(port)/second")!
        let otherURL = URL(string: "http://127.0.0.1:\(port)/other")!
        first.submitAddress("127.0.0.1:\(port)/first")
        second.submitAddress(otherURL.absoluteString)
        await first.session.waitForPendingCommands()
        await second.session.waitForPendingCommands()
        try await waitForNativeState("firstView.title == \"First\" && secondView.title == \"Other\"",
            observed: { nativeWebViewState(firstView) + "; " + nativeWebViewState(secondView) }
        ) { firstView.title == "First" && secondView.title == "Other" }
        try await captureSyntheticWindow(first)
        _ = try await firstView.evaluateJavaScript("document.getElementById('draft').value='Synthetic draft'; document.cookie='fixture=shared; path=/'; localStorage.setItem('fixture','shared');")
        first.submitAddress(secondURL.absoluteString)
        await first.session.waitForPendingCommands()
        try await waitForNativeState("firstView.title == \"Second\"",
            observed: { nativeWebViewState(firstView) }
        ) { firstView.title == "Second" }
        first.session.duplicateSelectedTab()
        await first.session.waitForPendingCommands()
        let duplicateView = try #require(first.session.selectedSurface?.webView)
        #expect(duplicateView !== firstView)
        try await waitForNativeState("duplicateView.title == \"Second\"",
            observed: { nativeWebViewState(duplicateView) }
        ) { duplicateView.title == "Second" }
        #expect(!duplicateView.canGoBack)
        first.closeSelectedTab()
        await first.session.waitForPendingCommands()
        #expect(duplicateView.navigationDelegate == nil)
        first.session.reopenClosedTab()
        await first.session.waitForPendingCommands()
        let reopenedView = try #require(first.session.selectedSurface?.webView)
        #expect(reopenedView !== duplicateView && reopenedView !== firstView)
        try await waitForNativeState("reopenedView.title == \"Second\"",
            observed: { nativeWebViewState(reopenedView) }
        ) { reopenedView.title == "Second" }
        #expect(!reopenedView.canGoBack)
        first.session.selectOccurrence(try #require(first.session.snapshot?.tabs.first?.occurrenceID))
        await first.session.waitForPendingCommands()
        #expect(firstView.canGoBack)
        #expect(!secondView.canGoBack)
        #expect(secondView.url == otherURL)
        #expect(try await secondView.evaluateJavaScript("document.cookie") as? String == "fixture=shared")
        #expect(try await secondView.evaluateJavaScript("localStorage.getItem('fixture')") as? String == "shared")
        first.navigateBack()
        await first.session.waitForPendingCommands()
        try await waitForNativeState("firstView.title == \"First\"",
            observed: { nativeWebViewState(firstView) + ", requests(first)=\(server.matchingRequests(path: "/first")), requests(second)=\(server.matchingRequests(path: "/second"))" }
        ) { firstView.title == "First" }
        #expect(try await firstView.evaluateJavaScript("document.getElementById('draft').value") as? String == "Synthetic draft")
        #expect(firstView.canGoForward)
        first.navigateForward()
        await first.session.waitForPendingCommands()
        try await waitForNativeState("firstView.title == \"Second\"",
            observed: { nativeWebViewState(firstView) }
        ) { firstView.title == "Second" }
        _ = try await firstView.evaluateJavaScript("document.title='Updated title'; history.pushState({}, '', '/dynamic');")
        try await waitForNativeState("dynamic address and tab title publication", observed: { "address=\(first.displayedAddress), titles=\(first.displayedTabTitles)" }) {
            first.displayedAddress.hasSuffix("/dynamic") && first.displayedTabTitles.contains("Updated title")
        }
        first.navigateBack()
        await first.session.waitForPendingCommands()
        try await waitForNativeState("firstView.url == secondURL",
            observed: { nativeWebViewState(firstView) }
        ) { firstView.url == secondURL }
        let isolatedEnvironment = PreviewEnvironment()
        let isolated = try await isolatedEnvironment.makeWindow()
        defer { isolated.window?.close() }
        await isolated.session.waitForPendingCommands()
        isolated.submitAddress(otherURL.absoluteString)
        await isolated.session.waitForPendingCommands()
        let isolatedView = try #require(isolated.session.selectedSurface?.webView)
        try await waitForNativeState("isolatedView.title == \"Other\"",
            observed: { nativeWebViewState(isolatedView) }
        ) { isolatedView.title == "Other" }
        #expect(try await isolatedView.evaluateJavaScript("document.cookie") as? String == "")
        #expect(try await isolatedView.evaluateJavaScript("localStorage.getItem('fixture')===null") as? Bool == true)
        _ = try await isolatedView.evaluateJavaScript("document.cookie='fixture=isolated; path=/'; localStorage.setItem('fixture','isolated');")
        #expect(try await secondView.evaluateJavaScript("document.cookie") as? String == "fixture=shared")
        #expect(try await secondView.evaluateJavaScript("localStorage.getItem('fixture')") as? String == "shared")
        let closedID = try #require(first.session.snapshot?.id)
        first.window?.close()
        await first.session.waitForPendingCommands()
        #expect(firstView.navigationDelegate == nil)
        await #expect(throws: BrowserStoreError.windowMissing) {
            try await environment.store.captureContext(in: closedID)
        }
        #expect(second.session.snapshot?.tabs.count == 1)
        #expect(secondView.url == otherURL)
        #expect(try await secondView.evaluateJavaScript("document.title") as? String == "Other")
        #expect(!second.window!.isVisible)
        second.window?.close()
        await second.session.waitForPendingCommands()
    }

    @Test("Closing a tab while editing its address displays the surviving tab's address")
    func addressEditingFollowsTabSelection() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try LocalFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        await controller.session.waitForPendingCommands()
        let firstURL = URL(string: "http://127.0.0.1:\(port)/first")!
        controller.submitAddress(firstURL.absoluteString)
        await controller.session.waitForPendingCommands()
        let firstView = try #require(controller.session.selectedSurface?.webView)
        try await waitForNativeState("firstView.title == \"First\"",
            observed: { nativeWebViewState(firstView) }
        ) { firstView.title == "First" }
        controller.openTab(url: URL(string: "http://127.0.0.1:\(port)/second")!)
        await controller.session.waitForPendingCommands()
        let secondView = try #require(controller.session.selectedSurface?.webView)
        try await waitForNativeState("secondView.title == \"Second\"",
            observed: { nativeWebViewState(secondView) }
        ) { secondView.title == "Second" }
        controller.focusAddress()
        await controller.session.waitForPendingCommands()
        let editor = try #require(controller.window?.firstResponder as? NSTextView)
        editor.string = "Uncommitted synthetic edit"
        #expect(controller.displayedAddress == "Uncommitted synthetic edit")
        controller.closeSelectedTab()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface?.webView === firstView)
        #expect(controller.displayedAddress == firstURL.absoluteString)
        controller.window?.makeFirstResponder(firstView)
        #expect(controller.displayedAddress == firstURL.absoluteString)
        controller.window?.close()
        await controller.session.waitForPendingCommands()
    }

    @Test("Repeated hidden window closure releases the controller and its real WebKit view")
    func retiredWindowReferencesAreReleased() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        var probes: [WindowLifetimeProbe] = []
        for _ in 0..<3 { probes.append(try await createAndRetireWindow(in: environment)) }
        try await waitForNativeState("probes.allSatisfy { $0.controller == nil && $0.webView == nil }",
            observed: { "controllers=\(probes.filter { $0.controller != nil }.count), views=\(probes.filter { $0.webView != nil }.count)" }
        ) { probes.allSatisfy { $0.controller == nil && $0.webView == nil } }
    }
}

}
