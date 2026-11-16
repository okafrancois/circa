import Foundation

/// NAV-INITIATOR. A link that the shell takes out of its tab (Option-click to a split, a Peek, a
/// Shift-click) used to be loaded again by URL in the new surface: a browser-initiated request with
/// no initiator origin, no Referer, `Sec-Fetch-Site: none` and SameSite=Strict cookies attached.
/// An engine that conforms can instead reopen the link from the document that showed it, as a
/// renderer-initiated `noopener` window: the request keeps that document as initiator (Referer
/// policy, `Sec-Fetch-Site`, SameSite cookies) and the engine then asks its delegate
/// `createSurfaceFor` with `modifiers`, so the shell's new-target routes place it.
@MainActor
public protocol BrowserLinkReopening: AnyObject {
    /// Starts reopening `url` from the current main document. False when that is impossible now
    /// (no document context, not a web URL); the caller keeps its own route. After true, `fallback`
    /// runs exactly once if the new-target request does not reach the delegate.
    func reopenLinkFromDocument(_ url: URL, modifiers: BrowserModifierKeys,
                                fallback: @escaping @MainActor () -> Void) -> Bool
}

/// Reopens waiting for the new-target request they cause. The request names the URL as the engine
/// resolved it, so URLs compare without case of scheme and host, default port or empty path.
public struct BrowserLinkReopenLedger: Sendable {
    public struct Entry: Sendable, Equatable {
        public let id: UInt64
        public let url: URL
        public let modifiers: BrowserModifierKeys
        public let disposition: BrowserNavigationDisposition
    }

    /// A reopen is a single user gesture; a few at most can overlap.
    public static let capacity = 4
    private var entries: [Entry] = []
    /// Entries pushed out by newer ones: still owed a fallback when they finish.
    private var overflowed: [UInt64] = []
    private var nextID: UInt64 = 1

    public init() {}

    public var pendingCount: Int { entries.count }

    /// Records a reopen about to start; beyond `capacity` the oldest entry no longer matches a
    /// request and its `finish` reports it as not delivered.
    public mutating func begin(url: URL, modifiers: BrowserModifierKeys,
                               disposition: BrowserNavigationDisposition) -> UInt64 {
        let id = nextID
        nextID &+= 1
        entries.append(Entry(id: id, url: url, modifiers: modifiers, disposition: disposition))
        if entries.count > Self.capacity {
            overflowed += entries.prefix(entries.count - Self.capacity).map(\.id)
            entries.removeFirst(entries.count - Self.capacity)
            if overflowed.count > Self.capacity * 4 { overflowed.removeFirst(overflowed.count - Self.capacity * 4) }
        }
        return id
    }

    /// The reopen that caused a new-target request for `url`, consumed. Nil for any other request.
    public mutating func take(url: String?) -> Entry? {
        guard let url, let target = URL(string: url),
              let index = entries.lastIndex(where: { Self.sameTarget($0.url, target) }) else { return nil }
        return entries.remove(at: index)
    }

    /// Ends the wait for `id`. True when its request never arrived: the caller runs its fallback.
    public mutating func finish(_ id: UInt64) -> Bool {
        if let index = overflowed.firstIndex(of: id) {
            overflowed.remove(at: index)
            return true
        }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    public static func sameTarget(_ lhs: URL, _ rhs: URL) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.host != nil, components.path.isEmpty { components.path = "/" }
        return components.string
    }
}
