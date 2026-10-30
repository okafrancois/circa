import Foundation
import BrowserCore

extension BrowserEnvironment {
    /// Only external URL delivery uses reuse and the device-local domain preference.
    func makeExternalQuickWindow(url: URL, spaceID: SpaceID?, profileID: ProfileID?) async throws -> BrowserQuickWindowWindowController<Engine> {
        _ = try await initialContext.value
        let key = BrowserQuickWindowURL.key(url)
        if let existing = quickWindows.values.first(where: {
            $0.acceptsCommands && ($0.externalURLKey == key || $0.surface?.currentURL.map(BrowserQuickWindowURL.key) == key)
        }) { return existing }
        let catalog = await store.catalogSnapshot()
        let remembered = BrowserQuickWindowURL.domain(url).flatMap { settings.document.quickWindowProfilesByDomain[$0] }
        let available = remembered.flatMap { id in catalog.spaces.contains { $0.profileID == id } ? id : nil }
        let little = try await makeQuickWindow(spaceID: available == nil ? spaceID : nil, url: url,
                                               preferredProfileID: available ?? profileID)
        little.externalURLKey = key
        return little
    }

}
