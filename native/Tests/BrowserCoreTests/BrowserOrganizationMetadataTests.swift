import Foundation
import Testing
@testable import BrowserCore

@Suite("Scoped organization metadata")
struct BrowserOrganizationMetadataTests {
    @Test("Coalesced metadata produces the canonical window state in both windows")
    func equivalentMetadata() async throws {
        let f = try await OrganizationFixture.make()
        for n in 0..<20 { try await f.open("tab-\(n)") }
        let unrelated = try await f.store.createWindow(activeSpaceID: f.lab)
        try await f.open("other-profile", in: unrelated)
        var states = try await [f.store.captureWindowState(in: f.window), f.store.captureWindowState(in: f.other),
                               f.store.captureWindowState(in: unrelated)]
        var seed: UInt64 = 42
        for step in 0..<120 {
            seed = seed &* 6364136223846793005 &+ 1
            let tabs = states[0].snapshot.tabs
            let tab = tabs[Int(seed % UInt64(tabs.count))]
            let authority = try #require(states[0].occurrenceAuthorities[tab.occurrenceID])
            if step % 3 == 0 {
                try await f.store.updateDestination(to: organizationURL("nav-\(step)"), from: authority)
            } else {
                try await f.store.updatePageTitle(step % 7 == 0 ? nil : "Title \(step)", from: authority)
            }
            // Deliberately skip notifications: newest-one buffering must retain all tab changes.
            if step % 5 != 4 { continue }
            for i in states.indices {
                let old = states[i]
                let delta = try #require(try await f.store.organizationMetadata(since: old.organization.organizationRevision, from: old.context, catalogRevision: old.catalogRevision))
                let full = try await f.store.captureWindowState(in: old.context.windowID)
                #expect(old.organization.applying(delta) == full.organization)
                #expect(old.snapshot.applying(delta) == full.snapshot)
                #expect(old.occurrenceAuthorities == full.occurrenceAuthorities)
                #expect(old.catalog == full.catalog)
                states[i] = full
            }
        }
    }

    @Test("Structural changes and exhausted history require a full resync")
    func resyncBoundary() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("first")
        let old = try await f.store.captureWindowState(in: f.window)
        let authority = try #require(old.occurrenceAuthorities.values.first)
        for step in 0..<257 { try await f.store.updatePageTitle("Title \(step)", from: authority) }
        #expect(try await f.store.organizationMetadata(since: old.organization.organizationRevision, from: old.context, catalogRevision: old.catalogRevision) == nil)
        let latest = try await f.store.captureWindowState(in: f.window)
        _ = try await f.store.pinTabs([id], from: latest.context)
        #expect(try await f.store.organizationMetadata(since: latest.organization.organizationRevision, from: latest.context, catalogRevision: latest.catalogRevision) == nil)
    }

    @Test("Metadata scope follows Space and profile Favorites visibility")
    func visibility() async throws {
        let f = try await OrganizationFixture.make()
        let id = try await f.open("first")
        #expect(await f.store.metadataIsVisible(id, in: f.other))
        try await f.activate(f.leisure, in: f.other)
        #expect(await !f.store.metadataIsVisible(id, in: f.other))
        _ = try await f.store.addToFavorites([id], from: f.context())
        #expect(await f.store.metadataIsVisible(id, in: f.other))
        try await f.activate(f.lab, in: f.other)
        #expect(await !f.store.metadataIsVisible(id, in: f.other))
    }
    @Test("Metadata and full resync stay equivalent through folders, Split, archive and undo")
    func structuralInterleaving() async throws {
        let f = try await OrganizationFixture.make()
        let first = try await f.open("first"), second = try await f.open("second")
        for round in 0..<12 {
            var before = try await f.store.captureWindowState(in: f.window)
            switch round % 6 {
            case 0: _ = try await f.store.pinTabs([first, second], from: before.context)
            case 1:
                _ = try await f.store.createFolder(title: "Synthetic folder", at: .init(.pinned(f.home)),
                                                  containing: [.tab(first), .tab(second)], from: before.context)
            case 2: _ = try await f.store.undoOrganization(from: before.context)
            case 3: _ = try await f.store.createSplit([first, second], from: before.context)
            case 4: _ = try await f.store.undoOrganization(from: before.context)
            default:
                _ = try await f.store.archiveTabs([second], from: before.context)
                _ = try await f.store.undoOrganization(from: f.context())
            }
            #expect(try await f.store.organizationMetadata(since: before.organization.organizationRevision, from: before.context, catalogRevision: before.catalogRevision) == nil)
            before = try await f.store.captureWindowState(in: f.window)
            let index = BrowserOrganizationMetadataIndex(before.organization)
            for authority in before.occurrenceAuthorities.values {
                try await f.store.updatePageTitle("Round \(round)", from: authority)
            }
            let delta = try #require(try await f.store.organizationMetadata(since: before.organization.organizationRevision, from: before.context, catalogRevision: before.catalogRevision))
            let full = try await f.store.captureWindowState(in: f.window)
            #expect(before.organization.applying(delta, index: index) == full.organization)
            #expect(before.snapshot.applying(delta) == full.snapshot)
            try await f.validate()
        }
    }

    @Test("Unrelated metadata preserves captured selection admission; catalog changes resync")
    func unrelatedAdmission() async throws {
        let f = try await OrganizationFixture.make()
        _ = try await f.open("home")
        try await f.activate(f.leisure, in: f.other)
        let target = try await f.open("leisure", in: f.other)
        let before = try await f.store.captureWindowState(in: f.other)
        let home = try await f.store.captureWindowState(in: f.window)
        let authority = try #require(home.occurrenceAuthorities.values.first)
        try await f.store.updatePageTitle("Unrelated", from: authority)
        let selected = try await f.store.selectTab(target, from: before.context, expecting: before.organization)
        #expect(selected.organization.selectedTab?.id == target)
        _ = try await f.store.createSpace(name: "New catalog entry", profileID: f.personal)
        #expect(try await f.store.organizationMetadata(since: selected.organization.organizationRevision, from: selected.context, catalogRevision: selected.catalogRevision) == nil)
    }

}
