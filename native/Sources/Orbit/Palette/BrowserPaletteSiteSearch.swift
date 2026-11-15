import BrowserCore
import Foundation

typealias BrowserPaletteSiteSearch = BrowserSiteSearch

extension BrowserSiteSearch {
    static var sites: [Self] { builtIns }

    func results(query: String) -> [BrowserPaletteResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = url(for: text) else { return [] }
        return results(query: text, destination: url)
    }

    func results(query: String, destination: URL) -> [BrowserPaletteResult] {
        [.init(id: "site-search", title: query.isEmpty ? uiText(name) : query, detail: uiFormat("Search %@", uiText(name)),
                      section: .search, action: .navigate(destination))]
    }
}
