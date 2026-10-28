import BrowserCore
import Foundation
import Testing
@testable import BrowserShell

@MainActor
private final class AdmissionSurface: BrowserSurface {
    let profileID: ProfileID
    let currentURL: URL?
    var disposals = 0
    init(profileID: ProfileID, url: URL) { self.profileID = profileID; currentURL = url }
    func dispose() { disposals += 1 }
}

@Suite("Independent captured Store admission recheck", .serialized)
@MainActor
struct CapturedStoreAdmissionRecheckTests {
    private let destination = URL(string: "https://chromewebstore.google.com/")!

    @Test("Actor authority rejects unpublished Space and occurrence ABA despite exact local equality",
          arguments: [0, 1, 2, 3])
    func unpublishedActorRevocation(mode: Int) async throws {
        let store = BrowserStore()
        var surfaces: [AdmissionSurface] = []
        let session = BrowserWindowSession(store: store) { profile, url in
            let surface = AdmissionSurface(profileID: profile, url: url)
            surfaces.append(surface)
            return surface
        }
        session.openTab(url: URL(string: "https://origin.invalid/form")!)
        session.openTab(url: URL(string: "https://origin.invalid/background")!, activate: false)
        await session.waitForPendingCommands()
        let context = try #require(session.paletteContext)
        var errors: [any Error] = []
        session.onError = { errors.append($0) }
        if mode == 3 {
            let other = try #require(session.snapshot?.tabs.last?.occurrenceID)
            try await store.selectOccurrence(other, in: context.windowID)
            try await store.selectOccurrence(try #require(context.selectedOccurrenceID), in: context.windowID)
        } else {
            let profile = mode == 2 ? context.profileID : await store.createProfile(name: "Synthetic foreign")
            let space = try await store.createSpace(name: "Synthetic alternate", profileID: profile)
            try await store.activateSpace(space, in: context.windowID)
            if mode != 0 { try await store.activateSpace(context.spaceID, in: context.windowID) }
        }
        // The new synchronous gate deliberately still passes. Only the real actor can refuse.
        #expect(session.activeContext == context)
        #expect(await store.isCurrent(context) == false)
        let before = await store.sessionDocument()
        let count = surfaces.count
        session.openTab(url: destination, from: context)
        #expect(session.hasPendingCommands)
        await session.waitForPendingCommands()
        #expect(await store.sessionDocument().tabs == before.tabs)
        #expect(surfaces.count == count)
        #expect(errors.count == 1 && errors.first as? BrowserStoreError == .staleContext)
        #expect(session.activeContext == context)
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Captured creation joins synchronously, commits once and a repeated stale capture cannot duplicate")
    func queueOrderAndDuplicate() async throws {
        let store = BrowserStore()
        let session = BrowserWindowSession(store: store) { AdmissionSurface(profileID: $0, url: $1) }
        session.openTab()
        await session.waitForPendingCommands()
        let context = try #require(session.paletteContext)
        let profile = await store.createProfile(name: "Synthetic next profile")
        let space = try await store.createSpace(name: "Synthetic next Space", profileID: profile)
        session.openTab(url: destination, from: context)
        session.openTab(url: destination, from: context)
        session.activateSpace(space)
        await session.waitForPendingCommands()
        let document = await store.sessionDocument()
        let created = document.tabs.filter { $0.url == destination }
        #expect(created.count == 1 && created.first?.spaceID == context.spaceID)
        #expect(session.activeProfileID == profile)
        // Uncaptured navigation still resolves the queued destination, as before this repair.
        session.openTab(url: URL(string: "https://ordinary.invalid/")!)
        let delivery = session.openTabForDelivery(url: URL(string: "https://delivery.invalid/")!, expectedProfileID: profile)
        #expect(await delivery.value != nil)
        await session.waitForPendingCommands()
        #expect(session.selectedSurface?.profileID == profile)
        #expect(session.selectedSurface?.currentURL?.host == "delivery.invalid")
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("Close or terminal retirement revoke queued captured creation", arguments: [false, true])
    func retirement(terminate: Bool) async throws {
        let store = BrowserStore()
        var surfaces: [AdmissionSurface] = []
        let session = BrowserWindowSession(store: store) { profile, url in
            let surface = AdmissionSurface(profileID: profile, url: url)
            surfaces.append(surface)
            return surface
        }
        session.openTab()
        await session.waitForPendingCommands()
        let context = try #require(session.paletteContext)
        session.openTab(url: destination, from: context)
        if terminate { session.retireForApplicationTermination() } else { session.close() }
        session.openTab(url: destination, from: context)
        await session.waitForPendingCommands()
        #expect(surfaces.count == 1 && surfaces[0].disposals == 1)
        #expect(await store.sessionDocument().tabs.allSatisfy { $0.url != destination })
        #expect(!session.hasPendingCommands)
    }

    @Test("Reentrant factory retirement cannot replay a committed Store or retain an orphan")
    func reentrantRetirement() async throws {
        let store = BrowserStore()
        var surfaces: [AdmissionSurface] = []
        var retire: (() -> Void)?
        let session = BrowserWindowSession(store: store) { profile, url in
            let surface = AdmissionSurface(profileID: profile, url: url)
            surfaces.append(surface)
            if url == URL(string: "https://chromewebstore.google.com/")! { retire?() }
            return surface
        }
        session.openTab()
        await session.waitForPendingCommands()
        let context = try #require(session.paletteContext)
        retire = { session.retireForApplicationTermination() }
        session.openTab(url: destination, from: context)
        await session.waitForPendingCommands()
        #expect(session.isClosed && session.ownedSurfaces.isEmpty)
        #expect(surfaces.count == 2 && surfaces.allSatisfy { $0.disposals == 1 })
        #expect(await store.sessionDocument().tabs.filter { $0.url == destination }.count == 1)
        #expect(!session.hasPendingCommands)
    }

    @Test("Concurrent actor admission and profile selection never retarget or replay a committed Store")
    func actorAdmissionRace() async throws {
        for _ in 0..<24 {
            let store = BrowserStore()
            var surfaces: [AdmissionSurface] = []
            let session = BrowserWindowSession(store: store) { profile, url in
                let surface = AdmissionSurface(profileID: profile, url: url)
                surfaces.append(surface)
                return surface
            }
            session.openTab(url: URL(string: "https://race-review.invalid/form")!)
            await session.waitForPendingCommands()
            let context = try #require(session.paletteContext)
            let profile = await store.createProfile(name: "Synthetic race B")
            let space = try await store.createSpace(name: "Synthetic race B Space", profileID: profile)
            let transition = Task.detached {
                try await store.activateSpace(space, in: context.windowID)
            }
            session.openTab(url: destination, from: context)
            try await transition.value
            await session.waitForPendingCommands()
            let created = await store.sessionDocument().tabs.filter { $0.url == destination }
            #expect(created.count <= 1)
            #expect(created.allSatisfy { $0.spaceID == context.spaceID && $0.windowID == context.windowID })
            #expect(surfaces.allSatisfy { $0.profileID == context.profileID })
            session.close()
            await session.waitForPendingCommands()
            #expect(surfaces.allSatisfy { $0.disposals == 1 })
        }
    }
}
