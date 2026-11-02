import Foundation
import Testing
import BrowserCore
@testable import Orbit

@MainActor struct BrowserSkillsRuntimeTests {
    @Test func permissionRoundTripRevokesQueuedWorkWithoutRevokingModelHandoff() {
        let draft = BrowserSkillDraft()
        var preferences = BrowserAIPreferences()
        preferences.isEnabled = true
        #expect(!draft.reconcilePermissions(preferences))
        let admitted = draft.revokeRevision
        preferences.defaultModels[.chat] = .init(provider: .codex, model: "synthetic")
        #expect(!draft.reconcilePermissions(preferences))
        #expect(draft.revokeRevision == admitted)
        preferences.isEnabled = false
        #expect(draft.reconcilePermissions(preferences))
        preferences.isEnabled = true
        #expect(draft.reconcilePermissions(preferences))
        #expect(draft.revokeRevision == admitted + 2)
        preferences.readsCurrentTabOnRequest = false
        #expect(draft.reconcilePermissions(preferences))
        preferences.disabledSites = ["example.invalid"]
        #expect(draft.reconcilePermissions(preferences))
    }

    @Test func mutationsRefreshBothConsumersAndProfileRemovalRevokesCache() async throws {
        let runtime = BrowserSkillsRuntime()
        let profile = ProfileID(), other = ProfileID()
        let store = try runtime.store(for: profile)
        await runtime.refresh(profile)
        let empty = try #require(runtime.documents[profile])
        let skill = try BrowserAISkill(name: "Synthetic instructions", prompt: "Use three points.", scope: .selectedTabs)
        try await store.save(skill, expected: empty)
        await runtime.refresh(profile)
        #expect(runtime.documents[profile]?.skills == [skill])
        await runtime.refresh(other)
        #expect(runtime.documents[other]?.skills.isEmpty == true)
        try await runtime.removeProfile(profile)
        #expect(runtime.documents[profile] == nil)
        await #expect(throws: BrowserAISkillError.staleRevision) { try await store.save(skill, expected: empty) }
        #expect(throws: BrowserAISkillError.wrongProfile) { try runtime.store(for: profile) }
        #expect(runtime.documents[other] != nil)
    }
}
