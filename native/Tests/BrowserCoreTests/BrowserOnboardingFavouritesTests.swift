import Foundation
import Testing
@testable import BrowserCore

struct BrowserOnboardingFavouritesTests {
    @Test("Starter choices have eight unique sites and the first three are checked")
    func starter() {
        let sites = BrowserOnboardingFavourite.starter
        #expect(sites.count == 8 && sites.filter(\.selected).count == 3)
        #expect(sites.prefix(3).allSatisfy { $0.selected })
        #expect(Set(sites.map(\.url)).count == 8)
    }

    @Test("Imported sites are ranked by visits, grouped by host and first six are checked")
    func ranked() {
        let visits = (1...9).flatMap { n in
            (0..<n).map { i in BrowserHistoryVisit(url: URL(string: "https://site\(n).example/page\(i)")!, title: "Site \(n)") }
        } + [BrowserHistoryVisit(url: URL(string: "https://user:password@private.example")!), BrowserHistoryVisit(url: URL(string: "file:///tmp/private")!)]
        let sites = BrowserOnboardingFavourite.mostVisited(visits)
        #expect(sites.count == 8 && sites.filter(\.selected).count == 6)
        #expect(sites.map(\.visits) == [9, 8, 7, 6, 5, 4, 3, 2])
        #expect(sites.first?.url.host == "site9.example")
    }

    @Test("Selected favourites are shared by every Space of every profile and replay is idempotent")
    func pinning() async throws {
        let store = BrowserStore()
        for n in 0..<2 {
            let profile = await store.createProfile(name: "Profile \(n)")
            for s in 0..<2 { _ = try await store.createSpace(name: "Space \(s)", profileID: profile) }
        }
        let sites = BrowserOnboardingFavourite.starter
        try await store.addOnboardingFavourites(sites)
        try await store.addOnboardingFavourites(sites)
        let document = await store.sessionDocument()
        #expect(document.organization.favorites.count == 2)
        #expect(document.organization.favorites.allSatisfy { $0.items.count == 3 })
        #expect(document.windows.isEmpty)
        try document.validate()
        for space in await store.catalogSnapshot().spaces {
            let window = try await store.createWindow(activeSpaceID: space.id)
            let snapshot = try await store.organizationSnapshot(from: store.captureContext(in: window))
            #expect(snapshot.favorites.count == 3)
            try await store.closeWindow(window)
        }
    }
}
