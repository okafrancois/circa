import Foundation
import Testing
@testable import BrowserCore

@Suite("Authentication transaction model only")
struct OrbitAuthenticationTransactionTests {
    private func transaction() throws -> ArcAuthenticationTransaction {
        try ArcAuthenticationTransaction(targetProfiles: [ProfileID()], verificationDeadline: 2000)
    }

    @Test("Planned verification restart is distinct from interrupted applying")
    func restartPhases() throws {
        var model = try transaction()
        #expect(model.startupPermission(now: 1000) == .discardPreparationBeforeCEF)
        try model.recordModelEvent(.backupDurable)
        #expect(model.startupPermission(now: 1000) == .recoverBeforeCEF)
        try model.recordModelEvent(.beginApply)
        #expect(model.startupPermission(now: 1000) == .recoverBeforeCEF)
        try model.recordModelEvent(.awaitRestartVerification)
        let reloaded = try JSONDecoder().decode(ArcAuthenticationTransaction.self, from: JSONEncoder().encode(model))
        #expect(reloaded == model)
        #expect(reloaded.startupPermission(now: 1000) == .verifierOnly(transaction: model.id, targets: model.targetProfiles))
        #expect(model.startupPermission(now: 2000) == .recoverBeforeCEF)
        #expect(model.startupPermission(now: 1000, cancelled: true) == .recoverBeforeCEF)
        #expect(model.startupPermission(now: 0) == .recoverBeforeCEF)
        #expect(throws: ArcAuthenticationError.invalidTransition) { try model.recordModelEvent(.claimVerifier, now: 2000) }
        #expect(model.phase == .verificationPending)
        try model.recordModelEvent(.claimVerifier, now: 1000)
        #expect(model.startupPermission(now: 1000) == .recoverBeforeCEF)
        #expect(throws: ArcAuthenticationError.invalidTransition) { try model.recordModelEvent(.claimVerifier) }
        #expect(throws: ArcAuthenticationError.invalidTransition) { try model.recordModelEvent(.verificationSucceeded, now: 2000) }
        try model.recordModelEvent(.verificationSucceeded, now: 1000)
        #expect(model.startupPermission(now: 3000) == .finishCommittedCleanupBeforeCEF)
        #expect(throws: ArcAuthenticationError.invalidTransition) { try model.recordModelEvent(.verificationSucceeded) }
        #expect(throws: ArcAuthenticationError.invalidTransition) { try model.recordModelEvent(.rollbackCompleted) }
    }

    @Test("Every incomplete phase allows conservative rollback and disables real mutations")
    func rollback() throws {
        let events: [ArcAuthenticationTransaction.Event] = [.backupDurable, .beginApply, .awaitRestartVerification, .claimVerifier]
        for prefix in 0...events.count {
            var model = try transaction()
            for event in events.prefix(prefix) { try model.recordModelEvent(event, now: 1000) }
            #expect(throws: ArcAuthenticationError.realMutationDisabled) { try model.authorizeRealMutation() }
            try model.recordModelEvent(.rollbackCompleted)
            #expect(model.startupPermission(now: 1000) == .normal)
            #expect(throws: ArcAuthenticationError.invalidTransition) { try model.recordModelEvent(.beginApply) }
        }
    }

    @Test("Illegal transitions never modify state")
    func invalidTransitions() throws {
        var model = try transaction()
        for event in [ArcAuthenticationTransaction.Event.beginApply, .awaitRestartVerification, .claimVerifier, .verificationSucceeded] {
            #expect(throws: ArcAuthenticationError.invalidTransition) { try model.recordModelEvent(event) }
            #expect(model.phase == .prepared)
        }
        #expect(throws: ArcAuthenticationError.invalidTransition) {
            try ArcAuthenticationTransaction(targetProfiles: [], verificationDeadline: 2000)
        }
    }

    @Test("Unknown and corrupt journals refuse decoding instead of permitting startup")
    func corruptJournal() throws {
        let original = try JSONEncoder().encode(transaction())
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["version"] = 2
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ArcAuthenticationTransaction.self, from: JSONSerialization.data(withJSONObject: object))
        }
        object["version"] = 1; object["phase"] = "unrecognized"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ArcAuthenticationTransaction.self, from: JSONSerialization.data(withJSONObject: object))
        }
        object["phase"] = "verificationPending"; object["targetProfiles"] = []
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ArcAuthenticationTransaction.self, from: JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ArcAuthenticationTransaction.self, from: original.dropLast()) }
        object["phase"] = "synthetic-secret-sentinel"
        #expect(throws: ArcAuthenticationError.invalidTransition) {
            try ArcAuthenticationTransaction.decodeJournalModel(JSONSerialization.data(withJSONObject: object))
        }
        #expect(throws: ArcAuthenticationError.sizeLimit) { try ArcAuthenticationTransaction.decodeJournalModel(Data(repeating: 32, count: 32_769)) }
    }
}

@Suite("Explicit authentication profile mapping")
struct OrbitAuthenticationProfileMappingTests {
    @Test("Same source directory in separate registrations stays isolated; unmapped C has no fallback")
    func isolation() throws {
        let registration = UUID()
        let a = try ArcAuthenticationSourceProfile(registration: registration, profile: .directory("Default"))
        let b = try ArcAuthenticationSourceProfile(registration: UUID(), profile: .directory("Default"))
        let c = try ArcAuthenticationSourceProfile(registration: registration, profile: .directory("Profile 1"))
        let targetA = ProfileID(); let targetB = ProfileID()
        let mapping = try ArcAuthenticationProfileMapping(explicitFreshTargets: [(a, targetA), (b, targetB)])
        #expect(try mapping.target(for: a) == targetA)
        #expect(try mapping.target(for: b) == targetB)
        #expect(throws: ArcAuthenticationError.invalidMapping) { try mapping.target(for: c) }
        #expect(throws: ArcAuthenticationError.invalidMapping) {
            try ArcAuthenticationProfileMapping(explicitFreshTargets: [(a, targetA), (b, targetA)])
        }
        #expect(throws: ArcAuthenticationError.invalidMapping) {
            try ArcAuthenticationProfileMapping(explicitFreshTargets: [(a, targetA), (a, targetB)])
        }
    }

    @Test("Unresolved, traversal, neutral and inferred names cannot acquire authentication")
    func invalidProfiles() throws {
        for key in [ArcProfileKey.unresolved("opaque"), .directory("../Default"), .directory(""),
                    .directory("neutral"), .directory("Profile 01"), .directory("Profile 0"), .directory("Profile 1/child")] {
            #expect(throws: ArcAuthenticationError.invalidMapping) {
                try ArcAuthenticationSourceProfile(registration: UUID(), profile: key)
            }
        }
        #expect(throws: ArcAuthenticationError.invalidMapping) { try ArcAuthenticationProfileMapping(explicitFreshTargets: []) }
    }
}
