import Foundation
import Network
import Testing
@testable import BrowserCore
@testable import Orbit

@Suite("Passive link summaries", .serialized)
struct BrowserLinkPreviewTests {
    @Test func anonymousHTMLProducesBoundedTextWithoutExecutingOrFetchingResources() throws {
        let html = """
        <head><title>Release &amp; Notes</title><meta content="A short description" name="description"></head>
        <body><h1>Changes</h1><p>Useful public text.</p><script>NEVER_SCRIPT</script>
        <style>NEVER_STYLE</style><form>NEVER_FORM<input value="NEVER_PASSWORD"></form>
        <template>NEVER_TEMPLATE</template><!-- NEVER_COMMENT --><img src="https://example.test/tracker">
        <textarea>NEVER_UNCLOSED
        """
        let parsed = try #require(BrowserLinkPreviewLoader.parse(Data(html.utf8)))
        #expect(parsed.title == "Release & Notes" && parsed.description == "A short description")
        #expect(parsed.text.contains("Useful public text."))
        #expect(!parsed.text.contains("NEVER_") && !parsed.text.contains("tracker"))
        #expect(BrowserLinkPreviewLoader.parse(Data(repeating: 65, count: BrowserLinkPreviewLoader.maximumBytes + 1)) == nil)
    }

    @Test func credentialsAndNonWebDestinationsAreRejected() {
        for raw in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "https://user:password@example.test/", "about:blank"] {
            #expect(!BrowserLinkPreviewLoader.validURL(URL(string: raw)!))
        }
        #expect(BrowserLinkPreviewLoader.validURL(URL(string: "https://example.test/article")!))
    }

    @Test func summariesHaveNoExecutableStructureAndRejectUnboundedLines() throws {
        #expect(try BrowserLinkPreviewHelp.parseSummary("{\"summary\":[\"One useful point\",\"Another point\"]}") == ["One useful point", "Another point"])
        for value in ["{\"summary\":[]}", "{\"summary\":[\"\"]}", "{\"summary\":[\"a\\nb\"]}",
                      "{\"summary\":[\"a\",\"b\",\"c\",\"d\"]}", "{\"summary\":[\"" + String(repeating: "x", count: 201) + "\"]}"] {
            #expect(throws: (any Error).self) { try BrowserLinkPreviewHelp.parseSummary(value) }
        }
    }

    @Test @MainActor func anonymousTransportRechecksRedirectPolicyAndRejectsFiles() async throws {
        let server = try LinkPreviewFixtureServer()
        let port = try await server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let loader = BrowserLinkPreviewLoader()
        let page = try await loader.load(base.appendingPathComponent("article"), allowed: { _ in true })
        #expect(page.title == "Public page" && page.text == "Useful text.")
        let sent = try #require(server.requests.first)
        #expect(sent.headers["cookie"] == nil && sent.headers["authorization"] == nil)
        server.reset()
        await #expect(throws: CancellationError.self) {
            try await loader.load(base.appendingPathComponent("redirect"), allowed: { $0.path != "/blocked" })
        }
        #expect(server.requests.map(\.path) == ["/redirect"])
        await #expect(throws: BrowserAIError.failed) {
            try await loader.load(base.appendingPathComponent("file"), allowed: { _ in true })
        }
        await #expect(throws: BrowserAIError.failed) {
            try await loader.load(base.appendingPathComponent("oversized"), allowed: { _ in true })
        }
    }
}

private final class LinkPreviewFixtureServer: @unchecked Sendable {
    struct Request {
        let path: String
        let headers: [String: String]
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Orbit.LinkPreviewTests.HTTP")
    private let lock = NSLock()
    private var stored: [Request] = []
    var requests: [Request] { lock.withLock { stored } }
    func reset() { lock.withLock { stored = [] } }

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

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, complete, error in
            var buffer = buffer
            buffer.append(data ?? Data())
            guard buffer.count < 16_384 else { connection.cancel(); return }
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !complete && error == nil { receive(connection, buffer: buffer) }
                else { connection.cancel() }
                return
            }
            let lines = request.components(separatedBy: "\r\n")
            let path = String(lines[0].split(separator: " ").dropFirst().first ?? "/")
            let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { first, _ in first })
            lock.withLock { stored.append(Request(path: path, headers: headers)) }
            let body = "<title>Public page</title><body>Useful text.</body>"
            let status = path == "/redirect" ? "302 Found" : "200 OK"
            let mime = path == "/file" ? "application/pdf" : "text/html"
            let length = path == "/oversized" ? 999999 : body.utf8.count
            let location = path == "/redirect" ? "Location: /blocked\r\n" : ""
            let response = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(length)\r\n\(location)Connection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
