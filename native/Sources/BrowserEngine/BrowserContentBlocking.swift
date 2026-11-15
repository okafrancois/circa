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
/// has not configured, or configured as disabled, is never filtered. Private stores have none of
/// their own: all private windows share one memory-only configuration owned by the normal engine.
@MainActor
public protocol BrowserContentBlocking: AnyObject {
    /// Replaces the profile's whole configuration. With `waitsForAcknowledgement`, returns once
    /// the engine confirms that an enabled configuration is in place, or after a short bound.
    /// Disabling takes effect before returning.
    func configure(_ configuration: BrowserContentBlockingConfiguration, profileID: ProfileID,
                   waitsForAcknowledgement: Bool) async throws
    /// Whether private windows can be filtered (`configurePrivateWindows`).
    var supportsPrivateWindows: Bool { get }
    /// Readies private filtering; call before creating a private window's context.
    func preparePrivateWindows() async throws
    /// Replaces the configuration of every open private context, with the same contract as
    /// `configure`, except that disabling also waits when asked. Nothing of it reaches disk.
    func configurePrivateWindows(_ configuration: BrowserContentBlockingConfiguration,
                                 waitsForAcknowledgement: Bool) async throws
    /// No private window remains: the engine forgets the session's rules.
    func endPrivateWindowSession()
}

/// In-memory protocol fake. No request filtering claims.
@MainActor
public final class BrowserFakeContentBlocking: BrowserContentBlocking {
    public private(set) var configurations: [ProfileID: BrowserContentBlockingConfiguration] = [:]
    public private(set) var configureCount = 0
    public private(set) var privateConfiguration: BrowserContentBlockingConfiguration?
    public private(set) var privateConfigureCount = 0
    public var supportsPrivateWindows = true
    public var failure: (any Error)?
    public init() {}

    public private(set) var preparedPrivateWindows = 0
    public private(set) var endedPrivateSessions = 0

    public func preparePrivateWindows() async throws {
        guard supportsPrivateWindows else { throw BrowserEngineError.unsupportedOperation }
        if let failure { throw failure }
        preparedPrivateWindows += 1
    }

    public func configurePrivateWindows(_ configuration: BrowserContentBlockingConfiguration,
                                        waitsForAcknowledgement: Bool) async throws {
        guard supportsPrivateWindows else { throw BrowserEngineError.unsupportedOperation }
        if let failure { throw failure }
        privateConfigureCount += 1
        privateConfiguration = configuration
    }

    public func endPrivateWindowSession() {
        endedPrivateSessions += 1
        privateConfiguration = nil
    }

    public func configure(_ configuration: BrowserContentBlockingConfiguration, profileID: ProfileID,
                          waitsForAcknowledgement: Bool) async throws {
        if let failure { throw failure }
        configureCount += 1
        configurations[profileID] = configuration
    }
}
