import BrowserCore
import Foundation
import Testing
@testable import BrowserShell

@MainActor
private final class PaletteSessionSurface: BrowserSurface {
    let profileID: ProfileID
    let initialURL: URL
    var currentURL: URL? { initialURL }
    init(profileID: ProfileID, url: URL) { self.profileID = profileID; initialURL = url }
    func dispose() {}
}

@Suite("Palette session operations")
@MainActor
struct BrowserPaletteSessionTests {
    @Test("Palette failures reach the error handler once and release the command queue")
    func reportsFailure() async throws {
        let store = BrowserStore()
        let session = BrowserWindowSession(store: store) { PaletteSessionSurface(profileID: $0, url: $1) }
        var errors: [any Error] = []
        session.onError = { errors.append($0) }
        session.openTab()
        await session.waitForPendingCommands()
        let context = try #require(session.paletteContext)
        #expect(await session.restoreFromPalette(TabID(), from: context).value == false)
        await session.waitForPendingCommands()
        #expect(errors.count == 1)
        #expect(errors.first as? BrowserOrganizationError == .archivedTabMissing)
        #expect(!session.hasPendingCommands)
        session.close()
        await session.waitForPendingCommands()
    }

    @Test("New-tab palette navigation racing a peer archive creates exactly one tab")
    func newTabArchiveRace() async throws {
        for _ in 0..<100 {
            let store = BrowserStore()
            let session = BrowserWindowSession(store: store) { PaletteSessionSurface(profileID: $0, url: $1) }
            var errors: [any Error] = []
            session.onError = { errors.append($0) }
            session.openTab(url: URL(string: "https://kept.race-palette.test/")!)
            session.openTab(url: URL(string: "https://archived.race-palette.test/")!)
            await session.waitForPendingCommands()
            let archived = try #require(session.organization?.selectedTab?.id)
            let context = try #require(session.paletteContext)
            let peer = try await store.createWindow(activeSpaceID: context.spaceID)
            let archive = Task.detached {
                _ = try await store.archiveTabs([archived], from: store.captureContext(in: peer))
            }
            var navigations = 0
            let navigated = await session.navigateFromPalette(from: context, newTab: true) { _ in navigations += 1 }.value
            try await archive.value
            await session.waitForPendingCommands()
            #expect(navigated && navigations == 1 && errors.isEmpty)
            let document = await store.sessionDocument()
            #expect(document.organization.tabs.count == 2)
            #expect(document.organization.tabs.filter { $0.url.absoluteString == "about:blank" }.count == 1)
            try document.validate()
            session.close()
            await session.waitForPendingCommands()
        }
    }

    @Test("An in-flight palette operation adopts peer archive reconciliation and retries before committing once")
    func retriesOrganizationRace() async throws {
        let store = BrowserStore()
        let session = BrowserWindowSession(store: store) { PaletteSessionSurface(profileID: $0, url: $1) }
        var errors: [any Error] = []
        session.onError = { errors.append($0) }
        session.openTab(url: URL(string: "https://kept.palette.test/")!)
        session.openTab(url: URL(string: "https://archived.palette.test/")!)
        await session.waitForPendingCommands()
        let archived = try #require(session.organization?.selectedTab?.id)
        session.closeSelectedTab()
        session.openTab(url: URL(string: "https://peer-archive.palette.test/")!)
        await session.waitForPendingCommands()
        let visible = try #require(session.organization?.selectedTab?.id)
        let context = try #require(session.paletteContext)
        let peer = try await store.createWindow(activeSpaceID: context.spaceID)
        var attempts = 0
        let result = await session.paletteOperation { session, current in
            attempts += 1
            if attempts == 1 {
                let peerContext = try await store.captureContext(in: peer)
                _ = try await store.archiveTabs([visible], from: peerContext)
            }
            let state = try await store.restoreArchivedTab(archived, activate: true, from: current)
            session.install(state)
            return true
        }.value
        #expect(result && attempts == 2)
        #expect(errors.isEmpty)
        #expect(session.organization?.selectedTab?.id == archived)
        let document = await store.sessionDocument()
        #expect(document.tabs.filter { $0.id == archived }.count == 1)
        try document.validate()
        session.close()
        await session.waitForPendingCommands()
    }
}
