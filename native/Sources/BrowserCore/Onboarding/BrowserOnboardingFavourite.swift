import Foundation

public struct BrowserOnboardingFavourite: Codable, Equatable, Sendable {
    public var title: String
    public var url: URL
    public var visits: Int?
    public var selected: Bool

    public init(title: String, url: URL, visits: Int? = nil, selected: Bool = false) {
        self.title = title; self.url = url; self.visits = visits; self.selected = selected
    }

    public static var starter: [Self] {
        let sites = [("Gmail", "https://gmail.com"), ("Google Calendar", "https://calendar.google.com"),
                     ("YouTube", "https://youtube.com"), ("Notion", "https://notion.so"),
                     ("GitHub", "https://github.com"), ("Figma", "https://figma.com"),
                     ("X", "https://x.com"), ("Wikipedia", "https://wikipedia.org")]
        return sites.enumerated().map { .init(title: $0.element.0, url: URL(string: $0.element.1)!, selected: $0.offset < 3) }
    }

    /// A site appears once, ordered by total visits. Credentials and non-web URLs never qualify.
    public static func mostVisited(_ visits: [BrowserHistoryVisit]) -> [Self] {
        var sites: [String: (String, URL, Int)] = [:]
        for visit in visits {
            guard ["http", "https"].contains(visit.url.scheme?.lowercased() ?? ""),
                  let host = visit.url.host, visit.url.user == nil, visit.url.password == nil,
                  let root = URL(string: "https://" + host) else { continue }
            let old = sites[host]
            sites[host] = (old?.0 ?? (visit.title.isEmpty ? host : visit.title), root, (old?.2 ?? 0) + 1)
        }
        return sites.values.sorted { $0.2 == $1.2 ? $0.1.absoluteString < $1.1.absoluteString : $0.2 > $1.2 }
            .prefix(8).enumerated().map { .init(title: $0.element.0, url: $0.element.1, visits: $0.element.2, selected: $0.offset < 6) }
    }
}

extension BrowserStore {
    /// Favorites belong to a profile and are consequently visible in all its Spaces.
    public func addOnboardingFavourites(_ sites: [BrowserOnboardingFavourite]) throws {
        for profile in profileOrder {
            guard let space = spaceOrder.first(where: { spaces[$0]?.profileID == profile }) else { continue }
            let window = try createWindow(activeSpaceID: space)
            var context = try captureContext(in: window)
            for site in sites where site.selected {
                if (organization.favorites[profile] ?? []).contains(where: {
                    if case let .tab(id) = $0 { return organization.tabs[id]?.url.host == site.url.host }; return false
                }) { continue }
                context = try captureContext(in: window)
                let occurrence = try openTab(url: site.url, from: context, activate: false)
                if let id = tabs[occurrence]?.id {
                    _ = try addToFavorites([id], from: captureContext(in: window))
                    _ = try renameTab(id, to: site.title, from: captureContext(in: window))
                }
            }
            try closeWindow(window)
        }
    }
}
