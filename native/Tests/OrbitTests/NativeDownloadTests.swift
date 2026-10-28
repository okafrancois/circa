import AppKit
import BrowserCore
import BrowserShell
import Foundation
import Network
import Testing
import WebKit
@testable import Orbit
import BrowserEngine
import WebKitEngine

private final class PopupStoreGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var timedOut = false
    var didTimeOut: Bool { lock.withLock { timedOut } }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 2) == .success }
    func wait() {
        entered.signal()
        if release.wait(timeout: .now() + 5) == .timedOut { lock.withLock { timedOut = true } }
    }
}

private extension BrowserStore {
    func holdPopupFixture(_ gate: PopupStoreGate) { gate.wait() }
}

@MainActor
private final class DownloadFileActionProbe: BrowserDownloadTransfer {
    func perform(_ action: BrowserDownloadAction, completion: @escaping @MainActor (Result<Void, BrowserDownloadError>) -> Void) {
        completion(.success(()))
    }
    func invalidate() {}
}

private final class DownloadFixtureServer: @unchecked Sendable {
    static let payload = Data((0..<524_288).map { UInt8(($0 * 31 + 17) % 251) })
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Orbit.NativeDownloads.HTTP")
    private let lock = NSLock()
    private var requestHeaders: [String] = []
    private var interrupted = false
    private var deferredResponses: [(NWConnection, String, String)] = []
    private var isGateOpen = false
    private var gatedStreams: [(NWConnection, Int)] = []
    private var gatedBytesSent = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
    var observedRangeRequest: Bool { lock.withLock { requestHeaders.contains { $0.lowercased().contains("\r\nrange: bytes=") } } }
    func rangeRequestsHaveCookie(_ expected: String, excluding other: String) -> Bool {
        lock.withLock {
            let ranges = requestHeaders.filter { $0.lowercased().contains("\r\nrange: bytes=") }
            return !ranges.isEmpty && ranges.allSatisfy { $0.contains(expected) && !$0.contains(other) }
        }
    }
    func matchingRequests(method: String, path: String, body: String? = nil) -> Int {
        lock.withLock {
            requestHeaders.filter {
                $0.hasPrefix("\(method) \(path) HTTP/") && (body == nil || $0.components(separatedBy: "\r\n\r\n").last == body)
            }.count
        }
    }

    /// Bytes `/gated` has handed to the network; it holds the rest until `openGate()`.
    var gatedBytes: Int { lock.withLock { gatedBytesSent } }

    func openGate() {
        let parked = lock.withLock {
            isGateOpen = true
            let parked = gatedStreams
            gatedStreams.removeAll()
            return parked
        }
        for (connection, offset) in parked {
            queue.async { [self] in stream(connection, offset: offset, slow: false, drop: false, gated: false) }
        }
    }

    func releaseDeferredResponses() {
        let pending = lock.withLock {
            let pending = deferredResponses
            deferredResponses.removeAll()
            return pending
        }
        for (connection, request, path) in pending {
            queue.async { [self] in respond(connection, request: request, path: path) }
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            buffer.append(data ?? Data())
            guard buffer.count <= 16_384 else { connection.cancel(); return }
            guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)),
                  let headers = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else {
                if !complete && error == nil { receive(connection, buffer: buffer) }
                else { connection.cancel() }
                return
            }
            let length = headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard length >= 0, boundary.upperBound + length <= 16_384 else { connection.cancel(); return }
            guard buffer.count >= boundary.upperBound + length else {
                if !complete && error == nil { receive(connection, buffer: buffer) }
                else { connection.cancel() }
                return
            }
            guard let request = String(data: buffer, encoding: .utf8) else { connection.cancel(); return }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let deferred = lock.withLock {
                requestHeaders.append(request)
                guard path == "/delayed-file" || path == "/delayed-popup" else { return false }
                deferredResponses.append((connection, request, path == "/delayed-popup" ? "/popup-page" : "/file"))
                return true
            }
            if deferred { return }
            respond(connection, request: request, path: path)
        }
    }

    private func respond(_ connection: NWConnection, request: String, path: String) {
        if path == "/page" {
            let body = Data("<!doctype html><title>Synthetic Downloads</title><h1>Downloads</h1><input id=draft><a id=download download href='/file'>Download</a><a id=attachment target=_blank href='/file'>Attachment in new tab</a><form id=popup rel=opener method=post target=_blank action='/popup-page'><input name=payload value=OrbitSyntheticPost></form>".utf8)
            sendHeaders(connection, status: "200 OK", length: body.count, type: "text/html", extra: "")
            connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        if path == "/popup-page" {
            let body = Data("<!doctype html><title>Synthetic Popup</title><h1>Native popup</h1><p id=opener></p><script>document.getElementById('opener').textContent=window.opener ? window.opener.document.getElementById('draft').value : 'missing';</script>".utf8)
            sendHeaders(connection, status: "200 OK", length: body.count, type: "text/html", extra: "")
            connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let rangeLine = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
        let offset = rangeLine.flatMap { Int($0.split(separator: "=").last?.split(separator: "-").first ?? "") } ?? 0
        guard offset >= 0, offset < Self.payload.count else { connection.cancel(); return }
        let range = offset > 0 ? "Content-Range: bytes \(offset)-\(Self.payload.count - 1)/\(Self.payload.count)\r\n" : ""
        sendHeaders(connection, status: offset > 0 ? "206 Partial Content" : "200 OK", length: Self.payload.count - offset,
            type: "application/octet-stream", extra: "Content-Disposition: attachment; filename=same.bin\r\nAccept-Ranges: bytes\r\nETag: \"orbit-wk-download-v1\"\r\n" + range)
        let drop: Bool = lock.withLock {
            if path == "/interrupt", offset == 0, !interrupted { interrupted = true; return true }
            return false
        }
        stream(connection, offset: offset, slow: path != "/file" && path != "/gated", drop: drop, gated: path == "/gated")
    }

    private func sendHeaders(_ connection: NWConnection, status: String, length: Int, type: String, extra: String) {
        let value = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nConnection: close\r\n" + extra + "\r\n"
        connection.send(content: Data(value.utf8), completion: .contentProcessed { _ in })
    }

    private func stream(_ connection: NWConnection, offset: Int, slow: Bool, drop: Bool, gated: Bool = false) {
        if drop && offset >= 131_072 { connection.cancel(); return }
        guard offset < Self.payload.count else { connection.cancel(); return }
        if gated && offset >= 16_384 {
            let parked: Bool = lock.withLock {
                gatedBytesSent = offset
                guard !isGateOpen else { return false }
                gatedStreams.append((connection, offset))
                return true
            }
            if parked { return }
        }
        let end = min(offset + 16_384, Self.payload.count)
        connection.send(content: Self.payload.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            queue.asyncAfter(deadline: .now() + (slow ? 0.04 : 0)) { [weak self] in
                self?.stream(connection, offset: end, slow: slow, drop: drop, gated: gated)
            }
        })
    }
}

private func downloadTestDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/private/tmp/OrbitDownloads-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    return directory
}

@MainActor
private func beginDownload(_ controller: PreviewWindowController, port: UInt16, path: String) async throws -> ProfileID {
    controller.submitAddress("http://127.0.0.1:\(port)/page")
    await controller.session.waitForPendingCommands()
    let surface = try #require(controller.session.selectedSurface)
    try await waitForNativeState("surface.webView.title == \"Synthetic Downloads\" && !surface.webView.isLoading",
        observed: { nativeWebViewState(surface.webView) }
    ) { surface.webView.title == "Synthetic Downloads" && !surface.webView.isLoading }
    _ = try await surface.webView.evaluateJavaScript("document.getElementById('download').href='\(path)'; document.getElementById('download').click();")
    return surface.profileID
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeDownloadTests {
    @Test("Address editing after the native selection commits survives its pending UI publication")
    func addressDraftSurvivesCommittedPromotionPublication() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.releaseDeferredResponses(); server.stop() }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.selectedSurface)
        try await waitForNativeState("source.webView.title == \"Synthetic Downloads\" && !source.webView.isLoading",
            observed: { nativeWebViewState(source.webView) }
        ) { source.webView.title == "Synthetic Downloads" && !source.webView.isLoading }
        _ = try await source.webView.evaluateJavaScript("window.open('/delayed-popup','publication-focus-fixture');void 0;")
        try await waitForNativeState("server.matchingRequests(method: \"GET\", path: \"/delayed-popup\") == 1",
            observed: { String(describing: server.matchingRequests(method: "GET", path: "/delayed-popup")) }
        ) { server.matchingRequests(method: "GET", path: "/delayed-popup") == 1 }
        await controller.session.waitForPendingCommands()
        let publish = controller.session.onChange
        var edited = false
        weak var editingView: NSTextView?
        controller.session.onChange = { [weak controller] in
            if let controller, !edited, controller.hasPendingNativePromotion,
               controller.session.selectedSurface !== source {
                edited = true
                controller.window?.makeFirstResponder(controller.addressControl)
                editingView = controller.window?.firstResponder as? NSTextView
                if let editingView {
                    editingView.insertText("Draft entered before native publication", replacementRange: NSRange(location: 0, length: editingView.string.utf16.count))
                }
            }
            publish?()
        }
        defer { controller.session.onChange = publish }
        server.releaseDeferredResponses()
        try await waitForNativeState("controller.session.ownedSurfaces.contains { $0.webView.title == \"Synthetic Popup\" && !$0.webView.isLoading }",
            observed: { "surfaces=\(controller.session.ownedSurfaces.count), selected=\(controller.session.selectedSurface?.webView.title ?? "nil"), promotion=\(controller.hasPendingNativePromotion), queued=\(controller.session.hasPendingCommands)" }
        ) { controller.session.ownedSurfaces.contains { $0.webView.title == "Synthetic Popup" && !$0.webView.isLoading } }
        await controller.session.waitForPendingCommands()
        #expect(edited)
        #expect(controller.session.selectedSurface !== source)
        #expect(controller.window?.firstResponder === editingView)
        #expect(controller.displayedAddress == "Draft entered before native publication")
    }

    @Test("Address editing revokes native foreground selection after it has already joined the command queue")
    func addressEditingRevokesQueuedPromotion() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.releaseDeferredResponses(); server.stop() }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.selectedSurface)
        try await waitForNativeState("source.webView.title == \"Synthetic Downloads\" && !source.webView.isLoading",
            observed: { nativeWebViewState(source.webView) }
        ) { source.webView.title == "Synthetic Downloads" && !source.webView.isLoading }
        _ = try await source.webView.evaluateJavaScript("window.open('/delayed-popup','queued-focus-fixture');void 0;")
        try await waitForNativeState("server.matchingRequests(method: \"GET\", path: \"/delayed-popup\") == 1",
            observed: { String(describing: server.matchingRequests(method: "GET", path: "/delayed-popup")) }
        ) { server.matchingRequests(method: "GET", path: "/delayed-popup") == 1 }
        await controller.session.waitForPendingCommands()
        let gate = PopupStoreGate()
        let hold = Task { await environment.store.holdPopupFixture(gate) }
        defer { gate.release.signal() }
        #expect(await Task.detached { gate.waitUntilEntered() }.value)
        server.releaseDeferredResponses()
        try await waitForNativeState("controller.hasPendingNativePromotion && controller.session.hasPendingCommands",
            observed: { "surfaces=\(controller.session.ownedSurfaces.count), selected=\(controller.session.selectedSurface?.webView.title ?? "nil"), promotion=\(controller.hasPendingNativePromotion), queued=\(controller.session.hasPendingCommands)" }
        ) { controller.hasPendingNativePromotion && controller.session.hasPendingCommands }
        controller.window?.makeFirstResponder(controller.addressControl)
        let editor = try #require(controller.window?.firstResponder as? NSTextView)
        editor.insertText("Draft entered after queued promotion", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        gate.release.signal()
        await hold.value
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("!controller.hasPendingNativePromotion",
            observed: { "surfaces=\(controller.session.ownedSurfaces.count), selected=\(controller.session.selectedSurface?.webView.title ?? "nil"), promotion=\(controller.hasPendingNativePromotion), queued=\(controller.session.hasPendingCommands)" }
        ) { !controller.hasPendingNativePromotion }
        #expect(!gate.didTimeOut)
        #expect(controller.session.selectedSurface === source)
        #expect(controller.window?.firstResponder === editor)
        #expect(controller.displayedAddress == "Draft entered after queued promotion")
    }

    @Test("An immediate native close is retained while provided-surface adoption waits for the store")
    func closeBeforeAdoption() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.selectedSurface)
        try await waitForNativeState("source.webView.title == \"Synthetic Downloads\" && !source.webView.isLoading",
            observed: { nativeWebViewState(source.webView) }
        ) { source.webView.title == "Synthetic Downloads" && !source.webView.isLoading }
        let gate = PopupStoreGate()
        let hold = Task { await environment.store.holdPopupFixture(gate) }
        defer { gate.release.signal() }
        let entered = await Task.detached { gate.waitUntilEntered() }.value
        #expect(entered)
        _ = try await source.webView.evaluateJavaScript("window.open('about:blank','immediate-close-fixture').close();")
        #expect(controller.session.hasPendingCommands)
        gate.release.signal()
        await hold.value
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("controller.session.ownedSurfaces.count == 1",
            observed: { "surfaces=\(controller.session.ownedSurfaces.count), selected=\(controller.session.selectedSurface?.webView.title ?? "nil"), promotion=\(controller.hasPendingNativePromotion), queued=\(controller.session.hasPendingCommands)" }
        ) { controller.session.ownedSurfaces.count == 1 }
        #expect(!gate.didTimeOut)
        #expect(controller.session.selectedSurface === source)
        #expect(controller.session.snapshot?.tabs.count == 1)
    }

    @Test("A subframe response cannot consume a pending native attachment target or steal its download owner")
    func iframeBeforeAttachmentHeaders() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.releaseDeferredResponses(); server.stop() }
        let environment = PreviewEnvironment()
        environment.downloads.destinationProvider = { _, _ in directory.appendingPathComponent("iframe-attachment.bin") }
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.selectedSurface)
        let occurrence = try #require(controller.session.occurrenceID(for: source))
        try await waitForNativeState("source.webView.title == \"Synthetic Downloads\" && !source.webView.isLoading",
            observed: { nativeWebViewState(source.webView) }
        ) { source.webView.title == "Synthetic Downloads" && !source.webView.isLoading }
        _ = try await source.webView.evaluateJavaScript("window.child=window.open('/delayed-file','iframe-fixture');void 0;")
        try await waitForNativeState("server.matchingRequests(method: \"GET\", path: \"/delayed-file\") == 1",
            observed: { String(describing: server.matchingRequests(method: "GET", path: "/delayed-file")) }
        ) { server.matchingRequests(method: "GET", path: "/delayed-file") == 1 }
        await controller.session.waitForPendingCommands()
        let child = try #require(controller.session.ownedSurfaces.first { $0 !== source })
        // Inject the adversarial frame classification at the same adapter boundary as WebKit.
        let response = URLResponse(url: URL(string: "http://127.0.0.1:\(port)/popup-page")!,
                                   mimeType: "text/html", expectedContentLength: 0, textEncodingName: "utf-8")
        let decision = controller.decideNavigationResponse(response, canShowMIMEType: true,
                                                                 isForMainFrame: false, in: child)
        #expect(decision == .allow)
        #expect(controller.session.selectedSurface === source)
        server.releaseDeferredResponses()
        try await waitForNativeState("environment.downloads.snapshots(profileID: source.profileID).first?.state == .complete",
            observed: { environment.downloads.snapshots(profileID: source.profileID).map { nativeDownloadState($0) }.joined(separator: "; ") }
        ) { environment.downloads.snapshots(profileID: source.profileID).first?.state == .complete }
        await controller.session.waitForPendingCommands()
        let download = try #require(environment.downloads.snapshots(profileID: source.profileID).first)
        #expect(download.owner.sourceOccurrenceID == occurrence)
        #expect(controller.session.ownedSurfaces.count == 1)
        #expect(controller.session.selectedSurface === source)
    }

    @Test("A delayed new target cannot discard an address draft entered after its creation")
    func delayedTargetPreservesNewerAddressIntent() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.releaseDeferredResponses(); server.stop() }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.selectedSurface)
        try await waitForNativeState("source.webView.title == \"Synthetic Downloads\" && !source.webView.isLoading",
            observed: { nativeWebViewState(source.webView) }
        ) { source.webView.title == "Synthetic Downloads" && !source.webView.isLoading }
        _ = try await source.webView.evaluateJavaScript("window.open('/delayed-popup','focus-fixture');void 0;")
        try await waitForNativeState("server.matchingRequests(method: \"GET\", path: \"/delayed-popup\") == 1",
            observed: { String(describing: server.matchingRequests(method: "GET", path: "/delayed-popup")) }
        ) { server.matchingRequests(method: "GET", path: "/delayed-popup") == 1 }
        controller.focusAddress()
        await controller.session.waitForPendingCommands()
        let editor = try #require(controller.window?.firstResponder as? NSTextView)
        editor.string = "Unsubmitted new-target draft"
        server.releaseDeferredResponses()
        try await waitForNativeState("controller.session.ownedSurfaces.contains { $0.webView.title == \"Synthetic Popup\" && !$0.webView.isLoading }",
            observed: { "surfaces=\(controller.session.ownedSurfaces.count), selected=\(controller.session.selectedSurface?.webView.title ?? "nil"), promotion=\(controller.hasPendingNativePromotion), queued=\(controller.session.hasPendingCommands)" }
        ) { controller.session.ownedSurfaces.contains { $0.webView.title == "Synthetic Popup" && !$0.webView.isLoading } }
        await controller.session.waitForPendingCommands()
        #expect(controller.session.selectedSurface === source)
        #expect(controller.window?.firstResponder === editor)
        #expect(controller.displayedAddress == "Unsubmitted new-target draft")
    }

    @Test("A delayed attachment closes its own auxiliary occurrence after the source Space becomes inactive")
    func inactiveSpaceAttachmentCleanup() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.releaseDeferredResponses(); server.stop() }
        let environment = PreviewEnvironment()
        environment.downloads.destinationProvider = { _, _ in directory.appendingPathComponent("inactive-attachment.bin") }
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.selectedSurface)
        let occurrence = try #require(controller.session.occurrenceID(for: source))
        try await waitForNativeState("source.webView.title == \"Synthetic Downloads\" && !source.webView.isLoading",
            observed: { nativeWebViewState(source.webView) }
        ) { source.webView.title == "Synthetic Downloads" && !source.webView.isLoading }
        _ = try await source.webView.evaluateJavaScript("document.getElementById('attachment').href='/delayed-file';document.getElementById('attachment').click();")
        try await waitForNativeState("server.matchingRequests(method: \"GET\", path: \"/delayed-file\") == 1",
            observed: { String(describing: server.matchingRequests(method: "GET", path: "/delayed-file")) }
        ) { server.matchingRequests(method: "GET", path: "/delayed-file") == 1 }
        let otherProfile = await environment.store.createProfile(name: "Synthetic inactive download profile")
        let otherSpace = try await environment.store.createSpace(name: "Synthetic inactive download Space", profileID: otherProfile)
        controller.activateSpace(otherSpace)
        await controller.session.waitForPendingCommands()
        server.releaseDeferredResponses()
        try await waitForNativeState("environment.downloads.snapshots(profileID: source.profileID).first?.state == .complete",
            observed: { environment.downloads.snapshots(profileID: source.profileID).map { nativeDownloadState($0) }.joined(separator: "; ") }
        ) { environment.downloads.snapshots(profileID: source.profileID).first?.state == .complete }
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.activeSpaceID == otherSpace)
        #expect(controller.session.selectedSurface == nil)
        #expect(controller.session.ownedSurfaces.count == 1)
        #expect(environment.downloads.snapshots(profileID: source.profileID).first?.owner.sourceOccurrenceID == occurrence)
        let document = await environment.store.sessionDocument()
        #expect(document.tabs.map(\.occurrenceID) == [occurrence])
    }

    @Test("An attachment in a new target downloads without replacing its source document")
    func attachmentInNewTarget() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        environment.downloads.destinationProvider = { _, _ in directory.appendingPathComponent("new-target.bin") }
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.selectedSurface)
        let sourceOccurrence = try #require(controller.session.occurrenceID(for: source))
        try await waitForNativeState("source.webView.title == \"Synthetic Downloads\" && !source.webView.isLoading",
            observed: { nativeWebViewState(source.webView) }
        ) { source.webView.title == "Synthetic Downloads" && !source.webView.isLoading }
        _ = try await source.webView.evaluateJavaScript("document.getElementById('draft').value='keep-source';document.getElementById('attachment').click();")
        try await waitForNativeState("environment.downloads.snapshots(profileID: source.profileID).first?.state == .complete",
            observed: { environment.downloads.snapshots(profileID: source.profileID).map { nativeDownloadState($0) }.joined(separator: "; ") }
        ) { environment.downloads.snapshots(profileID: source.profileID).first?.state == .complete }
        await controller.session.waitForPendingCommands()
        let record = try #require(environment.downloads.snapshots(profileID: source.profileID).first)
        #expect(record.owner.sourceOccurrenceID == sourceOccurrence)
        #expect(try Data(contentsOf: #require(record.destinationURL)) == DownloadFixtureServer.payload)
        #expect(controller.session.selectedSurface === source)
        #expect(controller.session.snapshot?.tabs.count == 1)
        #expect(try await source.webView.evaluateJavaScript("document.getElementById('draft').value") as? String == "keep-source")
        #expect(server.matchingRequests(method: "GET", path: "/file") == 1)
    }

    @Test("A native new target preserves one POST request, its opener and the provided WebKit configuration")
    func postAndOpenerInNewTarget() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let source = try #require(controller.session.selectedSurface)
        try await waitForNativeState("source.webView.title == \"Synthetic Downloads\" && !source.webView.isLoading",
            observed: { nativeWebViewState(source.webView) }
        ) { source.webView.title == "Synthetic Downloads" && !source.webView.isLoading }
        _ = try await source.webView.evaluateJavaScript("document.getElementById('draft').value='original-opener-draft';document.getElementById('popup').submit();")
        try await waitForNativeState("controller.session.ownedSurfaces.contains { $0.webView.title == \"Synthetic Popup\" && !$0.webView.isLoading }",
            observed: { "surfaces=\(controller.session.ownedSurfaces.count), selected=\(controller.session.selectedSurface?.webView.title ?? "nil"), promotion=\(controller.hasPendingNativePromotion), queued=\(controller.session.hasPendingCommands)" }
        ) { controller.session.ownedSurfaces.contains { $0.webView.title == "Synthetic Popup" && !$0.webView.isLoading } }
        let popup = try #require(controller.session.ownedSurfaces.first { $0.webView.title == "Synthetic Popup" })
        await controller.session.waitForPendingCommands()
        try await waitForNativeState("rendered popup becomes selected", observed: {
            "selected=\(controller.session.selectedSurface?.webView.title ?? "nil"), popup=\(nativeWebViewState(popup.webView)), promotion=\(controller.hasPendingNativePromotion), queued=\(controller.session.hasPendingCommands)"
        }) { controller.session.selectedSurface === popup }
        #expect(controller.session.selectedSurface === popup)
        #expect(popup.profileID == source.profileID)
        #expect(popup.webView.configuration.websiteDataStore === source.webView.configuration.websiteDataStore)
        let openerDraft = try await popup.webView.evaluateJavaScript("document.getElementById('opener').textContent") as? String
        #expect(openerDraft == "original-opener-draft")
        #expect(server.matchingRequests(method: "POST", path: "/popup-page", body: "payload=OrbitSyntheticPost") == 1)
        #expect(server.matchingRequests(method: "GET", path: "/popup-page") == 0)
        #expect(controller.session.snapshot?.tabs.count == 2)
        #expect(environment.downloads.snapshots(profileID: source.profileID).isEmpty)
    }

    @Test("File opening and Finder reveal are revoked by reentrant shutdown during metadata publication")
    func shutdownRevokesFileEffects() async throws {
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("completed.bin")
        try Data("Synthetic completed file".utf8).write(to: file)
        for action in [DownloadRowPresentation.Action.open, .reveal] {
            let manager = BrowserDownloadsController()
            let registration = try manager.coordinator.register(owner: .init(profileID: ProfileID()), transfer: DownloadFileActionProbe())
            registration.report(.init(key: registration.key, sequence: 1, state: .complete, destinationURL: file))
            let snapshot = try #require(manager.coordinator.snapshot(for: registration.key))
            var externalEffect = false
            manager.openFile = { _ in externalEffect = true }
            manager.revealFile = { _ in externalEffect = true }
            manager.observe(UUID()) {
                if manager.coordinator.snapshot(for: registration.key)?.fileAvailability == .available { manager.shutdown() }
            }
            manager.perform(action, in: snapshot.context)
            try await waitForNativeState("manager.coordinator.isClosed",
                observed: { String(describing: manager.coordinator.isClosed) }
            ) { manager.coordinator.isClosed }
            #expect(!externalEffect)
        }
    }

    @Test("Cancellation during pending resume waits for the new native attempt before terminal publication")
    func cancelPendingResume() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        environment.downloads.destinationProvider = { _, _ in directory.appendingPathComponent("pending-resume.bin") }
        var deferredResume: (@MainActor () -> Void)?
        var resumeReturned = false
        environment.engine.resumeDownload = { view, data, completion in
            deferredResume = {
                view.resumeDownload(fromResumeData: data) { download in
                    resumeReturned = true
                    completion(download)
                }
            }
        }
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        let profile = try await beginDownload(controller, port: port, path: "/interrupt")
        try await waitForNativeState("environment.downloads.snapshots(profileID: profile).first?.state == .interrupted",
            observed: { "downloads=\(environment.downloads.snapshots(profileID: profile).map { nativeDownloadState($0) }.joined(separator: "; "))" }
        ) { environment.downloads.snapshots(profileID: profile).first?.state == .interrupted }
        let interrupted = try #require(environment.downloads.snapshots(profileID: profile).first)
        try environment.downloads.coordinator.perform(.resume, in: interrupted.context)
        let pending = try #require(environment.downloads.coordinator.snapshot(for: interrupted.key))
        try environment.downloads.coordinator.perform(.cancel, in: pending.context)
        try await Task.sleep(for: .milliseconds(30))
        #expect(!resumeReturned)
        #expect(environment.downloads.coordinator.snapshot(for: interrupted.key)?.state == .interrupted)
        let startResume = try #require(deferredResume)
        startResume()
        deferredResume = nil
        try await waitForNativeState("environment.downloads.coordinator.snapshot(for: interrupted.key)?.state == .cancelled",
            observed: { nativeDownloadState(environment.downloads.coordinator.snapshot(for: interrupted.key)) }
        ) { environment.downloads.coordinator.snapshot(for: interrupted.key)?.state == .cancelled }
        #expect(resumeReturned)
    }

    @Test("Real WebKit download bytes, duplicate destinations and moved-file actions remain profile scoped")
    func realFilesAndProfileScopedLibrary() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        var destinations = 0
        environment.downloads.destinationProvider = { _, _ in
            destinations += 1
            return directory.appendingPathComponent("payload-\(destinations).bin")
        }
        let first = try await environment.makeWindow()
        defer { first.window?.close(); environment.downloads.shutdown() }
        let profile = try await beginDownload(first, port: port, path: "/file")
        try await waitForNativeState("environment.downloads.snapshots(profileID: profile).first?.state == .complete",
            observed: { "downloads=\(environment.downloads.snapshots(profileID: profile).map { nativeDownloadState($0) }.joined(separator: "; "))" }
        ) { environment.downloads.snapshots(profileID: profile).first?.state == .complete }
        let one = try #require(environment.downloads.snapshots(profileID: profile).first)
        #expect(try Data(contentsOf: #require(one.destinationURL)) == DownloadFixtureServer.payload)
        #expect(one.receivedBytes == Int64(DownloadFixtureServer.payload.count))
        _ = try await beginDownload(first, port: port, path: "/file")
        try await waitForNativeState("environment.downloads.snapshots(profileID: profile).filter { $0.state == .complete }.count == 2",
            observed: { "downloads=\(environment.downloads.snapshots(profileID: profile).map { nativeDownloadState($0) }.joined(separator: "; "))" }
        ) { environment.downloads.snapshots(profileID: profile).filter { $0.state == .complete }.count == 2 }
        let records = environment.downloads.snapshots(profileID: profile)
        #expect(records[0].key != records[1].key && records[0].destinationURL != records[1].destinationURL)
        #expect(try Data(contentsOf: #require(records[1].destinationURL)) == DownloadFixtureServer.payload)
        first.showDownloads()
        await first.session.waitForPendingCommands()
        #expect(first.downloadsPane.list.displayedTitles == ["payload-1.bin", "payload-2.bin"])
        #expect(first.session.selectedSurface?.webView.title == "Synthetic Downloads")
        try await captureSyntheticWindow(first)
        var opened = false
        environment.downloads.openFile = { _ in opened = true }
        environment.downloads.perform(.open, in: one.context)
        try await waitForNativeState("opened",
            observed: { "opened=\(opened)" }
        ) { opened }
        opened = false
        let current = try #require(environment.downloads.coordinator.snapshot(for: one.key))
        try FileManager.default.moveItem(at: #require(one.destinationURL), to: directory.appendingPathComponent("moved.bin"))
        environment.downloads.perform(.open, in: current.context)
        try await waitForNativeState("environment.downloads.coordinator.snapshot(for: one.key)?.fileAvailability == .missing",
            observed: { nativeDownloadState(environment.downloads.coordinator.snapshot(for: one.key)) }
        ) { environment.downloads.coordinator.snapshot(for: one.key)?.fileAvailability == .missing }
        #expect(!opened)
        #expect(environment.downloads.coordinator.snapshot(for: one.key)?.state == .complete)
        let profileB = await environment.store.createProfile(name: "Synthetic download profile")
        let spaceB = try await environment.store.createSpace(name: "Synthetic download Space", profileID: profileB)
        first.activateSpace(spaceB)
        first.showDownloads()
        await first.session.waitForPendingCommands()
        #expect(first.downloadsPane.list.displayedTitles.isEmpty)
        #expect(environment.downloads.snapshots(profileID: profile).count == 2)
        #expect(!first.window!.isVisible)
    }

    @Test("Cancelling a real active WebKit transfer reaches cancelled without inventing completion")
    func cancellation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        environment.downloads.destinationProvider = { _, _ in directory.appendingPathComponent("cancel.bin") }
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        let profile = try await beginDownload(controller, port: port, path: "/slow")
        try await waitForNativeState("environment.downloads.snapshots(profileID: profile).first?.receivedBytes ?? 0 > 0",
            observed: { "downloads=\(environment.downloads.snapshots(profileID: profile).map { nativeDownloadState($0) }.joined(separator: "; "))" }
        ) { environment.downloads.snapshots(profileID: profile).first?.receivedBytes ?? 0 > 0 }
        let active = try #require(environment.downloads.snapshots(profileID: profile).first)
        try environment.downloads.coordinator.perform(.cancel, in: active.context)
        try await waitForNativeState("environment.downloads.coordinator.snapshot(for: active.key)?.state == .cancelled",
            observed: { nativeDownloadState(environment.downloads.coordinator.snapshot(for: active.key)) }
        ) { environment.downloads.coordinator.snapshot(for: active.key)?.state == .cancelled }
        #expect(environment.downloads.coordinator.snapshot(for: active.key)?.isCancellationRequested == true)
        #expect(environment.downloads.coordinator.snapshot(for: active.key)?.receivedBytes ?? .max < Int64(DownloadFixtureServer.payload.count))
        #expect(!environment.downloads.hasActiveTransfers)
    }

    @Test("WebKit resumes an interrupted transfer with its original profile and engine resume data")
    func interruptedResume() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        environment.downloads.destinationProvider = { _, _ in directory.appendingPathComponent("resume.bin") }
        let controller = try await environment.makeWindow()
        defer { controller.window?.close(); environment.downloads.shutdown() }
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let original = try #require(controller.session.selectedSurface)
        try await waitForNativeState("original.webView.title == \"Synthetic Downloads\"",
            observed: { nativeWebViewState(original.webView) }
        ) { original.webView.title == "Synthetic Downloads" }
        _ = try await original.webView.evaluateJavaScript("document.cookie='download_profile=synthetic-a; path=/';")
        let profile = try await beginDownload(controller, port: port, path: "/interrupt")
        try await waitForNativeState("environment.downloads.snapshots(profileID: profile).first?.state == .interrupted",
            observed: { "downloads=\(environment.downloads.snapshots(profileID: profile).map { nativeDownloadState($0) }.joined(separator: "; "))" }
        ) { environment.downloads.snapshots(profileID: profile).first?.state == .interrupted }
        let interrupted = try #require(environment.downloads.snapshots(profileID: profile).first)
        #expect(interrupted.canPerform(.resume))
        let profileB = await environment.store.createProfile(name: "Synthetic other resume profile")
        let spaceB = try await environment.store.createSpace(name: "Synthetic other resume Space", profileID: profileB)
        controller.activateSpace(spaceB)
        await controller.session.waitForPendingCommands()
        controller.submitAddress("http://127.0.0.1:\(port)/page")
        await controller.session.waitForPendingCommands()
        let other = try #require(controller.session.selectedSurface)
        try await waitForNativeState("other.webView.title == \"Synthetic Downloads\"",
            observed: { nativeWebViewState(other.webView) }
        ) { other.webView.title == "Synthetic Downloads" }
        _ = try await other.webView.evaluateJavaScript("document.cookie='download_profile=synthetic-b; path=/';")
        try environment.downloads.coordinator.perform(.resume, in: interrupted.context)
        try await waitForNativeState("environment.downloads.coordinator.snapshot(for: interrupted.key)?.state == .complete",
            observed: { nativeDownloadState(environment.downloads.coordinator.snapshot(for: interrupted.key)) }
        ) { environment.downloads.coordinator.snapshot(for: interrupted.key)?.state == .complete }
        let complete = try #require(environment.downloads.coordinator.snapshot(for: interrupted.key))
        #expect(complete.owner.profileID == profile)
        #expect(server.observedRangeRequest)
        #expect(server.rangeRequestsHaveCookie("download_profile=synthetic-a", excluding: "download_profile=synthetic-b"))
        #expect(try Data(contentsOf: #require(complete.destinationURL)) == DownloadFixtureServer.payload)
    }

    @Test("Active downloads survive source window retirement and write their complete real bytes")
    func sourceWindowClose() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let environment = PreviewEnvironment()
        environment.downloads.destinationProvider = { _, _ in directory.appendingPathComponent("surviving.bin") }
        defer { environment.downloads.shutdown() }
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let profile = try await beginDownload(controller, port: port, path: "/slow")
        try await waitForNativeState("environment.downloads.snapshots(profileID: profile).first?.receivedBytes ?? 0 > 0",
            observed: { "downloads=\(environment.downloads.snapshots(profileID: profile).map { nativeDownloadState($0) }.joined(separator: "; "))" }
        ) { environment.downloads.snapshots(profileID: profile).first?.receivedBytes ?? 0 > 0 }
        let active = try #require(environment.downloads.snapshots(profileID: profile).first)
        #expect(active.receivedBytes < Int64(DownloadFixtureServer.payload.count))
        controller.window?.close()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.isClosed)
        try await waitForNativeState("environment.downloads.coordinator.snapshot(for: active.key)?.state == .complete",
            observed: { nativeDownloadState(environment.downloads.coordinator.snapshot(for: active.key)) }
        ) { environment.downloads.coordinator.snapshot(for: active.key)?.state == .complete }
        let complete = try #require(environment.downloads.coordinator.snapshot(for: active.key))
        #expect(complete.owner == active.owner)
        #expect(try Data(contentsOf: #require(complete.destinationURL)) == DownloadFixtureServer.payload)
    }

    @Test("A download that outlives its source window survives WebKit's background networking role")
    func backgroundNetworkingRole() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try DownloadFixtureServer()
        let port = try await server.start()
        defer { server.openGate(); server.stop() }
        let environment = PreviewEnvironment()
        environment.downloads.destinationProvider = { _, _ in directory.appendingPathComponent("gated.bin") }
        defer { environment.downloads.shutdown() }
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let profile = try await beginDownload(controller, port: port, path: "/gated")
        let store = environment.engine.websiteDataStore(for: profile)
        try await waitForNativeState("environment.downloads.snapshots(profileID: profile).first?.receivedBytes ?? 0 > 0",
            observed: { "downloads=\(environment.downloads.snapshots(profileID: profile).map { nativeDownloadState($0) }.joined(separator: "; "))" }
        ) { environment.downloads.snapshots(profileID: profile).first?.receivedBytes ?? 0 > 0 }
        let active = try #require(environment.downloads.snapshots(profileID: profile).first)
        controller.window?.close()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.isClosed)
        // No visible page remains: WebKit backgrounds networking while the transfer is active.
        // If WebKit starts holding a download assertion for applications, revisit this harness.
        try await waitForNativeState("nativeWebKitNetworkingIsBackground(store) == true",
            observed: { nativeWebKitNetworkingState(store) }
        ) { nativeWebKitNetworkingIsBackground(store) == true }
        let backgrounded = try #require(environment.downloads.coordinator.snapshot(for: active.key))
        #expect(backgrounded.state == .running)
        #expect(backgrounded.receivedBytes < Int64(DownloadFixtureServer.payload.count))
        #expect(server.gatedBytes < DownloadFixtureServer.payload.count)
        server.openGate()
        try await waitForNativeState("environment.downloads.coordinator.snapshot(for: active.key)?.state == .complete",
            observed: { nativeDownloadState(environment.downloads.coordinator.snapshot(for: active.key)) + ", " + nativeWebKitNetworkingState(store) }
        ) { environment.downloads.coordinator.snapshot(for: active.key)?.state == .complete }
        let complete = try #require(environment.downloads.coordinator.snapshot(for: active.key))
        #expect(complete.owner == active.owner)
        #expect(complete.receivedBytes == Int64(DownloadFixtureServer.payload.count))
        #expect(try Data(contentsOf: #require(complete.destinationURL)) == DownloadFixtureServer.payload)
        #expect(controller.window?.isVisible == false)
        #expect(!NSApplication.shared.isActive)
    }

    @Test("Suggested path metadata is sanitized and existing or symlink destinations are not overwritten")
    func destinationPolicy() throws {
        let directory = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("existing.bin")
        try Data("Synthetic prior bytes".utf8).write(to: file)
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("missing.bin"))
        #expect(BrowserDownloadPaths.suggestedFilename("../../escape.bin") == "escape.bin")
        #expect(!BrowserDownloadPaths.suggestedFilename("bad\u{202E}name.bin").contains("\u{202E}"))
        #expect(!BrowserDownloadPaths.isValidDestination(file))
        #expect(!BrowserDownloadPaths.isValidDestination(link))
        #expect(!BrowserDownloadPaths.isValidDestination(URL(string: "https://example.test/file")!))
        #expect(try Data(contentsOf: file) == Data("Synthetic prior bytes".utf8))
    }
}

}
