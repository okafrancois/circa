import Foundation
import Testing
@testable import BrowserCore

private let spacesTestURL = URL(string: "https://spaces.test/initial")!

@Test("Catalog arrays preserve creation and restored source order instead of UUID order")
func spacesCatalogPreservesPersistedOrder() async throws {
    let profile = BrowserProfile(id: ProfileID(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!), name: "First")
    let other = BrowserProfile(id: ProfileID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), name: "Second")
    let first = BrowserSpace(id: SpaceID(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!), profileID: profile.id, name: "First")
    let second = BrowserSpace(id: SpaceID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), profileID: other.id, name: "Second")
    let document = BrowserSessionDocument(profiles: [profile, other], spaces: [first, second], windows: [], tabs: [])
    let store = try BrowserStore(restoring: document)
    #expect(await store.catalogSnapshot() == BrowserCatalogSnapshot(profiles: [profile, other], spaces: [first, second]))
    let thirdProfile = await store.createProfile(name: "Third")
    let third = try await store.createSpace(name: "Third", profileID: thirdProfile)
    let fourth = try await store.createSpace(name: "Fourth", profileID: profile.id)
    let encoded = try await store.sessionDocument().encoded()
    let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(encoded))
    #expect(await restored.catalogSnapshot().profiles.map(\.id) == [profile.id, other.id, thirdProfile])
    #expect(await restored.catalogSnapshot().spaces.map(\.id) == [first.id, second.id, third, fourth])
    #expect(try await restored.sessionDocument().encoded() == encoded)
    #expect(await restored.sessionDocument().version == BrowserSessionDocument.currentVersion)
}

@Test("Space rename and move preserve profiles, identities and window authority and persist their order")
func spacesCatalogEditsPreserveOwnership() async throws {
    let store = BrowserStore()
    let personal = await store.createProfile(name: "Personal")
    let work = await store.createProfile(name: "Work")
    let home = try await store.createSpace(name: "Home", profileID: personal)
    let office = try await store.createSpace(name: "Office", profileID: work)
    let empty = try await store.createSpace(name: "Empty", profileID: personal)
    let window = try await store.createWindow(activeSpaceID: home)
    let context = try await store.captureContext(in: window)
    try await store.renameSpace(home, name: "  Renamed Home  ")
    try await store.moveSpace(empty, before: office)
    try await store.moveSpace(home, before: nil)
    try await store.moveSpace(office, before: office)
    let catalog = await store.catalogSnapshot()
    #expect(catalog.spaces.map(\.id) == [empty, office, home])
    #expect(catalog.spaces.map(\.profileID) == [personal, work, personal])
    #expect(catalog.spaces.last?.name == "Renamed Home")
    #expect(await store.isCurrent(context))
    let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await store.sessionDocument().encoded()))
    #expect(await restored.catalogSnapshot() == catalog)
    #expect(try await restored.snapshot(of: window).activeSpaceID == home)
}

@Test("Invalid catalog edits fail before mutation and rejected creation does not reserve an entry")
func spacesCatalogValidationIsAtomic() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let encoded = try await store.sessionDocument().encoded()
    for name in ["", " \n\t ", "A\nB", "A\u{0000}B"] {
        await #expect(throws: BrowserStoreError.invalidSpaceName) { try await store.renameSpace(space, name: name) }
        await #expect(throws: BrowserStoreError.invalidSpaceName) { try await store.createSpace(name: name, profileID: profile) }
    }
    await #expect(throws: BrowserStoreError.spaceMissing) { try await store.renameSpace(SpaceID(), name: "Valid") }
    await #expect(throws: BrowserStoreError.spaceMissing) { try await store.moveSpace(space, before: SpaceID()) }
    await #expect(throws: BrowserStoreError.spaceMissing) { try await store.moveSpace(SpaceID(), before: nil) }
    await #expect(throws: BrowserStoreError.profileMissing) { try await store.createSpace(name: "Valid", profileID: ProfileID()) }
    #expect(try await store.sessionDocument().encoded() == encoded)
}

@Test("Contextual switching restores each Space and atomically rejects old or restored-store authority")
func spacesSwitchRequiresCurrentAuthority() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let home = try await store.createSpace(name: "Home", profileID: profile)
    let office = try await store.createSpace(name: "Office", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: home)
    let other = try await store.createWindow(activeSpaceID: office)
    let tab = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: window), activate: true)
    let initial = try await store.captureContext(in: window)
    let empty = try await store.activateSpace(office, from: initial)
    #expect(empty.snapshot.tabs.isEmpty && empty.snapshot.selectedOccurrenceID == nil)
    let back = try await store.activateSpace(home, from: empty.context)
    #expect(back.snapshot.tabs.map(\.occurrenceID) == [tab])
    #expect(back.snapshot.selectedOccurrenceID == tab)
    let before = try await store.sessionDocument().encoded()
    await #expect(throws: BrowserStoreError.staleContext) { try await store.activateSpace(office, from: initial) }
    await #expect(throws: BrowserStoreError.staleContext) { try await store.createSpace(name: "Rejected", profileID: profile, from: initial) }
    await #expect(throws: BrowserStoreError.staleContext) { try await store.renameSpace(home, name: "Rejected", from: initial) }
    await #expect(throws: BrowserStoreError.staleContext) { try await store.moveSpace(home, before: nil, from: initial) }
    #expect(try await store.sessionDocument().encoded() == before)
    #expect(try await store.snapshot(of: other).activeSpaceID == office)
    let restored = try BrowserStore(restoring: await store.sessionDocument())
    await #expect(throws: BrowserStoreError.staleContext) { try await restored.activateSpace(office, from: back.context) }
    let unchanged = try await store.activateSpace(home, from: back.context)
    #expect(unchanged.context == back.context)
}

@Test("Occurrence authority updates an inactive profile while preserving active selection and old API guarantees")
func spacesInactiveOccurrenceMetadataAuthority() async throws {
    let store = BrowserStore()
    let personal = await store.createProfile(name: "Personal")
    let work = await store.createProfile(name: "Work")
    let home = try await store.createSpace(name: "Home", profileID: personal)
    let office = try await store.createSpace(name: "Office", profileID: work)
    let window = try await store.createWindow(activeSpaceID: home)
    let tab = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: window), activate: true)
    let original = try await store.captureContext(in: window)
    let authority = try await store.captureOccurrenceAuthority(for: tab, from: original)
    let active = try await store.activateSpace(office, from: original)
    let destination = URL(string: "https://spaces.test/inactive-redirect")!
    #expect(try await store.updateDestination(to: destination, from: authority, validating: active.context))
    #expect(try await !store.updateDestination(to: destination, from: authority))
    #expect(try await store.snapshot(of: window) == active.snapshot)
    #expect(await store.isCurrent(active.context))
    await #expect(throws: BrowserStoreError.staleContext) {
        try await store.updateDestination(for: tab, to: destination, from: original)
    }
    await #expect(throws: BrowserStoreError.occurrenceOwnedByAnotherWindow) {
        try await store.updateDestination(for: tab, to: destination, from: active.context)
    }
    let before = try await store.sessionDocument().encoded()
    await #expect(throws: BrowserSessionError.invalidURL) {
        try await store.updateDestination(to: URL(string: "relative")!, from: authority)
    }
    #expect(try await store.sessionDocument().encoded() == before)
    let back = try await store.activateSpace(home, from: active.context)
    #expect(back.snapshot.tabs.first?.url == destination)
    #expect(back.snapshot.tabs.first?.occurrenceID == tab)
    #expect(authority.profileID == personal)
    #expect(back.occurrenceAuthorities[tab] == authority)
}

@Test("Occurrence authority rejects foreign windows, removed occurrences, closed windows and previous store generations")
func spacesOccurrenceAuthorityCannotResurrectState() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    let other = try await store.createWindow(activeSpaceID: space)
    let tab = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: window), activate: false)
    let context = try await store.captureContext(in: window)
    let authority = try await store.captureOccurrenceAuthority(for: tab, from: context)
    let restored = try BrowserStore(restoring: await store.sessionDocument())
    await #expect(throws: BrowserStoreError.staleContext) {
        try await restored.updateDestination(to: spacesTestURL, from: authority)
    }
    await #expect(throws: BrowserStoreError.staleContext) {
        try await store.updateDestination(to: spacesTestURL, from: authority, validating: store.captureContext(in: other))
    }
    await #expect(throws: BrowserStoreError.occurrenceOwnedByAnotherWindow) {
        try await store.captureOccurrenceAuthority(for: tab, from: store.captureContext(in: other))
    }
    try await store.closeOccurrence(tab, from: context)
    let before = try await store.sessionDocument().encoded()
    await #expect(throws: BrowserStoreError.tabMissing) { try await store.updateDestination(to: spacesTestURL, from: authority) }
    #expect(try await store.sessionDocument().encoded() == before)
    try await store.closeWindow(window)
    await #expect(throws: BrowserStoreError.staleContext) { try await store.updateDestination(to: spacesTestURL, from: authority) }
    #expect(try await store.snapshot(of: other).tabs.isEmpty)
}

@Test("Adjacent switching uses current catalog order and clamps extreme offsets")
func spacesAdjacentSwitchUsesLiveCatalog() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let first = try await store.createSpace(name: "First", profileID: profile)
    let second = try await store.createSpace(name: "Second", profileID: profile)
    let third = try await store.createSpace(name: "Third", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: first)
    let next = try await store.activateAdjacentSpace(offset: 1, from: store.captureContext(in: window))
    #expect(next.context.spaceID == second)
    try await store.moveSpace(third, before: second)
    let previous = try await store.activateAdjacentSpace(offset: -1, from: next.context)
    #expect(previous.context.spaceID == third)
    let last = try await store.activateAdjacentSpace(offset: Int.max, from: previous.context)
    #expect(last.context.spaceID == second)
    let start = try await store.activateAdjacentSpace(offset: Int.min, from: last.context)
    #expect(start.context.spaceID == first)
    let clamped = try await store.activateAdjacentSpace(offset: -1, from: start.context)
    #expect(clamped.context == start.context)
}

@Test("Atomic post-close state resolves context-preserving background removals and insertions", arguments: [false, true])
func spacesAtomicCloseUsesCurrentMembership(insertBackground: Bool) async throws {
    let store = BrowserStore()
    let personal = await store.createProfile(name: "Synthetic Personal")
    let work = await store.createProfile(name: "Synthetic Work")
    let home = try await store.createSpace(name: "Home", profileID: personal)
    let office = try await store.createSpace(name: "Office", profileID: work)
    let window = try await store.createWindow(activeSpaceID: office)
    let workTab = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: window), activate: true)
    try await store.activateSpace(home, in: window)
    let first = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: window), activate: true)
    let selected = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: window), activate: true)
    let context = try await store.captureContext(in: window)
    try await store.closeOccurrence(first, from: context)
    var background: TabOccurrenceID?
    if insertBackground {
        background = try await store.openTab(url: spacesTestURL, from: context, activate: false)
    }
    #expect(await store.isCurrent(context))
    let state = try await store.closeOccurrenceAndCaptureState(selected, from: context)
    #expect(state.snapshot.tabs.map(\.occurrenceID) == background.map { [$0] } ?? [])
    #expect(state.snapshot.selectedOccurrenceID == background)
    #expect(state.context.selectedOccurrenceID == background)
    #expect(state.context.revision == context.revision &+ 1)
    #expect(Set(state.occurrenceAuthorities.keys) == Set([workTab] + (background.map { [$0] } ?? [])))
    #expect(state.occurrenceAuthorities[workTab]?.profileID == work)
    #expect(state.occurrenceAuthorities[first] == nil && state.occurrenceAuthorities[selected] == nil)
    #expect(state.snapshot == (try await store.snapshot(of: window)))
    let opened = try await store.openTab(url: spacesTestURL, from: state.context, activate: true)
    #expect(try await store.snapshot(of: window).selectedOccurrenceID == opened)
}

@Test("Atomic window state inventories exact active and inactive leases without including other windows")
func spacesWindowStateInventoriesInactiveLeases() async throws {
    let store = BrowserStore()
    let personal = await store.createProfile(name: "Synthetic Personal")
    let work = await store.createProfile(name: "Synthetic Work")
    let home = try await store.createSpace(name: "Home", profileID: personal)
    let office = try await store.createSpace(name: "Office", profileID: work)
    let window = try await store.createWindow(activeSpaceID: home)
    let other = try await store.createWindow(activeSpaceID: home)
    let homeTab = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: window), activate: true)
    let foreign = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: other), activate: true)
    let homeContext = try await store.captureContext(in: window)
    let homeAuthority = try await store.captureOccurrenceAuthority(for: homeTab, from: homeContext)
    _ = try await store.activateSpace(office, from: homeContext)
    let selected = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: window), activate: true)
    let background = try await store.openTab(url: spacesTestURL, from: store.captureContext(in: window), activate: false)
    let context = try await store.captureContext(in: window)
    let state = try await store.captureWindowState(from: context)
    #expect(state.snapshot.tabs.map(\.occurrenceID) == [selected, background])
    #expect(Set(state.occurrenceAuthorities.keys) == Set([homeTab, selected, background]))
    #expect(state.occurrenceAuthorities[homeTab] == homeAuthority)
    #expect(state.occurrenceAuthorities[foreign] == nil)
    #expect(state.occurrenceAuthorities[selected]?.profileID == work)
    try await store.closeOccurrence(background, from: context)
    #expect(await store.isCurrent(context))
    let refreshed = try await store.captureWindowState(from: context)
    #expect(Set(refreshed.occurrenceAuthorities.keys) == Set([homeTab, selected]))
    #expect(refreshed.occurrenceAuthorities[homeTab] == homeAuthority)
}
