import Foundation
import Testing
@testable import BrowserCore

private let exampleURL = URL(string: "https://example.test/page")!

@Test("Background tabs preserve the active tab in their owning window")
func backgroundTabPreservesSelection() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Personal")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    let first = try await store.openTab(
        url: exampleURL,
        from: store.captureContext(in: window),
        activate: true
    )
    let context = try await store.captureContext(in: window)
    let second = try await store.openTab(url: exampleURL, from: context, activate: false)
    let snapshot = try await store.snapshot(of: window)
    #expect(snapshot.selectedOccurrenceID == first)
    #expect(snapshot.tabs.map(\.occurrenceID) == [first, second])
    #expect(await store.isCurrent(context))
}

@Test("A second window has its own tabs and selection")
func windowsKeepIndependentSelection() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Personal")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let firstWindow = try await store.createWindow(activeSpaceID: space)
    let secondWindow = try await store.createWindow(activeSpaceID: space)
    let firstTab = try await store.openTab(
        url: exampleURL,
        from: store.captureContext(in: firstWindow),
        activate: true
    )
    let secondTab = try await store.openTab(
        url: exampleURL,
        from: store.captureContext(in: secondWindow),
        activate: true
    )
    #expect(try await store.snapshot(of: firstWindow).tabs.map(\.occurrenceID) == [firstTab])
    #expect(try await store.snapshot(of: secondWindow).tabs.map(\.occurrenceID) == [secondTab])
    await #expect(throws: BrowserStoreError.occurrenceOwnedByAnotherWindow) {
        try await store.selectOccurrence(firstTab, in: secondWindow)
    }
}

@Test("A Space round trip invalidates the previous context")
func spaceRoundTripRevokesContext() async throws {
    let store = BrowserStore()
    let personal = await store.createProfile(name: "Personal")
    let work = await store.createProfile(name: "Work")
    let home = try await store.createSpace(name: "Home", profileID: personal)
    let office = try await store.createSpace(name: "Office", profileID: work)
    let window = try await store.createWindow(activeSpaceID: home)
    let oldContext = try await store.captureContext(in: window)
    try await store.activateSpace(office, in: window)
    #expect(try await store.captureContext(in: window).profileID == work)
    try await store.activateSpace(home, in: window)
    #expect(try await store.captureContext(in: window).profileID == personal)
    #expect(!(await store.isCurrent(oldContext)))
    await #expect(throws: BrowserStoreError.staleContext) {
        try await store.openTab(url: exampleURL, from: oldContext, activate: false)
    }
    #expect(try await store.snapshot(of: window).tabs.isEmpty)
}

@Test("Selecting a tab revokes an older context even after selecting it again")
func selectionRoundTripRevokesContext() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Personal")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    let first = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: true)
    let oldContext = try await store.captureContext(in: window)
    let second = try await store.openTab(url: exampleURL, from: oldContext, activate: false)
    try await store.selectOccurrence(second, in: window)
    try await store.selectOccurrence(first, in: window)
    #expect(try await store.snapshot(of: window).selectedOccurrenceID == first)
    #expect(!(await store.isCurrent(oldContext)))
}

@Test("Closing one window invalidates only its own context and tabs")
func windowCloseRevokesOnlyItsOwnContext() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Personal")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let firstWindow = try await store.createWindow(activeSpaceID: space)
    let secondWindow = try await store.createWindow(activeSpaceID: space)
    let firstContext = try await store.captureContext(in: firstWindow)
    let secondContext = try await store.captureContext(in: secondWindow)
    try await store.closeWindow(firstWindow)
    #expect(!(await store.isCurrent(firstContext)))
    #expect(await store.isCurrent(secondContext))
    await #expect(throws: BrowserStoreError.staleContext) {
        try await store.openTab(url: exampleURL, from: firstContext, activate: false)
    }
    _ = try await store.openTab(url: exampleURL, from: secondContext, activate: false)
    #expect(try await store.snapshot(of: secondWindow).tabs.count == 1)
}

@Test("A Space cannot be created without a registered profile")
func spaceRequiresProfile() async throws {
    let store = BrowserStore()
    await #expect(throws: BrowserStoreError.profileMissing) {
        try await store.createSpace(name: "Unknown", profileID: ProfileID())
    }
}

@Test("Closing the selected tab chooses its neighbor and leaves an empty window alive")
func selectedTabClosureUpdatesSelection() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Test")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    let first = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: true)
    let second = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: false)
    let third = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: false)
    try await store.selectOccurrence(second, in: window)
    let oldContext = try await store.captureContext(in: window)
    try await store.closeOccurrence(second, from: oldContext)
    #expect(try await store.snapshot(of: window).selectedOccurrenceID == third)
    #expect(!(await store.isCurrent(oldContext)))
    try await store.closeOccurrence(third, from: store.captureContext(in: window))
    #expect(try await store.snapshot(of: window).selectedOccurrenceID == first)
    try await store.closeOccurrence(first, from: store.captureContext(in: window))
    let snapshot = try await store.snapshot(of: window)
    #expect(snapshot.tabs.isEmpty)
    #expect(snapshot.selectedOccurrenceID == nil)
}

@Test("Background closure preserves selection and cannot affect another window or Space")
func backgroundClosureRespectsOwnership() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Test")
    let home = try await store.createSpace(name: "Home", profileID: profile)
    let office = try await store.createSpace(name: "Office", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: home)
    let otherWindow = try await store.createWindow(activeSpaceID: home)
    let selected = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: true)
    let background = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: false)
    let context = try await store.captureContext(in: window)
    let otherContext = try await store.captureContext(in: otherWindow)
    await #expect(throws: BrowserStoreError.occurrenceOwnedByAnotherWindow) {
        try await store.closeOccurrence(background, from: otherContext)
    }
    try await store.activateSpace(office, in: window)
    await #expect(throws: BrowserStoreError.staleContext) {
        try await store.closeOccurrence(background, from: context)
    }
    await #expect(throws: BrowserStoreError.occurrenceOwnedByAnotherWindow) {
        try await store.closeOccurrence(background, from: store.captureContext(in: window))
    }
    try await store.activateSpace(home, in: window)
    let current = try await store.captureContext(in: window)
    try await store.closeOccurrence(background, from: current)
    #expect(await store.isCurrent(current))
    #expect(await store.isCurrent(otherContext))
    #expect(try await store.snapshot(of: window).tabs.map(\.occurrenceID) == [selected])
    await #expect(throws: BrowserStoreError.tabMissing) {
        try await store.closeOccurrence(background, from: current)
    }
}

@Test("Destination metadata preserves tab identities, order and captured selection authority")
func destinationUpdatePreservesSelectionAuthority() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    _ = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: true)
    let background = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: false)
    let context = try await store.captureContext(in: window)
    let before = try await store.snapshot(of: window)
    let destination = URL(string: "https://destination.test/redirected")!
    #expect(try await store.updateDestination(for: background, to: destination, from: context))
    let after = try await store.snapshot(of: window)
    #expect(after.id == before.id)
    #expect(after.activeSpaceID == before.activeSpaceID)
    #expect(after.selectedOccurrenceID == before.selectedOccurrenceID)
    #expect(after.revision == before.revision)
    #expect(after.tabs.map(\.id) == before.tabs.map(\.id))
    #expect(after.tabs.map(\.occurrenceID) == before.tabs.map(\.occurrenceID))
    #expect(after.tabs.map(\.windowID) == before.tabs.map(\.windowID))
    #expect(after.tabs.map(\.spaceID) == before.tabs.map(\.spaceID))
    #expect(after.tabs.map(\.url) == [exampleURL, destination])
    #expect(await store.isCurrent(context))
    #expect(try await !store.updateDestination(for: background, to: destination, from: context))
    #expect(try await store.snapshot(of: window) == after)
    #expect(try await store.captureContext(in: window).profileID == profile)
    let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await store.sessionDocument().encoded()))
    #expect(try await restored.snapshot(of: window).tabs == after.tabs)
    // The metadata update must not invalidate an unrelated selection already authorized by context.
    try await store.selectOccurrence(background, from: context)
    #expect(try await store.snapshot(of: window).selectedOccurrenceID == background)
}

@Test("Invalid destination metadata is rejected before any document mutation")
func destinationUpdateValidatesBeforeMutation() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let space = try await store.createSpace(name: "Home", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: space)
    let occurrence = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: true)
    let context = try await store.captureContext(in: window)
    let before = try await store.sessionDocument().encoded()
    await #expect(throws: BrowserSessionError.invalidURL) {
        try await store.updateDestination(for: occurrence, to: URL(string: "relative-destination")!, from: context)
    }
    #expect(try await store.sessionDocument().encoded() == before)
    #expect(await store.isCurrent(context))
}

@Test("Destination metadata cannot cross window or Space ownership or resurrect a closed occurrence")
func destinationUpdateChecksOccurrenceOwnership() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let home = try await store.createSpace(name: "Home", profileID: profile)
    let office = try await store.createSpace(name: "Office", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: home)
    let otherWindow = try await store.createWindow(activeSpaceID: home)
    let occurrence = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: false)
    let destination = URL(string: "https://destination.test")!
    await #expect(throws: BrowserStoreError.occurrenceOwnedByAnotherWindow) {
        try await store.updateDestination(for: occurrence, to: destination, from: store.captureContext(in: otherWindow))
    }
    try await store.activateSpace(office, in: window)
    await #expect(throws: BrowserStoreError.occurrenceOwnedByAnotherWindow) {
        try await store.updateDestination(for: occurrence, to: destination, from: store.captureContext(in: window))
    }
    try await store.activateSpace(home, in: window)
    let context = try await store.captureContext(in: window)
    try await store.closeOccurrence(occurrence, from: context)
    #expect(await store.isCurrent(context))
    let before = try await store.sessionDocument().encoded()
    await #expect(throws: BrowserStoreError.tabMissing) {
        try await store.updateDestination(for: occurrence, to: destination, from: context)
    }
    #expect(try await store.sessionDocument().encoded() == before)
    try await store.closeWindow(window)
    await #expect(throws: BrowserStoreError.staleContext) {
        try await store.updateDestination(for: occurrence, to: destination, from: context)
    }
    #expect(try await store.snapshot(of: otherWindow).tabs.isEmpty)
}

@Test("Restoration, selection and Space round trips do not revive destination or selection authority")
func destinationUpdateRejectsStaleContexts() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic")
    let home = try await store.createSpace(name: "Home", profileID: profile)
    let office = try await store.createSpace(name: "Office", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: home)
    let first = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: true)
    let second = try await store.openTab(url: exampleURL, from: store.captureContext(in: window), activate: false)
    let original = try await store.captureContext(in: window)
    let restored = try BrowserStore(restoring: await store.sessionDocument())
    let before = try await restored.sessionDocument().encoded()
    await #expect(throws: BrowserStoreError.staleContext) {
        try await restored.updateDestination(for: second, to: exampleURL, from: original)
    }
    #expect(try await restored.sessionDocument().encoded() == before)
    try await store.selectOccurrence(second, in: window)
    try await store.selectOccurrence(first, in: window)
    await #expect(throws: BrowserStoreError.staleContext) {
        try await store.updateDestination(for: second, to: exampleURL, from: original)
    }
    await #expect(throws: BrowserStoreError.staleContext) {
        try await store.selectOccurrence(second, from: original)
    }
    let context = try await store.captureContext(in: window)
    try await store.activateSpace(office, in: window)
    try await store.activateSpace(home, in: window)
    await #expect(throws: BrowserStoreError.staleContext) {
        try await store.updateDestination(for: second, to: exampleURL, from: context)
    }
}
