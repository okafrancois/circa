import BrowserCore
import BrowserEngine
import Testing

@Suite("Acknowledged per-profile Boost registry")
@MainActor
struct BrowserBoostHostTests {
    @Test func replaceUpdateRemoveAndRejectStaleReplies() async throws {
        let host = BrowserFakeBoostHost(), first = ProfileID(), second = ProfileID()
        var boost = BrowserBoost(title: "Synthetic", hostPattern: try .init(host: "example.test"))
        let css = try BrowserBoostCompiler.compile(boost)
        let initial = BrowserBoostProfilePayload(profileID: first, revision: 1, boosts: [css])
        let ack = try await host.replaceBoosts(initial)
        #expect(ack == BrowserBoostAcknowledgement(profileID: first, revision: 1))
        #expect(try await host.replaceBoosts(initial) == ack)
        _ = try await host.replaceBoosts(.init(profileID: second, revision: 1, boosts: [css]))
        boost.content.customCSS = "p { color: red; }"
        // A registration generation must not hide changed bytes at an unchanged Boost revision.
        let updated = try BrowserBoostCompiler.compile(boost)
        await #expect(throws: BrowserBoostError.staleRevision) {
            try await host.replaceBoosts(.init(profileID: first, revision: 1, boosts: [updated]))
        }
        await #expect(throws: BrowserBoostError.staleRevision) {
            try await host.replaceBoosts(.init(profileID: first, revision: 2, boosts: [updated]))
        }
        let store = try BrowserBoostStore(profileID: first)
        try await store.save(BrowserBoost(id: boost.id, title: boost.title, hostPattern: boost.hostPattern))
        let saved = try await store.save(boost, expectedRevision: 1)
        let next = try BrowserBoostCompiler.compile(saved)
        _ = try await host.replaceBoosts(.init(profileID: first, revision: 2, boosts: [next]))
        #expect(host.profiles[first]?.boosts.first?.css == next.css)
        _ = try await host.removeBoosts(profileID: first, revision: 3)
        #expect(host.profiles[first]?.boosts.isEmpty == true)
        #expect(host.profiles[second]?.boosts == [css])
        await #expect(throws: BrowserBoostError.staleRevision) { try await host.replaceBoosts(initial) }
    }
}
