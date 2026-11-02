import Foundation
import Testing
@testable import BrowserCore

struct BrowserAISkillTests {
    @Test func persistenceAndConcurrentEdits() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/OrbitSkillTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ProfileID()
        let store = try BrowserAISkillStore(profileID: profile, persistence: .profileDirectory(root))
        let empty = await store.snapshot()
        let skill = try BrowserAISkill(name: "Release notes", prompt: "Group this page by feature.")
        try await store.save(skill, expected: empty)
        await #expect(throws: BrowserAISkillError.staleRevision) { try await store.save(skill, expected: empty) }
        let reopened = try BrowserAISkillStore(profileID: profile, persistence: .profileDirectory(root))
        #expect(await reopened.snapshot() == store.snapshot())
        let privateStore = try BrowserAISkillStore(profileID: profile)
        #expect(await privateStore.snapshot().skills.isEmpty)
        let other = try BrowserAISkillStore(profileID: ProfileID(), persistence: .profileDirectory(root))
        #expect(await other.snapshot().skills.isEmpty)
        try await store.remove(skill.id, expected: store.snapshot())
        #expect(await store.snapshot().skills.isEmpty)
    }

    @Test func corruptAndOversizedInstructionsAreRejected() throws {
        #expect(throws: BrowserAISkillError.invalidContent) { try BrowserAISkill(name: "\u{00}", prompt: "Read") }
        #expect(throws: BrowserAISkillError.limitExceeded) {
            try BrowserAISkill(name: "Long", prompt: "a" + String(repeating: "\u{0301}", count: 9000))
        }
        var document = BrowserAISkillDocument(profileID: .init())
        let skill = try BrowserAISkill(name: "Summary", prompt: "Summarize this tab.")
        document.skills = [skill, skill]
        #expect(throws: BrowserAISkillError.invalidContent) { try document.validate() }
        document.skills = [skill]
        var invalid = skill; invalid.prompt = "\u{00}"
        document.skills = [invalid]
        #expect(throws: BrowserAISkillError.invalidContent) { try document.validate() }
    }

    @Test func replicaEditsAndDeletionConvergeWithoutPageData() async throws {
        let fixture = BrowserSyncTests(), session = BrowserSyncTests().document()
        let store = try BrowserAISkillStore(profileID: fixture.profile)
        var skill = try BrowserAISkill(name: "Summary", prompt: "Summarize this tab.")
        try await store.save(skill, expected: store.snapshot())
        func projection(_ document: BrowserAISkillDocument) throws -> BrowserSyncProjection {
            try BrowserSyncMapping.project(session: session, settings: .init(), skills: [document])
        }
        var a = BrowserSyncReplica(device: "a"), b = BrowserSyncReplica(device: "b")
        try a.capture(projection(await store.snapshot()))
        try b.merge(Array(a.records.values))
        let first = try BrowserSyncMapping.materialize(b.visible, local: session, settings: .init())
        #expect(first.skills.first?.skills == [skill])
        try b.acknowledge(projection(first.skills[0]))
        skill.prompt = "Write three short points."
        try await store.save(skill, expected: store.snapshot())
        try a.capture(projection(await store.snapshot()))
        try b.merge(Array(a.records.values))
        let edited = try BrowserSyncMapping.materialize(b.visible, local: session, settings: .init())
        #expect(edited.skills[0].skills[0].prompt == skill.prompt)
        try b.acknowledge(projection(edited.skills[0]))
        try await store.remove(skill.id, expected: store.snapshot())
        try a.capture(projection(await store.snapshot()))
        try b.merge(Array(a.records.values))
        let deleted = try BrowserSyncMapping.materialize(b.visible, local: session, settings: .init())
        #expect(deleted.skills[0].skills.isEmpty)
        #expect(b.records["skill/" + skill.id.uuidString]?.deleted == true)
    }
}
