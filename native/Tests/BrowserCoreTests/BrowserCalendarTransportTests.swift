import Foundation
import Testing
@testable import BrowserCore

@Suite(.serialized)
struct BrowserCalendarTransportTests {
    private let url = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!

    @Test("Cancelling a suspended transport cancels the underlying request promptly")
    func cancellationStopsRequest() async throws {
        let signals = CalendarTransportProtocol.state.prepare(oversize: false)
        let transport = BrowserCalendarURLSessionTransport(protocolClasses: [CalendarTransportProtocol.self])
        let task = Task { try await transport.send(url: url, bearerToken: "invented-token", maximumResponseBytes: 64) }
        var started = signals.started.makeAsyncIterator()
        _ = await started.next()
        let request = try #require(CalendarTransportProtocol.state.request())
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer invented-token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        task.cancel()
        let stoppedPromptly = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var stopped = signals.stopped.makeAsyncIterator()
                return await stopped.next() != nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(stoppedPromptly)
        await #expect(throws: BrowserCalendarTransportError.cancelled) { try await task.value }
    }

    @Test("Streaming byte bounds cancel oversized responses without trusting Content-Length")
    func streamingLimit() async throws {
        _ = CalendarTransportProtocol.state.prepare(oversize: true)
        let transport = BrowserCalendarURLSessionTransport(protocolClasses: [CalendarTransportProtocol.self])
        await #expect(throws: BrowserCalendarTransportError.responseTooLarge) {
            try await transport.send(url: url, bearerToken: "invented-token", maximumResponseBytes: 16)
        }
    }
}

private final class CalendarTransportProtocol: URLProtocol, @unchecked Sendable {
    static let state = CalendarTransportState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.googleapis.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard Self.state.start(request) else { return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 12))
        client?.urlProtocol(self, didLoad: Data(repeating: 66, count: 12))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { Self.state.stop() }
}

private final class CalendarTransportState: @unchecked Sendable {
    private let lock = NSLock()
    private var oversize = false
    private var sent: URLRequest?
    private var started: AsyncStream<Void>.Continuation?
    private var stopped: AsyncStream<Void>.Continuation?

    func prepare(oversize: Bool) -> (started: AsyncStream<Void>, stopped: AsyncStream<Void>) {
        let start = AsyncStream<Void>.makeStream(), stop = AsyncStream<Void>.makeStream()
        lock.withLock {
            self.oversize = oversize
            sent = nil
            started = start.continuation
            stopped = stop.continuation
        }
        return (start.stream, stop.stream)
    }

    func start(_ request: URLRequest) -> Bool {
        lock.withLock {
            sent = request
            started?.yield(())
            started?.finish()
            return oversize
        }
    }

    func request() -> URLRequest? { lock.withLock { sent } }
    func stop() { lock.withLock { stopped?.yield(()); stopped?.finish() } }
}
