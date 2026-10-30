import Foundation

/// Page identity for a pin. Queries and path case remain significant; anchors do not.
public enum BrowserPinnedPageIdentity {
    public static func matches(_ original: URL, _ current: URL) -> Bool {
        normalized(original) == normalized(current)
    }

    private static func normalized(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "http" && parts.port == 80) || (parts.scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        parts.fragment = nil
        if parts.host != nil {
            if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
            if parts.percentEncodedPath.count > 1 && parts.percentEncodedPath.hasSuffix("/") { parts.percentEncodedPath.removeLast() }
        }
        return parts.string ?? url.absoluteString
    }
}

/// Redirect-chain state belongs to an occurrence, never to a guessed host equivalence.
struct BrowserPinnedLanding: Equatable, Sendable {
    var pinnedURL: URL
    var url: URL?
    var isResolving = false

    mutating func start(_ destination: URL, isRedirect: Bool) {
        if !isRedirect {
            isResolving = BrowserPinnedPageIdentity.matches(pinnedURL, destination)
                || url.map { BrowserPinnedPageIdentity.matches($0, destination) } == true
        }
    }

    mutating func commit(_ destination: URL) {
        if isResolving { url = destination }
    }
}

extension BrowserStore {
    /// Called only for allowed main-frame navigations, in the same command queue as commits.
    @discardableResult
    public func recordPinnedNavigation(to destination: URL, isRedirect: Bool, committed: Bool,
                                       from authority: BrowserOccurrenceAuthority) throws -> Bool {
        guard authority.storeGeneration == storeGeneration,
              let tab = tabs[authority.occurrenceID], tab.windowID == authority.windowID,
              tab.spaceID == authority.spaceID,
              spaces[tab.spaceID]?.profileID == authority.profileID else { throw BrowserStoreError.staleContext }
        guard let pinned = organization.tabs[tab.id]?.pinnedURL else { return false }
        var landing = pinnedLandings[tab.occurrenceID] ?? BrowserPinnedLanding(pinnedURL: pinned, url: organization.tabs[tab.id]?.pinnedLandingURL)
        if landing.pinnedURL != pinned { landing = BrowserPinnedLanding(pinnedURL: pinned) }
        let previous = landing
        if committed { landing.commit(destination) }
        else { landing.start(destination, isRedirect: isRedirect) }
        pinnedLandings[tab.occurrenceID] = landing
        var persisted = false
        if committed, landing.isResolving, let url = landing.url {
            let alias = BrowserPinnedLandingAlias(pinnedURL: pinned, url: url)
            if organization.tabs[tab.id]?.pinnedLandingAlias != alias {
                try commitOrganization(validating: false) { $0.updateTab(tab.id) { $0.pinnedLandingAlias = alias } }
                persisted = true
            }
        }
        if landing != previous && !persisted { publishOrganizationChange() }
        return landing != previous || persisted
    }
}
