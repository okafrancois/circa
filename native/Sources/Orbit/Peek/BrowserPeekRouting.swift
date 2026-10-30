import BrowserCore
import BrowserEngine
import Foundation

/// Where the link that may open a Peek comes from, as the sidebar model (ORG-MODEL) classifies
/// its tab; `.unclassified` when the tab is unknown to the model.
enum BrowserPeekSourceRole: Sendable, Equatable {
    case favorite
    case pinned
    /// A Today (unpinned) tab.
    case unpinned
    /// No organization model available: automatic Peek never applies.
    case unclassified
}

struct BrowserPeekSettings: Sendable, Equatable {
    var opensPinnedLinksInPeek = true
    /// Shift-click opens Peek. Official notes 2023-07-06: on by default, can be turned off.
    var shiftClickOpensPeek = true
}

/// How an engine reports the link.
enum BrowserPeekRequestKind: Sendable, Equatable {
    /// An engine-created target (`target=_blank`, `window.open`, Chromium modified clicks): the
    /// engine surface keeps its opener and original request.
    case newTarget
    /// A navigation of the source document itself (WebKit modified clicks, plain link clicks).
    /// Routing it means cancelling it in the tab and loading the address in a new Peek surface,
    /// so only link activations made by the user qualify.
    case navigation
}

/// Everything the routing rule reads. No browsing content is retained.
struct BrowserPeekLinkRequest: Sendable, Equatable {
    var kind: BrowserPeekRequestKind
    var sourceRole: BrowserPeekSourceRole
    /// The source document's committed address.
    var sourceURL: URL?
    /// For Pinned tabs and Favorites, their saved home address.
    var sourceHomeURL: URL?
    var destinationURL: URL?
    var modifiers: BrowserModifierKeys
    var buttonNumber: Int
    /// Nil when the engine cannot tell.
    var isMainFrame: Bool?
    /// The engine proved a link activated by the user (not a form, redirect, history move or
    /// script). Unknown counts as false.
    var isUserLinkActivation = false
    /// The request is a GET without body, so a navigation can be cancelled in the tab and loaded in
    /// a Peek without losing method, body or state. Irrelevant for new targets, which the engine
    /// hands over with their original request.
    var isReplayableRequest = false
}

enum BrowserPeekTrigger: Sendable, Equatable {
    /// Shift-click, from any tab, including same-site links.
    case shiftClick
    /// A plain link leaving the site of a Pinned tab or Favorite.
    case pinnedSourceLeavingSite
    case command
}

enum BrowserPeekRoutingDecision: Sendable, Equatable {
    case peek(BrowserPeekTrigger)
    /// The window keeps its default behaviour (tab, background tab, Little Circa, in place).
    case decline
}

enum BrowserPeekRouting {
    static func decide(_ request: BrowserPeekLinkRequest, settings: BrowserPeekSettings) -> BrowserPeekRoutingDecision {
        guard let destination = request.destinationURL, isWebURL(destination), destination.user == nil,
              destination.password == nil, request.isMainFrame != false, request.buttonNumber == 0 else { return .decline }
        // Exclusions apply to every trigger, Shift-click included.
        if isMeetingLink(destination) || isAuthenticationFlow(destination) { return .decline }
        // Only a link the user activated opens a Peek: never a scripted popup, a form, a redirect
        // or a history move. A navigation is moreover cancelled in the tab and loaded again in the
        // Peek, which only a GET without body survives.
        guard request.isUserLinkActivation else { return .decline }
        if request.kind == .navigation, !request.isReplayableRequest { return .decline }
        let modifiers = request.modifiers
        if modifiers == [.shift] {
            return settings.shiftClickOpensPeek ? .peek(.shiftClick) : .decline
        }
        // ⌘ (background tab), ⌥⌘ (Little Circa), ⌃ and ⇧⌘ keep their own meaning.
        guard modifiers.isEmpty, settings.opensPinnedLinksInPeek else { return .decline }
        guard request.sourceRole == .pinned || request.sourceRole == .favorite else { return .decline }
        guard let source = request.sourceURL, let sourceSite = site(of: source),
              let destinationSite = site(of: destination), sourceSite != destinationSite else { return .decline }
        if let home = request.sourceHomeURL, site(of: home) != sourceSite { return .decline }
        return .peek(.pinnedSourceLeavingSite)
    }

    static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }

    /// The registrable domain from the Public Suffix List, private section included
    /// (`alice.github.io` ≠ `bob.github.io`); IP addresses, single-label hosts and hosts that are
    /// public suffixes compare as whole hosts.
    static func site(of url: URL) -> String? {
        BrowserPublicSuffixList.shared.site(of: url)
    }

    static func isMeetingLink(_ url: URL) -> Bool {
        BrowserMeetingLink.matches(url)
    }

    static func isAuthenticationFlow(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let firstLabel = host.split(separator: ".").first.map(String.init) ?? ""
        if ["auth", "accounts", "login", "signin", "identity", "sso", "oauth"].contains(firstLabel) { return true }
        let path = url.path.lowercased()
        if ["/oauth", "/o/oauth2", "/saml", "/sso", "/login/oauth"].contains(where: { path.hasPrefix($0) }) { return true }
        let query = url.query?.lowercased() ?? ""
        return query.contains("client_id=") && query.contains("redirect_uri=")
    }
}
