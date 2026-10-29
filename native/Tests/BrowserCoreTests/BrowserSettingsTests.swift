import Darwin
import Foundation
import Testing
@testable import BrowserCore

@Suite("Versioned native settings")
struct BrowserSettingsTests {
    private func destination() -> URL {
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("Orbit-SETTINGS-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test("Profile and app settings survive reopen without affecting another profile")
    func persistence() async throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = ProfileID(), second = ProfileID(), space = SpaceID()
        let store = try BrowserSettingsStore(destination: url)
        var profile = BrowserProfileSettings()
        profile.searchEngine = .duckDuckGo
        profile.opensPinnedLinksInPeek = false
        profile.shiftClickOpensPeek = false
        profile.extensionPinOrder = [String(repeating: "b", count: 32), String(repeating: "a", count: 32)]
        try await store.setProfile(profile, for: first)
        var theme = BrowserSpaceSettings()
        theme.icon = "🧪"
        theme.palette = .lavender
        try await store.setSpace(theme, for: space)
        try await store.setReducedMotion(.reduce)
        let reopened = try BrowserSettingsStore(destination: url)
        let saved = await reopened.snapshot()
        #expect(saved.version == 1 && saved.profile(first) == profile)
        #expect(saved.profile(second) == BrowserProfileSettings())
        #expect(saved.space(space) == theme && saved.reducedMotion == .reduce)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["settings.json"])
    }

    @Test("Profile preferences written before pin ordering keep their existing values")
    func profileBeforePinOrdering() throws {
        let data = Data(#"{"searchEngine":"google","opensPinnedLinksInPeek":false,"shiftClickOpensPeek":true}"#.utf8)
        let profile = try JSONDecoder().decode(BrowserProfileSettings.self, from: data)
        #expect(profile.extensionPinOrder.isEmpty)
        #expect(profile.searchEngine == .google && !profile.opensPinnedLinksInPeek && profile.shiftClickOpensPeek)
    }

    @Test("Version zero migrates the boolean override and publishes version one on the next write")
    func migration() async throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":0,"reduceMotion":false}"#.utf8).write(to: url)
        let store = try BrowserSettingsStore(destination: url)
        #expect(await store.snapshot().reducedMotion == .full)
        try await store.setReducedMotion(.system)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["version"] as? Int == BrowserSettingsDocument.currentVersion)
        #expect(json["reduceMotion"] == nil)
    }

    @Test("Unsupported and corrupt documents are preserved and never replaced by defaults")
    func incompatibleDocument() throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = Data(#"{"version":99}"#.utf8)
        try future.write(to: url)
        #expect(throws: BrowserSettingsError.unsupportedVersion) { try BrowserSettingsStore(destination: url) }
        #expect(try Data(contentsOf: url) == future)
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try BrowserSettingsStore(destination: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "broken")
    }

    @Test("An unsafe destination fails before publishing new in-memory settings")
    func writeFailure() async throws {
        let url = destination()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try BrowserSettingsStore(destination: url)
        try await store.setReducedMotion(.reduce)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/dev/null")
        await #expect(throws: (any Error).self) { try await store.setReducedMotion(.full) }
        #expect(await store.snapshot().reducedMotion == .reduce)
    }

    @Test("A single composed emoji is accepted while long and control-character icons are refused")
    func iconValidation() async throws {
        let store = try BrowserSettingsStore()
        let id = SpaceID()
        var value = BrowserSpaceSettings()
        value.icon = "👩🏽‍💻"
        try await store.setSpace(value, for: id)
        for icon in ["abc", "\n", "\u{0}"] {
            value.icon = icon
            await #expect(throws: BrowserSettingsError.invalidIcon) { try await store.setSpace(value, for: id) }
        }
        #expect(await store.snapshot().space(id).icon == "👩🏽‍💻")
    }

    @Test("Retiring a profile removes only its settings and Spaces")
    func removeSettings() async throws {
        let store = try BrowserSettingsStore()
        let first = ProfileID(), second = ProfileID(), one = SpaceID(), two = SpaceID()
        try await store.setProfile(.init(), for: first)
        try await store.setProfile(.init(), for: second)
        try await store.setSpace(.init(), for: one)
        try await store.setSpace(.init(), for: two)
        try await store.removeProfile(first, spaces: [one])
        let document = await store.snapshot()
        #expect(document.profiles[first] == nil && document.spaces[one] == nil)
        #expect(document.profiles[second] != nil && document.spaces[two] != nil)
    }

    @Test("Deleting an unused profile purges organization archives thresholds and undo state")
    func removeOrganizationProfile() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.activate(fixture.lab, in: fixture.other)
        let favorite = try await fixture.open("favorite-to-purge", in: fixture.other)
        _ = try await fixture.store.addToFavorites([favorite], from: fixture.context(fixture.other))
        let archived = try await fixture.open("archive-to-purge", in: fixture.other)
        _ = try await fixture.store.archiveTabs([archived], from: fixture.context(fixture.other))
        try await fixture.store.setAutoArchiveThreshold(.never, forProfile: fixture.work)
        try await fixture.store.closeWindow(fixture.other)
        try await fixture.store.removeSettingsSpace(fixture.lab)
        try await fixture.store.removeSettingsProfile(fixture.work)
        let document = await fixture.store.sessionDocument()
        try document.validate()
        #expect(document.profiles.map(\.id) == [fixture.personal])
        #expect(!document.spaces.contains { $0.profileID == fixture.work })
        #expect(document.organization.archive.isEmpty)
        #expect(document.organization.archivePolicy.profileThresholds[fixture.work] == nil)
        #expect(!document.organization.tabs.contains { $0.id == favorite || $0.id == archived })
        #expect(await fixture.store.organizationJournals.values.allSatisfy { ($0.undo + $0.redo).allSatisfy { $0.profileID != fixture.work } })
    }

    @Test("Last and active profiles cannot be deleted; rename keeps identity and validates input")
    func profileGuards() async throws {
        let fixture = try await OrganizationFixture.make()
        await #expect(throws: BrowserSettingsError.defaultProfile) { try await fixture.store.removeSettingsProfile(fixture.personal) }
        try await fixture.store.renameSettingsProfile(fixture.work, name: " Renamed ")
        #expect(await fixture.store.catalogSnapshot().profiles.last?.name == "Renamed")
        await #expect(throws: BrowserStoreError.invalidSpaceName) { try await fixture.store.renameSettingsProfile(fixture.work, name: "\n") }
        try await fixture.store.removeSettingsSpace(fixture.lab)
        try await fixture.store.removeSettingsProfile(fixture.work)
        await #expect(throws: BrowserSettingsError.lastProfile) { try await fixture.store.removeSettingsProfile(fixture.personal) }
    }

    @Test("An empty closed Space can change profile while a live or populated Space is refused")
    func spaceAssignment() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.store.assignSettingsSpace(fixture.leisure, to: fixture.work)
        #expect(await fixture.store.catalogSnapshot().spaces.first { $0.id == fixture.leisure }?.profileID == fixture.work)
        await #expect(throws: BrowserSettingsError.spaceNotEmpty) { try await fixture.store.assignSettingsSpace(fixture.home, to: fixture.work) }
        try await fixture.activate(fixture.lab, in: fixture.other)
        _ = try await fixture.open("kept", in: fixture.other)
        try await fixture.store.closeWindow(fixture.other)
        await #expect(throws: BrowserSettingsError.spaceNotEmpty) { try await fixture.store.assignSettingsSpace(fixture.lab, to: fixture.personal) }
        try await fixture.validate()
    }

    @Test("Permission enumeration is scoped by profile and contains origins without paths")
    func permissionEnumeration() async throws {
        let store = try BrowserSitePermissionStore()
        let first = ProfileID(), second = ProfileID()
        let origin = try #require(BrowserSiteOrigin(url: URL(string: "https://settings.test/path?private=sentinel")!))
        try await store.set(.allow, for: [.camera, .microphone], origin: origin, profileID: first)
        #expect(await store.configuredOrigins(profileID: first).map(\.value) == ["https://settings.test"])
        #expect(await store.configuredOrigins(profileID: second).isEmpty)
    }
}

extension BrowserSettingsTests {
    @Test("A reserved profile refuses new windows switches and Spaces before durable cleanup starts")
    func profileQuarantine() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.store.removeSettingsSpace(fixture.lab)
        _ = try await fixture.store.reserveSettingsProfileRemoval(fixture.work)
        await #expect(throws: BrowserStoreError.spaceMissing) { try await fixture.store.createWindow(activeSpaceID: fixture.lab) }
        await #expect(throws: BrowserStoreError.spaceMissing) { try await fixture.store.activateSpace(fixture.lab, in: fixture.window) }
        await #expect(throws: BrowserSettingsError.profileBeingDeleted) { try await fixture.store.createSpace(name: "Forbidden", profileID: fixture.work) }
        #expect(!(await fixture.store.catalogSnapshot().profiles.contains { $0.id == fixture.work }))
        var importPlan = BrowserImportPlan()
        importPlan.profiles = [.init(id: fixture.work, sourceKey: .directory("Default"), name: "Quarantined", sourceDirectory: nil, isAdopted: true)]
        await #expect(throws: BrowserSettingsError.profileBeingDeleted) { try await fixture.store.applyImport(importPlan, ledger: .init()) }
        await fixture.store.cancelSettingsProfileReservation(fixture.work)
        #expect(await fixture.store.catalogSnapshot().profiles.contains { $0.id == fixture.work })
        _ = try await fixture.store.reserveSettingsProfileRemoval(fixture.work)
        try await fixture.store.commitSettingsProfileRemoval(fixture.work)
        await #expect(throws: BrowserSettingsError.profileBeingDeleted) { try await fixture.store.applyImport(importPlan, ledger: .init()) }
        await fixture.store.finishSettingsProfileRemoval(fixture.work)
        try await fixture.validate()
    }

    @Test("A profile can have no Spaces and an invalid new profile creates no orphan")
    func lastSpaceAndAtomicCreation() async throws {
        let fixture = try await OrganizationFixture.make()
        try await fixture.store.assignSettingsSpace(fixture.lab, to: fixture.personal)
        #expect(await fixture.store.catalogSnapshot().spaces.allSatisfy { $0.profileID != fixture.work })
        let before = await fixture.store.sessionDocument()
        await #expect(throws: BrowserStoreError.invalidSpaceName) { try await fixture.store.createSettingsProfile(name: "\n") }
        #expect(await fixture.store.sessionDocument() == before)
    }

    @Test("Reassigning an empty Space purges another window's undo and redo patches across profiles", arguments: [true, false])
    func reassignmentRevokesCrossWindowUndo(undoing: Bool) async throws {
        let fixture = try await OrganizationFixture.make()
        if undoing {
            // The other browser window records a move out of Leisure, then returns to Home.
            // Its old undo would put the live tab back into Leisure after account reassignment.
            try await fixture.activate(fixture.leisure, in: fixture.other)
            let tab = try await fixture.open("undo-boundary", in: fixture.other)
            _ = try await fixture.store.moveItems([.tab(tab)], to: .init(.today(fixture.home)), from: fixture.context(fixture.other))
            try await fixture.activate(fixture.home, in: fixture.other)
            #expect(await fixture.store.organizationJournals[fixture.other]?.undo.last?.spaceID == fixture.leisure)
            try await fixture.store.assignSettingsSpace(fixture.leisure, to: fixture.work)
            await #expect(throws: BrowserOrganizationError.nothingToUndo) { try await fixture.store.undoOrganization(from: fixture.context(fixture.other)) }
        } else {
            let tab = try await fixture.open("redo-boundary")
            _ = try await fixture.store.moveItems([.tab(tab)], to: .init(.today(fixture.leisure)), from: fixture.context())
            _ = try await fixture.store.undoOrganization(from: fixture.context())
            #expect(await fixture.store.organizationJournals[fixture.window]?.redo.count == 1)
            try await fixture.store.assignSettingsSpace(fixture.leisure, to: fixture.work)
            #expect(await fixture.store.organizationJournals[fixture.window]?.redo.isEmpty == true)
            await #expect(throws: BrowserOrganizationError.nothingToRedo) { try await fixture.store.redoOrganization(from: fixture.context()) }
        }
        #expect(await fixture.store.catalogSnapshot().spaces.first { $0.id == fixture.leisure }?.profileID == fixture.work)
        try await fixture.validate()
    }

    @Test("A durable profile cleanup journal survives reopen and advances only after atomic writes")
    func removalJournalPersistence() async throws {
        let file = destination()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = ProfileID(), second = ProfileID()
        let journal = try BrowserProfileRemovalStore(destination: file)
        try await journal.put(.init(profileID: first, spaceIDs: [SpaceID()], nextStep: .history))
        try await journal.put(.init(profileID: second, spaceIDs: [], nextStep: .engine))
        let reopened = try BrowserProfileRemovalStore(destination: file)
        #expect(await reopened.entry(first)?.nextStep == .history)
        try await reopened.complete(first)
        let final = try BrowserProfileRemovalStore(destination: file)
        #expect(await final.pending().map(\.profileID) == [second])
    }
}

extension BrowserSettingsTests {

}
