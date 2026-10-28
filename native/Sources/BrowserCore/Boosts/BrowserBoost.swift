import Foundation

public struct BrowserBoostID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public enum BrowserBoostError: Error, Equatable, Sendable {
    case invalidHostPattern, invalidContent, limitExceeded, unsupportedVersion, wrongProfile
    case duplicateID, staleRevision, revisionExhausted, unavailable
}

/// Host scope, never a URL glob. Orbit policy: exact ASCII DNS host, HTTPS and default
/// port unless explicitly expanded. Paths/query/fragments do not restrict a host scope.
/// No inherited effective origin: blank/srcdoc/blob, internal and extension URLs never match.
public struct BrowserBoostHostPattern: Codable, Equatable, Sendable {
    public enum Scheme: String, Codable, Sendable { case http, https }
    public var host: String
    public var includesSubdomains: Bool
    public var schemes: Set<Scheme>
    /// Nil accepts only each selected scheme's default port; a value accepts only that port.
    public var port: Int?

    public init(host: String, includesSubdomains: Bool = false,
                schemes: Set<Scheme> = [.https], port: Int? = nil) throws {
        self.host = host.lowercased()
        self.includesSubdomains = includesSubdomains
        self.schemes = schemes
        self.port = port
        try validate()
    }

    func validate() throws {
        guard Self.isHost(host), host == host.lowercased(), !schemes.isEmpty,
              port.map({ (1...65535).contains($0) }) ?? true else {
            throw BrowserBoostError.invalidHostPattern
        }
        // IP addresses are exact-only. IPv6 literals and Unicode must be supplied through
        // a later explicit policy; ASCII punycode DNS labels are accepted as written.
        if includesSubdomains, host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            throw BrowserBoostError.invalidHostPattern
        }
    }

    static func isHost(_ host: String) -> Bool {
        guard (1...253).contains(host.utf8.count) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
}

/// Stored intentions only. Numeric colour mapping/ranges and rendering are deliberately
/// unspecified; absent fields preserve the original page rather than inventing defaults.
public struct BrowserBoostColorScheme: Codable, Equatable, Sendable {
    public enum Appearance: String, Codable, Sendable { case light, dark }
    public enum Source: String, Codable, Sendable { case themeDriven, colorWheelDriven }
    public var source: Source?
    public var appearance: Appearance?
    public var hue: Double?
    public var saturation: Double?
    public var invertLightness: Bool?
    public init() {}
}

public struct BrowserBoostContent: Codable, Equatable, Sendable {
    public enum TextTransform: String, Codable, Sendable { case capitalize, uppercase, lowercase }
    public var colorScheme: BrowserBoostColorScheme?
    public var fontFamily: String?
    /// Root font-size multiplier, not engine page zoom. Orbit policy bounds: 0.25...5.
    public var textZoom: Double?
    public var textTransform: TextTransform?
    public var zapSelectors: [String] = []
    public var customCSS = ""
    public var customJavaScript = ""
    public init() {}
}

public struct BrowserBoost: Codable, Equatable, Sendable {
    public let id: BrowserBoostID
    public var title: String
    public var hostPattern: BrowserBoostHostPattern
    public var isEnabled: Bool
    public internal(set) var revision: UInt64
    public var content: BrowserBoostContent
    /// Device-local explicit consent. Never inferred from the presence of script bytes.
    public var javaScriptOptIn: Bool

    public init(id: BrowserBoostID = .init(), title: String, hostPattern: BrowserBoostHostPattern,
                isEnabled: Bool = true, content: BrowserBoostContent = .init(), javaScriptOptIn: Bool = false) {
        self.id = id
        self.title = title
        self.hostPattern = hostPattern
        self.isEnabled = isEnabled
        revision = 1
        self.content = content
        self.javaScriptOptIn = javaScriptOptIn
    }
}
