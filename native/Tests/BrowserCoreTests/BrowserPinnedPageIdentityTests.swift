import Foundation
import Testing
@testable import BrowserCore

struct BrowserPinnedPageIdentityTests {
    @Test("Pin identity ignores host and scheme case, default ports, trailing slash and anchors",
          arguments: [
            ("HTTPS://EXAMPLE.test:443/start/", "https://example.test/start#section"),
            ("http://example.test:80", "http://EXAMPLE.test/#top"),
            ("https://example.test", "https://example.test/"),
            ("https://example.test/start?q=one#top", "https://example.test/start/?q=one#bottom")
          ])
    func equivalentPages(pair: (String, String)) throws {
        #expect(BrowserPinnedPageIdentity.matches(try #require(URL(string: pair.0)), try #require(URL(string: pair.1))))
    }

    @Test("Sub-pages, query changes, path case, schemes and nondefault ports remain distinct",
          arguments: ["https://example.test/start/child", "https://example.test/Start",
                      "https://example.test/start?q=other", "http://example.test/start",
                      "https://example.test:8443/start", "https://example.test/start%2F"])
    func distinctPages(address: String) throws {
        #expect(!BrowserPinnedPageIdentity.matches(URL(string: "https://example.test/start")!, try #require(URL(string: address))))
    }

    @Test("Returning through a redirect to the saved canonical page clears away without changing the pin")
    func canonicalReturnAndUnload() async throws {
        let fixture = try await OrganizationFixture.make()
        let id = try await fixture.open("canonical")
        _ = try await fixture.store.pinTabs([id], from: fixture.context())
        let occurrence = try #require(await fixture.occurrences(of: id).first)
        for path in ["canonical/child", "redirect", "canonical/#top"] {
            try await fixture.store.updateDestination(for: occurrence.occurrenceID, to: organizationURL(path), from: fixture.context())
            let tab = try #require(try await fixture.organization().tab(id))
            #expect(tab.isAwayFromPinnedURL == (path != "canonical/#top"))
            #expect(tab.pinnedURL == organizationURL("canonical"))
        }
        try await fixture.store.updateDestination(for: occurrence.occurrenceID, to: organizationURL("canonical/child"), from: fixture.context())
        _ = try await fixture.store.closeTabs([id], from: fixture.context())
        let unloaded = try #require(try await fixture.organization().tab(id))
        #expect(!unloaded.isLoadedInThisWindow && !unloaded.isAwayFromPinnedURL)
        #expect(unloaded.url == unloaded.pinnedURL)
        #expect(await fixture.occurrences(of: id).isEmpty)
        _ = try await fixture.store.archiveTabs([id], from: fixture.context())
        #expect(try await fixture.organization().tab(id) == nil)
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).contains { $0.id == id && $0.reason == .removed })
    }
}
