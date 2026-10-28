import Foundation

/// An explicit installation registration, never a display name or the structural `arc` namespace.
public struct ArcAuthenticationSourceProfile: Hashable, Sendable, ArcAuthenticationPrivateValue {
    public let registration: UUID
    public let directory: String

    public init(registration: UUID, profile: ArcProfileKey) throws {
        guard case let .directory(directory) = profile else { throw ArcAuthenticationError.invalidMapping }
        let number = directory.hasPrefix("Profile ") ? String(directory.dropFirst(8)) : ""
        guard directory == "Default" || (!number.isEmpty && number.count <= 9 && number.first != "0"
            && number.utf8.allSatisfy { (48...57).contains($0) }) else { throw ArcAuthenticationError.invalidMapping }
        self.registration = registration; self.directory = directory
    }
}

/// Mapping intent only: does not allocate/admit an engine context or prove a directory is empty.
/// A later fresh-profile lane must exclusively create/anchor each target before starting CEF.
public struct ArcAuthenticationProfileMapping: ArcAuthenticationPrivateValue {
    private let targets: [ArcAuthenticationSourceProfile: ProfileID]

    public init(explicitFreshTargets: [(ArcAuthenticationSourceProfile, ProfileID)]) throws {
        guard !explicitFreshTargets.isEmpty, explicitFreshTargets.count <= 64 else { throw ArcAuthenticationError.invalidMapping }
        var targets: [ArcAuthenticationSourceProfile: ProfileID] = [:]
        var uniqueTargets = Set<ProfileID>()
        for (source, target) in explicitFreshTargets {
            guard targets[source] == nil, uniqueTargets.insert(target).inserted else { throw ArcAuthenticationError.invalidMapping }
            targets[source] = target
        }
        self.targets = targets
    }

    public func target(for source: ArcAuthenticationSourceProfile) throws -> ProfileID {
        guard let target = targets[source] else { throw ArcAuthenticationError.invalidMapping }
        return target
    }
}
