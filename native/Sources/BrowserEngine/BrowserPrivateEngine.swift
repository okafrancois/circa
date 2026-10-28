import BrowserCore

/// An admission query that must not create a profile or access secure storage. This is an
/// engine-instance policy, not a private-window sharing policy or a claim of Orbit feature equivalence.
@MainActor
public protocol BrowserPrivateEngine: BrowserEngine {
    var persistence: BrowserWebsiteDataPersistence { get }
    /// Creates and awaits this scope's memory-only context, or throws without falling back.
    func preparePrivateProfile(_ profileID: ProfileID) async throws
    /// Finishes a single-profile private scope, then calls removeProfile. Engines with native
    /// logical windows must await those owners too. This must never quit a shared runtime.
    func releasePrivateProfile(_ profileID: ProfileID) async throws
}

public extension BrowserPrivateEngine {
    func releasePrivateProfile(_ profileID: ProfileID) async throws {
        guard persistence == .ephemeral else { throw BrowserEngineError.unsupportedOperation }
        try await removeProfile(profileID)
    }
    func preparePrivateProfile(_ profileID: ProfileID) async throws {
        guard persistence == .ephemeral else { throw BrowserEngineError.unsupportedOperation }
        let descriptor = profile(for: profileID)
        guard descriptor.profileID == profileID, descriptor.persistence == .ephemeral else {
            throw BrowserEngineError.unsupportedOperation
        }
    }
}
