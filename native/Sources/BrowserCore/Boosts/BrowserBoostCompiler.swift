import Foundation

public struct BrowserCompiledBoost: Equatable, Sendable {
    public let id: BrowserBoostID
    public let revision: UInt64
    public let hostPattern: BrowserBoostHostPattern
    public let css: String
    public let isolatedJavaScript: String?
}

public enum BrowserBoostCompiler {
    public static let maximumBoosts = 256
    public static let maximumSourceBytes = 64 * 1024
    public static let maximumCompiledBytes = 2 * 1024 * 1024
    // Protect both icon nodes and their descendants from declarative typography overrides.
    private static let textSelector = "*:not(i):not(i *):not(.material-symbols-outlined):not(.material-symbols-outlined *):not(.material-icons):not(.material-icons *)"

    public static func compile(_ boost: BrowserBoost) throws -> BrowserCompiledBoost {
        try boost.hostPattern.validate()
        let content = boost.content
        guard boost.revision > 0, boost.title.utf8.count <= 1024,
              content.customCSS.utf8.count <= maximumSourceBytes,
              content.customJavaScript.utf8.count <= maximumSourceBytes,
              content.zapSelectors.count <= 256 else { throw BrowserBoostError.limitExceeded }
        if let scheme = content.colorScheme {
            guard [scheme.hue, scheme.saturation].allSatisfy({ $0?.isFinite ?? true }) else {
                throw BrowserBoostError.invalidContent
            }
        }
        var rules: [String] = []
        for selector in content.zapSelectors {
            guard validSelector(selector) else { throw BrowserBoostError.invalidContent }
            rules.append(selector + " { display: none !important; }")
        }
        if let font = content.fontFamily {
            guard !font.isEmpty, font.utf8.count <= 256, !font.unicodeScalars.contains(where: { $0.value < 32 }) else {
                throw BrowserBoostError.invalidContent
            }
            // CSS hex escapes terminate with a space, including quotes/backslashes/newlines.
            let escaped = font.unicodeScalars.map { "\\" + String($0.value, radix: 16) + " " }.joined()
            rules.append(textSelector + " { font-family: \"" + escaped + "\" !important; }")
        }
        if let transform = content.textTransform {
            rules.append(textSelector + " { text-transform: " + transform.rawValue + " !important; }")
        }
        if let zoom = content.textZoom {
            guard zoom.isFinite, (0.25...5).contains(zoom) else { throw BrowserBoostError.invalidContent }
            rules.append(":root { font-size: \(zoom * 100)% !important; }")
        }
        // Custom CSS is intentionally unrestricted source and has final cascade order.
        if !content.customCSS.isEmpty { rules.append(content.customCSS) }
        return BrowserCompiledBoost(id: boost.id, revision: boost.revision, hostPattern: boost.hostPattern,
                                    css: rules.joined(separator: "\n"),
                                    isolatedJavaScript: boost.javaScriptOptIn && !content.customJavaScript.isEmpty
                                        ? content.customJavaScript : nil)
    }

    /// Conservative lexical containment, not a CSS parser. Accept complex selectors such as
    /// :has and quoted attributes; malformed selectors fail closed in the engine CSS parser.
    private static func validSelector(_ selector: String) -> Bool {
        guard !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selector.utf8.count <= 2048, !selector.contains("/*"), !selector.contains("*/") else { return false }
        var stack: [Character] = [], quote: Character?, escaped = false
        for character in selector {
            if character.unicodeScalars.contains(where: { $0.value < 32 }), character != " " { return false }
            if "{};@".contains(character) { return false }
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let current = quote { if character == current { quote = nil }; continue }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "(" { stack.append(")") }
            if character == "[" { stack.append("]") }
            if character == ")" || character == "]" {
                guard stack.popLast() == character else { return false }
            }
        }
        return quote == nil && stack.isEmpty && !escaped
    }
}

/// Immutable, bounded snapshot. Lookup only parses a URL and visits its DNS suffixes;
/// no disk, network, regex compilation or shell callback occurs on navigation.
public struct BrowserBoostMatchTable: Sendable {
    public let profileID: ProfileID
    public let payloads: [BrowserCompiledBoost]
    private let hosts: [String: [Int]]

    public init(profileID: ProfileID, boosts: [BrowserBoost]) throws {
        guard boosts.count <= BrowserBoostCompiler.maximumBoosts else { throw BrowserBoostError.limitExceeded }
        guard Set(boosts.map(\.id)).count == boosts.count else { throw BrowserBoostError.duplicateID }
        var payloads: [BrowserCompiledBoost] = [], hosts: [String: [Int]] = [:], bytes = 0
        // Creation order is durable and defines CSS cascade order, independent of dictionary order.
        for boost in boosts {
            let compiled = try BrowserBoostCompiler.compile(boost)
            bytes += compiled.css.utf8.count + (compiled.isolatedJavaScript?.utf8.count ?? 0)
            guard bytes <= BrowserBoostCompiler.maximumCompiledBytes else { throw BrowserBoostError.limitExceeded }
            if boost.isEnabled {
                hosts[compiled.hostPattern.host, default: []].append(payloads.count)
                payloads.append(compiled)
            }
        }
        self.profileID = profileID
        self.payloads = payloads
        self.hosts = hosts
    }

    public func matching(_ url: URL, in profileID: ProfileID, globallyEnabled: Bool = true) -> [BrowserCompiledBoost] {
        guard globallyEnabled, self.profileID == profileID, url.absoluteString.utf8.count <= 16384,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme.flatMap({ BrowserBoostHostPattern.Scheme(rawValue: $0.lowercased()) }),
              components.user == nil, components.password == nil,
              let host = components.encodedHost?.lowercased(), BrowserBoostHostPattern.isHost(host) else { return [] }
        let port = components.port ?? (scheme == .https ? 443 : 80)
        var suffix = host, indices: [Int] = []
        while true {
            for index in hosts[suffix] ?? [] {
                let pattern = payloads[index].hostPattern
                if (suffix == host || pattern.includesSubdomains), pattern.schemes.contains(scheme),
                   port == (pattern.port ?? (scheme == .https ? 443 : 80)) { indices.append(index) }
            }
            guard let dot = suffix.firstIndex(of: ".") else { break }
            suffix = String(suffix[suffix.index(after: dot)...])
        }
        return indices.sorted().map { payloads[$0] }
    }
}
