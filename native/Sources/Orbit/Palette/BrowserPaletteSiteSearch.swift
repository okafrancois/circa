import BrowserCore
import Foundation

typealias BrowserPaletteSiteSearch = BrowserSiteSearch

extension BrowserSiteSearch {
    static var sites: [Self] { builtIns }

    func results(query: String) -> [BrowserPaletteResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = url(for: text) else { return [] }
        return [.init(id: "site-search", title: text, detail: uiFormat("Search %@", uiText(name)),
                      section: .search, action: .navigate(url))]
    }
}
