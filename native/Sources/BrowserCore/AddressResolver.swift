import Foundation

public enum SearchEngine: String, Codable, Sendable, CaseIterable {
    case google
    case duckDuckGo
    case bing

    public func searchURL(for query: String) -> URL {
        let base: String
        switch self {
        case .google: base = "https://www.google.com/search"
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .bing: base = "https://www.bing.com/search"
        }
        var components = URLComponents(string: base)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

public enum AddressResolutionError: Error, Equatable, Sendable {
    case emptyInput
    case unsupportedScheme
    case credentialsNotAllowed
    case invalidAddress
}

public enum AddressDestination: Equatable, Sendable {
    case page(URL)
    case search(URL, query: String)

    public var url: URL {
        switch self {
        case .page(let url), .search(let url, _): return url
        }
    }
}

/// Parses explicit web URLs and local authorities; other text becomes a search query.
public struct AddressResolver: Sendable {
    public var searchEngine: SearchEngine

    public init(searchEngine: SearchEngine = .google) { self.searchEngine = searchEngine }

    public func resolve(_ text: String) throws -> AddressDestination {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw AddressResolutionError.emptyInput }
        if input.hasPrefix("?") {
            return try search(String(input.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if input.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil {
            return .page(try webURL(input))
        }
        if let scheme = URLComponents(string: input)?.scheme?.lowercased(),
           ["http", "https", "javascript", "data", "file", "about", "chrome", "mailto", "tel", "ftp"].contains(scheme) {
            throw AddressResolutionError.unsupportedScheme
        }
        let authority = String(input.prefix { !["/", "?", "#"].contains($0) })
        let host = authority.hasPrefix("[")
            ? String(authority.prefix { $0 != "]" }.dropFirst())
            : String(authority.split(separator: ":", maxSplits: 1).first ?? "")
        let numericPort = authority.contains(":") && authority.split(separator: ":").last.flatMap { UInt16($0) } != nil
        let looksLocal = host.lowercased() == "localhost" || host.lowercased().hasSuffix(".localhost")
            || authority.hasPrefix("[") || numericPort
        let looksLikeHost = host.contains(".") || looksLocal
        if looksLikeHost && !authority.contains(where: \.isWhitespace) {
            let scheme = looksLocal || host.split(separator: ".").allSatisfy({ UInt8($0) != nil }) ? "http" : "https"
            return .page(try webURL("\(scheme)://\(input)"))
        }
        return try search(input)
    }

    private func search(_ query: String) throws -> AddressDestination {
        guard !query.isEmpty else { throw AddressResolutionError.emptyInput }
        return .search(searchEngine.searchURL(for: query), query: query)
    }

    private func webURL(_ input: String) throws -> URL {
        guard let components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { throw AddressResolutionError.unsupportedScheme }
        guard components.user == nil, components.password == nil else {
            throw AddressResolutionError.credentialsNotAllowed
        }
        guard let host = components.host, !host.isEmpty, !host.contains(where: \.isWhitespace),
              components.port == nil || (1...65535).contains(components.port!),
              let url = components.url
        else { throw AddressResolutionError.invalidAddress }
        return url
    }
}
