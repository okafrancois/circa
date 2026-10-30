import Foundation
import Testing
@testable import BrowserCore

@Suite("Split organization and version 3")
struct BrowserSplitTests {
    @Test("A split is one sidebar row with individually addressable tabs and window-local focus")
    func groupedRowAndFocus() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, state) = try await f.store.createSplit([a, b], from: f.context())
        #expect(state.organization.rows().map(\.node) == [.split(id)])
        #expect(state.organization.allTabs.map(\.id) == [a, b])
        #expect(state.organization.selectedTab?.id == b)
        let other = try await f.store.selectSplit(id, from: f.context(f.other))
        #expect(other.organization.selectedTab?.id == a)
        #expect(other.snapshot.tabs.count == 2)
        #expect(try await f.organization().selectedTab?.id == b)
        try await f.validate()
    }

    @Test("Version 2 migrates without changing any model data, exports v3, and rejects future input")
    func migration() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("pinned")
        _ = try await f.store.pinTabs([a], from: f.context())
        _ = try await f.open("archived")
        _ = try await f.store.closeOccurrence(try #require(try await f.context().selectedOccurrenceID), from: f.context())
        let before = await f.store.sessionDocument()
        var json = try #require(JSONSerialization.jsonObject(with: before.encoded()) as? [String: Any])
        json["version"] = 2
        var organization = try #require(json["organization"] as? [String: Any])
        organization.removeValue(forKey: "splits")
        json["organization"] = organization
        let migrated = try BrowserSessionDocument.decode(JSONSerialization.data(withJSONObject: json))
        #expect(migrated == before)
        #expect(migrated.version == BrowserSessionDocument.currentVersion)
        #expect(try BrowserSessionDocument.decode(migrated.encoded()) == migrated)
        json["version"] = BrowserSessionDocument.currentVersion + 1
        let future = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: BrowserSessionError.unsupportedVersion) { try BrowserSessionDocument.decode(future) }
    }

    @Test("Group layout and focused occurrence survive a session round trip",
          arguments: [BrowserSplitOrientation.horizontal, .vertical])
    func restoration(_ orientation: BrowserSplitOrientation) async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, _) = try await f.store.createSplit([a,b], orientation: orientation, from: f.context())
        _ = try await f.store.resizeSplit(id, ratios: [0.3,0.7], from: f.context())
        let saved = await f.store.sessionDocument()
        let decoded = try BrowserSessionDocument.decode(saved.encoded())
        #expect(saved == decoded)
        let restored = try BrowserStore(restoring: decoded)
        #expect(await restored.sessionDocument() == saved)
    }

    @Test("Rescue persistence cannot overwrite another window's logical destinations or group")
    func rescuePreservesPeerDocuments() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("peer-a"), b = try await f.open("peer-b")
        let (id, _) = try await f.store.createSplit([a, b], from: f.context())
        _ = try await f.store.selectSplit(id, from: f.context(f.other))
        let before = await f.store.sessionDocument()
        let group = try #require(before.organization.splits.first)
        let profile = try await f.context().profileID
        let rescued = organizationURL("rescued-redirect")
        #expect(try await !f.store.preserveRescuedSplit(group, spaceID: f.home, profileID: profile,
                                                      urls: [a: rescued, b: rescued]))
        #expect(await f.store.sessionDocument() == before)
        let fresh = try await f.store.preserveRescuedTab(url: rescued, profileID: profile, existingTabID: a, standalone: true)
        #expect(fresh != a && fresh != b)
        let after = await f.store.sessionDocument()
        #expect(after.organization.splits == before.organization.splits)
        #expect(after.organization.tabs.first { $0.id == a } == before.organization.tabs.first { $0.id == a })
        #expect(after.organization.tabs.first { $0.id == fresh }?.url == rescued)
        try after.validate()
    }

    @Test("Version 3 requires an explicit split inventory while version 2 may omit it", arguments: [false, true])
    func explicitSplitInventory(nullInventory: Bool) async throws {
        let f = try await OrganizationFixture.make()
        _ = try await f.open("plain")
        let document = await f.store.sessionDocument()
        var json = try #require(JSONSerialization.jsonObject(with: document.encoded()) as? [String: Any])
        var organization = try #require(json["organization"] as? [String: Any])
        organization["splits"] = nullInventory ? NSNull() : nil
        json["organization"] = organization
        let missing = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: BrowserSessionError.invalidSplitGroup) { try BrowserSessionDocument.decode(missing) }
        json["version"] = 2
        let legacy = try JSONSerialization.data(withJSONObject: json)
        #expect(try BrowserSessionDocument.decode(legacy) == document)
        #expect(try BrowserSessionDocument.decode(document.encoded()) == document)
    }

    @Test("Quit separates degraded unowned Pinned members in place without changing their Space or pinned address")
    func rescuePreservesPinnedPlacement() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("pinned-rescue-a"), b = try await f.open("pinned-rescue-b")
        let (group, _) = try await f.store.createSplit([a, b], from: f.context())
        _ = try await f.store.moveItems([.split(group)], to: .init(.pinned(f.leisure)), from: f.context())
        try await f.store.closeWindow(f.window)
        let before = await f.store.sessionDocument()
        _ = try await f.store.preserveRescuedTab(url: organizationURL("pinned-live-a"), profileID: f.personal,
                                               existingTabID: a, standalone: true)
        _ = try await f.store.preserveRescuedTab(url: organizationURL("pinned-live-b"), profileID: f.personal,
                                               existingTabID: b, standalone: true)
        let after = await f.store.sessionDocument()
        #expect(after.organization.splits.isEmpty)
        #expect(after.organization.spaces.first { $0.spaceID == f.leisure }?.pinned == [.tab(a), .tab(b)])
        for id in [a, b] {
            #expect(after.organization.tabs.first { $0.id == id }?.pinnedURL == before.organization.tabs.first { $0.id == id }?.pinnedURL)
        }
        try after.validate()
    }

    @Test("Adding panes is bounded at four and a failed add leaves no orphan logical tab")
    func paneLimit() async throws {
        let f = try await OrganizationFixture.make()
        _ = try await f.open("first")
        for _ in 0..<3 { _ = try await f.store.splitWithNewTab(url: organizationURL("new"), from: f.context()) }
        let before = await f.store.sessionDocument()
        await #expect(throws: BrowserSplitError.invalidPaneCount) {
            try await f.store.splitWithNewTab(url: organizationURL("refused"), from: f.context())
        }
        #expect(await f.store.sessionDocument() == before)
        #expect(before.organization.splits.first?.tabIDs.count == 4)
        try await f.validate()
    }

    @Test("Creation, add, orientation, resize, swap, unsplit and redo all use the organization journal")
    func commandsAndUndo() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b"), c = try await f.open("c")
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        _ = try await f.store.addPane(c, to: id, at: 1, from: f.context())
        #expect(await f.store.sessionDocument().organization.splits.first?.tabIDs == [a,c,b])
        _ = try await f.store.setSplitOrientation(.vertical, for: id, from: f.context())
        _ = try await f.store.resizeSplit(id, ratios: [0.2,0.3,0.5], from: f.context())
        _ = try await f.store.swapSplitPanes(id, first: 0, second: 2, from: f.context())
        #expect(await f.store.sessionDocument().organization.splits.first?.tabIDs == [b,c,a])
        _ = try await f.store.unsplit(id, from: f.context())
        #expect(await f.store.sessionDocument().organization.splits.isEmpty == true)
        for _ in 0..<6 { _ = try await f.store.undoOrganization(from: f.context()); try await f.validate() }
        #expect(await f.store.sessionDocument().organization.splits.isEmpty == true)
        #expect(try await f.organization().allTabs.count == 3)
        for _ in 0..<6 { _ = try await f.store.redoOrganization(from: f.context()); try await f.validate() }
        #expect(try await f.organization().today.map(\.node) == [.tab(b),.tab(c),.tab(a)])
    }

    @Test("Closing the focused pane dissolves a pair, chooses its survivor, and undo restores focus and group")
    func closePane() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        _ = try await f.store.closeSplitPane(b, from: f.context())
        #expect(try await f.organization().selectedTab?.id == a)
        #expect(try await f.organization().rows().map(\.node) == [.tab(a)])
        #expect(try await f.store.archivedTabs(from: f.context()).map(\.id) == [b])
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(try await f.organization().rows().map(\.node) == [.split(id)])
        #expect(try await f.organization().selectedTab?.id == b)
        try await f.validate()
    }

    @Test("Closing a pinned pane keeps its sidebar tab and undo reopens the original identity")
    func closePinnedPane() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        _ = try await f.store.pinTabs([a,b], from: f.context())
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        _ = try await f.store.closeSplitPane(b, from: f.context())
        #expect(try await f.organization().allTabs.count == 2)
        #expect(await f.occurrences(of: b).isEmpty)
        #expect(try await f.store.archivedTabs(from: f.context()).isEmpty)
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(try await f.organization().split(containing: b)?.group.id == id)
        #expect(try await f.organization().selectedTab?.id == b)
        try await f.validate()
    }

    @Test("Archive is per tab; undo restores layout, reopening an archived tab restores a standalone row")
    func archiveSemantics() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        _ = try await f.store.archiveTabs([a,b], from: f.context())
        #expect(await f.store.sessionDocument().organization.splits.isEmpty)
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(try await f.organization().split(containing: a)?.group.id == id)
        _ = try await f.store.archiveTabs([a,b], from: f.context())
        _ = try await f.store.restoreArchivedTab(a, activate: true, from: f.context())
        #expect(try await f.organization().rows().map(\.node) == [.tab(a)])
        try await f.validate()
    }

    @Test("Automatic archive and Clear protect all visible panes and archive an inactive group as a unit")
    func archiveProtection() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        _ = try await f.store.createSplit([a,b], from: f.context())
        f.clock.advance(by: 13 * 3600)
        #expect(await f.store.archiveExpiredTabs().isEmpty)
        _ = try await f.store.clearTodayPreservingVisibleTabs(protecting: [], from: f.context())
        #expect(try await f.organization().allTabs.count == 2)
        _ = try await f.open("background")
        f.clock.advance(by: 13 * 3600)
        #expect(await f.store.autoArchiveCandidates() == [a,b])
        #expect(Set(await f.store.archiveExpiredTabs().map(\.id)) == [a,b])
        try await f.validate()
    }

    @Test("Refuses Favorites, mixed sections, other Spaces, duplicate members and stale contexts atomically")
    func boundaries() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let stale = try await f.context()
        _ = try await f.store.pinTabs([a], from: f.context())
        await #expect(throws: BrowserSplitError.incompatibleSection) { try await f.store.createSplit([a,b], from: f.context()) }
        _ = try await f.store.unpinTabs([a], from: f.context())
        let before = await f.store.sessionDocument()
        await #expect(throws: BrowserSplitError.invalidPaneCount) { try await f.store.createSplit([a,a], from: f.context()) }
        #expect(await f.store.sessionDocument() == before)
        try await f.activate(f.lab, in: f.other)
        await #expect(throws: BrowserOrganizationError.notVisibleInContext) {
            try await f.store.createSplit([a,b], from: f.context(f.other))
        }
        _ = try await f.open("changes-selection")
        await #expect(throws: BrowserStoreError.staleContext) { try await f.store.createSplit([a,b], from: stale) }
        _ = try await f.store.addToFavorites([a], from: f.context())
        await #expect(throws: BrowserSplitError.incompatibleSection) { try await f.store.createSplit([a,b], from: f.context()) }
    }

    @Test("Concurrent layout edits invalidate undo without overwriting another window")
    func concurrentUndo() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        _ = try await f.store.resizeSplit(id, ratios: [0.3,0.7], from: f.context())
        _ = try await f.store.selectSplit(id, from: f.context(f.other))
        _ = try await f.store.resizeSplit(id, ratios: [0.6,0.4], from: f.context(f.other))
        await #expect(throws: BrowserOrganizationError.undoConflict) { try await f.store.undoOrganization(from: f.context()) }
        #expect(await f.store.sessionDocument().organization.splits.first?.ratios == [0.6,0.4])
        try await f.validate()
    }

    @Test("Moving the grouped node to another Space preserves the group and revokes old occurrences")
    func groupMove() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        _ = try await f.store.moveItems([.split(id)], to: .init(.pinned(f.leisure)), from: f.context())
        #expect(try await f.organization().allTabs.isEmpty)
        try await f.activate(f.leisure)
        _ = try await f.store.selectSplit(id, from: f.context())
        #expect(try await f.organization().selectedTab != nil)
        #expect(try await f.organization().allTabs.allSatisfy { $0.pinnedURL != nil })
        try await f.validate()
    }

    @Test("Grouped pin/unpin, folder deletion and undo preserve grouping and all descendants")
    func groupedPinAndFolderDeletion() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        _ = try await f.store.pinTabs([a,b], from: f.context())
        #expect(try await f.organization().pinned.map(\.node) == [.split(id)])
        let (folder, _) = try await f.store.createFolder(title: "Synthetic group", at: .init(.pinned(f.home)),
                                                       containing: [.split(id)], from: f.context())
        _ = try await f.store.deleteFolder(folder, contents: .archiveContents, from: f.context())
        #expect(try await f.organization().allTabs.isEmpty)
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(try await f.organization().split(containing: a)?.group.id == id)
        try await f.validate()
        _ = try await f.store.unpinTabs([a,b], from: f.context())
        #expect(try await f.organization().today.map(\.node) == [.split(id)])
        try await f.validate()
    }

    @Test("Invalid split graph records are rejected before restoration")
    func invalidDocument() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let saved = await f.store.sessionDocument()
        let organization = saved.organization
        for ids in [[a], [a,a], [a,b,TabID(),TabID(),TabID()]] {
            let split = BrowserSplitGroup(tabIDs: ids)
            let malformed = BrowserOrganizationDocument(tabs: organization.tabs, folders: [],
                favorites: organization.favorites,
                spaces: [.init(spaceID: f.home, pinned: [], today: [.split(split.id)])],
                archive: [], archivePolicy: organization.archivePolicy, splits: [split])
            let document = BrowserSessionDocument(profiles: saved.profiles, spaces: saved.spaces, windows: saved.windows,
                tabs: saved.tabs, organization: malformed)
            #expect(throws: BrowserSessionError.invalidSplitGroup) { try document.validate() }
        }
    }

    @Test("Invalid layout input is rejected and separation keeps live occurrences")
    func ratiosAndSeparation() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b"), c = try await f.open("c")
        let (id, _) = try await f.store.createSplit([a,b,c], from: f.context())
        for ratios in [[0.5,0.5], [0.0,0.5,0.5], [0.1,0.2,0.3], [Double.nan,0.5,0.5]] {
            await #expect(throws: BrowserSplitError.invalidRatios) { try await f.store.resizeSplit(id, ratios: ratios, from: f.context()) }
        }
        _ = try await f.store.resizeSplit(id, ratios: [0.2,0.3,0.5], from: f.context())
        _ = try await f.store.separateSplitPane(b, from: f.context())
        #expect(try await f.organization().split(containing: a)?.group.tabIDs == [a,c])
        #expect(await f.occurrences(of: b).count == 1)
        #expect(try await f.organization().selectedTab?.id == c)
        try await f.validate()
    }
}

extension BrowserSplitTests {
    @Test("Seeded split transactions retain an independent pane-order oracle through undo and redo",
          arguments: [UInt64(0x51217), 0x900D, 0xC0FFEE])
    func randomizedSplitOracle(seed: UInt64) async throws {
        let f = try await OrganizationFixture.make()
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(bound))
        }
        var ids: [TabID] = []
        for index in 0..<4 { ids.append(try await f.open("oracle-\(index)")) }
        let (id, _) = try await f.store.createSplit(ids, from: f.context())
        var expectedOrder = ids
        var orientation = BrowserSplitOrientation.horizontal
        for _ in 0..<60 {
            switch next(4) {
            case 0:
                let first = next(4), second = next(4)
                _ = try await f.store.swapSplitPanes(id, first: first, second: second, from: f.context())
                expectedOrder.swapAt(first, second)
            case 1:
                orientation = orientation == .horizontal ? .vertical : .horizontal
                _ = try await f.store.setSplitOrientation(orientation, for: id, from: f.context())
            case 2:
                let a = Double(next(10) + 1), b = Double(next(10) + 1), c = Double(next(10) + 1), d = Double(next(10) + 1)
                let sum = a+b+c+d
                _ = try await f.store.resizeSplit(id, ratios: [a/sum,b/sum,c/sum,d/sum], from: f.context())
            default:
                _ = try await f.store.unsplit(id, from: f.context())
                try await f.validate()
                _ = try await f.store.undoOrganization(from: f.context())
                _ = try await f.store.redoOrganization(from: f.context())
                _ = try await f.store.undoOrganization(from: f.context())
            }
            let actual = try #require(await f.store.sessionDocument().organization.splits.first)
            #expect(actual.tabIDs == expectedOrder)
            #expect(actual.orientation == orientation)
            #expect(actual.isValid)
            try await f.validate()
            let saved = await f.store.sessionDocument()
            #expect(try BrowserSessionDocument.decode(saved.encoded()) == saved)
        }
    }

    @Test("Group pin shortcut and Favorites drop feedback operate on the logical grouped row")
    func pinShortcutAndFavoriteRefusal() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        _ = try await f.store.togglePinSelectedTab(from: f.context())
        #expect(try await f.organization().pinned.map(\.node) == [.split(id)])
        let snapshot = try await f.organization()
        #expect(snapshot.validateMove([.split(id)], to: .init(.favorites(f.personal)),
                                     catalog: await f.store.catalogSnapshot()) == .invalidDestination)
        await #expect(throws: BrowserOrganizationError.invalidDestination) {
            try await f.store.addToFavorites([a,b], from: f.context())
        }
        _ = try await f.store.togglePinSelectedTab(from: f.context())
        #expect(try await f.organization().today.map(\.node) == [.split(id)])
        try await f.validate()
    }
}

extension BrowserSplitTests {
    @Test("Structural transaction oracle restores complete groups after removal, moves and archive",
          arguments: [0,1,2,3,4,5])
    func structuralUndoOracle(operation: Int) async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b"), c = try await f.open("c")
        let (id, _) = try await f.store.createSplit([a,b,c], from: f.context())
        _ = try await f.store.pinTabs([a,b,c], from: f.context())
        let (folder, _) = try await f.store.createFolder(title: "Synthetic folder", at: .init(.pinned(f.home)),
                                                       containing: [.split(id)], from: f.context())
        let before = await f.store.sessionDocument().organization
        switch operation {
        case 0: _ = try await f.store.deleteFolder(folder, contents: .archiveContents, from: f.context())
        case 1: _ = try await f.store.deleteFolder(folder, contents: .keepContents, from: f.context())
        case 2: _ = try await f.store.archiveTabs([a,b,c], from: f.context())
        case 3: _ = try await f.store.moveItems([.split(id)], to: .init(.today(f.leisure)), from: f.context())
        case 4: _ = try await f.store.separateSplitPane(b, from: f.context())
        default: _ = try await f.store.closeSplitPane(c, from: f.context())
        }
        try await f.validate()
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(await f.store.sessionDocument().organization == before)
        try await f.validate()
        _ = try await f.store.redoOrganization(from: f.context())
        try await f.validate()
    }
}

extension BrowserSplitTests {
    @Test("Redo and edits from another window materialize every visible pane")
    func rehydrateVisiblePeers() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a")
        _ = try await f.store.splitWithNewTab(url: organizationURL("b"), from: f.context())
        let id = try #require(await f.store.sessionDocument().organization.splits.first?.id)
        let b = try #require(try await f.organization().selectedTab?.id)
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(await f.occurrences(of: b).isEmpty)
        _ = try await f.store.redoOrganization(from: f.context())
        #expect(await f.occurrences(of: b).count == 1)
        _ = try await f.store.selectSplit(id, from: f.context(f.other))
        _ = try await f.store.splitWithNewTab(url: organizationURL("c"), from: f.context())
        let c = try #require(try await f.organization().selectedTab?.id)
        #expect(await f.occurrences(of: c, in: f.other).count == 1)
        _ = try await f.store.closeSplitPane(b, from: f.context())
        #expect(await f.occurrences(of: b, in: f.other).isEmpty)
        _ = try await f.store.undoOrganization(from: f.context())
        #expect(await f.occurrences(of: b, in: f.other).count == 1)
        #expect(try await f.organization(f.other).selectedTab?.id == a)
        try await f.validate()
    }

    @Test("A resize gesture cannot overwrite a later layout with the same window context")
    func staleResize() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        let baseline = try #require(await f.store.sessionDocument().organization.splits.first)
        _ = try await f.store.resizeSplit(id, ratios: [0.3,0.7], from: f.context())
        await #expect(throws: BrowserSplitError.staleLayout) {
            try await f.store.resizeSplit(id, ratios: [0.6,0.4], expectedGroup: baseline, from: f.context())
        }
        #expect(await f.store.sessionDocument().organization.splits.first?.ratios == [0.3,0.7])
    }

    @Test("Adding a pane and changing orientation for an edge drop is one undo record")
    func atomicDrop() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b"), c = try await f.open("c")
        let (id, _) = try await f.store.createSplit([a,b], from: f.context())
        _ = try await f.store.addPane(c, to: id, at: 0, orientation: .vertical, from: f.context())
        #expect(await f.store.sessionDocument().organization.splits.first?.tabIDs == [c,a,b])
        _ = try await f.store.undoOrganization(from: f.context())
        let group = try #require(await f.store.sessionDocument().organization.splits.first)
        #expect(group.tabIDs == [a,b])
        #expect(group.orientation == .horizontal)
        try await f.validate()
    }
}

extension BrowserSplitTests {
    @Test("Live group admission and release remain complete through peer reconciliation")
    func atomicGroupTransfer() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (id, _) = try await f.store.createSplit([a,b], orientation: .vertical, from: f.context())
        _ = try await f.store.resizeSplit(id, ratios: [0.3,0.7], from: f.context())
        let group = try #require(await f.store.sessionDocument().organization.splits.first)
        let source = try await f.store.captureWindowState(in: f.window)
        let sourceLeases = source.snapshot.tabs.filter { group.tabIDs.contains($0.id) }.compactMap { source.occurrenceAuthorities[$0.occurrenceID] }
        let admitted = try await f.store.openTransferredSplitOccurrences(group,
            urlsByTabID: [a: organizationURL("a-live"), b: organizationURL("b-live")],
            expectedExistingOccurrences: [:], from: f.context(f.other), activating: b)
        #expect(admitted.occurrenceIDs.count == 2)
        #expect(admitted.state.snapshot.tabs.count == 2)
        _ = try await f.store.createFolder(title: "Peer", at: .init(.pinned(f.home)), from: f.context())
        let released = try await f.store.releaseOwnedOccurrencesAndCaptureState(sourceLeases, validating: f.context())
        #expect(released.snapshot.tabs.isEmpty)
        _ = try await f.store.createFolder(title: "Peer again", at: .init(.pinned(f.home)), from: f.context(f.other))
        #expect(await f.occurrences(of: a).isEmpty)
        #expect(await f.occurrences(of: b).isEmpty)
        #expect(await f.occurrences(of: a, in: f.other).count == 1)
        #expect(await f.occurrences(of: b, in: f.other).count == 1)
        #expect(await f.store.sessionDocument().organization.splits.first == group)
        try await f.validate()
    }

    @Test("A late sibling occurrence or stale group rejects the complete batch before any write")
    func atomicGroupRefusal() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (_, _) = try await f.store.createSplit([a,b], from: f.context())
        let group = try #require(await f.store.sessionDocument().organization.splits.first)
        _ = try await f.store.selectSplit(group.id, from: f.context(f.other))
        let before = await f.store.sessionDocument()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.openTransferredSplitOccurrences(group, urlsByTabID: [a: organizationURL("a"), b: organizationURL("b")],
                expectedExistingOccurrences: [:], from: f.context(f.other), activating: a)
        }
        #expect(await f.store.sessionDocument() == before)
    }
}

extension BrowserSplitTests {
    @Test("An invalid last URL or last release lease leaves all group members unchanged")
    func atomicLastMemberFailure() async throws {
        let f = try await OrganizationFixture.make()
        let a = try await f.open("a"), b = try await f.open("b")
        let (_, state) = try await f.store.createSplit([a,b], from: f.context())
        let group = try #require(await f.store.sessionDocument().organization.splits.first)
        let before = await f.store.sessionDocument()
        await #expect(throws: BrowserSessionError.invalidURL) {
            try await f.store.openTransferredSplitOccurrences(group,
                urlsByTabID: [a: organizationURL("valid"), b: URL(string: "relative-destination")!],
                expectedExistingOccurrences: [:], from: f.context(f.other), activating: a)
        }
        #expect(await f.store.sessionDocument() == before)
        let leases = state.snapshot.tabs.compactMap { state.occurrenceAuthorities[$0.occurrenceID] }
        await #expect(throws: BrowserStoreError.staleContext) {
            try await f.store.releaseOwnedOccurrencesAndCaptureState([leases[0], BrowserOccurrenceAuthority(
                storeGeneration: leases[1].storeGeneration, windowID: f.other, spaceID: f.home,
                profileID: f.personal, occurrenceID: leases[1].occurrenceID)], validating: f.context())
        }
        #expect(await f.store.sessionDocument() == before)
    }
}
