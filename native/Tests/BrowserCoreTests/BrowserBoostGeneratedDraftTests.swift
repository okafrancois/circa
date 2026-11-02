import Foundation
import Testing
@testable import BrowserCore

@Suite struct BrowserBoostGeneratedDraftTests {
    @Test func generatedApplyRejectsUnrelatedStoreChangesAndPreservesSavedCode() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let pattern = try BrowserBoostHostPattern(host: "example.test")
        var boost = BrowserBoost(title: "Synthetic", hostPattern: pattern)
        boost.content.customCSS = "body { color: red }"
        let saved = try await store.save(boost)
        let expected = await store.snapshot()
        _ = try await store.save(BrowserBoost(title: "Other", hostPattern: pattern))
        do {
            _ = try await store.applyGeneratedCSS("body { color: blue }", to: saved.id, expected: expected)
            Issue.record("Stale generated draft was persisted")
        } catch BrowserBoostError.staleRevision {}
        #expect(await store.snapshot().boosts.first?.content.customCSS == "body { color: red }")
    }
    @Test func applyIsExplicitAndDoesNotRecreateDeletedBoost() async throws {
        let store = try BrowserBoostStore(profileID: ProfileID())
        let boost = try await store.save(BrowserBoost(title: "Synthetic", hostPattern: BrowserBoostHostPattern(host: "example.test")))
        let expected = await store.snapshot()
        let applied = try await store.applyGeneratedCSS("p { display: none }", to: boost.id, expected: expected)
        #expect(applied.content.customCSS == "p { display: none }")
        let deleted = await store.snapshot()
        try await store.removeCurrent(boost.id)
        do {
            _ = try await store.applyGeneratedCSS("p { color: red }", to: boost.id, expected: deleted)
            Issue.record("Deleted Boost was recreated")
        } catch BrowserBoostError.staleRevision {}
        #expect(await store.snapshot().boosts.isEmpty)
    }
}
