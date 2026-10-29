import Foundation
import Testing
@testable import BrowserCore

@Suite struct BrowserOrganizationSelectionUpdateTests {
    @Test("Selection deltas match full capture across windows, metadata, folders, Splits and structural fallbacks")
    func randomizedEquivalence() async throws {
        let f = try await OrganizationFixture.make()
        var ids: [TabID] = []
        for i in 0..<20 { ids.append(try await f.open("tab-\(i)")) }
        _ = try await f.store.addToFavorites([ids[0], ids[1]], from: f.context())
        _ = try await f.store.pinTabs(Array(ids[2..<8]), from: f.context())
        _ = try await f.store.createFolder(title: "Nested", at: .init(.pinned(f.home)),
            containing: [.tab(ids[2]), .tab(ids[3])], from: f.context())
        _ = try await f.store.createSplit([ids[4], ids[5], ids[6]], from: f.context())
        var states = [try await f.store.captureWindowState(in: f.window), try await f.store.captureWindowState(in: f.other)]
        var seed: UInt64 = 41
        var scoped = 0
        for step in 0..<400 {
            seed = seed &* 6364136223846793005 &+ 1
            let slot = Int(seed % 2), id = ids[Int((seed >> 16) % UInt64(ids.count))]
            var before = states[slot]
            if step.isMultiple(of: 23) {
                _ = try await f.store.renameTab(id, to: "Renamed \(step)", from: before.context)
            } else if step.isMultiple(of: 7), let authority = before.occurrenceAuthorities.values.first {
                try await f.store.updatePageTitle("Metadata \(step)", from: authority)
            }
            // A fresh authoritative context does not imply a fresh structural projection.
            let context = try await f.store.captureContext(in: before.context.windowID)
            if context != before.context { before = try await f.store.captureWindowState(in: context.windowID) }
            f.clock.advance(by: 1)
            let result = try await f.store.selectTabUpdating(id, from: before.context, state: before,
                index: BrowserOrganizationMetadataIndex(before.organization))
            let full = try await f.store.captureWindowState(in: before.context.windowID)
            #expect(result.context == full.context)
            #expect(result.snapshot == full.snapshot)
            #expect(result.catalog == full.catalog)
            #expect(result.occurrenceAuthorities == full.occurrenceAuthorities)
            #expect(result.occurrenceTabIDs == full.occurrenceTabIDs)
            #expect(result.organization == full.organization)
            if result.selectionTabIDs != nil { scoped += 1 }
            states[slot] = result
        }
        #expect(scoped > 300)
        try await f.validate()
    }

    @Test("Favorite adoption, missing activity history and catalog mutations take full capture")
    func fallbacks() async throws {
        let f = try await OrganizationFixture.make()
        let first = try await f.open("favorite"), second = try await f.open("second")
        _ = try await f.store.addToFavorites([first], from: f.context())
        try await f.activate(f.leisure)
        var before = try await f.store.captureWindowState(in: f.window)
        var result = try await f.store.selectTabUpdating(first, from: before.context, state: before, index: .init(before.organization))
        #expect(result.selectionTabIDs == nil)
        #expect(result.organization.selectedTab?.id == first)
        try await f.activate(f.home)
        _ = try await f.store.selectTab(first, from: f.context(f.other))
        _ = try await f.store.selectTab(second, from: f.context(f.other))
        before = try await f.store.captureWindowState(in: f.window)
        // Activity in another window can overflow without changing this window's context.
        for _ in 0..<140 {
            _ = try await f.store.selectTab(first, from: f.context(f.other))
            _ = try await f.store.selectTab(second, from: f.context(f.other))
        }
        let afterActivity = try await f.store.captureWindowState(in: f.window)
        #expect(afterActivity.context == before.context)
        #expect(afterActivity.organization.organizationRevision == before.organization.organizationRevision)
        #expect(afterActivity.activityRevision > before.activityRevision + 256)
        result = try await f.store.selectTabUpdating(second, from: before.context, state: before, index: .init(before.organization))
        #expect(result.selectionTabIDs == nil)
        before = result
        _ = try await f.store.createSpace(name: "Catalog", profileID: f.personal)
        result = try await f.store.selectTabUpdating(second, from: before.context, state: before, index: .init(before.organization))
        #expect(result.selectionTabIDs == nil)
        let left = try await f.open("cold-left"), right = try await f.open("cold-right")
        let group = try await f.store.createSplit([left, right], from: f.context()).0
        let peer = try await f.store.captureWindowState(in: f.other)
        let admitted = try await f.store.selectSplitUpdating(group, from: peer.context,
            state: peer, index: .init(peer.organization))
        #expect(admitted.selectionTabIDs == nil)
        #expect(admitted.organization.split(containing: left)?.tabs.allSatisfy { $0.occurrenceID != nil } == true)
        #expect(admitted.organization == (try await f.store.captureWindowState(in: f.other)).organization)
    }

    @Test("Revoked and stale selection admission preserve full-path semantics")
    func admission() async throws {
        let f = try await OrganizationFixture.make()
        let first = try await f.open("first")
        _ = try await f.open("second")
        let before = try await f.store.captureWindowState(in: f.window)
        let intent = BrowserSidebarSelectionAdmission(); intent.revoke()
        let refused = try await f.store.selectTabUpdating(first, from: before.context, state: before,
            index: .init(before.organization), expecting: before.organization, admission: intent)
        #expect(refused.context == before.context)
        #expect(refused.organization == before.organization)
        _ = try await f.store.renameTab(first, to: "Changed", from: before.context)
        await #expect(throws: BrowserOrganizationError.notVisibleInContext) {
            try await f.store.selectTabUpdating(first, from: before.context, state: before,
                index: .init(before.organization), expecting: before.organization)
        }
        #expect(try await f.context() == before.context)
    }
}
