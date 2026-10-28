import Foundation
import Network

/// A loopback HTTP server for conformance fixtures. It records every request it actually
/// receives (method, target, body), so the harness counts real network requests rather than
/// policy callbacks: a refused navigation must emit none, a resumed one exactly one, a popup POST
/// exactly one with its body. Bound to 127.0.0.1 on an ephemeral port; synthetic content only.
final class ConformanceFixtureServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let target: String
        let body: String
    }

    static let downloadBody = "orbit-conformance-download"
    static let postBody = "field=orbit-post-body"
    static let popupName = "orbit-conformance-popup"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "Orbit.Conformance.Fixture")
    private let lock = NSLock()
    private var received: [Request] = []
    private(set) var port: UInt16 = 0

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

    func start() async throws {
        port = try await withCheckedThrowingContinuation { continuation in
            let listener = listener
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
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

    func url(_ target: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(target)")! }
    func page(_ id: String) -> URL { url("/page?id=\(id)") }

    var requests: [Request] { lock.withLock { received } }
    func count(_ target: String, method: String? = nil) -> Int {
        requests.filter { $0.target == target && (method == nil || $0.method == method) }.count
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            buffer.append(data ?? Data())
            guard buffer.count < 262_144 else { connection.cancel(); return }
            guard let request = Self.parse(buffer) else {
                if !complete && error == nil { receive(connection, buffer: buffer) } else { connection.cancel() }
                return
            }
            lock.withLock { received.append(request) }
            connection.send(content: Self.response(for: request), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    /// Nil until the head and the whole `Content-Length` body arrived.
    private static func parse(_ buffer: Data) -> Request? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return Request(method: "?", target: "?", body: "") }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = buffer[separator.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(parts[0]), target: String(parts[1]),
                       body: String(decoding: body.prefix(length), as: UTF8.self))
    }

    private static func response(for request: Request) -> Data {
        let path = request.target.split(separator: "?").first.map(String.init) ?? request.target
        let id = request.target.components(separatedBy: "id=").dropFirst().first ?? "page"
        let (type, extra, body): (String, String, String)
        switch path {
        case "/download":
            (type, extra, body) = ("application/octet-stream",
                                   "Content-Disposition: attachment; filename=\"conformance.txt\"\r\n", downloadBody)
        case "/posted":
            (type, extra, body) = ("text/html; charset=utf-8", "", "<!doctype html><title>posted</title><p>posted</p>")
        case "/page", "/convert":
            (type, extra, body) = ("text/html; charset=utf-8", "", """
                <!doctype html><title>\(id)</title>
                <script>window.__orbitKeys = '';
                // Consumed, so that the engine does not re-dispatch the key to AppKit as unhandled
                // (it would stay `NSApp.currentEvent` and disable menu actions in the test process).
                addEventListener('keydown', e => { window.__orbitKeys += e.key; e.preventDefault(); });</script>
                <p>conformance-needle</p><input id="field"><a id="link" href="/page?id=linked">link</a>
                <form id="post" method="post" action="/posted" target="\(popupName)">\
                <input type="hidden" name="field" value="orbit-post-body"></form>
                """)
        default:
            let status = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            return Data(status.utf8)
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\n\(extra)Content-Length: \(body.utf8.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data((head + body).utf8)
    }
}
