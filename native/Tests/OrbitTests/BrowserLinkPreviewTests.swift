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
        defer { server.stop() }
        let port = try await server.start()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let loader = BrowserLinkPreviewLoader(destinations: .fixture(port))
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
        await #expect(throws: BrowserAIError.failed) {
            try await loader.load(base.appendingPathComponent("streamed-oversized"), allowed: { _ in true })
        }
        #expect(server.requests.map(\.path) == ["/redirect", "/file", "/oversized", "/streamed-oversized"])
    }

    @Test @MainActor func cancellingALoadStopsItsTransfer() async throws {
        let server = try LinkPreviewFixtureServer()
        defer { server.stop() }
        let port = try await server.start()
        let loader = BrowserLinkPreviewLoader(destinations: .fixture(port))
        let load = Task { try await loader.load(URL(string: "http://127.0.0.1:\(port)/held")!, allowed: { _ in true }) }
        try await server.waitForRequest(path: "/held")
        load.cancel()
        await #expect(throws: CancellationError.self) { try await load.value }
        server.releaseHeld()
    }

    @Test @MainActor func revokingPolicyDuringTheBodyStopsBeforeTheResponseFinishes() async throws {
        let server = try LinkPreviewFixtureServer()
        defer { server.releaseHeld(); server.stop() }
        let port = try await server.start()
        let loader = BrowserLinkPreviewLoader(requestTimeout: 1, resourceTimeout: 2, destinations: .fixture(port))
        var checks = 0
        await #expect(throws: CancellationError.self) {
            try await loader.load(URL(string: "http://127.0.0.1:\(port)/stream-held")!, allowed: { _ in
                checks += 1
                // Permit the request (before and after resolution) and headers, then revoke
                // when the first body chunk arrives.
                return checks < 4
            })
        }
        #expect(checks == 4)
        #expect(server.requests.map(\.path) == ["/stream-held"])
    }

    /// The transport must finish on URLSession's own queue: a saturated Swift cooperative pool
    /// (other suites blocking its threads under a loaded full run) once outlasted the resource
    /// timeout. Opt-in, because it deliberately occupies the shared pool for two seconds.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_LINK_PREVIEW_STARVATION"] == "1"))
    @MainActor func transportCompletesWhileTheCooperativePoolIsSaturated() async throws {
        let server = try LinkPreviewFixtureServer()
        defer { server.stop() }
        let port = try await server.start()
        let width = ProcessInfo.processInfo.activeProcessorCount
        server.beforeResponse = {
            for _ in 0..<width { Task.detached { usleep(2_000_000) } }
            usleep(50_000)
        }
        let loader = BrowserLinkPreviewLoader(requestTimeout: 1, resourceTimeout: 1, destinations: .fixture(port))
        let page = try await loader.load(URL(string: "http://127.0.0.1:\(port)/article")!, allowed: { _ in true })
        #expect(page.title == "Public page")
    }
}

@Suite("Link summary destinations", .serialized)
struct BrowserLinkPreviewDestinationTests {
    @Test(arguments: [
        ("https://example.com/a", true), ("http://93.184.216.34/", true), ("http://[2606:4700::1111]/", true),
        ("http://8.8.8.8/", true), ("https://xn--bcher-kva.example/", true), ("http://172.32.0.1/", true),
        ("http://100.128.0.1/", true), ("http://[::ffff:8.8.8.8]/", true),
        ("http://localhost/", false), ("http://LOCALHOST./", false), ("http://api.localhost:8080/", false),
        ("http://printer.local/", false), ("http://router.home.arpa/", false), ("http://intranet/", false),
        ("http://nas.lan/", false), ("http://db.internal/", false),
        ("http://127.0.0.1/", false), ("http://127.8.9.10/", false), ("http://127.1/", false),
        ("http://2130706433/", false), ("http://0x7f.1/", false), ("http://0.0.0.0/", false),
        ("http://10.1.2.3/", false), ("http://172.16.0.1/", false), ("http://172.31.255.255/", false),
        ("http://192.168.1.1/", false), ("http://169.254.169.254/latest/meta-data", false),
        ("http://100.64.0.1/", false), ("http://100.127.255.255/", false), ("http://224.0.0.1/", false),
        ("http://255.255.255.255/", false), ("http://198.18.0.1/", false),
        ("http://[::1]/", false), ("http://[::]/", false), ("http://[fe80::1]/", false), ("http://[fd12:3456::1]/", false),
        ("http://[fc00::1]/", false), ("http://[ff02::1]/", false), ("http://[::ffff:127.0.0.1]/", false),
        ("http://[::ffff:10.0.0.1]/", false), ("http://[64:ff9b::a9fe:a9fe]/", false), ("http://[2002:c0a8:0101::1]/", false),
    ])
    func hostTable(raw: String, permitted: Bool) throws {
        let url = try #require(URL(string: raw))
        #expect(BrowserLinkPreviewDestinations.publicInternet.permitsLiteral(url) == permitted, "\(raw)")
    }

    @Test func resolvedAddressesMustAllBePublic() throws {
        let table: [String: [String]] = [
            "public.test": ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"],
            "rebind.test": ["93.184.216.34", "10.0.0.7"], "loopback.test": ["127.0.0.1"],
            "metadata.test": ["169.254.169.254"], "ula.test": ["fd00::5"], "scoped.test": ["fe80::1%en0"],
            "empty.test": [],
        ]
        let destinations = BrowserLinkPreviewDestinations(resolve: { table[$0] })
        #expect(destinations.permitsResolved(try #require(URL(string: "https://public.test/x"))))
        for host in ["rebind.test", "loopback.test", "metadata.test", "ula.test", "scoped.test", "empty.test", "missing.test"] {
            #expect(!destinations.permitsResolved(try #require(URL(string: "https://\(host)/x"))), "\(host)")
        }
        #expect(destinations.permits(remoteAddress: "93.184.216.34", port: 443))
        #expect(!destinations.permits(remoteAddress: "127.0.0.1", port: 443))
        #expect(!destinations.permits(remoteAddress: "fe80::1%lo0", port: 443))
    }

    @Test @MainActor func loopbackIsRefusedBeforeAnyRequest() async throws {
        let server = try LinkPreviewFixtureServer()
        defer { server.stop() }
        let port = try await server.start()
        let loader = BrowserLinkPreviewLoader()
        for host in ["127.0.0.1", "localhost", "[::ffff:127.0.0.1]"] {
            await #expect(throws: CancellationError.self) {
                try await loader.load(URL(string: "http://\(host):\(port)/article")!, allowed: { _ in true })
            }
        }
        // A name that resolves to loopback is refused after resolution.
        let resolving = BrowserLinkPreviewLoader(destinations: .init(resolve: { _ in ["127.0.0.1"] }))
        await #expect(throws: CancellationError.self) {
            try await resolving.load(URL(string: "http://fixture.example:\(port)/article")!, allowed: { _ in true })
        }
        #expect(server.requests.isEmpty)
    }

    @Test @MainActor func redirectToLoopbackIsRefused() async throws {
        let site = try LinkPreviewFixtureServer()
        let intranet = try LinkPreviewFixtureServer()
        defer { site.stop(); intranet.stop() }
        let port = try await site.start()
        let internalPort = try await intranet.start()
        site.redirects = [
            "/to-loopback": "http://127.0.0.1:\(internalPort)/article",
            "/to-localhost": "http://localhost:\(internalPort)/article",
            "/to-metadata": "http://169.254.169.254/latest/meta-data",
        ]
        let loader = BrowserLinkPreviewLoader(destinations: .fixture(port))
        for path in ["/to-loopback", "/to-localhost", "/to-metadata"] {
            await #expect(throws: CancellationError.self) {
                try await loader.load(URL(string: "http://127.0.0.1:\(port)\(path)")!, allowed: { _ in true })
            }
        }
        #expect(site.requests.map(\.path) == ["/to-loopback", "/to-localhost", "/to-metadata"])
        #expect(intranet.requests.isEmpty)
    }

    @Test @MainActor func reachedAddressIsVerifiedBeforeTheBodyIsUsed() async throws {
        let server = try LinkPreviewFixtureServer()
        defer { server.stop() }
        let port = try await server.start()
        // The URL passes the pre-request checks, but the connection lands on loopback.
        let loader = BrowserLinkPreviewLoader(destinations: .init(trustedEndpoints: ["127.0.0.1:\(port)"], trustedConnections: []))
        await #expect(throws: CancellationError.self) {
            try await loader.load(URL(string: "http://127.0.0.1:\(port)/article")!, allowed: { _ in true })
        }
        #expect(server.requests.map(\.path) == ["/article"])
    }
}

private extension BrowserLinkPreviewDestinations {
    /// The loopback fixture stands in for a public web server; nothing else on loopback is trusted.
    static func fixture(_ port: UInt16) -> Self { .init(trustedEndpoints: ["127.0.0.1:\(port)"]) }
}

/// Loopback-only HTTP fixture (127.0.0.1, ephemeral port). Every wait is bounded and fails
/// with the listener or request state; `stop` cancels the listener and every connection.
private final class LinkPreviewFixtureServer: @unchecked Sendable {
    struct Request {
        let path: String
        let headers: [String: String]
    }
    struct FixtureError: Error, CustomStringConvertible { let description: String }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Orbit.LinkPreviewTests.HTTP")
    private let lock = NSLock()
    private var stored: [Request] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var held: NWConnection?
    /// Runs on the fixture queue after a request is recorded, before its response is sent.
    var beforeResponse: (@Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }
    private var hook: (@Sendable () -> Void)?
    var requests: [Request] { lock.withLock { stored } }
    /// Path → absolute Location answered with 302.
    var redirects: [String: String] {
        get { lock.withLock { redirectTable } }
        set { lock.withLock { redirectTable = newValue } }
    }
    private var redirectTable: [String: String] = [:]
    func reset() { lock.withLock { stored = [] } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            lock.withLock { connections[ObjectIdentifier(connection)] = connection }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .cancelled, .failed:
                    self?.lock.withLock { _ = self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
                default: break
                }
            }
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
    }

    /// Resumed exactly once, always on the fixture queue: ready, failed, or the deadline.
    private final class StartGate: @unchecked Sendable {
        var continuation: CheckedContinuation<UInt16, Error>?
        init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
        func finish(_ result: Result<UInt16, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    func start(within timeout: DispatchTimeInterval = .seconds(10)) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let gate = StartGate(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue { gate.finish(.success(port)) }
                    else { gate.finish(.failure(FixtureError(description: "listener ready without a port"))) }
                case .failed(let error): gate.finish(.failure(error))
                case .waiting(let error): gate.finish(.failure(FixtureError(description: "listener waiting: \(error)")))
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [listener] in
                gate.finish(.failure(FixtureError(description: "listener not ready in time, state \(listener.state)")))
            }
        }
    }

    /// Bounded wait for a recorded request; polls the lock-protected log.
    func waitForRequest(path: String, within timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !requests.contains(where: { $0.path == path }) {
            guard ContinuousClock.now < deadline else {
                throw FixtureError(description: "no \(path) request in time; seen \(requests.map(\.path))")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseHeld() { queue.async { [self] in held?.cancel(); held = nil } }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            defer { connections.removeAll() }
            return Array(connections.values)
        }
        open.forEach { $0.cancel() }
    }

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
            let hook = lock.withLock { () -> (@Sendable () -> Void)? in
                stored.append(Request(path: path, headers: headers))
                return self.hook
            }
            hook?()
            if let target = lock.withLock({ redirectTable[path] }) {
                let response = "HTTP/1.1 302 Found\r\nLocation: \(target)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            // `/held` answers nothing until released or cancelled: a transfer in flight.
            if path == "/held" { held = connection; return }
            if path == "/stream-held" {
                held = connection
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2048\r\nConnection: close\r\n\r\n"
                    + String(repeating: "x", count: 1024)
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
                return
            }
            let body = path == "/streamed-oversized"
                ? String(repeating: "x", count: BrowserLinkPreviewLoader.maximumBytes + 1)
                : "<title>Public page</title><body>Useful text.</body>"
            let status = path == "/redirect" ? "302 Found" : "200 OK"
            let mime = path == "/file" ? "application/pdf" : "text/html"
            // `/oversized` declares a large length; `/streamed-oversized` sends one without a length.
            let length = path == "/oversized" ? "Content-Length: 999999\r\n"
                : path == "/streamed-oversized" ? "" : "Content-Length: \(body.utf8.count)\r\n"
            let location = path == "/redirect" ? "Location: /blocked\r\n" : ""
            let response = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\n\(length)\(location)Connection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
