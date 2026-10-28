import Foundation
import Testing
@testable import BrowserCore

private struct OwnedOccurrenceFixture: Sendable {
    let store: BrowserStore
    let home: SpaceID
    let work: SpaceID
    let sameProfileSpace: SpaceID
    let windowID: WindowID
    let otherWindowID: WindowID
    let homeIDs: [TabOccurrenceID]
    let workIDs: [TabOccurrenceID]
    let homeAuthority: BrowserOccurrenceAuthority
    let foreignAuthority: BrowserOccurrenceAuthority
    let active: BrowserContext
}

private func ownedOccurrenceFixture() async throws -> OwnedOccurrenceFixture {
    let store = BrowserStore()
    let personal = await store.createProfile(name: "Synthetic Owned Personal")
    let professional = await store.createProfile(name: "Synthetic Owned Work")
    let home = try await store.createSpace(name: "Owned Home", profileID: personal)
    let work = try await store.createSpace(name: "Owned Work", profileID: professional)
    let sameProfileSpace = try await store.createSpace(name: "Owned Other Personal", profileID: personal)
    let window = try await store.createWindow(activeSpaceID: home)
    var homeIDs: [TabOccurrenceID] = []
    var workIDs: [TabOccurrenceID] = []
    for index in 0..<2 {
        homeIDs.append(try await store.openTab(url: URL(string: "https://owned.test/home/\(index)")!,
            from: store.captureContext(in: window), activate: index == 0))
    }
    let authority = try await store.captureOccurrenceAuthority(for: homeIDs[0], from: store.captureContext(in: window))
    try await store.activateSpace(work, in: window)
    for index in 0..<2 {
        workIDs.append(try await store.openTab(url: URL(string: "https://owned.test/work/\(index)")!,
            from: store.captureContext(in: window), activate: index == 0))
    }
    let other = try await store.createWindow(activeSpaceID: home)
    let foreignID = try await store.openTab(url: URL(string: "https://owned.test/foreign")!,
        from: store.captureContext(in: other), activate: true)
    let foreignAuthority = try await store.captureOccurrenceAuthority(for: foreignID, from: store.captureContext(in: other))
    return OwnedOccurrenceFixture(store: store, home: home, work: work, sameProfileSpace: sameProfileSpace,
        windowID: window, otherWindowID: other, homeIDs: homeIDs, workIDs: workIDs,
        homeAuthority: authority, foreignAuthority: foreignAuthority, active: try await store.captureContext(in: window))
}

private func changedOwnedAuthority(
    _ authority: BrowserOccurrenceAuthority, generation: UUID? = nil, window: WindowID? = nil,
    space: SpaceID? = nil, profile: ProfileID? = nil, occurrence: TabOccurrenceID? = nil
) -> BrowserOccurrenceAuthority {
    BrowserOccurrenceAuthority(storeGeneration: generation ?? authority.storeGeneration,
        windowID: window ?? authority.windowID, spaceID: space ?? authority.spaceID,
        profileID: profile ?? authority.profileID, occurrenceID: occurrence ?? authority.occurrenceID)
}

@Suite("Exact owned occurrence closure")
struct BrowserOwnedOccurrenceTests {
    @Test("Inactive-profile closure preserves active context and reconciles the inactive neighbor")
    func inactiveClosurePreservesCurrentContext() async throws {
        let fixture = try await ownedOccurrenceFixture()
        let store = fixture.store
        let activeBefore = try await store.snapshot(of: fixture.windowID)
        let otherBefore = try await store.snapshot(of: fixture.otherWindowID)
        await #expect(throws: BrowserStoreError.occurrenceOwnedByAnotherWindow) {
            try await store.closeOccurrence(fixture.homeIDs[0], from: fixture.active)
        }
        let state = try await store.closeOwnedOccurrenceAndCaptureState(fixture.homeAuthority, validating: fixture.active)
        #expect(state.context == fixture.active && state.snapshot == activeBefore)
        #expect(state.occurrenceAuthorities[fixture.homeIDs[0]] == nil)
        #expect(state.occurrenceAuthorities[fixture.homeIDs[1]]?.profileID == fixture.homeAuthority.profileID)
        #expect(state.occurrenceAuthorities[fixture.workIDs[0]]?.profileID == fixture.active.profileID)
        #expect(try await store.snapshot(of: fixture.otherWindowID) == otherBefore)
        let document = await store.sessionDocument()
        try document.validate()
        let window = try #require(document.windows.first { $0.id == fixture.windowID })
        let inactive = try #require(window.spaces.first { $0.spaceID == fixture.home })
        #expect(inactive.occurrenceIDs == [fixture.homeIDs[1]] && inactive.selectedOccurrenceID == fixture.homeIDs[1])
        let back = try await store.activateSpace(fixture.home, from: state.context)
        #expect(back.snapshot.tabs.map(\.occurrenceID) == [fixture.homeIDs[1]])
        #expect(back.context.profileID == fixture.homeAuthority.profileID && back.snapshot.selectedOccurrenceID == fixture.homeIDs[1])
    }

    @Test("Closing the last inactive selected occurrence preserves the active revision")
    func inactiveLastOccurrenceLeavesEmptySpace() async throws {
        let fixture = try await ownedOccurrenceFixture()
        let first = try await fixture.store.closeOwnedOccurrenceAndCaptureState(fixture.homeAuthority, validating: fixture.active)
        let last = try #require(first.occurrenceAuthorities[fixture.homeIDs[1]])
        let state = try await fixture.store.closeOwnedOccurrenceAndCaptureState(last, validating: first.context)
        #expect(state.context == fixture.active && state.snapshot.selectedOccurrenceID == fixture.workIDs[0])
        let back = try await fixture.store.activateSpace(fixture.home, from: state.context)
        #expect(back.snapshot.tabs.isEmpty && back.snapshot.selectedOccurrenceID == nil)
        try await fixture.store.sessionDocument().validate()
    }

    @Test("Active background and selected closures preserve existing neighbor and revision behavior", arguments: [false, true])
    func activeClosureKeepsExistingSelectionRules(closeSelected: Bool) async throws {
        let fixture = try await ownedOccurrenceFixture()
        let target = fixture.workIDs[closeSelected ? 0 : 1]
        let before = try await fixture.store.captureWindowState(from: fixture.active)
        let authority = try #require(before.occurrenceAuthorities[target])
        let state = try await fixture.store.closeOwnedOccurrenceAndCaptureState(authority, validating: fixture.active)
        let remaining = fixture.workIDs[closeSelected ? 1 : 0]
        #expect(state.snapshot.tabs.map(\.occurrenceID) == [remaining])
        #expect(state.snapshot.selectedOccurrenceID == remaining)
        #expect(state.context.revision == fixture.active.revision &+ (closeSelected ? 1 : 0))
        #expect(state.context.spaceID == fixture.work && state.context.profileID == fixture.active.profileID)
        #expect(state.occurrenceAuthorities[fixture.homeIDs[0]] == fixture.homeAuthority)
    }

    @Test("Every lease field and target inventory are validated before exact closure")
    func malformedOrForeignLeasesCannotMutate() async throws {
        let fixture = try await ownedOccurrenceFixture()
        let authority = fixture.homeAuthority
        let invalid: [(BrowserOccurrenceAuthority, BrowserStoreError)] = [
            (changedOwnedAuthority(authority, generation: UUID()), .staleContext),
            (changedOwnedAuthority(authority, window: fixture.otherWindowID), .staleContext),
            (changedOwnedAuthority(authority, profile: fixture.active.profileID), .staleContext),
            (changedOwnedAuthority(authority, space: fixture.work), .staleContext),
            (changedOwnedAuthority(authority, space: fixture.sameProfileSpace), .occurrenceOwnedByAnotherWindow),
            (changedOwnedAuthority(authority, occurrence: fixture.foreignAuthority.occurrenceID), .occurrenceOwnedByAnotherWindow),
            (changedOwnedAuthority(authority, occurrence: TabOccurrenceID()), .tabMissing),
            (fixture.foreignAuthority, .staleContext)
        ]
        let before = await fixture.store.sessionDocument()
        for (lease, error) in invalid {
            await #expect(throws: error) {
                try await fixture.store.closeOwnedOccurrenceAndCaptureState(lease, validating: fixture.active)
            }
            #expect(await fixture.store.sessionDocument() == before)
        }
    }

    @Test("An exact lease cannot replace independently current window authorization", arguments: ["selection", "space", "foreign-window"])
    func staleContextCannotAuthorizeInactiveClosure(change: String) async throws {
        let fixture = try await ownedOccurrenceFixture()
        var context = fixture.active
        switch change {
        case "selection":
            try await fixture.store.selectOccurrence(fixture.workIDs[1], in: fixture.windowID)
            try await fixture.store.selectOccurrence(fixture.workIDs[0], in: fixture.windowID)
        case "space":
            try await fixture.store.activateSpace(fixture.home, in: fixture.windowID)
            try await fixture.store.activateSpace(fixture.work, in: fixture.windowID)
        default:
            context = try await fixture.store.captureContext(in: fixture.otherWindowID)
        }
        let before = await fixture.store.sessionDocument()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await fixture.store.closeOwnedOccurrenceAndCaptureState(fixture.homeAuthority, validating: context)
        }
        #expect(await fixture.store.sessionDocument() == before)
    }

    @Test("Removed leases and closed windows cannot be recreated through exact closure")
    func removedOrClosedTargetsAreRejected() async throws {
        let fixture = try await ownedOccurrenceFixture()
        _ = try await fixture.store.closeOwnedOccurrenceAndCaptureState(fixture.homeAuthority, validating: fixture.active)
        #expect(await fixture.store.isCurrent(fixture.active))
        let before = await fixture.store.sessionDocument()
        await #expect(throws: BrowserStoreError.tabMissing) {
            try await fixture.store.closeOwnedOccurrenceAndCaptureState(fixture.homeAuthority, validating: fixture.active)
        }
        #expect(await fixture.store.sessionDocument() == before)
        try await fixture.store.closeWindow(fixture.windowID)
        let closed = await fixture.store.sessionDocument()
        await #expect(throws: BrowserStoreError.staleContext) {
            try await fixture.store.closeOwnedOccurrenceAndCaptureState(fixture.homeAuthority, validating: fixture.active)
        }
        #expect(await fixture.store.sessionDocument() == closed)
        #expect(try await fixture.store.snapshot(of: fixture.otherWindowID).tabs.count == 1)
    }

    @Test("Restored stores reject previous-generation leases and contexts independently")
    func previousGenerationCannotAuthorizeClosure() async throws {
        let fixture = try await ownedOccurrenceFixture()
        let document = await fixture.store.sessionDocument()
        let restored = try BrowserStore(restoring: document)
        let current = try await restored.captureWindowState(in: fixture.windowID)
        let newLease = try #require(current.occurrenceAuthorities[fixture.homeIDs[0]])
        await #expect(throws: BrowserStoreError.staleContext) {
            try await restored.closeOwnedOccurrenceAndCaptureState(fixture.homeAuthority, validating: current.context)
        }
        await #expect(throws: BrowserStoreError.staleContext) {
            try await restored.closeOwnedOccurrenceAndCaptureState(newLease, validating: fixture.active)
        }
        #expect(await restored.sessionDocument() == document)
        #expect(await fixture.store.sessionDocument() == document)
    }
}
