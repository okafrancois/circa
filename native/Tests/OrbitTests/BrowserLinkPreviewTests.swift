import Foundation
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LinkPreviewURLProtocol.self]
        let loader = BrowserLinkPreviewLoader(configuration: configuration)
        LinkPreviewURLProtocol.requests.reset()
        let page = try await loader.load(URL(string: "https://preview.test/article")!, allowed: { _ in true })
        #expect(page.title == "Public page" && page.text == "Useful text.")
        let sent = try #require(LinkPreviewURLProtocol.requests.values.first)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil && sent.value(forHTTPHeaderField: "Authorization") == nil)
        LinkPreviewURLProtocol.requests.reset()
        await #expect(throws: CancellationError.self) {
            try await loader.load(URL(string: "https://preview.test/redirect")!, allowed: { $0.path != "/blocked" })
        }
        #expect(LinkPreviewURLProtocol.requests.values.map { $0.url?.path } == ["/redirect"])
        await #expect(throws: BrowserAIError.failed) {
            try await loader.load(URL(string: "https://preview.test/file")!, allowed: { _ in true })
        }
        await #expect(throws: BrowserAIError.failed) {
            try await loader.load(URL(string: "https://preview.test/oversized")!, allowed: { _ in true })
        }
    }
}

private final class LinkPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        var values: [URLRequest] { lock.withLock { stored } }
        func reset() { lock.withLock { stored = [] } }
        func record(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    }
    static let requests = Requests()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "preview.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.record(request)
        let url = request.url!
        var headers = ["Content-Type": url.path == "/file" ? "application/pdf" : "text/html"]
        if url.path == "/redirect" { headers["Location"] = "https://preview.test/blocked" }
        if url.path == "/oversized" { headers["Content-Length"] = "999999" }
        let response = HTTPURLResponse(url: url, statusCode: url.path == "/redirect" ? 302 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<title>Public page</title><body>Useful text.</body>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
