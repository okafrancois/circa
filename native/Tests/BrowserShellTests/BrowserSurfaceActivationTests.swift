import BrowserCore
import BrowserShell
import Foundation
import Testing

@MainActor
private final class ActivationSurface: BrowserSurface {
    let profileID: ProfileID
    let currentURL: URL?
    init(profile: ProfileID, url: URL) { profileID = profile; currentURL = url }
    func dispose() {}
}

@Suite("Native surface activation")
@MainActor
struct BrowserSurfaceActivationTests {
    @Test("A native activation returns to the original occurrence and profile across Spaces")
    func originalSurface() async throws {
        let store = BrowserStore()
        let firstProfile = try await store.createProfile(name: "First")
        let secondProfile = try await store.createProfile(name: "Second")
        let first = try await store.createSpace(name: "First", profileID: firstProfile)
        let second = try await store.createSpace(name: "Second", profileID: secondProfile)
        let session = BrowserWindowSession<ActivationSurface>(store: store, spaceID: first) { profile, url in
            ActivationSurface(profile: profile, url: url)
        }
        session.openTab(url: URL(string: "https://example.test")!)
        await session.waitForPendingCommands()
        let surface = try #require(session.selectedSurface)
        let occurrence = try #require(session.snapshot?.selectedOccurrenceID)
        session.activateSpace(second)
        session.openTab(url: URL(string: "https://example.test")!)
        await session.waitForPendingCommands()
        #expect(session.selectedSurface !== surface)
        #expect(await session.activateOwnedSurface(surface).value)
        #expect(session.selectedSurface === surface)
        #expect(session.snapshot?.selectedOccurrenceID == occurrence)
        #expect(session.paletteContext?.profileID == firstProfile)
        #expect(session.paletteContext?.spaceID == first)
        session.close()
        await session.waitForPendingCommands()
        #expect(await session.activateOwnedSurface(surface).value == false)
    }

    @Test("Another window cannot activate a surface it does not own")
    func foreignWindow() async throws {
        let store = BrowserStore()
        let owner = BrowserWindowSession<ActivationSurface>(store: store) { profile, url in ActivationSurface(profile: profile, url: url) }
        let other = BrowserWindowSession<ActivationSurface>(store: store) { profile, url in ActivationSurface(profile: profile, url: url) }
        owner.openTab()
        other.openTab()
        await owner.waitForPendingCommands()
        await other.waitForPendingCommands()
        let surface = try #require(owner.selectedSurface)
        let before = other.snapshot?.selectedOccurrenceID
        #expect(await other.activateOwnedSurface(surface).value == false)
        #expect(other.snapshot?.selectedOccurrenceID == before)
        owner.close()
        other.close()
        await owner.waitForPendingCommands()
        await other.waitForPendingCommands()
    }
}
