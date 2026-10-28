import Foundation
import Testing
@testable import BrowserCore

private func sessionFixture() async throws -> BrowserSessionDocument {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    _ = try await store.openTab(url: URL(string: "https://session.test/first")!,
                               from: store.captureContext(in: window), activate: true)
    _ = try await store.openTab(url: URL(string: "https://session.test/second")!,
                               from: store.captureContext(in: window), activate: false)
    return await store.sessionDocument()
}

private func replacingSession(
    _ document: BrowserSessionDocument, version: Int? = nil,
    profiles: [BrowserProfile]? = nil, spaces: [BrowserSpace]? = nil,
    windows: [BrowserSessionDocument.Window]? = nil, tabs: [BrowserTab]? = nil
) -> BrowserSessionDocument {
    BrowserSessionDocument(version: version ?? document.version, profiles: profiles ?? document.profiles,
        spaces: spaces ?? document.spaces, windows: windows ?? document.windows, tabs: tabs ?? document.tabs)
}

@Test("Session encoding restores every window, Space, profile, selection and occurrence order")
func sessionDocumentRestoresWindowGraph() async throws {
    let store = BrowserStore()
    let personal = await store.createProfile(name: "Personal")
    let work = await store.createProfile(name: "Work")
    let home = try await store.createSpace(name: "Home", profileID: personal)
    let office = try await store.createSpace(name: "Office", profileID: work)
    let window = try await store.createWindow(activeSpaceID: home)
    let otherWindow = try await store.createWindow(activeSpaceID: home)
    let first = try await store.openTab(url: URL(string: "https://session.test/home")!,
                                      from: store.captureContext(in: window), activate: true)
    let background = try await store.openTab(url: URL(string: "https://session.test/background")!,
                                           from: store.captureContext(in: window), activate: false)
    let other = try await store.openTab(url: URL(string: "https://session.test/other-window")!,
                                      from: store.captureContext(in: otherWindow), activate: true)
    try await store.activateSpace(office, in: window)
    let officeTab = try await store.openTab(url: URL(string: "https://session.test/office")!,
                                          from: store.captureContext(in: window), activate: true)
    let context = try await store.captureContext(in: window)
    let encoded = try await store.sessionDocument().encoded()
    #expect(try await store.sessionDocument().encoded() == encoded)
    #expect(await store.isCurrent(context))
    let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(encoded))
    #expect(try await restored.captureContext(in: window).profileID == work)
    #expect(try await restored.snapshot(of: window).tabs.map(\.occurrenceID) == [officeTab])
    #expect(try await restored.snapshot(of: otherWindow).selectedOccurrenceID == other)
    try await restored.activateSpace(home, in: window)
    #expect(try await restored.snapshot(of: window).tabs.map(\.occurrenceID) == [first, background])
    #expect(try await restored.snapshot(of: window).selectedOccurrenceID == first)
    #expect(try await restored.captureContext(in: window).profileID == personal)
    try await restored.closeWindow(window)
    #expect(try await restored.snapshot(of: otherWindow).selectedOccurrenceID == other)
}

@Test("Restoring identical IDs and revisions never revives a context from the previous store")
func sessionDocumentRevokesPreviousStoreAuthority() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    _ = try await store.openTab(url: URL(string: "https://session.test/background-only")!,
                               from: store.captureContext(in: window), activate: false)
    let oldContext = try await store.captureContext(in: window)
    #expect(oldContext.revision == 0)
    let document = try BrowserSessionDocument.decode(await store.sessionDocument().encoded())
    let restored = try BrowserStore(restoring: document)
    let newContext = try await restored.captureContext(in: window)
    #expect(newContext.revision == oldContext.revision)
    #expect(newContext.selectedOccurrenceID == nil)
    #expect(newContext.storeGeneration != oldContext.storeGeneration)
    #expect(!(await restored.isCurrent(oldContext)))
    await #expect(throws: BrowserStoreError.staleContext) {
        try await restored.openTab(url: URL(string: "https://session.test/stale")!, from: oldContext, activate: true)
    }
    #expect(try await restored.snapshot(of: window).tabs.count == 1)
    #expect(await store.isCurrent(oldContext))
}

@Test("An empty window survives a session round trip")
func sessionDocumentRestoresEmptyWindow() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let space = try await store.createSpace(name: "Empty", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await store.sessionDocument().encoded()))
    #expect(try await restored.snapshot(of: window).tabs.isEmpty)
    #expect(try await restored.snapshot(of: window).activeSpaceID == space)
}

@Test("Duplicate identities and a Space without its profile are rejected")
func sessionDocumentRejectsInvalidCatalogue() async throws {
    let document = try await sessionFixture()
    #expect(throws: BrowserSessionError.duplicateIdentity) {
        try replacingSession(document, profiles: document.profiles + document.profiles).validate()
    }
    let space = BrowserSpace(id: document.spaces[0].id, profileID: ProfileID(), name: "Invalid")
    #expect(throws: BrowserSessionError.profileMissing) {
        try BrowserStore(restoring: replacingSession(document, spaces: [space]))
    }
}

@Test("An occurrence cannot be restored into another window")
func sessionDocumentRejectsForeignOwnership() async throws {
    let document = try await sessionFixture()
    let saved = document.windows[0]
    let foreign = BrowserSessionDocument.Window(id: WindowID(), activeSpaceID: saved.activeSpaceID, spaces: saved.spaces)
    #expect(throws: BrowserSessionError.occurrenceOwnedByAnotherContainer) {
        try BrowserStore(restoring: replacingSession(document, windows: [foreign]))
    }
}

@Test("A selection outside its Space and an unreferenced occurrence are rejected")
func sessionDocumentRejectsInvalidReferences() async throws {
    let document = try await sessionFixture()
    let saved = document.windows[0]
    let group = saved.spaces[0]
    let invalidSelection = BrowserSessionDocument.SpaceTabs(spaceID: group.spaceID,
        occurrenceIDs: group.occurrenceIDs, selectedOccurrenceID: TabOccurrenceID())
    #expect(throws: BrowserSessionError.invalidSelection) {
        try replacingSession(document, windows: [.init(id: saved.id, activeSpaceID: saved.activeSpaceID,
                                                       spaces: [invalidSelection])]).validate()
    }
    let orphan = BrowserSessionDocument.SpaceTabs(spaceID: group.spaceID,
        occurrenceIDs: [], selectedOccurrenceID: nil)
    #expect(throws: BrowserSessionError.orphanedOccurrence) {
        try replacingSession(document, windows: [.init(id: saved.id, activeSpaceID: saved.activeSpaceID,
                                                       spaces: [orphan])]).validate()
    }
}

@Test("Logical tab sharing preserves independent occurrence identities")
func sessionDocumentAllowsSharedLogicalTabs() async throws {
    let document = try await sessionFixture()
    let original = document.tabs[0]
    let second = document.tabs[1]
    let secondWindowID = WindowID()
    let shared = BrowserTab(id: original.id, occurrenceID: second.occurrenceID,
        windowID: secondWindowID, spaceID: second.spaceID, url: second.url)
    let firstWindow = BrowserSessionDocument.Window(id: original.windowID, activeSpaceID: original.spaceID,
        spaces: [.init(spaceID: original.spaceID, occurrenceIDs: [original.occurrenceID], selectedOccurrenceID: original.occurrenceID)])
    let secondWindow = BrowserSessionDocument.Window(id: secondWindowID, activeSpaceID: second.spaceID,
        spaces: [.init(spaceID: second.spaceID, occurrenceIDs: [second.occurrenceID], selectedOccurrenceID: second.occurrenceID)])
    let modified = replacingSession(document, windows: [firstWindow, secondWindow], tabs: [original, shared])
    let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(modified.encoded()))
    let firstSnapshot = try await restored.snapshot(of: firstWindow.id)
    let secondSnapshot = try await restored.snapshot(of: secondWindow.id)
    #expect(firstSnapshot.tabs[0].id == secondSnapshot.tabs[0].id)
    #expect(firstSnapshot.tabs[0].occurrenceID != secondSnapshot.tabs[0].occurrenceID)
    try await restored.closeWindow(firstWindow.id)
    #expect(try await restored.snapshot(of: secondWindow.id).selectedOccurrenceID == second.occurrenceID)
}

@Test("Unknown session versions and oversized inputs are refused before restoration")
func sessionDocumentRejectsUnsupportedInputs() async throws {
    let document = try await sessionFixture()
    #expect(throws: BrowserSessionError.unsupportedVersion) {
        try BrowserStore(restoring: replacingSession(document, version: BrowserSessionDocument.currentVersion + 1))
    }
    #expect(throws: BrowserSessionError.limitExceeded) {
        try BrowserSessionDocument.decode(Data(repeating: 32, count: BrowserSessionDocument.defaultMaximumInputBytes + 1))
    }
}

@Test("Accepted long URLs remain exportable and relative destinations fail before mutation")
func sessionDocumentKeepsAdmittedStateExportable() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    let url = URL(string: "https://session.test/?q=" + String(repeating: "a", count: 16_384))!
    _ = try await store.openTab(url: url, from: store.captureContext(in: window), activate: true)
    let encoded = try await store.sessionDocument().encoded()
    let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(encoded))
    #expect(try await restored.snapshot(of: window).tabs[0].url == url)
    await #expect(throws: BrowserSessionError.invalidURL) {
        try await store.openTab(url: URL(string: "relative-destination")!,
                                from: store.captureContext(in: window), activate: false)
    }
    #expect(try await store.sessionDocument().encoded() == encoded)
}
