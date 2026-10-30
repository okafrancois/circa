import BrowserCore
import Foundation
import Testing

@Test("Domains, IDN, local hosts, IP literals and explicit web URLs resolve as pages")
func resolveWebAddresses() throws {
    let resolver = AddressResolver()
    let inputs = [
        (" example.test/path?q=1#anchor ", "https://example.test/path?q=1#anchor"),
        ("bücher.de", "https://xn--bcher-kva.de"),
        ("localhost:8080/first", "http://localhost:8080/first"),
        ("127.0.0.1:4318", "http://127.0.0.1:4318"),
        ("[::1]:8080/first", "http://[::1]:8080/first"),
        ("printer:8080/status", "http://printer:8080/status"),
        ("http://example.test/a", "http://example.test/a"),
        ("https://example.test/a b", "https://example.test/a%20b")
    ]
    for (input, expected) in inputs {
        #expect(try resolver.resolve(input) == .page(URL(string: expected)!))
    }
}

@Test("Queries keep their exact text and use the selected search engine without query injection")
func resolveSearchQueries() throws {
    for engine in SearchEngine.allCases {
        let resolver = AddressResolver(searchEngine: engine)
        for query in ["two words", "123", "C++", "Swift: actors", "weather: Paris", "site:example.test term", "a & b # café"] {
            guard case .search(let url, let original) = try resolver.resolve(query) else {
                Issue.record("Expected a search destination")
                continue
            }
            #expect(original == query)
            #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: query)])
            #expect(!url.absoluteString.contains("+"))
        }
        guard case .search(_, let forced) = try resolver.resolve("? example.test") else {
            Issue.record("Expected forced search")
            continue
        }
        #expect(forced == "example.test")
    }
}

@Test("Unsafe schemes, embedded credentials, blank input and invalid ports are rejected")
func rejectUnsafeAddresses() {
    let resolver = AddressResolver()
    for input in ["javascript:alert(1)", "javascript:123", "data:text/html,example", "chrome://extensions", "mailto:test@example.test"] {
        #expect(throws: AddressResolutionError.unsupportedScheme) { try resolver.resolve(input) }
    }
    #expect(throws: AddressResolutionError.credentialsNotAllowed) {
        try resolver.resolve("https://synthetic:password@example.test")
    }
    for input in ["", " \n\t", "? "] {
        #expect(throws: AddressResolutionError.emptyInput) { try resolver.resolve(input) }
    }
    #expect(throws: AddressResolutionError.invalidAddress) { try resolver.resolve("http://example.test:65536") }
}
