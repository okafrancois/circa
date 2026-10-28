import BrowserCore
import Foundation
import Testing

@Suite("Space and profile deletion")
struct BrowserSpaceRemovalTests {
    @Test("Settings profile creation has no implicit Space and survives a session round trip")
    func profileOnlyCreation() async throws {
        let store = BrowserStore()
        let profile = try await store.createSettingsProfile(name: "Separate")
        #expect(await store.catalogSnapshot().profiles.map(\.id) == [profile])
        #expect(await store.catalogSnapshot().spaces.isEmpty)
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await store.sessionDocument().encoded()))
        #expect(await restored.catalogSnapshot() == store.catalogSnapshot())
        _ = try await store.createSpace(name: "Explicit", profileID: profile)
        #expect(await store.catalogSnapshot().spaces.count == 1)
    }

    @Test("New Space with a new profile inserts exactly one pair and validates before inserting")
    func newSpaceNewProfile() async throws {
        let store = BrowserStore()
        let first = await store.createProfile(name: "Initial")
        let home = try await store.createSpace(name: "Home", profileID: first)
        let window = try await store.createWindow(activeSpaceID: home)
        let context = try await store.captureContext(in: window)
        let before = await store.sessionDocument()
        await #expect(throws: BrowserStoreError.invalidSpaceName) {
            try await store.createSpace(name: "Work", newProfileName: "\n", from: context)
        }
        #expect(await store.sessionDocument() == before)
        let state = try await store.createSpace(name: "Work", newProfileName: "Work Profile", from: context)
        #expect(state.catalog.profiles.count == 2 && state.catalog.spaces.count == 2)
        #expect(state.catalog.spaces.filter { $0.profileID == state.context.profileID }.count == 1)
        await #expect(throws: BrowserStoreError.staleContext) {
            try await store.createSpace(name: "Rejected", newProfileName: "Rejected", from: context)
        }
        #expect(await store.catalogSnapshot().profiles.count == 2)
    }

    @Test("Deleting a Space archives nested pinned and Today tabs, keeps Favorites and switches all windows")
    func removalAcrossWindows() async throws {
        let fixture = try await OrganizationFixture.make()
        let store = fixture.store
        let extra = try await store.createWindow(activeSpaceID: fixture.home)
        let context = try await store.captureContext(in: fixture.window)
        let one = try await store.openTab(url: URL(string: "https://spaces.test/pinned")!, from: context, activate: true)
        let oneID = try #require(try await store.snapshot(of: fixture.window).tabs.first { $0.occurrenceID == one }?.id)
        _ = try await store.pinTabs([oneID], from: store.captureContext(in: fixture.window))
        let two = try await store.openTab(url: URL(string: "https://spaces.test/today")!, from: store.captureContext(in: fixture.window), activate: true)
        let twoID = try #require(try await store.snapshot(of: fixture.window).tabs.first { $0.occurrenceID == two }?.id)
        _ = try await store.openTab(url: URL(string: "https://spaces.test/other-window")!, from: store.captureContext(in: extra), activate: true)
        let old = try await store.captureContext(in: fixture.window)
        try await store.removeSettingsSpace(fixture.home)
        let doc = await store.sessionDocument()
        try doc.validate()
        #expect(!doc.spaces.contains { $0.id == fixture.home })
        #expect(doc.windows.allSatisfy { $0.activeSpaceID != fixture.home })
        #expect(doc.tabs.allSatisfy { $0.spaceID != fixture.home })
        #expect(Set(doc.organization.archive.map(\.id)).isSuperset(of: [oneID, twoID]))
        #expect(doc.organization.archive.allSatisfy { $0.profileID == fixture.personal })
        await #expect(throws: BrowserStoreError.staleContext) { try await store.openTab(url: URL(string: "about:blank")!, from: old, activate: true) }
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(doc.encoded()))
        let state = try await restored.captureWindowState(in: fixture.window)
        #expect(state.context.profileID == fixture.personal)
        let replay = try await restored.restoreArchivedTab(oneID, activate: true, from: state.context)
        #expect(replay.snapshot.tabs.contains { $0.id == oneID })
        try await restored.sessionDocument().validate()
    }

    @Test("The final global Space is protected even with an unused second profile")
    func finalSpaceProtection() async throws {
        let store = BrowserStore()
        let first = await store.createProfile(name: "First")
        let space = try await store.createSpace(name: "Last", profileID: first)
        _ = try await store.createSettingsProfile(name: "Unused")
        let before = await store.sessionDocument()
        await #expect(throws: BrowserSettingsError.lastSpace) { try await store.removeSettingsSpace(space) }
        #expect(await store.sessionDocument() == before)
        await #expect(throws: BrowserStoreError.spaceMissing) { try await store.removeSettingsSpace(SpaceID()) }
    }
}

extension BrowserSpaceRemovalTests {
    @Test("Deletion retires nested folders and split groups without removing shared Favorites")
    func removesStructuresAndPreservesFavorites() async throws {
        let fixture = try await OrganizationFixture.make()
        let store = fixture.store
        let favorite = try await fixture.open("favorite")
        _ = try await store.addToFavorites([favorite], from: fixture.context())
        let pinned = try await fixture.open("nested")
        _ = try await store.pinTabs([pinned], from: fixture.context())
        let (outer, _) = try await store.createFolder(title: "Outer", at: .init(.pinned(fixture.home), position: .end), from: fixture.context())
        _ = try await store.createFolder(title: "Inner", at: .init(.folder(outer), position: .end), containing: [.tab(pinned)], from: fixture.context())
        let first = try await fixture.open("split-first")
        let second = try await fixture.open("split-second")
        _ = try await store.createSplit([first, second], from: fixture.context())
        try await store.removeSettingsSpace(fixture.home)
        let doc = await store.sessionDocument()
        try doc.validate()
        #expect(doc.organization.folders.isEmpty && doc.organization.splits.isEmpty)
        #expect(doc.organization.tabs.contains { $0.id == favorite })
        #expect(Set(doc.organization.archive.map(\.id)) == Set([pinned, first, second]))
        let state = try await store.captureWindowState(in: fixture.window)
        #expect(state.organization.favorites.count == 1)
        #expect(state.organization.undoAction == nil && state.organization.redoAction == nil)
    }

    @Test("A confirmation from the old profile cannot delete a Space reassigned to another account")
    func removalConfirmationKeepsProfileBoundary() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.store.assignSettingsSpace(fixture.leisure, to: fixture.work)
        let before = await fixture.store.sessionDocument()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await fixture.store.removeSettingsSpace(fixture.leisure, expectedProfileID: fixture.personal)
        }
        #expect(await fixture.store.sessionDocument() == before)
    }
}

extension BrowserSpaceRemovalTests {
    @Test("Deleted Space folder hierarchy, empty folders, tabs and splits survive persistence and restore together")
    func folderArchiveRoundTrip() async throws {
        let fixture = try await OrganizationFixture.make()
        let store = fixture.store
        let one = try await fixture.open("tree-one")
        let two = try await fixture.open("tree-two")
        _ = try await store.pinTabs([one, two], from: fixture.context())
        let (split, _) = try await store.createSplit([one, two], from: fixture.context())
        let (outer, _) = try await store.createFolder(title: "Outer", at: .init(.pinned(fixture.home)), containing: [.split(split)], from: fixture.context())
        _ = try await store.createFolder(title: "Empty Child", at: .init(.folder(outer)), from: fixture.context())
        let original = await store.sessionDocument()
        try await store.removeSettingsSpace(fixture.home)
        let document = await store.sessionDocument()
        #expect(document.organization.archivedSpaces.count == 1)
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(document.encoded()))
        try await restored.restoreSettingsSpace(fixture.home)
        let recovered = await restored.sessionDocument()
        try recovered.validate()
        #expect(recovered.version == original.version)
        #expect(recovered.organization.folders == original.organization.folders)
        #expect(recovered.organization.splits == original.organization.splits)
        #expect(recovered.organization.spaces == original.organization.spaces)
        #expect(recovered.organization.tabs == original.organization.tabs)
        #expect(recovered.organization.archivedSpaces.isEmpty && recovered.organization.archive.isEmpty)
    }

    @Test("Restoring an individual tab or clearing the archive never resurrects erased tab data in a Space backup")
    func archivedSpaceRespectsIndividualRestorationAndClear() async throws {
        let fixture = try await OrganizationFixture.make()
        let id = try await fixture.open("restore-once")
        _ = try await fixture.store.pinTabs([id], from: fixture.context())
        _ = try await fixture.store.createFolder(title: "Keep Empty", at: .init(.pinned(fixture.home)), containing: [.tab(id)], from: fixture.context())
        try await fixture.store.removeSettingsSpace(fixture.home)
        _ = try await fixture.store.restoreArchivedTab(id, activate: true, from: fixture.context())
        #expect(await fixture.store.sessionDocument().organization.archivedSpaces.first?.contents.tabs.isEmpty == true)
        try await fixture.store.restoreSettingsSpace(fixture.home)
        let recovered = await fixture.store.sessionDocument()
        try recovered.validate()
        #expect(recovered.organization.tabs.filter { $0.id == id }.count == 1)
        #expect(recovered.organization.folders.first?.children.isEmpty == true)
        try await fixture.store.removeSettingsSpace(fixture.home)
        _ = try await fixture.store.clearArchive(from: fixture.context())
        #expect(await fixture.store.sessionDocument().organization.archivedSpaces.isEmpty)
    }
}

extension BrowserSpaceRemovalTests {
    @Test("Deleting an unused profile purges even an empty Space recovery record and keeps the session valid")
    func emptySpaceThenProfileDeletion() async throws {
        let fixture = try await OrganizationFixture.make()
        let profile = try await fixture.store.createSettingsProfile(name: "Unused")
        let space = try await fixture.store.createSpace(name: "Empty", profileID: profile)
        try await fixture.store.removeSettingsSpace(space)
        #expect(await fixture.store.sessionDocument().organization.archivedSpaces.contains { $0.id == space })
        try await fixture.store.removeSettingsProfile(profile)
        let doc = await fixture.store.sessionDocument()
        try doc.validate()
        #expect(!doc.organization.archivedSpaces.contains { $0.space.profileID == profile })
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(doc.encoded()))
        #expect(await restored.catalogSnapshot().profiles.allSatisfy { $0.id != profile })
    }
}

extension BrowserSpaceRemovalTests {
    @Test("Archived Space recovery refuses copied tab payloads that differ from the profile's real archive")
    func copiedArchivePayloadValidation() async throws {
        let fixture = try await OrganizationFixture.make()
        _ = try await fixture.open("archived-payload")
        try await fixture.store.removeSettingsSpace(fixture.home)
        let data = try await fixture.store.sessionDocument().encoded()
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var organization = try #require(object["organization"] as? [String: Any])
        var spaces = try #require(organization["archivedSpaces"] as? [[String: Any]])
        var contents = try #require(spaces[0]["contents"] as? [String: Any])
        var tabs = try #require(contents["tabs"] as? [[String: Any]])
        tabs[0]["url"] = "https://spaces.test/replaced-payload"
        contents["tabs"] = tabs
        spaces[0]["contents"] = contents
        organization["archivedSpaces"] = spaces
        object["organization"] = organization
        let changed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: BrowserSessionError.organizationInvalidArchive) { try BrowserSessionDocument.decode(changed) }
    }
}

extension BrowserSpaceRemovalTests {
    @Test("Archive deletion and cap eviction prune recovery payloads before validating their candidate state", arguments: [false, true])
    func archiveMutationNormalizesRecovery(capEviction: Bool) async throws {
        let fixture = try await OrganizationFixture.make()
        let id = try await fixture.open("erase-or-evict")
        _ = try await fixture.store.pinTabs([id], from: fixture.context())
        _ = try await fixture.store.createFolder(title: "Empty after purge", at: .init(.pinned(fixture.home)), containing: [.tab(id)], from: fixture.context())
        try await fixture.store.removeSettingsSpace(fixture.home)
        if capEviction { try await fixture.store.setMaximumArchivedTabs(0) }
        else { _ = try await fixture.store.deleteArchivedTabs([id], from: fixture.context()) }
        let saved = await fixture.store.sessionDocument()
        try saved.validate()
        #expect(saved.organization.archive.isEmpty)
        #expect(saved.organization.archivedSpaces.first?.contents.tabs.isEmpty == true)
        try await fixture.store.restoreSettingsSpace(fixture.home)
        let restored = await fixture.store.sessionDocument()
        try restored.validate()
        #expect(restored.organization.tabs.isEmpty && restored.organization.folders.first?.children.isEmpty == true)
    }

    @Test("A stale restore action cannot restore the same Space identity after it moved to another profile")
    func restorationKeepsCapturedProfile() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.store.removeSettingsSpace(fixture.leisure)
        try await fixture.store.restoreSettingsSpace(fixture.leisure)
        try await fixture.store.assignSettingsSpace(fixture.leisure, to: fixture.work)
        try await fixture.store.removeSettingsSpace(fixture.leisure)
        let before = await fixture.store.sessionDocument()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await fixture.store.restoreSettingsSpace(fixture.leisure, expectedProfileID: fixture.personal)
        }
        #expect(await fixture.store.sessionDocument() == before)
    }
}

extension BrowserSpaceRemovalTests {
    @Test("Undo can evict a deleted Space's archived tab without invalidating recovery metadata or discarding the undo record")
    func undoArchiveCapNormalizesRecovery() async throws {
        let fixture = try await OrganizationFixture.make()
        let older = try await fixture.open("older-deleted-space")
        try await fixture.store.removeSettingsSpace(fixture.home)
        fixture.clock.advance(by: 1)
        let newer = try await fixture.open("newer-survivor")
        _ = try await fixture.store.archiveTabs([newer], from: fixture.context())
        _ = try await fixture.store.restoreArchivedTab(newer, activate: true, from: fixture.context())
        try await fixture.store.setMaximumArchivedTabs(1)
        _ = try await fixture.store.undoOrganization(from: fixture.context())
        let undone = await fixture.store.sessionDocument()
        try undone.validate()
        #expect(undone.organization.archive.map(\.id) == [newer])
        #expect(undone.organization.archivedSpaces.first?.contents.tabs.isEmpty == true)
        _ = try await fixture.store.redoOrganization(from: fixture.context())
        let redone = await fixture.store.sessionDocument()
        try redone.validate()
        #expect(redone.organization.archive.map(\.id) == [older])
    }
}
