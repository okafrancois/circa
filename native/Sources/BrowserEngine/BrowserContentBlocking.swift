import BrowserCore

/// One persistent profile's built-in ad and tracker blocking.
public struct BrowserContentBlockingConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    /// Hosts, with their subdomains, whose pages are never filtered. Empty while disabled.
    public let allowedHosts: [String]

    /// Hosts are lowercased, deduplicated and sorted; anything but an ASCII host name or IPv4
    /// address is dropped, so a configuration is always valid for the engine.
    public init(isEnabled: Bool, allowedHosts: [String] = []) {
        self.isEnabled = isEnabled
        self.allowedHosts = isEnabled ? Set(allowedHosts.map { $0.lowercased() }.filter(Self.isHost)).sorted() : []
    }

    public static func isHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, !host.hasPrefix("."), !host.hasSuffix("."),
              !host.contains("..") else { return false }
        return host.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-"
        }
    }
}

/// Built-in blocking owned by the engine, never a user-installed extension. A profile the shell
/// has not configured, or configured as disabled, is never filtered. Private stores have none.
@MainActor
public protocol BrowserContentBlocking: AnyObject {
    /// Replaces the profile's whole configuration. With `waitsForAcknowledgement`, returns once
    /// the engine confirms that an enabled configuration is in place, or after a short bound.
    /// Disabling takes effect before returning.
    func configure(_ configuration: BrowserContentBlockingConfiguration, profileID: ProfileID,
                   waitsForAcknowledgement: Bool) async throws
}

/// In-memory protocol fake. No request filtering claims.
@MainActor
public final class BrowserFakeContentBlocking: BrowserContentBlocking {
    public private(set) var configurations: [ProfileID: BrowserContentBlockingConfiguration] = [:]
    public private(set) var configureCount = 0
    public var failure: (any Error)?
    public init() {}

    public func configure(_ configuration: BrowserContentBlockingConfiguration, profileID: ProfileID,
                          waitsForAcknowledgement: Bool) async throws {
        if let failure { throw failure }
        configureCount += 1
        configurations[profileID] = configuration
    }
}
