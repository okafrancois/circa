@testable import BrowserCore
import Foundation
import Testing

@Suite("source browser import merge into the store")
struct OrbitImportMergeTests {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func plan(adopting profile: ProfileID?, items: [[String: Any]] = OrbitFixture.items(),
                      options: ArcImportOptions = ArcImportOptions()) throws -> BrowserImportPlan {
        ArcImportMapper.plan(try OrbitFixture.graph(sidebar: OrbitFixture.sidebar(items: items)), options: options,
                             defaultProfileTarget: profile, importedAt: now)
    }

    @Test("A first import adds every object without loading anything; the document stays valid")
    func firstImport() async throws {
        let store = BrowserStore(clock: { Date(timeIntervalSince1970: 1_760_000_000) })
        let existing = await store.createProfile(name: "Synthetic Existing")
        let home = try await store.createSpace(name: "Existing Home", profileID: existing)
        let window = try await store.createWindow(activeSpaceID: home)
        let plan = try plan(adopting: existing)
        let preview = await store.previewImport(plan, ledger: BrowserImportLedger())
        #expect(await store.catalogSnapshot().spaces.count == 1, "a preview never mutates")
        let result = try await store.applyImport(plan, ledger: BrowserImportLedger())
        #expect(result.counts == preview)
        #expect(result.counts.profilesAdded == 2 && result.counts.profilesPresent == 1)
        #expect(result.counts.spacesAdded == 3)
        #expect(result.counts.favoritesAdded == 3 && result.counts.pinnedTabsAdded == 5 && result.counts.pinnedFoldersAdded == 2)
        #expect(result.counts.todayTabsAdded == 3 && result.counts.archivedTabsAdded == 2)
        let document = await store.sessionDocument()
        try document.validate()
        #expect(document.profiles.map(\.name) == ["Synthetic Existing", "Synthetic Work", "Synthetic Other"])
        #expect(document.spaces.map(\.name) == ["Existing Home", "Space a", "Space b", "Space c"])
        #expect(document.tabs.isEmpty, "imported tabs have no live occurrence")
        #expect(document.windows.map(\.id) == [window])
        let a = document.spaces[1].id
        let sections = try #require(document.organization.spaces.first { $0.spaceID == a })
        #expect(sections.pinned.count == 4 && sections.today.count == 2)
        #expect(document.organization.favorites.first { $0.profileID == existing }?.items.count == 2)
        #expect(!result.ledger.profiles.contains(existing.rawValue), "an adopted profile is not an imported one")
    }

    @Test("Re-running adds nothing, keeps the user's changes and appends only new source browser objects")
    func idempotentRerun() async throws {
        let store = BrowserStore()
        let first = try plan(adopting: nil)
        var ledger = BrowserImportLedger()
        ledger.formUnion(try await store.applyImport(first, ledger: ledger).ledger)
        let before = await store.sessionDocument()
        let again = try await store.applyImport(first, ledger: ledger)
        #expect(again.counts.addedItems == 0 && again.counts.archivedTabsAdded == 0)
        #expect(again.counts.profilesAdded == 0 && again.counts.spacesAdded == 0)
        #expect(again.counts.itemsPresent == 15)
        #expect(await store.sessionDocument() == before)

        // The user renames an imported Space; Arc gains a new pinned tab.
        let a = before.spaces[0].id
        try await store.renameSpace(a, name: "Renamed by the user")
        var items = OrbitFixture.items()
        let pins = items.firstIndex { ($0["id"] as! String) == "a-pins" }!
        items[pins]["childrenIds"] = ["a-new"] + (items[pins]["childrenIds"] as! [String])
        items.append(OrbitFixture.tab("a-new", "a-pins"))
        let grown = try plan(adopting: nil, items: items)
        let third = try await store.applyImport(grown, ledger: ledger)
        #expect(third.counts.pinnedTabsAdded == 1 && third.counts.addedItems == 1)
        let document = await store.sessionDocument()
        #expect(document.spaces[0].name == "Renamed by the user")
        let pinned = try #require(document.organization.spaces.first { $0.spaceID == a }?.pinned)
        #expect(pinned.last == .tab(ArcImportIdentity().tab("a-new")), "new objects are appended")
    }

    @Test("Objects deleted after an import are not resurrected by a re-import")
    func noResurrection() async throws {
        let store = BrowserStore()
        let plan = try plan(adopting: nil)
        var ledger = BrowserImportLedger()
        ledger.formUnion(try await store.applyImport(plan, ledger: ledger).ledger)
        let a = await store.catalogSnapshot().spaces[0].id
        let window = try await store.createWindow(activeSpaceID: a)
        let context = try await store.captureContext(in: window)
        let today = ArcImportIdentity().tab("a-today-1")
        _ = try await store.archiveTabs([today], from: context)
        _ = try await store.deleteArchivedTabs([today], from: try await store.captureContext(in: window))
        let rerun = try await store.applyImport(plan, ledger: ledger)
        #expect(rerun.counts.itemsPreviouslyRemoved == 1 && rerun.counts.todayTabsAdded == 0)
        let sections = await store.sessionDocument().organization.spaces.first { $0.spaceID == a }
        #expect(sections?.today.contains(.tab(today)) == false)
    }

    @Test("An archived imported tab stays archived on re-import")
    func archivedStaysArchived() async throws {
        let store = BrowserStore()
        let plan = try plan(adopting: nil)
        let ledger = try await store.applyImport(plan, ledger: BrowserImportLedger()).ledger
        let a = await store.catalogSnapshot().spaces[0].id
        let window = try await store.createWindow(activeSpaceID: a)
        let tab = ArcImportIdentity().tab("a-today-2")
        _ = try await store.archiveTabs([tab], from: try await store.captureContext(in: window))
        let rerun = try await store.applyImport(plan, ledger: ledger)
        #expect(rerun.counts.todayTabsAdded == 0 && rerun.counts.itemsPresent >= 1)
        #expect(await store.sessionDocument().organization.archive.contains { $0.id == tab })
    }

    @Test("Archive records beyond the per-profile cap are evicted and counted")
    func archiveCap() async throws {
        let store = BrowserStore()
        try await store.setMaximumArchivedTabs(1)
        let result = try await store.applyImport(try plan(adopting: nil), ledger: BrowserImportLedger())
        // closed-a (Default) and closed-b (Profile 1): one record each, under a cap of one.
        #expect(result.counts.archivedTabsAdded == 2 && result.counts.archivedTabsEvicted == 0)
        // Placing the unattributed record in Default evicts that profile's older record.
        var options = ArcImportOptions()
        options.unattributedArchives = .defaultProfile
        let more = ArcImportMapper.plan(try OrbitFixture.graph(), options: options, defaultProfileTarget: nil, importedAt: now)
        let second = try await store.applyImport(more, ledger: result.ledger)
        #expect(second.counts.archivedTabsAdded == 1 && second.counts.archivedTabsEvicted == 1)
        try await store.sessionDocument().validate()
    }

    @Test("A failed merge leaves catalog and organization untouched")
    func atomicFailure() async throws {
        let store = BrowserStore()
        var broken = try plan(adopting: nil)
        // An archive record pointing at a Space of another profile violates the model invariants.
        let wrong = broken.archive[0]
        let otherProfile = broken.profiles.first { $0.id != wrong.profileID }!.id
        broken.archive[0] = BrowserArchivedTab(tab: wrong.tab, profileID: otherProfile, spaceID: wrong.spaceID,
                                               origin: wrong.origin, reason: wrong.reason, archivedAt: wrong.archivedAt)
        let before = await store.sessionDocument()
        await #expect(throws: BrowserSessionError.self) { try await store.applyImport(broken, ledger: BrowserImportLedger()) }
        #expect(await store.sessionDocument() == before)
        #expect(await store.catalogSnapshot().profiles.isEmpty)
    }

    @Test("Ledgers encode identities only, deterministically")
    func ledgerEncoding() throws {
        var ledger = BrowserImportLedger()
        ledger.tabs = [UUID(), UUID(), UUID()]
        let data = try ArcImportFiles.encoder().encode(ledger)
        #expect(try ArcImportFiles.encoder().encode(try ArcImportFiles.decoder().decode(BrowserImportLedger.self, from: data)) == data)
        #expect(try ArcImportFiles.decoder().decode(BrowserImportLedger.self, from: data) == ledger)
    }
}
