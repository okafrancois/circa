import AppKit
import BrowserCore
import Foundation
import Testing
@testable import Orbit

class SuggestionURLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var stops = 0
        func reset() { lock.withLock { requests = []; stops = 0 } }
        var captured: [URLRequest] { lock.withLock { requests } }
        var cancellations: Int { lock.withLock { stops } }
    }
    private static let sharedState = State()
    class var state: State { sharedState }
    private var job: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.withLock { Self.state.requests.append(request) }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { ["q", "query"].contains($0.name) }!.value!
        let work = DispatchWorkItem { [self] in
            let data = try! JSONSerialization.data(withJSONObject: [query, [query + " guide", query + " news"]])
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        job = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (query == "slow" ? 0.4 : 0.01), execute: work)
    }
    override func stopLoading() { job?.cancel(); Self.state.lock.withLock { Self.state.stops += 1 } }

    @MainActor static func service(debounce: Duration = .milliseconds(30)) -> BrowserSearchSuggestions {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [self]
        return BrowserSearchSuggestions(configuration: configuration, debounce: debounce, endpoint: { $0.suggestionURL(for: $1) })
    }
}

@Suite("Remote search suggestions", .serialized)
@MainActor
struct SearchSuggestionTests {
    @Test("All built-in engines encode only the query and required response format")
    func engineURLs() throws {
        let query = "café + tea & 東京?#"
        for (engine, host, path, extra) in [(SearchEngine.google, "suggestqueries.google.com", "/complete/search", "client"),
                                          (.duckDuckGo, "duckduckgo.com", "/ac/", "type"), (.bing, "www.bing.com", "/osjson.aspx", "")] {
            let url = try #require(engine.suggestionURL(for: query))
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(parts.scheme == "https" && parts.host == host && parts.path == path)
            let queryKey = engine == .bing ? "query" : "q"
            #expect(parts.queryItems?.first { $0.name == queryKey }?.value == query)
            #expect(Set(parts.queryItems!.map(\.name)) == (extra.isEmpty ? [queryKey] : [queryKey, extra]))
            #expect(parts.user == nil && parts.password == nil && parts.fragment == nil)
        }
    }

    @Test("OpenSearch parsing rejects malformed, mismatched and oversized responses and bounds distinct text")
    func parsing() throws {
        func parse(_ object: Any) throws -> [String] { BrowserSearchSuggestions.parse(try JSONSerialization.data(withJSONObject: object), query: "orbit") }
        #expect(try parse(["orbit", [" Orbit guide ", "ORBIT GUIDE", "", "orbit news"], [], [:]]) == ["Orbit guide", "orbit news"])
        #expect(try parse(["different", ["orbit guide"]]).isEmpty)
        #expect(try parse(["orbit", [1]]).isEmpty)
        #expect(try parse(["orbit"]).isEmpty)
        #expect(BrowserSearchSuggestions.parse(Data("bad json".utf8), query: "orbit").isEmpty)
        #expect(try parse(["orbit", [String(repeating: "a", count: 70_000)]]).isEmpty)
        #expect(try parse(["orbit", (0..<20).map { "orbit \($0)" }]).count == 8)
    }

    @Test("Debounce replaces drafts, cancels in-flight work, and sends no cookies or credentials")
    func debounceAndCancel() async throws {
        SuggestionURLProtocol.state.reset()
        let service = SuggestionURLProtocol.service(debounce: .milliseconds(60)), profile = ProfileID()
        func update(_ text: String) { service.update(query: text, engine: .google, profileID: profile, enabled: true, isPrivate: false) }
        update("o"); update("or"); update("orbit")
        #expect(SuggestionURLProtocol.state.captured.isEmpty)
        await service.waitForResults()
        #expect(SuggestionURLProtocol.state.captured.count == 1)
        #expect(service.values == ["orbit guide", "orbit news"])
        let request = try #require(SuggestionURLProtocol.state.captured.first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
        #expect(!request.httpShouldHandleCookies && request.timeoutInterval == 2)
        update("slow")
        try await Task.sleep(for: .milliseconds(110))
        update("new")
        await service.waitForResults()
        try await Task.sleep(for: .milliseconds(420))
        #expect(service.values == ["new guide", "new news"])
        #expect(SuggestionURLProtocol.state.cancellations >= 1)
        service.cancel()
    }

    @Test("Empty input, URLs, private windows, disabled settings and unsupported endpoints make no requests")
    func suppression() async throws {
        SuggestionURLProtocol.state.reset()
        let service = SuggestionURLProtocol.service(), profile = ProfileID()
        for query in ["", "   ", "https://example.test/private", "example.test", "localhost:8000", "file:///tmp/test", "data:text/plain,test"] {
            service.update(query: query, engine: .bing, profileID: profile, enabled: true, isPrivate: false)
            await service.waitForResults()
        }
        service.update(query: "private draft", engine: .google, profileID: profile, enabled: true, isPrivate: true)
        await service.waitForResults()
        service.update(query: "disabled draft", engine: .google, profileID: profile, enabled: false, isPrivate: false)
        await service.waitForResults()
        let unsupported = BrowserSearchSuggestions(debounce: .zero, endpoint: { _, _ in nil })
        unsupported.update(query: "draft", engine: .google, profileID: profile, enabled: true, isPrivate: false)
        await unsupported.waitForResults()
        #expect(SuggestionURLProtocol.state.captured.isEmpty)
        service.update(query: "slow", engine: .google, profileID: profile, enabled: true, isPrivate: false)
        try await Task.sleep(for: .milliseconds(75))
        service.update(query: "slow", engine: .google, profileID: profile, enabled: false, isPrivate: false)
        try await Task.sleep(for: .milliseconds(450))
        #expect(service.values.isEmpty)
    }

    @Test("Local rows remain first, remote duplicates disappear, and hidden text stays hidden after reopening")
    func mergingAndHiding() async throws {
        SuggestionURLProtocol.state.reset()
        let local = [BrowserPaletteResult(id: "local", title: "Orbit guide", detail: "", section: .history, action: .navigate(URL(string: "https://example.test")!)),
                     BrowserPaletteResult(id: "search", title: "orbit", detail: "", section: .search, action: .navigate(SearchEngine.google.searchURL(for: "orbit")))]
        let merged = BrowserPaletteRanking.merging(["orbit", "orbit guide", "orbit news", "ORBIT NEWS"], into: local, engine: .google)
        #expect(merged.map(\.title) == ["Orbit guide", "orbit news", "orbit"])
        #expect(merged[1].remoteSuggestion == "orbit news")
        let service = SuggestionURLProtocol.service(), profile = ProfileID()
        service.update(query: "orbit", engine: .google, profileID: profile, enabled: true, isPrivate: false)
        await service.waitForResults()
        service.hide("orbit news", engine: .google)
        service.cancel()
        service.update(query: "orbit", engine: .google, profileID: profile, enabled: true, isPrivate: false)
        await service.waitForResults()
        #expect(service.values == ["orbit guide"])
    }

    @Test("The profile toggle defaults on for older settings and persists off")
    func preference() throws {
        let legacy = Data(#"{"searchEngine":"google","opensPinnedLinksInPeek":true,"shiftClickOpensPeek":true}"#.utf8)
        var settings = try JSONDecoder().decode(BrowserProfileSettings.self, from: legacy)
        #expect(settings.showSearchSuggestions)
        settings.showSearchSuggestions = false
        #expect(try !JSONDecoder().decode(BrowserProfileSettings.self, from: JSONEncoder().encode(settings)).showSearchSuggestions)
    }
}

final class PaletteSuggestionURLProtocol: SuggestionURLProtocol, @unchecked Sendable {
    private static let paletteState = State()
    override class var state: State { paletteState }
}
