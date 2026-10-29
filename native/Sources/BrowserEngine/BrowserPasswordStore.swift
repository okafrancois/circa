import BrowserCore
import Foundation

/// Chromium's durable composite identity, scoped to one profile. Changing any
/// field changes the key. Local row numbers are deliberately not portable.
public struct BrowserPasswordKey: Hashable, Sendable {
    public var signonRealm: String
    public var originURL: String
    public var usernameElement: String
    public var usernameValue: String
    public var passwordElement: String

    public init(signonRealm: String, originURL: String, usernameElement: String,
                usernameValue: String, passwordElement: String) {
        self.signonRealm = signonRealm; self.originURL = originURL
        self.usernameElement = usernameElement; self.usernameValue = usernameValue
        self.passwordElement = passwordElement
    }
}

/// In-memory only. Never serialize into diagnostics or ordinary sync payloads.
/// Swift String copies cannot be reliably erased; consumers should release results
/// promptly. Bridge-owned temporary password buffers are erased after each call.
public struct BrowserPasswordRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var primaryKey: BrowserPasswordKey
    public var actionURL: String
    public var passwordValue: String
    /// Exact Chromium microseconds since 1601 UTC; zero means unset.
    public var dateCreated: Int64
    public var dateLastUsed: Int64
    public var datePasswordModified: Int64
    public var blockedByUser: Bool
    /// Persisted Chromium scheme: HTML=0, Basic=1, Digest=2, Other=3, username-only=4.
    public var scheme: Int32

    public init(primaryKey: BrowserPasswordKey, actionURL: String = "", passwordValue: String = "",
                dateCreated: Int64 = 0, dateLastUsed: Int64 = 0, datePasswordModified: Int64 = 0,
                blockedByUser: Bool = false, scheme: Int32 = 0) {
        self.primaryKey = primaryKey; self.actionURL = actionURL; self.passwordValue = passwordValue
        self.dateCreated = dateCreated; self.dateLastUsed = dateLastUsed
        self.datePasswordModified = datePasswordModified; self.blockedByUser = blockedByUser
        self.scheme = scheme
    }
    public var description: String { "BrowserPasswordRecord(<redacted>)" }
    public var debugDescription: String { description }
}

public enum BrowserPasswordStoreError: Error, Equatable, Sendable {
    case unavailable, backendFailure, cancelled, conflict
}

public enum BrowserPasswordStoreChange: Sendable, Equatable {
    /// Re-list after either notification; some Chromium backends omit removal details.
    case changed, retained, closed
}

/// Profile-scoped asynchronous access to the engine's own password store. Private
/// engines expose no host. No disk access, parallel vault, or synchronization.
/// Closing a profile cancels pending callbacks, not backend writes already accepted.
/// A cancelled writer must re-list before retrying. Updates preserve unexposed native
/// metadata; newly added records cannot restore notes, federation or sharing metadata.
@MainActor
public protocol BrowserPasswordStore: AnyObject, Sendable {
    func list(profileID: ProfileID) async throws -> [BrowserPasswordRecord]
    func add(_ record: BrowserPasswordRecord, profileID: ProfileID) async throws
    func update(_ record: BrowserPasswordRecord, replacing key: BrowserPasswordKey, profileID: ProfileID) async throws
    func remove(_ key: BrowserPasswordKey, profileID: ProfileID) async throws
    func changes(profileID: ProfileID) async throws -> AsyncStream<BrowserPasswordStoreChange>
}
