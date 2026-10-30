import BrowserCore
import BrowserShell
import Foundation
import Testing

@MainActor
private final class OrganizationSurface: BrowserSurface {
    let profileID: ProfileID
    let initialURL: URL
    var currentURL: URL?
    var navigations: [URL] = []
    var disposalCount = 0

    init(profileID: ProfileID, url: URL) {
        self.profileID = profileID
        initialURL = url
        currentURL = url
    }

    func dispose() { disposalCount += 1 }
}

@MainActor
private final class OrganizationRecorder {
    var surfaces: [OrganizationSurface] = []
    var errors: [any Error] = []

    func session(_ store: BrowserStore, window: WindowID) -> BrowserWindowSession<OrganizationSurface> {
        let session = BrowserWindowSession(store: store, restoringWindowID: window) { profile, url in
            let surface = OrganizationSurface(profileID: profile, url: url)
            self.surfaces.append(surface)
            return surface
        }
        session.onError = { self.errors.append($0) }
        return session
    }
}

private struct SessionFixture: Sendable {
    let store: BrowserStore
    let personal: ProfileID
    let work: ProfileID
    let home: SpaceID
    let leisure: SpaceID
    let lab: SpaceID
    let window: WindowID
    let other: WindowID

    static func make() async throws -> SessionFixture {
        let store = BrowserStore()
        let personal = await store.createProfile(name: "Synthetic Personal")
        let work = await store.createProfile(name: "Synthetic Work")
        let home = try await store.createSpace(name: "Home", profileID: personal)
        let leisure = try await store.createSpace(name: "Leisure", profileID: personal)
        let lab = try await store.createSpace(name: "Lab", profileID: work)
        let window = try await store.createWindow(activeSpaceID: home)
        let other = try await store.createWindow(activeSpaceID: home)
        return SessionFixture(store: store, personal: personal, work: work, home: home, leisure: leisure,
                              lab: lab, window: window, other: other)
    }
}

private func url(_ path: String) -> URL { URL(string: "https://organization-session.test/\(path)")! }

@MainActor
private func tabID(at index: Int, in session: BrowserWindowSession<OrganizationSurface>) throws -> TabID {
    try #require(session.organization?.today[index].node.tabID)
}

@Suite("Window session organization commands")
@MainActor
struct BrowserOrganizationSessionTests {
    @Test("Repeated archive queries preserve command order without publishing or changing persisted state")
    func archiveReadsDoNotPublish() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        defer { session.close() }
        session.openTab(url: url("query-target"))
        await session.waitForPendingCommands()
        let id = try #require(session.organization?.selectedTab?.id)
        session.archiveTabs([id])
        let archived = await session.archivedTabs().value
        #expect(archived.map(\.id).contains(id))
        await session.waitForPendingCommands()
        let before = await fixture.store.sessionDocument()
        var publications = 0
        session.onChange = { publications += 1 }
        for _ in 0..<20 {
            #expect(await session.archivedTabs(matching: "query-target").value.count == 1)
        }
        #expect(publications == 0)
        #expect(await fixture.store.sessionDocument() == before)
        #expect(recorder.errors.isEmpty)
    }

    @Test("Archive restore and replay keep a selected surface in both windows and recover split focus")
    func archiveRestoreUndoSelection() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        let other = recorder.session(fixture.store, window: fixture.other)
        session.surfaceLoadingPolicy = .visibleOnly
        other.surfaceLoadingPolicy = .visibleOnly
        defer { session.close(); other.close() }
        session.openTab(url: url("favorite"))
        await session.waitForPendingCommands()
        let favorite = try #require(session.organization?.selectedTab?.id)
        session.addToFavorites([favorite])
        session.openTab(url: url("nested"))
        await session.waitForPendingCommands()
        let nested = try #require(session.organization?.selectedTab?.id)
        session.renameTab(nested, to: "Synthetic custom title")
        let parent = try #require(await session.createFolder(title: "Parent", at: .init(.pinned(fixture.home))).value)
        let child = try #require(await session.createFolder(title: "Child", at: .init(.folder(parent))).value)
        session.moveItems([.tab(nested)], to: .init(.folder(child)))
        session.openTab(url: url("left"))
        await session.waitForPendingCommands()
        let left = try #require(session.organization?.selectedTab?.id)
        session.openTab(url: url("right"))
        await session.waitForPendingCommands()
        let right = try #require(session.organization?.selectedTab?.id)
        session.createSplit([left, right])
        other.openTab(url: url("other"))
        await session.waitForPendingCommands()
        await other.waitForPendingCommands()
        session.synchronizeOrganization()
        await session.waitForPendingCommands()
        let selected = try #require(session.organization?.selectedTab?.id)
        let before = await fixture.store.sessionDocument().organization
        let ids = try #require(session.organization).allTabs.filter { $0.id != favorite }.map(\.id)

        func checkSelection() async {
            other.synchronizeOrganization()
            await other.waitForPendingCommands()
            for window in [session, other] {
                #expect(window.organization?.selectedTab != nil)
                #expect(window.selectedSurface != nil)
                #expect(window.selectedSurface?.currentURL == window.organization?.selectedTab?.url)
            }
        }

        session.archiveTabs(ids)
        await session.waitForPendingCommands()
        await checkSelection()
        for id in ids {
            session.restoreArchivedTab(id, activate: false)
            await session.waitForPendingCommands()
            #expect(session.organization?.today.first?.node == .tab(id))
            await checkSelection()
        }
        for _ in 0...ids.count {
            #expect(await session.undoOrganization().value != nil)
            await checkSelection()
        }
        let after = await fixture.store.sessionDocument().organization
        #expect(after.spaces == before.spaces && after.folders == before.folders && after.splits == before.splits)
        #expect(session.organization?.selectedTab?.id == selected)
        #expect(session.activeSplit?.tabs.allSatisfy { tab in
            tab.occurrenceID.flatMap { session.surface(for: $0) } != nil
        } == true)
        #expect(session.organization?.tab(nested)?.customTitle == "Synthetic custom title")
        #expect(recorder.errors.isEmpty)
    }

    @Test("Background restore into an empty window materializes a page without changing Today insertion")
    func backgroundRestoreIntoEmptyWindowSelects() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        session.surfaceLoadingPolicy = .visibleOnly
        defer { session.close() }
        session.openTab(url: url("only"))
        await session.waitForPendingCommands()
        let id = try #require(session.organization?.selectedTab?.id)
        session.archiveTabs([id])
        await session.waitForPendingCommands()
        #expect(session.selectedSurface == nil && session.organization?.allTabs.isEmpty == true)
        session.restoreArchivedTab(id, activate: false)
        await session.waitForPendingCommands()
        #expect(session.organization?.today.first?.node == .tab(id))
        #expect(session.organization?.selectedTab?.id == id)
        #expect(session.selectedSurface?.currentURL == url("only"))
        #expect(await session.undoOrganization().value != nil)
        #expect(session.selectedSurface == nil)
        #expect(await session.undoOrganization().value != nil)
        #expect(session.organization?.selectedTab?.id == id && session.selectedSurface != nil)
        #expect(recorder.errors.isEmpty)
    }

    @Test("Archiving the last live tab loads the next logical neighbour, or the previous one at the end",
          arguments: [false, true])
    func archiveLoadsDormantNeighbour(atEnd: Bool) async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        session.surfaceLoadingPolicy = .visibleOnly
        defer { session.close() }
        for path in ["first", "middle", "last"] { session.openTab(url: url(path)) }
        await session.waitForPendingCommands()
        let ids = try #require(session.organization).allTabs.map(\.id)
        session.pinTabs(ids)
        session.closeTabs(ids)
        await session.waitForPendingCommands()
        let order = try #require(session.organization).allTabs.map(\.id)
        let index = atEnd ? order.count - 1 : 1
        let selected = order[index]
        session.selectTab(selected)
        await session.waitForPendingCommands()
        session.archiveTabs([selected])
        await session.waitForPendingCommands()
        #expect(session.organization?.selectedTab?.id == order[atEnd ? index - 1 : index + 1])
        #expect(session.selectedSurface != nil)
        #expect(await session.undoOrganization().value != nil)
        #expect(session.organization?.selectedTab?.id == selected && session.selectedSurface != nil)
        #expect(await session.redoOrganization().value != nil)
        #expect(session.organization?.selectedTab?.id == order[atEnd ? index - 1 : index + 1])
        #expect(session.selectedSurface != nil && recorder.errors.isEmpty)
    }

    @Test("Closing the only live Today tab loads a dormant pin and undo rematerializes the closed page")
    func closeTodayLoadsDormantPin() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        session.surfaceLoadingPolicy = .visibleOnly
        defer { session.close() }
        session.openTab(url: url("pin"))
        await session.waitForPendingCommands()
        let pin = try #require(session.organization?.selectedTab?.id)
        session.pinTabs([pin])
        session.closeSelectedTab()
        session.openTab(url: url("today"))
        await session.waitForPendingCommands()
        let today = try #require(session.organization?.selectedTab?.id)
        session.closeSelectedTab()
        await session.waitForPendingCommands()
        #expect(session.organization?.selectedTab?.id == pin && session.selectedSurface != nil)
        #expect(await session.undoOrganization().value != nil)
        #expect(session.organization?.selectedTab?.id == today && session.selectedSurface?.currentURL == url("today"))
        #expect(recorder.errors.isEmpty)
    }

    @Test("The session publishes the organization with the window state and loads unloaded tabs on selection")
    func publishesAndLoadsOnSelection() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        let otherRecorder = OrganizationRecorder()
        let other = otherRecorder.session(fixture.store, window: fixture.other)
        session.observeOrganizationChanges()
        other.observeOrganizationChanges()
        session.openTab(url: url("a"))
        session.openTab(url: url("b"))
        await session.waitForPendingCommands()
        other.synchronizeOrganization()
        await other.waitForPendingCommands()
        #expect(session.organization?.todayIDs == other.organization?.todayIDs)
        #expect(other.organization?.today.count == 2 && otherRecorder.surfaces.isEmpty)
        let target = try tabID(at: 1, in: other)
        other.selectTab(target)
        await other.waitForPendingCommands()
        #expect(otherRecorder.surfaces.map(\.initialURL) == [url("a")])
        #expect(other.organization?.selectedTab?.id == target)
        #expect(other.selectedSurface === otherRecorder.surfaces.first)
        session.synchronizeOrganization()
        await session.waitForPendingCommands()
        #expect(session.organization?.tab(target)?.isOpenInAnotherWindow == true)
        #expect(recorder.errors.isEmpty && otherRecorder.errors.isEmpty)
        session.close()
        other.close()
        await session.waitForPendingCommands()
        await other.waitForPendingCommands()
    }

    @Test("Archiving a tab in one window disposes its live surface in another and adopts the new selection")
    func crossWindowArchiveRetiresSurfaces() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        let otherRecorder = OrganizationRecorder()
        let other = otherRecorder.session(fixture.store, window: fixture.other)
        other.observeOrganizationChanges()
        session.openTab(url: url("keep"))
        session.openTab(url: url("shared"))
        await session.waitForPendingCommands()
        other.synchronizeOrganization()
        await other.waitForPendingCommands()
        let shared = try tabID(at: 0, in: other)
        let keep = try tabID(at: 1, in: other)
        other.selectTab(keep)
        other.selectTab(shared)
        await other.waitForPendingCommands()
        let sharedSurface = try #require(other.selectedSurface)
        session.closeSelectedTab()
        await session.waitForPendingCommands()
        other.synchronizeOrganization()
        await other.waitForPendingCommands()
        #expect(sharedSurface.disposalCount == 1)
        #expect(other.organization?.todayIDs == [keep])
        #expect(other.organization?.selectedTab?.id == keep)
        // The out-of-band selection change does not make later commands stale.
        other.pinTabs([keep])
        await other.waitForPendingCommands()
        #expect(other.organization?.pinned.map(\.node) == [.tab(keep)])
        #expect(otherRecorder.errors.isEmpty)
        session.close()
        other.close()
        await session.waitForPendingCommands()
        await other.waitForPendingCommands()
    }

    @Test("Moving a live tab to another Space of the profile keeps its surface; another profile is refused")
    func spaceMovesRetainSurfaces() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        session.openTab(url: url("mail"))
        session.openTab(url: url("doc"))
        await session.waitForPendingCommands()
        let doc = try tabID(at: 0, in: session)
        let mail = try tabID(at: 1, in: session)
        let docSurface = try #require(session.selectedSurface)
        session.moveItems([.tab(doc)], to: .init(.pinned(fixture.leisure)))
        await session.waitForPendingCommands()
        #expect(docSurface.disposalCount == 0 && session.ownedSurfaces.contains { $0 === docSurface })
        #expect(session.organization?.today.map(\.node) == [.tab(mail)])
        session.activateSpace(fixture.leisure)
        session.selectTab(doc)
        await session.waitForPendingCommands()
        #expect(session.selectedSurface === docSurface && recorder.surfaces.count == 2)

        session.activateSpace(fixture.home)
        session.addToFavorites([mail])
        session.selectTab(mail)
        await session.waitForPendingCommands()
        let mailSurface = try #require(session.selectedSurface)
        session.activateSpace(fixture.leisure)
        session.selectTab(mail)
        await session.waitForPendingCommands()
        #expect(session.selectedSurface === mailSurface && mailSurface.disposalCount == 0)
        #expect(recorder.surfaces.count == 2)

        session.moveItems([.tab(doc)], to: .init(.today(fixture.lab)))
        await session.waitForPendingCommands()
        #expect(recorder.errors.last as? BrowserOrganizationError == .crossProfileMove)
        #expect(docSurface.disposalCount == 0)
        session.close()
        await session.waitForPendingCommands()
        #expect(recorder.surfaces.allSatisfy { $0.disposalCount == 1 })
    }

    @Test("Reset navigates the live surface to the pinned URL")
    func resetNavigatesSurface() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        session.openTab(url: url("home"))
        await session.waitForPendingCommands()
        let tab = try tabID(at: 0, in: session)
        session.pinTabs([tab])
        await session.waitForPendingCommands()
        let surface = try #require(session.selectedSurface)
        surface.currentURL = url("home/away")
        session.updateDestination(for: surface, to: url("home/away"))
        await session.waitForPendingCommands()
        #expect(session.organization?.tab(tab)?.isAwayFromPinnedURL == true)
        session.resetTabToPinnedURL(tab) { surface, destination in
            surface.navigations.append(destination)
            surface.currentURL = destination
        }
        await session.waitForPendingCommands()
        #expect(surface.navigations == [url("home")])
        #expect(session.organization?.tab(tab)?.isAwayFromPinnedURL == false)
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Undo of a close reopens the tab with a new surface and selects it; titles flow into the snapshot")
    func undoCloseAndTitles() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        session.openTab(url: url("first"))
        session.openTab(url: url("second"))
        await session.waitForPendingCommands()
        let second = try tabID(at: 0, in: session)
        let surface = try #require(session.selectedSurface)
        session.updatePageTitle(for: surface, to: "Second page")
        await session.waitForPendingCommands()
        #expect(session.organization?.tab(second)?.pageTitle == "Second page")
        session.renameTab(second, to: "Renamed")
        session.closeSelectedTab()
        await session.waitForPendingCommands()
        #expect(surface.disposalCount == 1 && session.organization?.undoAction == .closeTabs)
        session.undoOrganization()
        await session.waitForPendingCommands()
        let reopened = try #require(session.selectedSurface)
        #expect(reopened !== surface && reopened.initialURL == url("second"))
        #expect(session.organization?.selectedTab?.id == second)
        #expect(session.organization?.selectedTab?.title == "Renamed")
        let folder = await session.createFolder(title: "Saved", at: .init(.pinned(fixture.home)),
                                                containing: [.tab(second)]).value
        #expect(folder != nil && session.organization?.pinned.map(\.node) == [.folder(folder!)])
        session.closeTabs([second])
        await session.waitForPendingCommands()
        #expect(reopened.disposalCount == 1)
        #expect(session.organization?.pinned.map(\.node) == [.folder(folder!)])
        #expect(await session.archivedTabs().value.isEmpty)
        #expect(recorder.errors.isEmpty)
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Repeated candidate changes stop at the retry bound without replaying any record")
    func replayCandidateRetryBoundIsExplicit() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        for index in 0..<5 { session.openTab(url: url("bound-\(index)")) }
        await session.waitForPendingCommands()
        let organization = try #require(session.organization)
        let ids = organization.today.compactMap(\.node.tabID)
        for id in ids { session.renameTab(id, to: "Local") }
        await session.waitForPendingCommands()
        let peerContext = try await fixture.store.captureContext(in: fixture.other)
        let store = fixture.store
        var attempts = 0
        var peerTasks: [Task<Void, Error>] = []
        var completions = 0
        let replay = session.routeOrganizationReplay(undoing: true, choosingOrganization: {
            let id = ids[ids.count - 1 - attempts]
            attempts += 1
            let finished = DispatchSemaphore(value: 0)
            peerTasks.append(Task.detached {
                defer { finished.signal() }
                _ = try await store.renameTab(id, to: "Remote", from: peerContext)
            })
            #expect(finished.wait(timeout: .now() + 5) == .success)
            return true
        }, completion: { id in
            #expect(id == nil)
            completions += 1
        })
        #expect(await replay.value == nil)
        for peer in peerTasks { try await peer.value }
        #expect(attempts == 4 && completions == 1)
        #expect(recorder.errors.count == 1)
        #expect(recorder.errors.first as? BrowserOrganizationReplayError == .candidateChangedRepeatedly)
        session.synchronizeOrganization()
        await session.waitForPendingCommands()
        #expect(session.organization?.undoRecordCount == 5 && session.organization?.redoRecordID == nil)
        #expect(session.organization?.undoRecordID == 1)
        #expect(session.organization?.allTabs.filter { $0.customTitle == "Remote" }.count == 4)
        #expect(session.organization?.allTabs.filter { $0.customTitle == "Local" }.count == 1)
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Replay routing refreshes metadata-only peer conflicts and completes after publication, including retirement")
    func replayRoutingPublishesBeforeCompletion() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        session.openTab(url: url("pin"))
        session.openTab(url: url("rename"))
        await session.waitForPendingCommands()
        let y = try tabID(at: 0, in: session)
        let x = try tabID(at: 1, in: session)
        session.pinTabs([x])
        await session.waitForPendingCommands()
        let pinID = try #require(session.organization?.undoRecordID)
        session.renameTab(y, to: "Local")
        await session.waitForPendingCommands()
        let renameID = try #require(session.organization?.undoRecordID)
        // No observer is installed here: the session still sees Local and the same context.
        _ = try await fixture.store.renameTab(y, to: "Remote", from: fixture.store.captureContext(in: fixture.other))
        #expect(session.organization?.tab(y)?.customTitle == "Local")
        var choices: [UInt64?] = []
        var completions: [UInt64?] = []
        let replay = session.routeOrganizationReplay(undoing: true, choosingOrganization: {
            choices.append(session.organization?.undoRecordID)
            return true
        }, completion: { id in
            completions.append(id)
            #expect(session.organization?.redoRecordID == id)
            #expect(session.organization?.today.contains { $0.node == .tab(x) } == true)
        })
        #expect(await replay.value == pinID && pinID != renameID)
        #expect(choices == [pinID] && completions == [pinID])
        #expect(session.organization?.tab(y)?.customTitle == "Remote" && recorder.errors.isEmpty)
        session.close()
        await session.waitForPendingCommands()
        let retired = session.routeOrganizationReplay(undoing: false, choosingOrganization: {
            Issue.record("A retired session must not resolve another source")
            return true
        }, completion: { completions.append($0) })
        #expect(await retired.value == nil && completions == [pinID, nil])
    }
}

@Suite("Live surface transfers keep logical tabs")
@MainActor
struct BrowserOrganizationTransferTests {
    @Test("Moving a live tab to a window of the same Space keeps its identity, section and URL")
    func sameSpaceTransfer() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let source = recorder.session(fixture.store, window: fixture.window)
        let destination = recorder.session(fixture.store, window: fixture.other)
        source.openTab(url: url("today"))
        source.openTab(url: url("pinned"))
        await source.waitForPendingCommands()
        let pinned = try tabID(at: 0, in: source)
        let today = try tabID(at: 1, in: source)
        source.pinTabs([pinned])
        await source.waitForPendingCommands()
        let pinnedSurface = try #require(source.selectedSurface)
        pinnedSurface.currentURL = url("pinned/away")
        source.updateDestination(for: pinnedSurface, to: url("pinned/away"))
        await source.waitForPendingCommands()
        for (tab, surface) in [(pinned, pinnedSurface), (today, try #require(source.ownedSurfaces.first { $0 !== pinnedSurface }))] {
            let transfer = try #require(source.releaseSurface(surface))
            #expect(transfer.tabID == tab)
            let adopted = await destination.acceptTransfer(transfer).value
            await source.waitForPendingCommands()
            #expect(adopted != nil && destination.selectedSurface === surface && surface.disposalCount == 0)
            #expect(destination.organization?.selectedTab?.id == tab)
        }
        source.synchronizeOrganization()
        await source.waitForPendingCommands()
        #expect(source.organization?.pinned.map(\.node) == [.tab(pinned)])
        #expect(source.organization?.todayIDs == [today])
        #expect(source.organization?.allTabs.allSatisfy { $0.occurrenceID == nil && $0.isOpenInAnotherWindow } == true)
        #expect(destination.organization?.tab(pinned)?.url == url("pinned/away"))
        #expect(destination.organization?.tab(pinned)?.pinnedURL == url("pinned"))
        #expect(await destination.archivedTabs().value.isEmpty)
        #expect(recorder.errors.isEmpty && recorder.surfaces.allSatisfy { $0.disposalCount == 0 })
        source.close()
        destination.close()
        await source.waitForPendingCommands()
        await destination.waitForPendingCommands()
    }

    @Test("A window showing another Space of the profile receives the tab in its Today, without a ghost occurrence")
    func otherSpaceTransferBeforeRelease() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let source = recorder.session(fixture.store, window: fixture.window)
        let destination = recorder.session(fixture.store, window: fixture.other)
        destination.activateSpace(fixture.leisure)
        source.openTab(url: url("stay"))
        source.openTab(url: url("move"))
        await source.waitForPendingCommands()
        await destination.waitForPendingCommands()
        let moving = try tabID(at: 0, in: source)
        let surface = try #require(source.selectedSurface)
        // Occupy the source queue so the destination commits first.
        source.performWindowAction {}
        let transfer = try #require(source.releaseSurface(surface))
        let adopted = await destination.acceptTransfer(transfer).value
        await source.waitForPendingCommands()
        #expect(adopted != nil && destination.selectedSurface === surface)
        #expect(destination.organization?.todayIDs == [moving])
        source.synchronizeOrganization()
        await source.waitForPendingCommands()
        #expect(source.organization?.todayIDs.contains(moving) == false)
        let document = await fixture.store.sessionDocument()
        try document.validate()
        #expect(document.tabs.filter { $0.id == moving }.map(\.windowID) == [fixture.other])
        #expect(recorder.errors.isEmpty && surface.disposalCount == 0)
        source.close()
        destination.close()
        await source.waitForPendingCommands()
        await destination.waitForPendingCommands()
    }

    @Test("Commands that do not act on the selection adopt another window's archive of the visible tab")
    func queuedCommandsAdoptExternalArchive() async throws {
        let fixture = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let session = recorder.session(fixture.store, window: fixture.window)
        session.openTab(url: url("kept"))
        session.openTab(url: url("archived"))
        await session.waitForPendingCommands()
        let visible = try #require(session.organization?.selectedTab?.id)
        // Another window archives this window's visible tab; this session has not refreshed (it does
        // not observe), so every queued command starts from a stale context.
        _ = try await fixture.store.archiveTabs([visible], from: fixture.store.captureContext(in: fixture.other))
        session.renameSpace(fixture.home, name: "Renamed")
        session.moveSpace(fixture.lab, before: fixture.home)
        session.refreshCatalog()
        session.openTab(url: url("new"))
        await session.waitForPendingCommands()
        #expect(recorder.errors.isEmpty)
        #expect(session.catalog?.spaces.first { $0.id == fixture.home }?.name == "Renamed")
        #expect(session.catalog?.spaces.first?.id == fixture.lab)
        #expect(session.snapshot?.tabs.map(\.url) == [url("kept"), url("new")])
        #expect(session.organization?.selectedTab?.url == url("new"))

        // A command on the selection stays strict: the tab the user meant to close is gone.
        let current = try #require(session.organization?.selectedTab?.id)
        _ = try await fixture.store.archiveTabs([current], from: fixture.store.captureContext(in: fixture.other))
        session.closeSelectedTab()
        await session.waitForPendingCommands()
        #expect(recorder.errors.count == 1 && recorder.errors.first as? BrowserStoreError == .staleContext)
        #expect(try await fixture.store.snapshot(of: fixture.window).tabs.map(\.url) == [url("kept")])
        // Out-of-band selections and Space round trips stay refused (BrowserWindowSessionTests,
        // BrowserSpacesSessionTests): the store vouches only for organization reconciliation.
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Racing another window's archive of the visible tab against queued commands never loses one")
    func archiveRaceNeverLosesCommands() async throws {
        let iterations = 200
        var refused = 0
        var lost = 0
        for iteration in 0..<iterations {
            let fixture = try await SessionFixture.make()
            let recorder = OrganizationRecorder()
            let session = recorder.session(fixture.store, window: fixture.window)
            let otherRecorder = OrganizationRecorder()
            let other = otherRecorder.session(fixture.store, window: fixture.other)
            session.observeOrganizationChanges()
            other.observeOrganizationChanges()
            session.openTab(url: url("kept"))
            session.openTab(url: url("archived"))
            await session.waitForPendingCommands()
            await other.waitForPendingCommands()
            let visible = try #require(session.organization?.selectedTab?.id)
            let kept = try #require(session.organization?.today.compactMap(\.node.tabID).first { $0 != visible })
            other.archiveTabs([visible])
            // Odd runs race an organization command first, even runs a catalog command.
            if iteration.isMultiple(of: 2) {
                session.renameSpace(fixture.home, name: "Renamed \(iteration)")
                session.renameTab(kept, to: "Kept \(iteration)")
            } else {
                session.renameTab(kept, to: "Kept \(iteration)")
                session.renameSpace(fixture.home, name: "Renamed \(iteration)")
            }
            session.refreshCatalog()
            session.openTab(url: url("new"))
            await other.waitForPendingCommands()
            await session.waitForPendingCommands()
            refused += recorder.errors.count
            let renamed = session.catalog?.spaces.first { $0.id == fixture.home }?.name == "Renamed \(iteration)"
            let opened = try await fixture.store.snapshot(of: fixture.window).tabs.contains { $0.url == url("new") }
            let retitled = session.organization?.tab(kept)?.customTitle == "Kept \(iteration)"
            if !renamed || !opened || !retitled { lost += 1 }
            #expect(otherRecorder.errors.isEmpty)
            session.close()
            other.close()
            await session.waitForPendingCommands()
            await other.waitForPendingCommands()
        }
        print("ORG-R2 archive race: \(refused) refused commands, \(lost) runs with a lost action, of \(iterations) runs")
        #expect(refused == 0 && lost == 0)
    }
}

private extension BrowserOrganizationSnapshot {
    var todayIDs: [TabID] { today.compactMap(\.node.tabID) }
}

@Test("Folder preview activation rechecks its epoch in queue order without loading a dormant tab")
@MainActor
func folderPreviewQueuedSelection() async throws {
    let fixture = try await SessionFixture.make()
    let occurrence = try await fixture.store.openTab(url: url("preview-dormant"), from: fixture.store.captureContext(in: fixture.other), activate: false)
    let document = await fixture.store.sessionDocument()
    let tab = try #require(document.tabs.first { $0.occurrenceID == occurrence }?.id)
    let recorder = OrganizationRecorder()
    let session = recorder.session(fixture.store, window: fixture.window)
    await session.waitForPendingCommands()
    let expected = try #require(session.organization)
    let before = await fixture.store.sessionDocument()
    var current = true
    session.performWindowAction { current = false }
    session.selectTab(tab, expecting: expected, isCurrent: { current })
    await session.waitForPendingCommands()
    #expect(recorder.surfaces.isEmpty)
    #expect(await fixture.store.sessionDocument() == before)
    #expect(recorder.errors.isEmpty)
    session.close()
    await session.waitForPendingCommands()
}

extension BrowserOrganizationSessionTests {
    @Test("Export and replay adopt retired Spaces in peer sessions while retaining live documents")
    func exportAcrossSessions() async throws {
        let f = try await SessionFixture.make()
        let recorder = OrganizationRecorder()
        let owner = recorder.session(f.store, window: f.window)
        let peer = recorder.session(f.store, window: f.other)
        let localID = try await f.store.createStandaloneWindow(profileID: f.personal, homeSpaceID: f.home)
        let local = recorder.session(f.store, window: localID)
        defer { owner.close(); peer.close(); local.close() }
        for session in [owner, peer, local] {
            session.observeOrganizationChanges()
            await session.waitForPendingCommands()
        }
        peer.openTab(url: url("shared")); local.openTab(url: url("local"))
        await peer.waitForPendingCommands(); await local.waitForPendingCommands()
        let peerSurface = try #require(peer.selectedSurface)
        let localSurface = try #require(local.selectedSurface)
        owner.exportSpace(f.home, to: f.leisure)
        await owner.waitForPendingCommands()
        for session in [peer, local] {
            session.synchronizeOrganization()
            await session.waitForPendingCommands()
            #expect(session.snapshot?.activeSpaceID == f.leisure)
        }
        #expect(peer.selectedSurface === peerSurface && local.selectedSurface === localSurface)
        // Moving a peer's selected shared tab away remains a conflict until that peer closes.
        #expect(owner.organization?.undoAction != .exportSpace)
        peer.close()
        owner.undoOrganization(); await owner.waitForPendingCommands()
        #expect(owner.snapshot?.activeSpaceID == f.home)
        #expect(owner.catalog?.spaces.contains { $0.id == f.home } == true)
        owner.redoOrganization(); await owner.waitForPendingCommands()
        #expect(owner.snapshot?.activeSpaceID == f.leisure)
        #expect(recorder.errors.isEmpty)
        #expect(peerSurface.disposalCount == 1 && localSurface.disposalCount == 0)
    }
}
