import BrowserCore
@testable import BrowserShell
import Foundation
import Testing

@MainActor
private final class SwipeSurface: BrowserSurface {
    let profileID: ProfileID
    let initialURL: URL
    var currentURL: URL? { initialURL }
    func dispose() {}
    init(profileID: ProfileID, initialURL: URL) { self.profileID = profileID; self.initialURL = initialURL }
}

@Test("Space swipe activation rejects revoked input and stale catalog without changing selection")
@MainActor
func spaceSwipeSessionRevocation() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic swipe")
    let first = try await store.createSpace(name: "First", profileID: profile)
    let second = try await store.createSpace(name: "Second", profileID: profile)
    let session = BrowserWindowSession<SwipeSurface>(store: store, spaceID: first) { SwipeSurface(profileID: $0, initialURL: $1) }
    await session.waitForPendingCommands()
    let catalog = try #require(session.catalog)
    var accepted: Bool?
    session.activateSpaceFromSwipe(second, catalog: catalog, isCurrent: { false }, completion: { accepted = $0 })
    await session.waitForPendingCommands()
    #expect(accepted == false)
    #expect(session.snapshot?.activeSpaceID == first)
    _ = try await store.createSpace(name: "Catalog changed", profileID: profile)
    session.activateSpaceFromSwipe(second, catalog: catalog, isCurrent: { true }, completion: { accepted = $0 })
    await session.waitForPendingCommands()
    #expect(accepted == false)
    #expect(session.snapshot?.activeSpaceID == first)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Space swipe valid commitment preserves live documents and profile identity")
@MainActor
func spaceSwipeSessionPreservesDocuments() async throws {
    let store = BrowserStore()
    let firstProfile = await store.createProfile(name: "Synthetic A")
    let secondProfile = await store.createProfile(name: "Synthetic B")
    let first = try await store.createSpace(name: "First", profileID: firstProfile)
    let second = try await store.createSpace(name: "Second", profileID: secondProfile)
    var surfaces: [SwipeSurface] = []
    let session = BrowserWindowSession<SwipeSurface>(store: store, spaceID: first) {
        let surface = SwipeSurface(profileID: $0, initialURL: $1); surfaces.append(surface); return surface
    }
    session.openTab(url: URL(string: "https://synthetic.invalid/a")!)
    await session.waitForPendingCommands()
    let original = try #require(session.selectedSurface)
    let catalog = try #require(session.catalog)
    var accepted: Bool?
    session.activateSpaceFromSwipe(second, catalog: catalog, isCurrent: { true }, completion: { accepted = $0 })
    await session.waitForPendingCommands()
    #expect(accepted == true)
    #expect(session.snapshot?.activeSpaceID == second)
    #expect(surfaces.count == 1)
    session.activateSpace(first)
    await session.waitForPendingCommands()
    #expect(session.selectedSurface === original)
    #expect(original.profileID == firstProfile)
    #expect(surfaces.count == 1)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Space swipe queued activation cannot override an earlier external Space selection")
@MainActor
func spaceSwipeQueuedExternalSelection() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic queued swipe")
    let first = try await store.createSpace(name: "First", profileID: profile)
    let second = try await store.createSpace(name: "Second", profileID: profile)
    let third = try await store.createSpace(name: "Third", profileID: profile)
    let session = BrowserWindowSession<SwipeSurface>(store: store, spaceID: first) {
        SwipeSurface(profileID: $0, initialURL: $1)
    }
    await session.waitForPendingCommands()
    let catalog = try #require(session.catalog)
    var accepted: Bool?
    session.activateSpace(third)
    session.activateSpaceFromSwipe(second, catalog: catalog, isCurrent: { true }, completion: { accepted = $0 })
    await session.waitForPendingCommands()
    #expect(accepted == false)
    #expect(session.snapshot?.activeSpaceID == third)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Space swipe revocation before store admission refuses even after main actor validity passed")
@MainActor
func spaceSwipeBeforeAdmissionRevocation() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic admission")
    let first = try await store.createSpace(name: "First", profileID: profile)
    let second = try await store.createSpace(name: "Second", profileID: profile)
    let session = BrowserWindowSession<SwipeSurface>(store: store, spaceID: first) { SwipeSurface(profileID: $0, initialURL: $1) }
    await session.waitForPendingCommands()
    let catalog = try #require(session.catalog)
    for _ in ["resize", "modal", "Peek"] {
        let admission = SpaceSwipeAdmission()
        var accepted: Bool?
        session.activateSpaceFromSwipe(second, catalog: catalog, admission: admission,
            isCurrent: {
                let mainActorValidity = true
                // Inject revocation after this stale UI decision, before crossing to the store.
                #expect(admission.revoke())
                return mainActorValidity
            }, completion: { accepted = $0 })
        await session.waitForPendingCommands()
        #expect(accepted == false)
        #expect(admission.state == .revoked)
        #expect(session.snapshot?.activeSpaceID == first)
    }
    session.close()
    await session.waitForPendingCommands()
}


@Test("Space swipe store admission precedes render publication and cannot be retracted by later UI cancellation")
@MainActor
func spaceSwipeAdmittedPublicationBoundary() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic publication boundary")
    let first = try await store.createSpace(name: "First", profileID: profile)
    let second = try await store.createSpace(name: "Second", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: first)
    let context = try await store.captureContext(in: window)
    let catalog = await store.catalogSnapshot()
    let admission = SpaceSwipeAdmission()
    let state = try await store.activateSpaceFromSwipe(second, from: context, catalog: catalog, admission: admission)
    #expect(admission.state == .admitted)
    // This state has not been installed/published by any shell. The store has already selected.
    #expect(state.snapshot.activeSpaceID == second)
    #expect(!admission.revoke())
    #expect(try await store.snapshot(of: window).activeSpaceID == second)
    try await store.closeWindow(window)
}

@Test("Space swipe store rejects deleted or reassigned identities and same-Space context round trips before admission")
@MainActor
func spaceSwipeIndependentStoreInvalidation() async throws {
    for mutation in ["target removal", "target reassignment", "profile removal", "source round trip"] {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic source")
        let targetProfile = await store.createProfile(name: "Synthetic target")
        let first = try await store.createSpace(name: "Source", profileID: profile)
        let target = try await store.createSpace(name: "Target", profileID: targetProfile)
        let window = try await store.createWindow(activeSpaceID: first)
        let context = try await store.captureContext(in: window)
        let catalog = await store.catalogSnapshot()
        switch mutation {
        case "target removal": try await store.removeSettingsSpace(target)
        case "target reassignment": try await store.assignSettingsSpace(target, to: profile)
        case "profile removal":
            try await store.removeSettingsSpace(target)
            try await store.removeSettingsProfile(targetProfile)
        default:
            try await store.activateSpace(target, in: window)
            try await store.activateSpace(first, in: window)
        }
        let before = await store.sessionDocument()
        let admission = SpaceSwipeAdmission()
        do {
            _ = try await store.activateSpaceFromSwipe(target, from: context, catalog: catalog, admission: admission)
            Issue.record("Stale swipe unexpectedly selected after \(mutation)")
        } catch {
            #expect(error as? BrowserStoreError == .staleContext)
        }
        #expect(admission.state == .pending)
        #expect(await store.sessionDocument() == before)
        #expect(try await store.snapshot(of: window).activeSpaceID == first)
        try await store.closeWindow(window)
    }
}

@Test("Space swipe admission is one shot even when a fresh context requests the reverse selection")
@MainActor
func spaceSwipeIndependentAdmissionReplay() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic replay")
    let first = try await store.createSpace(name: "Source", profileID: profile)
    let second = try await store.createSpace(name: "Target", profileID: profile)
    let window = try await store.createWindow(activeSpaceID: first)
    let context = try await store.captureContext(in: window)
    let catalog = await store.catalogSnapshot()
    let admission = SpaceSwipeAdmission()
    let state = try await store.activateSpaceFromSwipe(second, from: context, catalog: catalog, admission: admission)
    do {
        _ = try await store.activateSpaceFromSwipe(first, from: state.context, catalog: catalog, admission: admission)
        Issue.record("An admitted swipe lease was reused")
    } catch {
        #expect(error as? BrowserStoreError == .staleContext)
    }
    #expect(admission.state == .admitted)
    #expect(try await store.snapshot(of: window).activeSpaceID == second)
    try await store.closeWindow(window)
}

@Test("Space swipe waits for presentation before activating or creating destination surfaces")
@MainActor
func spaceSwipeWaitsForPresentation() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic presentation")
    let first = try await store.createSpace(name: "First", profileID: profile)
    let second = try await store.createSpace(name: "Second", profileID: profile)
    let session = BrowserWindowSession<SwipeSurface>(store: store, spaceID: first) { SwipeSurface(profileID: $0, initialURL: $1) }
    await session.waitForPendingCommands()
    let catalog = try #require(session.catalog)
    var release: CheckedContinuation<Void, Never>?
    var accepted: Bool?
    session.activateSpaceFromSwipe(second, catalog: catalog,
        waitForPresentation: { await withCheckedContinuation { release = $0 } },
        isCurrent: { true }, completion: { accepted = $0 })
    for _ in 0..<20 where release == nil { await Task.yield() }
    let continuation = try #require(release)
    #expect(accepted == nil)
    #expect(session.snapshot?.activeSpaceID == first)
    #expect(try await store.captureContext(in: session.windowID!).spaceID == first)
    continuation.resume()
    await session.waitForPendingCommands()
    #expect(accepted == true)
    #expect(session.snapshot?.activeSpaceID == second)
    session.close()
    await session.waitForPendingCommands()
}

@Test("Cancelling a Space swipe during presentation revokes the waiting activation")
@MainActor
func spaceSwipeCancelledPresentation() async throws {
    let store = BrowserStore()
    let profile = await store.createProfile(name: "Synthetic cancelled presentation")
    let first = try await store.createSpace(name: "First", profileID: profile)
    let second = try await store.createSpace(name: "Second", profileID: profile)
    let session = BrowserWindowSession<SwipeSurface>(store: store, spaceID: first) { SwipeSurface(profileID: $0, initialURL: $1) }
    await session.waitForPendingCommands()
    let catalog = try #require(session.catalog)
    let admission = SpaceSwipeAdmission()
    var release: CheckedContinuation<Void, Never>?
    var accepted: Bool?
    session.activateSpaceFromSwipe(second, catalog: catalog, admission: admission,
        waitForPresentation: { await withCheckedContinuation { release = $0 } },
        isCurrent: { true }, completion: { accepted = $0 })
    for _ in 0..<20 where release == nil { await Task.yield() }
    let continuation = try #require(release)
    #expect(admission.revoke())
    continuation.resume()
    await session.waitForPendingCommands()
    #expect(accepted == false)
    #expect(session.snapshot?.activeSpaceID == first)
    session.close()
    await session.waitForPendingCommands()
}
