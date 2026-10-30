import Foundation
import Testing
@testable import BrowserCore

struct LiveFolderModelTests {
    let date = Date(timeIntervalSince1970: 100)
    let folderID = FolderID(UUID(uuidString: "00000000-0000-0000-0000-000000000050")!)

    func item(_ id: String = "PR_1", title: String = "Synthetic request", fingerprint: String = "revision-1") -> BrowserLiveFolderFetchedItem {
        .init(identity: .init(itemID: id), url: URL(string: "https://example.invalid/pulls/\(id)")!, title: title, fingerprint: fingerprint)
    }
    func folder() -> BrowserOrganizedFolder {
        .init(id: folderID, title: "Requests", createdAt: date, liveFolder: .init())
    }
    func reconcile(_ folder: BrowserOrganizedFolder, _ rows: [BrowserOrganizedTab] = [],
                   items: [BrowserLiveFolderFetchedItem], coverage: BrowserLiveFolderFetch.Coverage = .complete,
                   preserving: Set<TabID> = [], fetchedGeneration: UInt64 = 1) throws -> BrowserLiveFolderReconciler.Result {
        try BrowserLiveFolderReconciler.reconcile(folder, children: rows,
            fetched: .init(generation: fetchedGeneration, coverage: coverage, items: items), generation: 1,
            preserving: preserving, now: date)
    }
    func fixture() async throws -> (OrganizationFixture, FolderID, UInt64) {
        let f = try await OrganizationFixture.make()
        let id = try await f.store.createLiveFolder(title: "Requests", configuration: .init(),
            at: .init(.pinned(f.home)), from: f.context())
        let generation = await f.store.liveFolderLocalStore(for: f.personal).generation(for: .githubPullRequests)
        return (f, id, generation)
    }
    func fetch(_ f: OrganizationFixture, _ id: FolderID, _ generation: UInt64,
               _ items: [BrowserLiveFolderFetchedItem], coverage: BrowserLiveFolderFetch.Coverage = .complete) async throws -> Bool {
        try await f.store.reconcileLiveFolder(id, profileID: f.personal,
            fetched: .init(generation: generation, coverage: coverage, items: items))
    }
    func project(_ session: BrowserSessionDocument) throws -> BrowserSyncProjection {
        try BrowserSyncMapping.project(session: session, settings: .init())
    }
    func materialize(_ replica: BrowserSyncReplica, local: BrowserSessionDocument) throws -> BrowserSessionDocument {
        let value = try BrowserSyncMapping.materialize(replica.visible, local: local, settings: .init())
        let next = BrowserSessionDocument(profiles: value.profiles, spaces: value.spaces, windows: [], tabs: [], organization: value.organization)
        try next.validate()
        return next
    }

    @Test func oldFolderEncodingIsUnchanged() throws {
        let old = "{\"children\":[],\"createdAt\":-978307100,\"id\":{\"rawValue\":\"00000000-0000-0000-0000-000000000050\"},\"isCollapsed\":false,\"title\":\"Requests\"}"
        let decoded = try JSONDecoder().decode(BrowserOrganizedFolder.self, from: Data(old.utf8))
        #expect(decoded.liveFolder == nil)
        #expect(try BrowserSyncReplica.encodeValue(decoded) == Data(old.utf8))
        let tab = BrowserOrganizedTab(id: TabID(), url: item().url, createdAt: date, lastActiveAt: date)
        #expect(!String(decoding: try BrowserSyncReplica.encodeValue(tab), as: UTF8.self).contains("liveFolderChild"))
    }

    @Test func configuredDocumentRoundTrip() async throws {
        let (f, id, generation) = try await fixture()
        #expect(try await fetch(f, id, generation, [item()]))
        let session = await f.store.sessionDocument()
        let bytes = try BrowserSyncReplica.encodeValue(session)
        let restored = try JSONDecoder().decode(BrowserSessionDocument.self, from: bytes)
        #expect(restored == session)
        try restored.validate()
        #expect(try BrowserSyncReplica.encodeValue(restored) == bytes)
        #expect(restored.organization.folders.first?.liveFolder?.filters == [.authored, .reviewRequested])
    }

    @Test func configurationSetEncodingIsCanonical() throws {
        let config = BrowserLiveFolderConfiguration(filters: Set(BrowserLiveFolderFilter.allCases),
                                                     excludedRepositories: ["example/a", "example/b", "example/c"])
        let first = try BrowserSyncReplica.encodeValue(config)
        for _ in 0..<20 { #expect(try BrowserSyncReplica.encodeValue(config) == first) }
        #expect(try JSONDecoder().decode(BrowserLiveFolderConfiguration.self, from: first) == config)
    }

    @Test func identitySurvivesReorderRenameAndDuplicateFetches() throws {
        let initial = try reconcile(folder(), items: [item(), item("PR_2")])
        let next = try reconcile(initial.folder, initial.children,
            items: [item("PR_2", title: "Renamed"), item(), item("PR_2")])
        #expect(next.children.map(\.id) == initial.children.map(\.id).reversed())
        #expect(next.children.first?.pageTitle == "Renamed")
        #expect(next.children.first?.createdAt == date)
        #expect(item().identity.tabID(in: folderID) != item().identity.tabID(in: FolderID()))
    }

    @Test func partialNeverRemovesCompleteDoes() throws {
        let first = try reconcile(folder(), items: [item(), item("PR_2")])
        let partial = try reconcile(first.folder, first.children, items: [item("PR_3")], coverage: .partial)
        #expect(partial.children.count == 3 && partial.removed.isEmpty)
        let complete = try reconcile(partial.folder, partial.children, items: [item("PR_2")])
        #expect(complete.children.count == 1 && complete.removed.count == 2)
        let emptyPartial = try reconcile(complete.folder, complete.children, items: [], coverage: .partial)
        #expect(emptyPartial.folder == complete.folder)
        #expect(try reconcile(complete.folder, complete.children, items: []).removed.count == 1)
    }

    @Test func pureReconciliationPreservesVisibleOrdinaryTab() throws {
        let first = try reconcile(folder(), items: [item()])
        let id = try #require(first.children.first?.id)
        let next = try reconcile(first.folder, first.children, items: [], preserving: [id])
        #expect(next.children.isEmpty && next.removed.isEmpty)
        #expect(next.preserved.first?.id == id)
        #expect(next.preserved.first?.liveFolderChild == nil && next.preserved.first?.pinnedURL == nil)
    }

    @Test func staleGenerationDoesNotMutateAnything() throws {
        let first = try reconcile(folder(), items: [item()])
        let stale = try reconcile(first.folder, first.children, items: [], fetchedGeneration: 0)
        #expect(!stale.accepted && stale.folder == first.folder && stale.children == first.children)
    }

    @Test func localReadStateIsProfileScopedAndReflagsMaterialChanges() throws {
        let profile = ProfileID(), other = ProfileID(), identity = item().identity
        var local = BrowserLiveFolderLocalStore(profileID: profile)
        #expect(local.isUnread(identity, fingerprint: "one"))
        local.acknowledge(identity, fingerprint: "one")
        #expect(!local.isUnread(identity, fingerprint: "one"))
        #expect(local.isUnread(identity, fingerprint: "two"))
        #expect(BrowserLiveFolderLocalStore(profileID: other).isUnread(identity, fingerprint: "one"))
        let decoded = try JSONDecoder().decode(BrowserLiveFolderLocalStore.self, from: BrowserSyncReplica.encodeValue(local))
        #expect(decoded == local)
        local.resetConnection(for: .githubPullRequests)
        #expect(local.isUnread(identity, fingerprint: "one"))
        #expect(local.generation(for: .githubPullRequests) == 1)
    }

    @Test func selectingAcknowledgesAndClosedSelectionKeepsOccurrence() async throws {
        let (f, id, gen) = try await fixture()
        try await fetch(f, id, gen, [item()])
        let tabID = item().identity.tabID(in: id)
        #expect(await f.store.liveFolderLocalStore(for: f.personal).isUnread(item().identity, fingerprint: item().fingerprint))
        _ = try await f.store.selectTab(tabID, from: f.context())
        #expect(await !f.store.liveFolderLocalStore(for: f.personal).isUnread(item().identity, fingerprint: item().fingerprint))
        let occurrence = try #require(await f.occurrences(of: tabID).first)
        try await fetch(f, id, gen, [item(fingerprint: "revision-2")])
        #expect(await f.store.liveFolderLocalStore(for: f.personal).isUnread(item().identity, fingerprint: "revision-2"))
        _ = try await f.store.selectTab(tabID, from: f.context())
        #expect(await !f.store.liveFolderLocalStore(for: f.personal).isUnread(item().identity, fingerprint: "revision-2"))
        try await fetch(f, id, gen, [])
        let document = await f.store.sessionDocument()
        #expect(document.organization.tabs.first?.liveFolderChild == nil)
        #expect(document.organization.spaces.first { $0.spaceID == f.home }?.today.contains(.tab(tabID)) == true)
        #expect(await f.occurrences(of: tabID).first?.occurrenceID == occurrence.occurrenceID)
        try await f.validate()
    }

    @Test func pinnedCopySurvivesUpstreamRemoval() async throws {
        let (f, id, gen) = try await fixture()
        try await fetch(f, id, gen, [item()])
        _ = try await f.store.pinTabs([item().identity.tabID(in: id)], from: f.context())
        let copy = try #require(await f.store.sessionDocument().organization.tabs.first { $0.liveFolderChild == nil })
        #expect(copy.id != item().identity.tabID(in: id) && copy.pinnedURL == item().url)
        try await fetch(f, id, gen, [])
        #expect(await f.store.sessionDocument().organization.tabs == [copy])
        try await f.validate()
    }

    @Test func ordinaryCommandsRefuseProviderRowsAndDestinations() async throws {
        let (f, id, gen) = try await fixture()
        try await fetch(f, id, gen, [item(), item("PR_2")])
        let tab = item().identity.tabID(in: id), second = item("PR_2").identity.tabID(in: id)
        let ordinary = try await f.open("ordinary")
        let context = try await f.context()
        let before = await f.store.sessionDocument()
        await #expect(throws: BrowserOrganizationError.providerOwnedItem) { try await f.store.renameTab(tab, to: "No", from: context) }
        await #expect(throws: BrowserOrganizationError.providerOwnedItem) { try await f.store.moveItems([.tab(tab)], to: .init(.pinned(f.home)), from: context) }
        await #expect(throws: BrowserOrganizationError.providerOwnedItem) { try await f.store.moveItems([.tab(ordinary)], to: .init(.folder(id)), from: context) }
        await #expect(throws: BrowserOrganizationError.providerOwnedItem) { try await f.store.createFolder(title: "Nested", at: .init(.folder(id)), from: context) }
        await #expect(throws: BrowserOrganizationError.providerOwnedItem) { try await f.store.createFolder(title: "Wrapping", at: .init(.pinned(f.home)), containing: [.tab(tab)], from: context) }
        await #expect(throws: BrowserOrganizationError.providerOwnedItem) { try await f.store.archiveTabs([tab], from: context) }
        await #expect(throws: BrowserOrganizationError.providerOwnedItem) { try await f.store.createSplit([tab, second], from: context) }
        #expect(await f.store.sessionDocument() == before)
        try await f.validate()
    }

    @Test func deletingDisablesAutomaticRecreationUntilExplicitEnable() async throws {
        let (f, id, gen) = try await fixture()
        try await fetch(f, id, gen, [item()])
        _ = try await f.store.deleteFolder(id, contents: .archiveContents, from: f.context())
        #expect(await !f.store.liveFolderLocalStore(for: f.personal).allowsAutomaticCreation(for: .githubPullRequests))
        #expect(await f.store.sessionDocument().organization.archive.isEmpty)
        let config = BrowserLiveFolderConfiguration(creation: .automatic)
        await #expect(throws: BrowserOrganizationError.providerOwnedItem) {
            try await f.store.createLiveFolder(title: "Requests", configuration: config, at: .init(.pinned(f.home)), from: f.context())
        }
        #expect(try await !fetch(f, id, gen, [item()]))
        try await f.store.reenableLiveFolders(for: .githubPullRequests, profileID: f.personal)
        _ = try await f.store.createLiveFolder(title: "Requests", configuration: config, at: .init(.pinned(f.home)), from: f.context())
        try await f.validate()
    }

    @Test func configChangesInvalidateFetchesAndDisabledConfigIgnoresResults() async throws {
        let (f, id, gen) = try await fixture()
        try await fetch(f, id, gen, [item()])
        let config = BrowserLiveFolderConfiguration(filters: [.assigned], isEnabled: false)
        try await f.store.configureLiveFolder(id, configuration: config, from: f.context())
        #expect(try await !fetch(f, id, gen, []))
        let next = await f.store.liveFolderLocalStore(for: f.personal).generation(for: .githubPullRequests)
        #expect(try await !fetch(f, id, next, []))
        #expect(await f.store.sessionDocument().organization.tabs.count == 1)
    }

    @Test func syncProjectsConfigurationOnlyAndRebuildsEmptyOnNewMac() async throws {
        let (f, id, gen) = try await fixture()
        try await fetch(f, id, gen, [item(title: "Private synthetic cached title", fingerprint: "private-fingerprint")])
        _ = try await f.store.selectTab(item().identity.tabID(in: id), from: f.context())
        let session = await f.store.sessionDocument(), projection = try project(session)
        #expect(!projection.entries.keys.contains { $0.hasPrefix("tab/") })
        let folderKey = BrowserSyncMapping.id("folder", id.rawValue)
        #expect(projection.lists[folderKey] == [])
        let text = projection.entries.values.flatMap { $0.values }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        #expect(!text.contains("Private synthetic") && !text.contains("fingerprint") && !text.contains("liveFolderChild"))
        #expect(!text.contains("lastSeen") && !text.contains("generation"))
        #expect(!text.contains(item().url.absoluteString) && !text.contains(item().identity.itemID))
        var replica = BrowserSyncReplica(); try replica.capture(projection)
        let emptyLocal = BrowserSessionDocument(profiles: session.profiles, spaces: session.spaces, windows: [], tabs: [], organization: .empty)
        let rebuilt = try materialize(replica, local: emptyLocal)
        #expect(rebuilt.organization.folders.first?.liveFolder == BrowserLiveFolderConfiguration())
        #expect(rebuilt.organization.folders.first?.children.isEmpty == true && rebuilt.organization.tabs.isEmpty)
        let kept = try materialize(replica, local: session)
        #expect(kept.organization.tabs == session.organization.tabs)
        try replica.acknowledge(project(kept))
        let records = replica.records; try replica.capture(project(kept))
        #expect(replica.records == records)
    }

    @Test func olderReaderReuploadsWithoutLosingUnknownConfiguration() async throws {
        let (f, id, _) = try await fixture()
        let session = await f.store.sessionDocument(), key = BrowserSyncMapping.id("folder", id.rawValue)
        var modern = BrowserSyncReplica(device: "modern"), legacy = BrowserSyncReplica(device: "legacy")
        try modern.capture(project(session), now: date)
        try legacy.merge(Array(modern.records.values))
        // A previous folder DTO ignores unknown JSON keys and sees an ordinary empty folder.
        struct LegacyFolder: Codable { let id: FolderID; var title: String; let children: [BrowserOrganizationNode]; let isCollapsed: Bool; let createdAt: Date }
        var fields = try #require(legacy.visible[key]); fields["children"] = try BrowserSyncReplica.encodeValue([BrowserOrganizationNode]())
        fields["isCollapsed"] = try BrowserSyncReplica.encodeValue(false)
        var old = try BrowserSyncMapping.decode(LegacyFolder.self, fields)
        #expect(old.children.isEmpty)
        var oldProjection = try project(session); oldProjection.entries[key]?.removeValue(forKey: "liveFolder")
        try legacy.acknowledge(oldProjection)
        old.title = "Renamed by older reader"
        oldProjection.entries[key]?["title"] = try BrowserSyncReplica.encodeValue(old.title)
        try legacy.capture(oldProjection, now: date.addingTimeInterval(1))
        #expect(legacy.visible[key]?["liveFolder"] == modern.visible[key]?["liveFolder"])
        try modern.merge(Array(legacy.records.values))
        let result = try materialize(modern, local: session)
        #expect(result.organization.folders.first?.title == old.title)
        #expect(result.organization.folders.first?.liveFolder == .init())
    }

    @Test func twoReplicasConvergeAfterOfflineFolderDeletion() async throws {
        let (f, id, gen) = try await fixture()
        try await fetch(f, id, gen, [item()])
        let initial = await f.store.sessionDocument()
        var a = BrowserSyncReplica(device: "a"), b = BrowserSyncReplica(device: "b")
        try a.capture(project(initial), now: date); try b.merge(Array(a.records.values))
        let onB = try materialize(b, local: initial); try b.acknowledge(project(onB))
        _ = try await f.store.deleteFolder(id, contents: .archiveContents, from: f.context())
        try a.capture(project(await f.store.sessionDocument()), now: date.addingTimeInterval(1))
        var edit = try project(onB)
        edit.entries[BrowserSyncMapping.id("folder", id.rawValue)]?["liveFolder"] = try BrowserSyncReplica.encodeValue(BrowserLiveFolderConfiguration(filters: [.mentioned]))
        try b.capture(edit, now: date.addingTimeInterval(2))
        let left = Array(a.records.values), right = Array(b.records.values)
        try a.merge(right); try b.merge(left)
        #expect(a.records == b.records)
        let finalA = try materialize(a, local: initial), finalB = try materialize(b, local: onB)
        #expect(finalA.organization.folders.isEmpty && finalB.organization.folders.isEmpty)
        #expect(try project(finalA) == project(finalB))
        let storeB = try BrowserStore(restoring: onB)
        let expected = await storeB.sessionDocument()
        let value = try BrowserSyncMapping.materialize(b.visible, local: expected, settings: .init())
        try await storeB.applySync(value, expected: expected)
        #expect(await !storeB.liveFolderLocalStore(for: f.personal).allowsAutomaticCreation(for: .githubPullRequests))
    }
    @Test func returningItemDoesNotReclaimDetachedOrdinaryPage() async throws {
        let (f, id, gen) = try await fixture()
        try await fetch(f, id, gen, [item()])
        let original = item().identity.tabID(in: id)
        _ = try await f.store.selectTab(original, from: f.context())
        try await fetch(f, id, gen, [])
        try await fetch(f, id, gen, [item()])
        let next = await f.store.sessionDocument()
        let returning = try #require(next.organization.tabs.first { $0.liveFolderChild != nil })
        #expect(returning.id != original)
        #expect(next.organization.tabs.first { $0.id == original }?.liveFolderChild == nil)
        try await fetch(f, id, gen, [item(title: "Updated")])
        #expect(await f.store.sessionDocument().organization.tabs.first { $0.liveFolderChild != nil }?.id == returning.id)
        try await f.validate()
    }

    @Test func twoReplicasMergeConfigurationAndFolderTitleIndependently() async throws {
        let (f, id, _) = try await fixture()
        let initial = await f.store.sessionDocument(), key = BrowserSyncMapping.id("folder", id.rawValue)
        var a = BrowserSyncReplica(device: "a"), b = BrowserSyncReplica(device: "b")
        try a.capture(project(initial), now: date); try b.merge(Array(a.records.values))
        try b.acknowledge(project(initial))
        var left = try project(initial), right = left
        let config = BrowserLiveFolderConfiguration(filters: [.assigned, .teamReview, .drafts], excludedRepositories: ["example/excluded"])
        left.entries[key]?["liveFolder"] = try BrowserSyncReplica.encodeValue(config)
        right.entries[key]?["title"] = try BrowserSyncReplica.encodeValue("Renamed offline")
        try a.capture(left, now: date.addingTimeInterval(1)); try b.capture(right, now: date.addingTimeInterval(1))
        let aRecords = Array(a.records.values), bRecords = Array(b.records.values)
        try a.merge(bRecords); try b.merge(aRecords)
        #expect(a.records == b.records)
        let result = try materialize(a, local: initial)
        #expect(result.organization.folders.first?.liveFolder == config)
        #expect(result.organization.folders.first?.title == "Renamed offline")
    }

    @Test func remoteDeletionPreservesOpenPageAndInvalidatesResults() async throws {
        let (f, id, gen) = try await fixture()
        try await fetch(f, id, gen, [item()])
        let tab = item().identity.tabID(in: id)
        _ = try await f.store.selectTab(tab, from: f.context())
        let initial = await f.store.sessionDocument()
        var replica = BrowserSyncReplica()
        try replica.capture(project(initial), now: date)
        var deletion = try project(initial)
        let key = BrowserSyncMapping.id("folder", id.rawValue)
        deletion.entries[key] = nil; deletion.roots[key] = nil; deletion.lists[key] = nil
        for parent in deletion.lists.keys { deletion.lists[parent]?.removeAll { $0 == key } }
        try replica.capture(deletion, now: date.addingTimeInterval(1))
        let value = try BrowserSyncMapping.materialize(replica.visible, local: initial, settings: .init())
        try await f.store.applySync(value, expected: initial)
        #expect(await f.store.sessionDocument().organization.tabs.first?.id == tab)
        #expect(await f.store.sessionDocument().organization.tabs.first?.liveFolderChild == nil)
        #expect(try await !fetch(f, id, gen, [item()]))
        try await f.validate()
    }

}
