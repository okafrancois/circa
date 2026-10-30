import Foundation
import Testing
@testable import BrowserCore

extension BrowserPinnedPageIdentityTests {
    @Test("Imported folder pins keep logical identity when opened, unloaded and reopened")
    func importedPinOccurrence() async throws {
        let f = try await OrganizationFixture.make()
        let profile = ArcProfileKey.directory("Default")
        let source = ArcImportedTab(sourceID: "imported-pin", savedURL: organizationURL("saved"),
            savedTitle: "Illustrated Atlas — Field Notes", customTitle: nil, createdAt: nil, lastActiveAt: nil)
        let graph = ArcSidebarGraph(formatVersion: 1, formatRecognized: true,
            profiles: [], spaces: [.init(sourceID: "imported-space", profile: profile, title: "Reading",
                appearance: .init(), pinned: [.folder(.init(sourceID: "reading-folder", title: "SAVED", isCollapsed: false, createdAt: nil, children: [.tab(source)]))], today: [])], favorites: [], archive: [], diagnostics: .init())
        let plan = ArcImportMapper.plan(graph, defaultProfileTarget: f.personal, importedAt: f.clock.now)
        _ = try await f.store.applyImport(plan, ledger: .init())
        let space = try #require(plan.spaces.first?.id)
        try await f.activate(space)
        let id = try #require(try await f.organization().allTabs.first?.id)
        #expect(try await f.organization().tab(id)?.isLoadedInThisWindow == false)
        for _ in 0..<2 {
            _ = try await f.store.selectTab(id, from: f.context())
            let row = try #require(try await f.organization().tab(id))
            #expect(row.isSelected && row.isLoadedInThisWindow && row.occurrenceID != nil)
            #expect(row.pinnedURL == source.savedURL)
            _ = try await f.store.closeTabs([id], from: f.context())
            #expect(try await f.organization().tab(id)?.isLoadedInThisWindow == false)
        }
    }
}
