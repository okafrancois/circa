import BrowserCore
import Foundation

/// Retained until a destination confirms delivery. Retries keep the captured account and mode.
@MainActor
final class BrowserQuickWindowOpenRequest {
    let id = UUID()
    let url: URL?
    let opensInQuickWindow: Bool
    var spaceID: SpaceID?
    var profileID: ProfileID?
    var isRouting = true
    var hasRoutingDestination = false

    init(url: URL?, spaceID: SpaceID? = nil, profileID: ProfileID? = nil, opensInQuickWindow: Bool = true) {
        self.url = url
        self.spaceID = spaceID
        self.profileID = profileID
        self.opensInQuickWindow = opensInQuickWindow
    }
}
