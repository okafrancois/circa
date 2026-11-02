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
    @Test func concurrentWorkerEditsAndProfileRemovalConverge() async throws {
        let fixture = BrowserSyncTests(), session = BrowserSyncTests().document()
        let root = URL(fileURLWithPath: "/private/tmp/OrbitSkillConflict-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = BrowserSyncWorker(state: .init(), destination: root.appendingPathComponent("a.json"))
        let b = BrowserSyncWorker(state: .init(), destination: root.appendingPathComponent("b.json"))
        try await a.admit("synthetic"); try await b.admit("synthetic")
        var left = BrowserAISkillDocument(profileID: fixture.profile)
        left.skills = [try BrowserAISkill(name: "Summary", prompt: "Initial instructions.")]
        func snapshot(_ document: BrowserAISkillDocument) -> BrowserSyncWorker.Snapshot {
            .init(session: session, settings: .init(), skills: [document])
        }
        try await b.merge(a.capture(snapshot(left)), identity: "synthetic")
        let initial = try await b.prepare(snapshot(left))
        try await b.acknowledge(initial.projection)
        var right = left
        left.skills[0].prompt = "Left instructions."
        right.skills[0].prompt = "Right instructions."
        let editsA = try await a.capture(snapshot(left))
        let editsB = try await b.capture(snapshot(right))
        try await a.merge(editsB, identity: "synthetic")
        try await b.merge(editsA, identity: "synthetic")
        let resultA = try await a.prepare(snapshot(left))
        let resultB = try await b.prepare(snapshot(right))
        #expect(resultA.value.skills == resultB.value.skills)
        #expect([left.skills[0].prompt, right.skills[0].prompt].contains(resultA.value.skills[0].skills[0].prompt))
        try await a.acknowledge(resultA.projection)
        try await b.acknowledge(resultB.projection)
        let removed = BrowserSessionDocument(profiles: [], spaces: [], windows: [], tabs: [])
        let deletion = try await a.capture(.init(session: removed, settings: .init()))
        #expect(deletion.first { $0.id == "skill/" + left.skills[0].id.uuidString }?.deleted == true)
        try await b.merge(deletion, identity: "synthetic")
        let afterRemoval = try await b.prepare(snapshot(right))
        #expect(afterRemoval.value.profiles.isEmpty)
        #expect(afterRemoval.value.skills.isEmpty)
    }

    @Test func workerRecapturesLocalEditsAndPreservesUnknownSkillRecords() async throws {
        let fixture = BrowserSyncTests(), session = BrowserSyncTests().document()
        let root = URL(fileURLWithPath: "/private/tmp/OrbitSkillWorker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = BrowserSyncWorker(state: .init(), destination: root.appendingPathComponent("a.json"))
        let b = BrowserSyncWorker(state: .init(), destination: root.appendingPathComponent("b.json"))
        try await a.admit("synthetic"); try await b.admit("synthetic")
        let store = try BrowserAISkillStore(profileID: fixture.profile)
        var skill = try BrowserAISkill(name: "Summary", prompt: "Summarize this tab.")
        try await store.save(skill, expected: store.snapshot())
        func snapshot(_ document: BrowserAISkillDocument) -> BrowserSyncWorker.Snapshot {
            .init(session: session, settings: .init(), skills: [document])
        }
        let outgoing = try await a.capture(snapshot(await store.snapshot()))
        try await b.merge(outgoing, identity: "synthetic")
        // A caller unaware of Skills must not delete records it has never projected.
        let oldAPI = try await b.prepare(.init(session: session, settings: .init()))
        #expect(oldAPI.value.skills.first?.skills == [skill])
        try await b.acknowledge(oldAPI.projection)
        let repeated = try await b.prepare(.init(session: session, settings: .init()))
        #expect(repeated.value.skills.first?.skills == [skill])
        try await b.acknowledge(repeated.projection)
        let legacyCapture = try await b.capture(.init(session: session, settings: .init()))
        #expect(legacyCapture.first { $0.id == "skill/" + skill.id.uuidString }?.deleted == false)
        let original = await store.snapshot()
        skill.prompt = "Write three points."
        try await store.save(skill, expected: original)
        // The post-network capture sees the edit and cannot reuse the old projection cache.
        let edited = try await a.prepare(snapshot(await store.snapshot()))
        #expect(edited.value.skills.first?.skills.first?.prompt == skill.prompt)
        await #expect(throws: BrowserSyncError.localChange) {
            try await store.applySync(oldAPI.value.skills[0], expected: original)
        }
        let latest = try await a.capture(snapshot(await store.snapshot()))
        try await b.merge(latest, identity: "synthetic")
        let received = try await b.prepare(snapshot(oldAPI.value.skills[0]))
        #expect(received.value.skills.first?.skills.first?.prompt == skill.prompt)
        try await b.acknowledge(received.projection)
        try await store.remove(skill.id, expected: store.snapshot())
        let deleted = try await a.capture(snapshot(await store.snapshot()))
        try await b.merge(deleted, identity: "synthetic")
        let tombstone = try await b.prepare(snapshot(received.value.skills[0]))
        #expect(tombstone.value.skills.first?.skills.isEmpty == true)
    }
}
