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

extension BrowserPinnedPageIdentityTests {
    @Test("Pin landings follow server and client redirects until a separate navigation", arguments: [
        "https://organization.test/canonical", "https://www.organization.test/en/start?locale=en",
        "https://landing.test/final?q=added"
    ])
    func redirectedLanding(address: String) async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("saved")
        _ = try await f.store.pinTabs([id], from: f.context())
        let occurrence = try #require(await f.occurrences(of: id).first)
        let authority = try await f.store.captureOccurrenceAuthority(for: occurrence.occurrenceID, from: f.context())
        let saved = organizationURL("saved")
        let landing = try #require(URL(string: address))
        try await f.store.recordPinnedNavigation(to: saved, isRedirect: false, committed: false, from: authority)
        for url in [organizationURL("intermediate"), landing] {
            try await f.store.recordPinnedNavigation(to: url, isRedirect: true, committed: false, from: authority)
            try await f.store.updateDestination(to: url, from: authority)
            try await f.store.recordPinnedNavigation(to: url, isRedirect: false, committed: true, from: authority)
            #expect(try await f.organization().tab(id)?.isAwayFromPinnedURL == false)
        }
        #expect(try await f.organization().tab(id)?.pinnedLandingURL == landing)
        let child = landing.appendingPathComponent("child")
        try await f.store.recordPinnedNavigation(to: child, isRedirect: false, committed: false, from: authority)
        try await f.store.updateDestination(to: child, from: authority)
        try await f.store.recordPinnedNavigation(to: child, isRedirect: false, committed: true, from: authority)
        #expect(try await f.organization().tab(id)?.isAwayFromPinnedURL == true)
        #expect(try await f.organization().tab(id)?.pinnedLandingURL == landing)
        // A redirect in the later navigation must not replace the home alias.
        try await f.store.recordPinnedNavigation(to: organizationURL("elsewhere"), isRedirect: true, committed: false, from: authority)
        try await f.store.recordPinnedNavigation(to: organizationURL("elsewhere"), isRedirect: false, committed: true, from: authority)
        #expect(try await f.organization().tab(id)?.pinnedLandingURL == landing)
        _ = try await f.store.resetTabToPinnedURL(id, from: f.context())
        try await f.store.recordPinnedNavigation(to: saved, isRedirect: false, committed: false, from: authority)
        try await f.store.recordPinnedNavigation(to: landing, isRedirect: true, committed: false, from: authority)
        try await f.store.updateDestination(to: landing, from: authority)
        try await f.store.recordPinnedNavigation(to: landing, isRedirect: false, committed: true, from: authority)
        #expect(try await f.organization().tab(id)?.isAwayFromPinnedURL == false)
        _ = try await f.store.closeTabs([id], from: f.context())
        #expect(await f.store.pinnedLandings[occurrence.occurrenceID] == nil)
        #expect(try await f.organization().tab(id)?.isAwayFromPinnedURL == false)
    }
}

extension BrowserPinnedPageIdentityTests {
    @Test("Committed landing aliases survive relaunch, preserve away documents and invalidate on home edits")
    func restoredLandingAlias() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("saved")
        _ = try await f.store.pinTabs([id], from: f.context())
        let occurrence = try #require(await f.occurrences(of: id).first)
        let authority = try await f.store.captureOccurrenceAuthority(for: occurrence.occurrenceID, from: f.context())
        let landing = URL(string: "https://alias.test/en/home?locale=en")!
        try await f.store.recordPinnedNavigation(to: organizationURL("saved"), isRedirect: false, committed: false, from: authority)
        try await f.store.recordPinnedNavigation(to: landing, isRedirect: true, committed: false, from: authority)
        try await f.store.updateDestination(to: landing, from: authority)
        try await f.store.recordPinnedNavigation(to: landing, isRedirect: false, committed: true, from: authority)
        let saved = try await f.store.sessionDocument().encoded()
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(saved))
        let context = try await restored.captureContext(in: f.window)
        var row = try #require(try await restored.organizationSnapshot(from: context).tab(id))
        #expect(row.pinnedLandingURL == landing && !row.isAwayFromPinnedURL)
        let lease = try await restored.captureOccurrenceAuthority(for: occurrence.occurrenceID, from: context)
        try await restored.recordPinnedNavigation(to: landing, isRedirect: false, committed: false, from: lease)
        try await restored.recordPinnedNavigation(to: landing, isRedirect: false, committed: true, from: lease)
        let child = landing.appendingPathComponent("child")
        try await restored.recordPinnedNavigation(to: child, isRedirect: false, committed: false, from: lease)
        try await restored.updateDestination(to: child, from: lease)
        try await restored.recordPinnedNavigation(to: child, isRedirect: false, committed: true, from: lease)
        let awayRestore = try BrowserStore(restoring: await restored.sessionDocument())
        let awayContext = try await awayRestore.captureContext(in: f.window)
        #expect(try await awayRestore.organizationSnapshot(from: awayContext).tab(id)?.isAwayFromPinnedURL == true)
        _ = try await restored.editPinnedURL(id, to: organizationURL("different"), from: context)
        row = try #require(try await restored.organizationSnapshot(from: context).tab(id))
        #expect(row.pinnedLandingURL == nil && row.isAwayFromPinnedURL)
    }
}
