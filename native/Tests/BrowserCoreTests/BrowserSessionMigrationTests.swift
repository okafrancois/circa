import Foundation
import Testing
@testable import BrowserCore

private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix))!
}

/// Bytes in the exact shape the version 1 writer produced (sorted keys), with synthetic identities.
/// Window 1 shows Space 1 (tabs 31, 32) and Space 2 (tab 33); window 2 shows Space 1 with an
/// occurrence of tab 31 and, in Space 2, an occurrence of tab 32, which version 2 must split.
private let versionOneJSON = """
{"profiles":[{"id":{"rawValue":"00000000-0000-4000-8000-000000000001"},"name":"Synthetic"}],\
"spaces":[{"id":{"rawValue":"00000000-0000-4000-8000-000000000011"},"name":"One",\
"profileID":{"rawValue":"00000000-0000-4000-8000-000000000001"}},\
{"id":{"rawValue":"00000000-0000-4000-8000-000000000012"},"name":"Two",\
"profileID":{"rawValue":"00000000-0000-4000-8000-000000000001"}}],\
"tabs":[\
{"id":{"rawValue":"00000000-0000-4000-8000-000000000031"},"occurrenceID":{"rawValue":"00000000-0000-4000-8000-000000000041"},\
"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000011"},"url":"https:\\/\\/migration.test\\/a",\
"windowID":{"rawValue":"00000000-0000-4000-8000-000000000021"}},\
{"id":{"rawValue":"00000000-0000-4000-8000-000000000032"},"occurrenceID":{"rawValue":"00000000-0000-4000-8000-000000000042"},\
"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000011"},"url":"https:\\/\\/migration.test\\/b",\
"windowID":{"rawValue":"00000000-0000-4000-8000-000000000021"}},\
{"id":{"rawValue":"00000000-0000-4000-8000-000000000033"},"occurrenceID":{"rawValue":"00000000-0000-4000-8000-000000000043"},\
"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000012"},"url":"https:\\/\\/migration.test\\/c",\
"windowID":{"rawValue":"00000000-0000-4000-8000-000000000021"}},\
{"id":{"rawValue":"00000000-0000-4000-8000-000000000031"},"occurrenceID":{"rawValue":"00000000-0000-4000-8000-000000000044"},\
"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000011"},"url":"https:\\/\\/migration.test\\/a2",\
"windowID":{"rawValue":"00000000-0000-4000-8000-000000000022"}},\
{"id":{"rawValue":"00000000-0000-4000-8000-000000000032"},"occurrenceID":{"rawValue":"00000000-0000-4000-8000-000000000045"},\
"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000012"},"url":"https:\\/\\/migration.test\\/b2",\
"windowID":{"rawValue":"00000000-0000-4000-8000-000000000022"}}],\
"version":1,\
"windows":[\
{"activeSpaceID":{"rawValue":"00000000-0000-4000-8000-000000000011"},"id":{"rawValue":"00000000-0000-4000-8000-000000000021"},\
"spaces":[{"occurrenceIDs":[{"rawValue":"00000000-0000-4000-8000-000000000041"},{"rawValue":"00000000-0000-4000-8000-000000000042"}],\
"selectedOccurrenceID":{"rawValue":"00000000-0000-4000-8000-000000000042"},"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000011"}},\
{"occurrenceIDs":[{"rawValue":"00000000-0000-4000-8000-000000000043"}],"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000012"}}]},\
{"activeSpaceID":{"rawValue":"00000000-0000-4000-8000-000000000012"},"id":{"rawValue":"00000000-0000-4000-8000-000000000022"},\
"spaces":[{"occurrenceIDs":[{"rawValue":"00000000-0000-4000-8000-000000000044"}],\
"selectedOccurrenceID":{"rawValue":"00000000-0000-4000-8000-000000000044"},"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000011"}},\
{"occurrenceIDs":[{"rawValue":"00000000-0000-4000-8000-000000000045"}],\
"selectedOccurrenceID":{"rawValue":"00000000-0000-4000-8000-000000000045"},"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000012"}}]}]}
"""

private struct VersionOneFields: Decodable {
    let profiles: [BrowserProfile]
    let spaces: [BrowserSpace]
    let windows: [BrowserSessionDocument.Window]
    let tabs: [BrowserTab]
}

private func replacingOrganization(
    _ document: BrowserSessionDocument, tabs: [BrowserTab]? = nil,
    _ change: (inout OrganizationParts) -> Void
) -> BrowserSessionDocument {
    var parts = OrganizationParts(document.organization)
    change(&parts)
    return BrowserSessionDocument(profiles: document.profiles, spaces: document.spaces, windows: document.windows,
                                  tabs: tabs ?? document.tabs, organization: parts.document)
}

private struct OrganizationParts {
    var tabs: [BrowserOrganizedTab]
    var folders: [BrowserOrganizedFolder]
    var favorites: [BrowserOrganizationDocument.Favorites]
    var spaces: [BrowserOrganizationDocument.SpaceSections]
    var archive: [BrowserArchivedTab]
    var policy: BrowserArchivePolicy

    init(_ document: BrowserOrganizationDocument) {
        tabs = document.tabs
        folders = document.folders
        favorites = document.favorites
        spaces = document.spaces
        archive = document.archive
        policy = document.archivePolicy
    }

    var document: BrowserOrganizationDocument {
        BrowserOrganizationDocument(tabs: tabs, folders: folders, favorites: favorites, spaces: spaces,
                                    archive: archive, archivePolicy: policy)
    }
}

@Suite("Session document version 2 and migration")
struct BrowserSessionMigrationTests {
    @Test("A version 1 file migrates losslessly into shared Today sections")
    func versionOneMigratesLosslessly() async throws {
        let data = Data(versionOneJSON.utf8)
        let legacy = try JSONDecoder().decode(VersionOneFields.self, from: data)
        let migrationDate = Date(timeIntervalSinceReferenceDate: 812_345_678)
        let document = try BrowserSessionDocument.decode(data, migrationDate: migrationDate)
        #expect(document.version == BrowserSessionDocument.currentVersion)
        #expect(document.profiles == legacy.profiles && document.spaces == legacy.spaces)
        #expect(document.windows == legacy.windows)
        #expect(document.tabs.map(\.occurrenceID) == legacy.tabs.map(\.occurrenceID))
        #expect(document.tabs.map(\.url) == legacy.tabs.map(\.url))
        #expect(document.tabs.map(\.windowID) == legacy.tabs.map(\.windowID))
        #expect(document.tabs.map(\.spaceID) == legacy.tabs.map(\.spaceID))
        // Only the occurrence of tab 32 in a second Space receives a derived logical identity.
        let changed = zip(document.tabs, legacy.tabs).filter { $0.id != $1.id }
        #expect(changed.map(\.0.occurrenceID) == [TabOccurrenceID(uuid(45))])
        let derived = try #require(changed.first?.0.id)
        #expect(derived == BrowserSessionDocument.derivedTabID(TabID(uuid(32)), TabOccurrenceID(uuid(45))))
        #expect(try BrowserSessionDocument.decode(data).tabs == document.tabs)

        let one = SpaceID(uuid(11)), two = SpaceID(uuid(12))
        let sections = Dictionary(uniqueKeysWithValues: document.organization.spaces.map { ($0.spaceID, $0) })
        #expect(sections[one]?.today == [.tab(TabID(uuid(31))), .tab(TabID(uuid(32)))])
        #expect(sections[two]?.today == [.tab(TabID(uuid(33))), .tab(derived)])
        let pinnedSectionsEmpty = document.organization.spaces.allSatisfy { $0.pinned.isEmpty }
        #expect(pinnedSectionsEmpty)
        #expect(document.organization.favorites.isEmpty && document.organization.archive.isEmpty)
        #expect(document.organization.tabs.allSatisfy { $0.createdAt == migrationDate && $0.lastActiveAt == migrationDate })
        let entry = try #require(document.organization.tabs.first { $0.id == TabID(uuid(31)) })
        #expect(entry.url == URL(string: "https://migration.test/a")! && entry.pinnedURL == nil)

        let store = try BrowserStore(restoring: document)
        let first = try await store.snapshot(of: WindowID(uuid(21)))
        #expect(first.tabs.map(\.occurrenceID) == [TabOccurrenceID(uuid(41)), TabOccurrenceID(uuid(42))])
        #expect(first.selectedOccurrenceID == TabOccurrenceID(uuid(42)))
        let second = try await store.snapshot(of: WindowID(uuid(22)))
        #expect(second.activeSpaceID == two && second.selectedOccurrenceID == TabOccurrenceID(uuid(45)))
        let shared = try await store.organizationSnapshot(from: store.captureContext(in: WindowID(uuid(21))))
        #expect(shared.tab(TabID(uuid(31)))?.isOpenInAnotherWindow == true)
        #expect(await store.sessionDocument() == document)
        let reencoded = try document.encoded()
        #expect(try BrowserSessionDocument.decode(reencoded) == document)
        #expect(String(decoding: reencoded, as: UTF8.self).contains("\"version\":4"))
    }

    @Test("Version 1 graphs that were invalid stay invalid after migration")
    func invalidVersionOneStaysInvalid() throws {
        let orphan = versionOneJSON.replacingOccurrences(of: """
            {"occurrenceIDs":[{"rawValue":"00000000-0000-4000-8000-000000000043"}],"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000012"}}
            """, with: """
            {"occurrenceIDs":[],"spaceID":{"rawValue":"00000000-0000-4000-8000-000000000012"}}
            """)
        #expect(orphan != versionOneJSON)
        #expect(throws: BrowserSessionError.orphanedOccurrence) { try BrowserSessionDocument.decode(Data(orphan.utf8)) }
        let unknown = versionOneJSON.replacingOccurrences(of: "\"version\":1", with: "\"version\":\(BrowserSessionDocument.currentVersion + 1)")
        #expect(throws: BrowserSessionError.unsupportedVersion) { try BrowserSessionDocument.decode(Data(unknown.utf8)) }
    }

    @Test("A full organization round-trips through encoding and restoration unchanged")
    func fullOrganizationRoundTrip() async throws {
        let fixture = try await OrganizationFixture.make()
        let mail = try await fixture.open("mail")
        let docs = try await fixture.open("docs")
        let nested = try await fixture.open("nested")
        let closed = try await fixture.open("closed")
        _ = try await fixture.open("today")
        _ = try await fixture.store.addToFavorites([mail], from: fixture.context())
        let (outer, _) = try await fixture.store.createFolder(title: "Outer", at: .init(.pinned(fixture.home)),
            containing: [.tab(docs)], from: fixture.context())
        let (inner, _) = try await fixture.store.createFolder(title: "Inner", at: .init(.folder(outer), position: .start),
            containing: [.tab(nested)], from: fixture.context())
        _ = try await fixture.store.setFolderCollapsed(inner, true, from: fixture.context())
        _ = try await fixture.store.setPinnedSectionCollapsed(true, from: fixture.context())
        _ = try await fixture.store.renameTab(docs, to: "Docs", from: fixture.context())
        _ = try await fixture.store.closeTabs([closed], from: fixture.context())
        try await fixture.store.setAutoArchiveThreshold(.sevenDays, forProfile: fixture.work)
        let document = await fixture.store.sessionDocument()
        let decoded = try BrowserSessionDocument.decode(document.encoded())
        #expect(decoded == document)
        let restored = try BrowserStore(restoring: decoded)
        #expect(await restored.sessionDocument() == document)
        let snapshot = try await restored.organizationSnapshot(from: restored.captureContext(in: fixture.window))
        #expect(snapshot == (try await fixture.organization()).withoutJournal)
        #expect(await restored.archivePolicy().threshold(for: fixture.work) == .sevenDays)
    }

    @Test("Version 2 validation rejects every broken organization invariant")
    func versionTwoValidation() async throws {
        let fixture = try await OrganizationFixture.make()
        let a = try await fixture.open("a")
        let b = try await fixture.open("b")
        _ = try await fixture.open("c")
        _ = try await fixture.store.pinTabs([b], from: fixture.context())
        _ = try await fixture.store.closeTabs([a], from: fixture.context())
        let valid = await fixture.store.sessionDocument()
        try valid.validate()
        let home = fixture.home, leisure = fixture.leisure
        let liveTab = try #require(valid.tabs.first).id
        func expectFailure(_ error: BrowserSessionError, _ document: BrowserSessionDocument,
                           sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(throws: error, sourceLocation: sourceLocation) { try document.validate() }
        }
        expectFailure(.occurrenceWithoutLogicalTab, replacingOrganization(valid) { parts in
            parts.tabs.removeAll { $0.id == liveTab }
            parts.spaces = parts.spaces.map { .init(spaceID: $0.spaceID, pinned: $0.pinned.filter { $0 != .tab(liveTab) },
                                                    today: $0.today.filter { $0 != .tab(liveTab) }) }
        })
        expectFailure(.occurrenceOutsideLogicalTabSection, replacingOrganization(valid) { parts in
            let today = parts.spaces.first { $0.spaceID == home }?.today ?? []
            parts.spaces = parts.spaces.map { .init(spaceID: $0.spaceID, pinned: $0.pinned, today: []) }
                + [.init(spaceID: leisure, pinned: [], today: today)]
        })
        expectFailure(.organizationDuplicateNode, replacingOrganization(valid) { parts in
            parts.spaces = parts.spaces.map { .init(spaceID: $0.spaceID, pinned: $0.pinned, today: $0.today + $0.today) }
        })
        expectFailure(.organizationOrphanedItem, replacingOrganization(valid) { parts in
            parts.tabs.append(BrowserOrganizedTab(id: TabID(), url: organizationURL("orphan"), createdAt: .distantPast,
                                                  lastActiveAt: .distantPast))
        })
        expectFailure(.organizationOrphanedItem, replacingOrganization(valid) { parts in
            let first = FolderID(), second = FolderID()
            parts.folders += [BrowserOrganizedFolder(id: first, title: "Loop", children: [.folder(second)], createdAt: .distantPast),
                              BrowserOrganizedFolder(id: second, title: "Loop", children: [.folder(first)], createdAt: .distantPast)]
        })
        expectFailure(.organizationInvalidSection, replacingOrganization(valid) { parts in
            let folder = FolderID()
            parts.folders.append(BrowserOrganizedFolder(id: folder, title: "Today folder", createdAt: .distantPast))
            parts.spaces = parts.spaces.map { .init(spaceID: $0.spaceID, pinned: $0.pinned, today: $0.today + [.folder(folder)]) }
        })
        expectFailure(.organizationInvalidPinnedURL, replacingOrganization(valid) { parts in
            parts.tabs = parts.tabs.map { tab in
                var copy = tab
                copy.pinnedURL = tab.pinnedURL == nil ? tab.url : nil
                return copy
            }
        })
        expectFailure(.organizationInvalidTitle, replacingOrganization(valid) { parts in
            parts.tabs = parts.tabs.map { tab in
                var copy = tab
                copy.customTitle = "line\nbreak"
                return copy
            }
        })
        expectFailure(.duplicateIdentity, replacingOrganization(valid) { parts in
            let record = parts.archive[0]
            let live = parts.tabs[0]
            parts.archive = [BrowserArchivedTab(tab: live, profileID: record.profileID, spaceID: record.spaceID,
                origin: record.origin, reason: record.reason, archivedAt: record.archivedAt)]
        })
        expectFailure(.organizationInvalidArchive, replacingOrganization(valid) { parts in
            let record = parts.archive[0]
            parts.archive = [BrowserArchivedTab(tab: record.tab, profileID: fixture.work, spaceID: record.spaceID,
                origin: record.origin, reason: record.reason, archivedAt: record.archivedAt)]
        })
        expectFailure(.organizationInvalidPolicy, replacingOrganization(valid) { parts in
            parts.policy.profileThresholds[ProfileID()] = .oneDay
        })
        expectFailure(.spaceMissing, replacingOrganization(valid) { parts in
            parts.spaces.append(.init(spaceID: SpaceID(), pinned: [], today: [], isPinnedCollapsed: true))
        })
        // Two occurrences of one logical tab in the same window.
        let occurrence = try #require(valid.tabs.first)
        let duplicate = BrowserTab(id: occurrence.id, occurrenceID: TabOccurrenceID(), windowID: occurrence.windowID,
                                   spaceID: occurrence.spaceID, url: occurrence.url)
        let windows = valid.windows.map { window in
            BrowserSessionDocument.Window(id: window.id, activeSpaceID: window.activeSpaceID, spaces: window.spaces.map { group in
                group.spaceID == occurrence.spaceID && window.id == occurrence.windowID
                    ? .init(spaceID: group.spaceID, occurrenceIDs: group.occurrenceIDs + [duplicate.occurrenceID],
                            selectedOccurrenceID: group.selectedOccurrenceID)
                    : group
            })
        }
        expectFailure(.duplicateIdentity, BrowserSessionDocument(profiles: valid.profiles, spaces: valid.spaces,
            windows: windows, tabs: valid.tabs + [duplicate], organization: valid.organization))
    }

    @Test("Documents built without an organization derive it from their occurrences")
    func initializerDerivesOrganization() async throws {
        let fixture = try await OrganizationFixture.make()
        _ = try await fixture.open("a")
        _ = try await fixture.open("b", in: fixture.other)
        let document = await fixture.store.sessionDocument()
        let derived = BrowserSessionDocument(profiles: document.profiles, spaces: document.spaces,
                                             windows: document.windows, tabs: document.tabs)
        try derived.validate()
        #expect(Set(derived.organization.tabs.map(\.id)) == Set(document.organization.tabs.map(\.id)))
    }
}

private extension BrowserOrganizationSnapshot {
    /// Restoration starts with empty undo journals.
    var withoutJournal: BrowserOrganizationSnapshot {
        BrowserOrganizationSnapshot(windowID: windowID, spaceID: spaceID, profileID: profileID, favorites: favorites,
            pinned: pinned, today: today, isPinnedSectionCollapsed: isPinnedSectionCollapsed,
            archiveRevision: archiveRevision, canRestoreArchivedTab: canRestoreArchivedTab,
            autoArchiveThreshold: autoArchiveThreshold, inheritsAutoArchiveThreshold: inheritsAutoArchiveThreshold,
            archivedTabCount: archivedTabCount, undoAction: nil, redoAction: nil)
    }
}
