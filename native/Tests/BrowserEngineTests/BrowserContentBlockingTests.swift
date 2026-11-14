import Testing
@testable import BrowserCore
@testable import BrowserEngine

@Suite("Content blocking configuration")
@MainActor
struct BrowserContentBlockingTests {
    @Test("Allowed hosts are normalized and dropped while disabled")
    func normalization() {
        let configuration = BrowserContentBlockingConfiguration(isEnabled: true, allowedHosts: [
            "B.example.test", "a.example.test", "a.example.test", "127.0.0.1", "", ".lead.test", "trail.test.",
            "double..test", "bücher.test", "[::1]", "under_score.test", "pipe|host.test"])
        #expect(configuration.allowedHosts == ["127.0.0.1", "a.example.test", "b.example.test"])
        #expect(BrowserContentBlockingConfiguration(isEnabled: false, allowedHosts: ["a.example.test"]).allowedHosts.isEmpty)
    }

    @Test("Engines without built-in blocking report none")
    func defaultNone() async throws {
        let fake = BrowserFakeContentBlocking()
        let profile = ProfileID()
        try await fake.configure(.init(isEnabled: true, allowedHosts: ["a.test"]), profileID: profile, waitsForAcknowledgement: true)
        #expect(fake.configurations[profile] == .init(isEnabled: true, allowedHosts: ["a.test"]))
    }
}
