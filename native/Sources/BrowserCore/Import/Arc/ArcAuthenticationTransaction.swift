import Foundation

/// Versioned production *state model*. No durable writer, backup envelope or product startup
/// integration exists in this lot. Advancing this value does not perform or prove an operation.
public struct ArcAuthenticationTransaction: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case prepared, backupDurable, applying, verificationPending, verifying, complete, rolledBack
    }
    public enum Event: Sendable {
        case backupDurable, beginApply, awaitRestartVerification, claimVerifier, verificationSucceeded, rollbackCompleted
    }
    public enum StartupPermission: Equatable, Sendable {
        case discardPreparationBeforeCEF
        case recoverBeforeCEF
        case verifierOnly(transaction: UUID, targets: Set<ProfileID>)
        case finishCommittedCleanupBeforeCEF
        case normal
    }

    public let version: Int
    public let id: UUID
    public let targetProfiles: Set<ProfileID>
    public let verificationDeadline: Int64
    public private(set) var phase: Phase

    public init(id: UUID = UUID(), targetProfiles: Set<ProfileID>, verificationDeadline: Int64) throws {
        guard !targetProfiles.isEmpty, targetProfiles.count <= 64,
              (1...253_402_300_799).contains(verificationDeadline) else { throw ArcAuthenticationError.invalidTransition }
        self.version = 1; self.id = id; self.targetProfiles = targetProfiles
        self.verificationDeadline = verificationDeadline; self.phase = .prepared
    }

    /// Persist this new state durably *before* taking its next permitted action. A future writer
    /// must bind backup/path/profile identities and lock ownership; this model cannot attest them.
    public mutating func recordModelEvent(_ event: Event, now: Int64? = nil) throws {
        switch (phase, event) {
        case (.prepared, .backupDurable): phase = .backupDurable
        case (.backupDurable, .beginApply): phase = .applying
        case (.applying, .awaitRestartVerification): phase = .verificationPending
        case (.verificationPending, .claimVerifier):
            guard let now, now > 0, now < verificationDeadline else { throw ArcAuthenticationError.invalidTransition }
            phase = .verifying
        case (.verifying, .verificationSucceeded):
            guard let now, now > 0, now < verificationDeadline else { throw ArcAuthenticationError.invalidTransition }
            phase = .complete
        case (.prepared, .rollbackCompleted), (.backupDurable, .rollbackCompleted),
             (.applying, .rollbackCompleted), (.verificationPending, .rollbackCompleted),
             (.verifying, .rollbackCompleted): phase = .rolledBack
        default: throw ArcAuthenticationError.invalidTransition
        }
    }

    /// Contract boundary: after stable product-root lock admission, before ChromiumRuntime.run
    /// (even its reserved initial context). Acquire import-directory lock second, never swap the
    /// root/lock inode. Corrupt/unknown journal must block CEF, never be treated as no journal.
    /// verifierOnly allows these targets and synthetic verifier only: no restored windows,
    /// external URLs, ordinary navigation, workers or extensions. No source key is needed.
    public func startupPermission(now: Int64, cancelled: Bool = false) -> StartupPermission {
        switch phase {
        case .prepared: return .discardPreparationBeforeCEF
        case .backupDurable, .applying, .verifying: return .recoverBeforeCEF
        case .verificationPending:
            guard now > 0, now < verificationDeadline, !cancelled else { return .recoverBeforeCEF }
            return .verifierOnly(transaction: id, targets: targetProfiles)
        case .complete: return .finishCommittedCleanupBeforeCEF
        case .rolledBack: return .normal
        }
    }

    /// Deliberately unconditional until encrypted backup and pre-CEF recovery ship separately.
    public func authorizeRealMutation() throws { throw ArcAuthenticationError.realMutationDisabled }

    /// Bounded admission for a future startup reader. Raw JSONDecoder failures may contain input
    /// strings; collapse them here and in Decodable to a redacted code before leaving this model.
    public static func decodeJournalModel(_ data: Data) throws -> Self {
        guard data.count <= 32_768 else { throw ArcAuthenticationError.sizeLimit }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ArcAuthenticationError.invalidTransition }
    }

    private enum CodingKeys: String, CodingKey { case version, id, targetProfiles, verificationDeadline, phase }
    public init(from decoder: Decoder) throws {
        do {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            guard try fields.decode(Int.self, forKey: .version) == 1 else { throw ArcAuthenticationError.invalidTransition }
            let profiles = try fields.decode([ProfileID].self, forKey: .targetProfiles)
            guard profiles.count <= 64, Set(profiles).count == profiles.count else { throw ArcAuthenticationError.invalidTransition }
            try self.init(id: fields.decode(UUID.self, forKey: .id), targetProfiles: Set(profiles),
                          verificationDeadline: fields.decode(Int64.self, forKey: .verificationDeadline))
            self.phase = try fields.decode(Phase.self, forKey: .phase)
        } catch { throw ArcAuthenticationError.invalidTransition }
    }
}
