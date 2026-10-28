import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Network
import Testing
import WebKit
@testable import Orbit
import WebKitEngine

private enum PeekWebKitTestError: Error { case timedOut }

@MainActor
private func waitForWebKit(_ predicate: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while try await !predicate() {
        guard ContinuousClock.now < deadline else { throw PeekWebKitTestError.timedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Serves synthetic pages on 127.0.0.1; links point to `localhost`, another site on the same port.
/// Records every request's method and path.
private final class PeekFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Orbit.NativePeekWebKitTests.HTTP")
    private let lock = NSLock()
    private var log: [(method: String, path: String)] = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: queue)
            receive(connection, buffer: Data())
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

    func requests(_ method: String, _ path: String) -> Int {
        lock.withLock { log.filter { $0.method == method && $0.path == path }.count }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            buffer.append(data ?? Data())
            guard let text = String(data: buffer, encoding: .utf8), let headerEnd = text.range(of: "\r\n\r\n") else {
                if !complete && error == nil && buffer.count < 65536 { receive(connection, buffer: buffer) } else { connection.cancel() }
                return
            }
            let head = text[..<headerEnd.lowerBound]
            let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            if text[headerEnd.upperBound...].utf8.count < length, !complete {
                receive(connection, buffer: buffer)
                return
            }
            let requestLine = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
            let method = requestLine.first.map(String.init) ?? "GET"
            let target = requestLine.dropFirst().first.map(String.init) ?? "/"
            let path = String(target.split(separator: "?").first ?? "/")
            lock.withLock { log.append((method, path)) }
            let body = Self.page(for: path)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func page(for path: String) -> String {
        switch path {
        case "/source":
            // Links to the other site get their port from this page's address.
            return """
            <!doctype html><title>Source</title>
            <style>body{margin:0} a{display:block;height:100px}</style>
            <a id="plain" data-cross="/second">Plain</a>
            <a id="blank" data-cross="/second" target="_blank" rel="opener">Blank</a>
            <a id="auth" data-cross="/oauth/authorize?client_id=1&redirect_uri=x">Auth</a>
            <form id="form" method="post" data-cross-action="/posted"><input name="payload" value="synthetic"><button id="submit">Send</button></form>
            <script>
            for (const a of document.querySelectorAll('[data-cross]')) a.href = 'http://localhost:' + location.port + a.dataset.cross;
            const f = document.getElementById('form'); f.action = 'http://localhost:' + location.port + f.dataset.crossAction;
            </script>
            """
        case "/second": return "<!doctype html><title>Second</title><input id='draft'>"
        case "/posted": return "<!doctype html><title>Posted</title>"
        default: return "<!doctype html><title>Other</title>"
        }
    }
}

/// Real WebKit, hidden windows. The page is served from `127.0.0.1`; its links go to `localhost`.
/// Real WebKit: `127.0.0.1` and `localhost` are two sites served by the same fixture.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativePeekWebKitTests {
    private func openSource(_ port: UInt16, pinned: Bool) async throws -> (PreviewEnvironment, PreviewWindowController, PreviewSurface) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        if pinned { controller.peek.sourceClassifier = { _ in (.pinned, nil) } }
        controller.submitAddress("http://127.0.0.1:\(port)/source")
        await controller.session.waitForPendingCommands()
        let tab = try #require(controller.session.selectedSurface)
        try await waitForWebKit { tab.webView.title == "Source" && !tab.webView.isLoading }
        return (environment, controller, tab)
    }

    /// A click delivered to the link as AppKit mouse events, through WebKit's own event path.
    private func click(_ webView: WKWebView, at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard let window = webView.window else { return }
        let location = webView.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            if type == .leftMouseDown { webView.mouseDown(with: event) } else { webView.mouseUp(with: event) }
        }
    }

    @Test("A pinned tab's target=_blank link to another site opens a live WebKit Peek that becomes a tab with form, script and opener intact")
    func routedPeekPromotesWithoutReload() async throws {
        let server = try PeekFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let (_, controller, tab) = try await openSource(port, pinned: true)
        defer { controller.window?.close() }
        _ = try await tab.webView.evaluateJavaScript("window.open('http://localhost:\(port)/scripted'); void 0;")
        try await waitForWebKit { controller.session.ownedSurfaces.count == 2 && controller.session.selectedSurface !== tab }
        await controller.session.waitForPendingCommands()
        #expect(!controller.isPeekPresented, "a scripted popup becomes a tab, never a Peek")
        controller.session.selectOccurrence(try #require(controller.session.occurrenceID(for: tab)))
        await controller.session.waitForPendingCommands()

        _ = try await tab.webView.evaluateJavaScript("document.getElementById('blank').click(); void 0;")
        try await waitForWebKit { controller.presentedPeekSurface?.webView.title == "Second" }
        let peeked = try #require(controller.presentedPeekSurface)
        try await waitForWebKit { !peeked.webView.isLoading }
        #expect(controller.session.ownedSurfaces.count == 2, "the routed target is not a tab")
        #expect(peeked.webView.isDescendant(of: controller.peekOverlay))
        #expect(peeked.placement.container == .peek)
        #expect(controller.window?.firstResponder === peeked.webView, "focusDocument() moved focus into the Peek")
        _ = try await peeked.webView.evaluateJavaScript(
            "document.getElementById('draft').value = 'typed in Peek'; window.liveMarker = 7; void 0;")
        let generation = peeked.documentGeneration

        let adoption = try #require(controller.promotePeekToTab())
        #expect(peeked.delegate === controller)
        let occurrence = try #require(await adoption.value)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface === peeked)
        #expect(controller.session.occurrenceID(for: peeked) == occurrence)
        #expect(peeked.webView.isDescendant(of: controller.contentCard))
        #expect(peeked.documentGeneration == generation, "no new document committed")
        let state = try await peeked.webView.evaluateJavaScript(
            "document.getElementById('draft').value + ':' + window.liveMarker + ':' + (window.opener !== null)") as? String
        #expect(state == "typed in Peek:7:true", "form, script state and opener survive")
        #expect(server.requests("GET", "/second") == 1)
        #expect(controller.peek.container.surfaces.isEmpty)
        #expect(!peeked.isDisposed)
    }

    @Test("A real ⇧-click on a plain link, delivered as AppKit events, opens the Peek once")
    func shiftClickWithAppKitEvents() async throws {
        let server = try PeekFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let (_, controller, tab) = try await openSource(port, pinned: false)
        defer { controller.window?.close() }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        // The "plain" link is the first 100-point block of the page.
        let bounds = tab.webView.bounds
        click(tab.webView, at: NSPoint(x: bounds.midX, y: tab.webView.isFlipped ? 50 : bounds.maxY - 50), modifiers: .shift)
        try await waitForWebKit { controller.presentedPeekSurface?.webView.title == "Second" }
        #expect(tab.webView.title == "Source", "the tab never left its page")
        #expect(controller.peek.presentation?.trigger == .shiftClick)
        #expect(server.requests("GET", "/second") == 1, "loaded once, in the Peek")
        #expect(controller.session.ownedSurfaces.count == 1)
    }

    @Test("A real plain click in a pinned tab on a link to another site opens the Peek; the tab stays")
    func pinnedPlainClickWithAppKitEvents() async throws {
        let server = try PeekFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let (_, controller, tab) = try await openSource(port, pinned: true)
        defer { controller.window?.close() }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let bounds = tab.webView.bounds
        click(tab.webView, at: NSPoint(x: bounds.midX, y: tab.webView.isFlipped ? 50 : bounds.maxY - 50), modifiers: [])
        try await waitForWebKit { controller.presentedPeekSurface?.webView.title == "Second" }
        #expect(tab.webView.title == "Source")
        #expect(controller.peek.presentation?.trigger == .pinnedSourceLeavingSite)
        #expect(server.requests("GET", "/second") == 1)
    }

    @Test("Sign-in links and ⇧-submitted POST forms stay in the tab, with exactly one POST")
    func authAndPostStayInTab() async throws {
        let server = try PeekFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let (_, controller, tab) = try await openSource(port, pinned: true)
        defer { controller.window?.close() }
        let shiftClickScript = { (id: String) in
            "document.getElementById('\(id)').dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, shiftKey: true})); void 0;"
        }
        _ = try await tab.webView.evaluateJavaScript(shiftClickScript("auth"))
        try await waitForWebKit { tab.webView.url?.path == "/oauth/authorize" && !tab.webView.isLoading }
        #expect(!controller.isPeekPresented, "a sign-in flow stays in the tab that started it")

        tab.webView.goBack()
        try await waitForWebKit { tab.webView.title == "Source" && !tab.webView.isLoading }
        _ = try await tab.webView.evaluateJavaScript(shiftClickScript("submit"))
        try await waitForWebKit { tab.webView.title == "Posted" && !tab.webView.isLoading }
        #expect(!controller.isPeekPresented, "a POST is never cancelled and replayed in a Peek")
        #expect(server.requests("POST", "/posted") == 1)
        #expect(server.requests("GET", "/posted") == 0)
        #expect(controller.session.ownedSurfaces.count == 1)
    }

    @Test("A same-site target of a pinned tab stays a tab; a dismissed WebKit Peek is released")
    func sameSiteStaysTabAndDismissReleases() async throws {
        let server = try PeekFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let (_, controller, tab) = try await openSource(port, pinned: true)
        defer { controller.window?.close() }
        _ = try await tab.webView.evaluateJavaScript(
            "const a = document.createElement('a'); a.href = '/other'; a.target = '_blank'; document.body.append(a); a.click(); void 0;")
        // The foreground tab is selected once it renders; a Peek opened before would close then.
        try await waitForWebKit {
            controller.session.ownedSurfaces.count == 2 && controller.session.selectedSurface !== tab
                && controller.session.selectedSurface?.webView.title == "Other"
        }
        await controller.session.waitForPendingCommands()
        #expect(!controller.isPeekPresented)

        let peeked = try #require(controller.openPeek(URL(string: "http://localhost:\(port)/second")!))
        try await waitForWebKit { peeked.webView.title == "Second" }
        controller.dismissPeek()
        #expect(peeked.isDisposed)
        #expect(peeked.webView.superview == nil && peeked.webView.navigationDelegate == nil)
        #expect(controller.session.ownedSurfaces.count == 2)
    }
}

}
