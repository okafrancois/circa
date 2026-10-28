import Foundation
import Testing
@testable import BrowserCore

@Suite("Sidebar organization model")
struct BrowserOrganizationStoreTests {
    @Test("A new tab is a Today tab of its Space, inserted at the top and shared by every window of the Space")
    func newTabsJoinSharedToday() async throws {
        let fixture = try await OrganizationFixture.make()
        let first = try await fixture.open("first")
        let second = try await fixture.open("second")
        let mine = try await fixture.organization()
        #expect(mine.todayIDs == [second, first])
        #expect(mine.tab(second)?.isSelected == true)
        #expect(mine.tab(first)?.occurrenceID != nil)
        let theirs = try await fixture.organization(fixture.other)
        #expect(theirs.todayIDs == [second, first])
        #expect(theirs.tab(second)?.occurrenceID == nil)
        #expect(theirs.tab(second)?.isOpenInAnotherWindow == true)
        #expect(theirs.tab(second)?.isLoadedInThisWindow == false)
        try await fixture.activate(fixture.leisure, in: fixture.other)
        #expect(try await fixture.organization(fixture.other).today.isEmpty)
        try await fixture.validate()
    }

    @Test("Favorites are shared by the Spaces of one profile and never appear in another profile")
    func favoritesFollowProfileBoundary() async throws {
        let fixture = try await OrganizationFixture.make()
        let mail = try await fixture.open("mail")
        _ = try await fixture.store.addToFavorites([mail], from: fixture.context())
        let home = try await fixture.organization()
        #expect(home.favoriteIDs == [mail])
        #expect(home.today.isEmpty)
        #expect(home.tab(mail)?.pinnedURL == organizationURL("mail"))
        try await fixture.activate(fixture.leisure, in: fixture.other)
        #expect(try await fixture.organization(fixture.other).favoriteIDs == [mail])
        try await fixture.activate(fixture.lab, in: fixture.other)
        let lab = try await fixture.organization(fixture.other)
        #expect(lab.favorites.isEmpty && lab.allTabs.isEmpty)
        await #expect(throws: BrowserOrganizationError.notVisibleInContext) {
            try await fixture.store.selectTab(mail, from: fixture.context(fixture.other))
        }
        await #expect(throws: BrowserOrganizationError.crossProfileMove) {
            try await fixture.store.moveItems([.tab(mail)], to: .init(.favorites(fixture.work)), from: fixture.context())
        }
        try await fixture.validate()
    }

    @Test("Pinning records a pinned URL that navigation never changes; unpinning clears it")
    func pinnedURLIsIndependentOfDestination() async throws {
        let fixture = try await OrganizationFixture.make()
        let docs = try await fixture.open("docs")
        _ = try await fixture.store.pinTabs([docs], from: fixture.context())
        var snapshot = try await fixture.organization()
        #expect(snapshot.pinnedNodes == [.tab(docs)] && snapshot.today.isEmpty)
        #expect(snapshot.undoAction == .pinTabs)
        let occurrence = try #require(snapshot.tab(docs)?.occurrenceID)
        try await fixture.store.updateDestination(for: occurrence, to: organizationURL("docs/deep"), from: fixture.context())
        snapshot = try await fixture.organization()
        #expect(snapshot.tab(docs)?.url == organizationURL("docs/deep"))
        #expect(snapshot.tab(docs)?.pinnedURL == organizationURL("docs"))
        #expect(snapshot.tab(docs)?.isAwayFromPinnedURL == true)
        _ = try await fixture.store.unpinTabs([docs], from: fixture.context())
        snapshot = try await fixture.organization()
        #expect(snapshot.todayIDs == [docs] && snapshot.pinned.isEmpty)
        #expect(snapshot.tab(docs)?.pinnedURL == nil)
        #expect(snapshot.tab(docs)?.isAwayFromPinnedURL == false)
        try await fixture.validate()
    }

    @Test("Toggle pin acts on the visible tab in both directions")
    func togglePinUsesVisibleTab() async throws {
        let fixture = try await OrganizationFixture.make()
        let tab = try await fixture.open("toggle")
        _ = try await fixture.store.togglePinSelectedTab(from: fixture.context())
        #expect(try await fixture.organization().pinnedNodes == [.tab(tab)])
        _ = try await fixture.store.togglePinSelectedTab(from: fixture.context())
        #expect(try await fixture.organization().todayIDs == [tab])
    }

    @Test("Reset returns a Pinned tab and its live occurrence exactly to the pinned URL")
    func resetToPinnedURL() async throws {
        let fixture = try await OrganizationFixture.make()
        let docs = try await fixture.open("docs")
        let wiki = try await fixture.open("wiki")
        _ = try await fixture.store.pinTabs([docs, wiki], from: fixture.context())
        let docsOccurrence = try #require(try await fixture.organization().tab(docs)?.occurrenceID)
        try await fixture.store.updateDestination(for: docsOccurrence, to: organizationURL("docs/a?b#c"),
                                                  from: fixture.context())
        let (reset, state) = try await fixture.store.resetTabToPinnedURL(docs, from: fixture.context())
        #expect(reset == BrowserOrganizationReset(tabID: docs, url: organizationURL("docs"), occurrenceID: docsOccurrence))
        #expect(state.organization.tab(docs)?.url == organizationURL("docs"))
        #expect(state.snapshot.tabs.first { $0.occurrenceID == docsOccurrence }?.url == organizationURL("docs"))
        let wikiOccurrence = try #require(state.organization.tab(wiki)?.occurrenceID)
        try await fixture.store.updateDestination(for: wikiOccurrence, to: organizationURL("wiki/page"), from: fixture.context())
        let (resets, _) = try await fixture.store.resetPinnedTabs(from: fixture.context())
        #expect(resets.map(\.tabID) == [wiki])
        let today = try await fixture.open("today")
        await #expect(throws: BrowserOrganizationError.notPinned) {
            try await fixture.store.resetTabToPinnedURL(today, from: fixture.context())
        }
    }

    @Test("Closing a Today tab archives it for every window; closing a Pinned tab only unloads it here")
    func closeSemanticsDependOnSection() async throws {
        let fixture = try await OrganizationFixture.make()
        let shared = try await fixture.open("shared")
        _ = try await fixture.store.selectTab(shared, from: fixture.context(fixture.other))
        #expect(await fixture.occurrences(of: shared, in: fixture.other).count == 1)
        let mine = try #require(await fixture.occurrences(of: shared).first)
        try await fixture.store.closeOccurrence(mine.occurrenceID, from: fixture.context())
        #expect(await fixture.occurrences(of: shared, in: fixture.other).isEmpty)
        #expect(try await fixture.organization(fixture.other).today.isEmpty)
        let archived = try await fixture.store.archivedTabs(from: fixture.context())
        #expect(archived.map(\.id) == [shared])
        #expect(archived.first?.reason == .closed && archived.first?.origin == .today)
        #expect(archived.first?.spaceID == fixture.home && archived.first?.profileID == fixture.personal)

        let pinned = try await fixture.open("pinned")
        _ = try await fixture.store.pinTabs([pinned], from: fixture.context())
        _ = try await fixture.store.selectTab(pinned, from: fixture.context(fixture.other))
        let occurrence = try #require(await fixture.occurrences(of: pinned).first)
        try await fixture.store.updateDestination(for: occurrence.occurrenceID, to: organizationURL("pinned/away"),
                                                  from: fixture.context())
        try await fixture.store.closeOccurrence(occurrence.occurrenceID, from: fixture.context())
        let after = try await fixture.organization()
        #expect(after.pinnedNodes == [.tab(pinned)])
        #expect(after.tab(pinned)?.occurrenceID == nil)
        #expect(after.tab(pinned)?.url == organizationURL("pinned"))
        #expect(await fixture.occurrences(of: pinned, in: fixture.other).count == 1)
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).count == 1)
        try await fixture.validate()
    }

    @Test("Closing a window keeps its logical tabs in the shared sidebar")
    func closingWindowKeepsSidebar() async throws {
        let fixture = try await OrganizationFixture.make()
        let tab = try await fixture.open("kept", in: fixture.other)
        try await fixture.store.closeWindow(fixture.other)
        let snapshot = try await fixture.organization()
        #expect(snapshot.todayIDs == [tab])
        #expect(snapshot.tab(tab)?.isOpenInAnotherWindow == false)
        _ = try await fixture.store.selectTab(tab, from: fixture.context())
        let selected = try await fixture.organization().selectedTab
        #expect(selected?.id == tab && selected?.url == organizationURL("kept"))
        try await fixture.validate()
    }

    @Test("Selecting a Favorite live in another Space of the window moves that same occurrence")
    func favoriteOccurrenceFollowsWindowAcrossSpaces() async throws {
        let fixture = try await OrganizationFixture.make()
        let mail = try await fixture.open("mail")
        _ = try await fixture.store.addToFavorites([mail], from: fixture.context())
        let original = try #require(await fixture.occurrences(of: mail).first)
        #expect(original.spaceID == fixture.home)
        try await fixture.activate(fixture.leisure)
        let leisure = try await fixture.organization()
        #expect(leisure.tab(mail)?.occurrenceID == nil && leisure.tab(mail)?.isLoadedInThisWindow == true)
        let state = try await fixture.store.selectTab(mail, from: fixture.context())
        #expect(state.snapshot.selectedOccurrenceID == original.occurrenceID)
        let moved = try #require(await fixture.occurrences(of: mail).first)
        #expect(moved.occurrenceID == original.occurrenceID && moved.spaceID == fixture.leisure)
        #expect(await fixture.occurrences(of: mail).count == 1)
        try await fixture.activate(fixture.home)
        #expect(try await fixture.store.snapshot(of: fixture.window).selectedOccurrenceID == nil)
        try await fixture.validate()
    }

    @Test("Selecting an unloaded sidebar tab opens one occurrence at its destination")
    func selectingUnloadedTabOpensOccurrence() async throws {
        let fixture = try await OrganizationFixture.make()
        let tab = try await fixture.open("remote", in: fixture.other)
        let state = try await fixture.store.selectTab(tab, from: fixture.context())
        let occurrence = try #require(state.organization.tab(tab)?.occurrenceID)
        #expect(state.snapshot.selectedOccurrenceID == occurrence)
        #expect(state.snapshot.tabs.map(\.url) == [organizationURL("remote")])
        #expect(state.organization.tab(tab)?.isOpenInAnotherWindow == true)
        _ = try await fixture.store.selectTab(tab, from: fixture.context())
        #expect(await fixture.occurrences(of: tab).count == 1)
    }

    @Test("Moves keep sidebar order, honor anchors, and relocate live occurrences within a profile")
    func movesReorderAndRelocate() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        let c = try await fixture.open("c")
        let d = try await fixture.open("d")
        #expect(try await fixture.organization().todayIDs == [d, c, b, a])
        // Argument order does not matter; the block keeps sidebar order.
        _ = try await fixture.store.moveItems([.tab(a), .tab(c)], to: .init(.today(fixture.home), position: .start),
                                              from: fixture.context())
        #expect(try await fixture.organization().todayIDs == [c, a, d, b])
        // An anchor that is itself moved keeps the block where the anchor was.
        _ = try await fixture.store.moveItems([.tab(b), .tab(a)], to: .init(.today(fixture.home), position: .before(.tab(a))),
                                              from: fixture.context())
        #expect(try await fixture.organization().todayIDs == [c, a, b, d])
        _ = try await fixture.store.moveItems([.tab(c)], to: .init(.today(fixture.home), position: .after(.tab(d))),
                                              from: fixture.context())
        #expect(try await fixture.organization().todayIDs == [a, b, d, c])
        await #expect(throws: BrowserOrganizationError.invalidPosition) {
            try await fixture.store.moveItems([.tab(a)], to: .init(.pinned(fixture.home), position: .before(.tab(b))),
                                              from: fixture.context())
        }

        let live = try #require(await fixture.occurrences(of: b).first)
        _ = try await fixture.store.moveItems([.tab(b)], to: .init(.pinned(fixture.leisure)), from: fixture.context())
        let relocated = try #require(await fixture.occurrences(of: b).first)
        #expect(relocated.occurrenceID == live.occurrenceID && relocated.spaceID == fixture.leisure)
        try await fixture.activate(fixture.leisure)
        let leisure = try await fixture.organization()
        #expect(leisure.pinnedNodes == [.tab(b)] && leisure.tab(b)?.occurrenceID == live.occurrenceID)
        #expect(leisure.tab(b)?.pinnedURL == organizationURL("b"))
        await #expect(throws: BrowserOrganizationError.crossProfileMove) {
            try await fixture.store.moveItems([.tab(b)], to: .init(.today(fixture.lab)), from: fixture.context())
        }
        await #expect(throws: BrowserOrganizationError.notVisibleInContext) {
            try await fixture.store.moveItems([.tab(a)], to: .init(.today(fixture.leisure)), from: fixture.context())
        }
        try await fixture.validate()
    }

    @Test("Folders nest, refuse cycles and non-Pinned sections, persist collapse state and delete explicitly")
    func folderLifecycle() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        let c = try await fixture.open("c")
        let (outer, _) = try await fixture.store.createFolder(title: "  Projects ", at: .init(.pinned(fixture.home)),
            containing: [.tab(a), .tab(b)], from: fixture.context())
        let (inner, _) = try await fixture.store.createFolder(title: "Archive", at: .init(.folder(outer), position: .start),
            containing: [.tab(c)], from: fixture.context())
        var snapshot = try await fixture.organization()
        #expect(snapshot.pinnedNodes == [.folder(outer)] && snapshot.today.isEmpty)
        #expect(snapshot.folder(outer)?.title == "Projects")
        #expect(snapshot.folder(outer)?.childNodes == [.folder(inner), .tab(b), .tab(a)])
        #expect(snapshot.folder(inner)?.childNodes == [.tab(c)])
        #expect(snapshot.tab(c)?.pinnedURL == organizationURL("c"))
        #expect(snapshot.rows().map(\.depth) == [0, 1, 2, 1, 1])

        await #expect(throws: BrowserOrganizationError.cycle) {
            try await fixture.store.moveItems([.folder(outer)], to: .init(.folder(inner)), from: fixture.context())
        }
        await #expect(throws: BrowserOrganizationError.cycle) {
            try await fixture.store.moveItems([.folder(outer)], to: .init(.folder(outer)), from: fixture.context())
        }
        await #expect(throws: BrowserOrganizationError.invalidDestination) {
            try await fixture.store.moveItems([.folder(inner)], to: .init(.today(fixture.home)), from: fixture.context())
        }
        await #expect(throws: BrowserOrganizationError.invalidDestination) {
            try await fixture.store.createFolder(title: "Nope", at: .init(.favorites(fixture.personal)), from: fixture.context())
        }
        await #expect(throws: BrowserOrganizationError.invalidTitle) {
            try await fixture.store.createFolder(title: " \n ", at: .init(.pinned(fixture.home)), from: fixture.context())
        }

        _ = try await fixture.store.setFolderCollapsed(inner, true, from: fixture.context())
        snapshot = try await fixture.organization(fixture.other)
        #expect(snapshot.folder(inner)?.isCollapsed == true)
        #expect(snapshot.rows().map(\.node) == [.folder(outer), .folder(inner), .tab(b), .tab(a)])
        #expect(snapshot.undoAction == nil)
        _ = try await fixture.store.setAllFoldersCollapsed(true, from: fixture.context())
        #expect(try await fixture.organization().rows().map(\.node) == [.folder(outer)])
        _ = try await fixture.store.setPinnedSectionCollapsed(true, from: fixture.context())
        #expect(try await fixture.organization().rows().isEmpty)
        #expect(try await fixture.organization().rows(includingCollapsed: true).count == 5)
        _ = try await fixture.store.renameFolder(outer, to: "Work", from: fixture.context())
        #expect(try await fixture.organization().folder(outer)?.title == "Work")

        _ = try await fixture.store.deleteFolder(outer, contents: .keepContents, from: fixture.context())
        snapshot = try await fixture.organization()
        #expect(snapshot.pinnedNodes == [.folder(inner), .tab(b), .tab(a)])
        _ = try await fixture.store.deleteFolder(inner, contents: .archiveContents, from: fixture.context())
        snapshot = try await fixture.organization()
        #expect(snapshot.pinnedNodes == [.tab(b), .tab(a)])
        let archived = try await fixture.store.archivedTabs(from: fixture.context())
        #expect(archived.map(\.id) == [c] && archived[0].reason == .removed && archived[0].origin == .pinned)
        try await fixture.validate()
    }

    @Test("Custom titles survive navigation and web title updates; blank restores the web title")
    func renameKeepsCustomTitle() async throws {
        let fixture = try await OrganizationFixture.make()
        let tab = try await fixture.open("titled")
        let occurrence = try #require(await fixture.occurrences(of: tab).first)
        let context = try await fixture.context()
        let authority = try await fixture.store.captureOccurrenceAuthority(for: occurrence.occurrenceID, from: context)
        #expect(try await fixture.store.updatePageTitle("Web\u{0007} title ", from: authority))
        #expect(try await !fixture.store.updatePageTitle("Web  title", from: authority))
        _ = try await fixture.store.renameTab(tab, to: "  Mine ", from: fixture.context())
        try await fixture.store.updateDestination(to: organizationURL("titled/next"), from: authority)
        #expect(try await fixture.store.updatePageTitle("Next page", from: authority))
        var item = try #require(try await fixture.organization().tab(tab))
        #expect(item.customTitle == "Mine" && item.pageTitle == "Next page" && item.title == "Mine")
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await fixture.store.sessionDocument().encoded()))
        item = try #require(try await restored.organizationSnapshot(from: restored.captureContext(in: fixture.window)).tab(tab))
        #expect(item.customTitle == "Mine" && item.pageTitle == "Next page")
        await #expect(throws: BrowserOrganizationError.invalidTitle) {
            try await fixture.store.renameTab(tab, to: "bad\u{0000}title", from: fixture.context())
        }
        _ = try await fixture.store.renameTab(tab, to: "   ", from: fixture.context())
        item = try #require(try await fixture.organization().tab(tab))
        #expect(item.customTitle == nil && item.title == "Next page")
    }

    @Test("A batch with one invalid item leaves the whole model unchanged")
    func batchesAreAtomic() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        let foreign = try await fixture.open("foreign")
        _ = try await fixture.store.moveItems([.tab(foreign)], to: .init(.today(fixture.leisure)), from: fixture.context())
        let before = try await fixture.store.sessionDocument().encoded()
        for command in [
            { try await fixture.store.pinTabs([a, foreign, b], from: fixture.context()) },
            { try await fixture.store.archiveTabs([a, TabID()], from: fixture.context()) },
            { try await fixture.store.closeTabs([b, foreign], from: fixture.context()) }
        ] as [@Sendable () async throws -> BrowserWindowState] {
            await #expect(throws: (any Error).self) { try await command() }
            #expect(try await fixture.store.sessionDocument().encoded() == before)
        }
        await #expect(throws: BrowserOrganizationError.emptySelection) {
            try await fixture.store.moveItems([], to: .init(.pinned(fixture.home)), from: fixture.context())
        }
    }

    @Test("Organization commands require the current window context")
    func staleContextsAreRejected() async throws {
        let fixture = try await OrganizationFixture.make()
        let tab = try await fixture.open("tab")
        let stale = try await fixture.context()
        _ = try await fixture.open("newer")
        await #expect(throws: BrowserStoreError.staleContext) {
            try await fixture.store.pinTabs([tab], from: stale)
        }
        await #expect(throws: BrowserStoreError.staleContext) {
            try await fixture.store.organizationSnapshot(from: stale)
        }
    }

    @Test("Observers receive a revision after shared changes, not after selection-only changes")
    func observersSeeSharedChanges() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        let stream = await fixture.store.organizationChanges()
        var iterator = stream.makeAsyncIterator()
        let start = await fixture.store.currentOrganizationRevision()
        let occurrence = try #require(await fixture.occurrences(of: a).first)
        try await fixture.store.selectOccurrence(occurrence.occurrenceID, in: fixture.window)
        #expect(await fixture.store.currentOrganizationRevision() == start)
        _ = try await fixture.store.pinTabs([b], from: fixture.context())
        let revision = await iterator.next()
        #expect(revision == start + 1)
    }

    @Test("A transferred document keeps its logical tab whichever window commits first")
    func transfersKeepLogicalTabs() async throws {
        let fixture = try await OrganizationFixture.make()
        let pinned = try await fixture.open("pinned")
        _ = try await fixture.store.pinTabs([pinned], from: fixture.context())
        let moving = try await fixture.open("moving")
        let source = try #require(await fixture.occurrences(of: moving).first)
        let sourceContext = try await fixture.context()
        let authority = try await fixture.store.captureOccurrenceAuthority(for: source.occurrenceID, from: sourceContext)
        // The receiver shows another Space of the profile and commits before the source releases.
        try await fixture.activate(fixture.leisure, in: fixture.other)
        let received = try await fixture.store.openTransferredOccurrence(
            of: moving, url: organizationURL("moving/live"), from: fixture.context(fixture.other), activate: true)
        #expect(try await fixture.organization(fixture.other).todayIDs == [moving])
        #expect(!(await fixture.store.isCurrent(sourceContext)))
        let state = try await fixture.store.releaseOwnedOccurrenceAndCaptureState(authority, validating: sourceContext)
        #expect(state.snapshot.tabs.allSatisfy { $0.id != moving })
        #expect(await fixture.occurrences(of: moving).isEmpty)
        #expect(await fixture.occurrences(of: moving, in: fixture.other).map(\.occurrenceID) == [received])
        #expect(try await fixture.store.archivedTabs(from: fixture.context()).isEmpty)

        // Releasing first, then receiving in the same Space, keeps a Pinned tab pinned and unreset.
        let pinnedOccurrence = try #require(await fixture.occurrences(of: pinned).first)
        try await fixture.store.updateDestination(for: pinnedOccurrence.occurrenceID, to: organizationURL("pinned/away"),
                                                  from: fixture.context())
        let pinnedAuthority = try await fixture.store.captureOccurrenceAuthority(
            for: pinnedOccurrence.occurrenceID, from: fixture.context())
        _ = try await fixture.store.releaseOwnedOccurrenceAndCaptureState(pinnedAuthority, validating: fixture.context())
        try await fixture.activate(fixture.home, in: fixture.other)
        _ = try await fixture.store.openTransferredOccurrence(
            of: pinned, url: organizationURL("pinned/away"), from: fixture.context(fixture.other), activate: true)
        let receiver = try await fixture.organization(fixture.other)
        #expect(receiver.pinnedNodes == [.tab(pinned)] && receiver.selectedTab?.id == pinned)
        #expect(receiver.tab(pinned)?.url == organizationURL("pinned/away"))
        // Without a usable logical tab, a transfer becomes a new Today tab.
        let fresh = try await fixture.store.openTransferredOccurrence(
            of: nil, url: organizationURL("peek"), from: fixture.context(fixture.other), activate: false)
        let freshTab = try await fixture.occurrence(fresh, in: fixture.other).id
        #expect(try await fixture.organization(fixture.other).todayIDs.first == freshTab)
        try await fixture.validate()
    }

    @Test("Randomized organization commands always keep every invariant and round-trip losslessly")
    func randomizedCommandsPreserveInvariants() async throws {
        let fixture = try await OrganizationFixture.make()
        var generator = SplitMix64(seed: 0xA5C1_2026)
        var folders: [FolderID] = []
        var succeeded: [UInt64: Int] = [:]
        for step in 0..<300 {
            let windowID = generator.next() % 3 == 0 ? fixture.other : fixture.window
            let spaces = [fixture.home, fixture.leisure, fixture.lab]
            if generator.next() % 7 == 0 { try await fixture.activate(spaces[Int(generator.next() % 3)], in: windowID) }
            let context = try await fixture.context(windowID)
            let before = await fixture.store.sessionDocument()
            let snapshot = try await fixture.store.organizationSnapshot(from: context)
            let tabs = snapshot.allTabs.map(\.id)
            let rows = snapshot.rows(includingCollapsed: true).map(\.node)
            func pick<T>(_ values: [T]) -> T? { values.isEmpty ? nil : values[Int(generator.next() % UInt64(values.count))] }
            let localFolders = rows.compactMap(\.folderID)
            let containers: [BrowserOrganizationContainer] = [.favorites(context.profileID), .pinned(context.spaceID),
                .today(context.spaceID), .pinned(fixture.leisure), .today(fixture.home)] + localFolders.map { .folder($0) }
            let kind = generator.next() % 12
            do {
                switch kind {
                case 0, 1: _ = try await fixture.open("step\(step)", in: windowID, activate: generator.next() % 2 == 0)
                case 2: if let tab = pick(tabs) { _ = try await fixture.store.selectTab(tab, from: context) }
                case 3, 4:
                    let nodes = rows.filter { _ in generator.next() % 3 == 0 }
                    if let container = pick(containers), !nodes.isEmpty {
                        _ = try await fixture.store.moveItems(nodes, to: .init(container, position: .start), from: context)
                    }
                case 5:
                    let (folder, _) = try await fixture.store.createFolder(title: "F\(step)",
                        at: .init(pick(localFolders).map { .folder($0) } ?? .pinned(context.spaceID)),
                        containing: tabs.filter { _ in generator.next() % 4 == 0 }.map { .tab($0) }, from: context)
                    folders.append(folder)
                case 6: if let tab = pick(tabs) { _ = try await fixture.store.closeTabs([tab], from: context) }
                case 7: if let folder = pick(localFolders) {
                    _ = try await fixture.store.deleteFolder(folder, contents: generator.next() % 2 == 0
                        ? .keepContents : .archiveContents, from: context)
                }
                case 8: _ = try await fixture.store.undoOrganization(from: context)
                case 9: _ = try await fixture.store.redoOrganization(from: context)
                case 10:
                    if let record = pick(try await fixture.store.archivedTabs(from: context)) {
                        _ = try await fixture.store.restoreArchivedTab(record.id, activate: generator.next() % 2 == 0, from: context)
                    }
                default:
                    fixture.clock.advance(by: 3_600 * Double(generator.next() % 30))
                    _ = await fixture.store.archiveExpiredTabs()
                }
                // Only a command that changed the session counts; no-op branches do not.
                if await fixture.store.sessionDocument() != before { succeeded[kind, default: 0] += 1 }
            } catch is BrowserOrganizationError {
                // Refusals (cycles, conflicts, empty journals) are expected; invariants are checked below.
            }
            let document = await fixture.store.sessionDocument()
            try document.validate()
            let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(document.encoded()))
            #expect(await restored.sessionDocument() == document)
        }
        #expect(!folders.isEmpty)
        // Every command family, including undo, redo, restoration and sweeps, changed the session.
        #expect(Set(succeeded.keys) == Set(0..<12))
        #expect(succeeded.values.reduce(0, +) > 150)
    }
}

/// Small deterministic generator for reproducible randomized tests.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
