import BrowserCore

public struct BrowserBoostProfilePayload: Equatable, Sendable {
    public let profileID: ProfileID
    /// Monotonic registry generation, including preference changes and removals.
    public let revision: UInt64
    public let boosts: [BrowserCompiledBoost]

    public init(profileID: ProfileID, revision: UInt64, boosts: [BrowserCompiledBoost]) {
        self.profileID = profileID
        self.revision = revision
        self.boosts = boosts
    }
}

public struct BrowserBoostAcknowledgement: Equatable, Sendable {
    public let profileID: ProfileID
    public let revision: UInt64
    public init(profileID: ProfileID, revision: UInt64) {
        self.profileID = profileID
        self.revision = revision
    }
}

/// Browser-owned per-profile document-start registrations, never a DevTools emulation.
/// CSS insertion/removal and isolated JS must reach new renderers and eligible local frames
/// before navigation. JS has DOM access only, no native/extension bindings or origin bypass.
/// JS executes once per document; changing/removing a registration cannot undo its side effects.
/// Acknowledgement confirms registry installation, not reversal of JS or a live preview paint.
@MainActor
public protocol BrowserBoostHost: AnyObject {
    /// Atomically registers/updates a whole profile snapshot and removes omitted Boosts.
    /// Array order defines CSS cascade order. Reject stale generations; an identical retry
    /// may acknowledge the same generation. Per-Boost revisions identify compiled content.
    func replaceBoosts(_ payload: BrowserBoostProfilePayload) async throws -> BrowserBoostAcknowledgement
    /// Clears registrations and retains a generation tombstone to reject delayed updates.
    func removeBoosts(profileID: ProfileID, revision: UInt64) async throws -> BrowserBoostAcknowledgement
}

/// In-memory protocol fake. No rendering, script execution or persistence claims.
@MainActor
public final class BrowserFakeBoostHost: BrowserBoostHost {
    public private(set) var profiles: [ProfileID: BrowserBoostProfilePayload] = [:]
    public init() {}

    public func replaceBoosts(_ payload: BrowserBoostProfilePayload) async throws -> BrowserBoostAcknowledgement {
        guard payload.revision > 0 else { throw BrowserBoostError.staleRevision }
        if let current = profiles[payload.profileID] {
            guard payload.revision > current.revision || payload == current else { throw BrowserBoostError.staleRevision }
            let previous = Dictionary(uniqueKeysWithValues: current.boosts.map { ($0.id, $0) })
            for boost in payload.boosts {
                if let old = previous[boost.id] {
                    guard boost.revision > old.revision || boost == old else { throw BrowserBoostError.staleRevision }
                }
            }
        }
        guard payload.boosts.count <= BrowserBoostCompiler.maximumBoosts,
              Set(payload.boosts.map(\.id)).count == payload.boosts.count,
              payload.boosts.reduce(0, { $0 + $1.css.utf8.count + ($1.isolatedJavaScript?.utf8.count ?? 0) })
                <= BrowserBoostCompiler.maximumCompiledBytes else { throw BrowserBoostError.limitExceeded }
        profiles[payload.profileID] = payload
        return BrowserBoostAcknowledgement(profileID: payload.profileID, revision: payload.revision)
    }

    public func removeBoosts(profileID: ProfileID, revision: UInt64) async throws -> BrowserBoostAcknowledgement {
        try await replaceBoosts(.init(profileID: profileID, revision: revision, boosts: []))
    }
}
