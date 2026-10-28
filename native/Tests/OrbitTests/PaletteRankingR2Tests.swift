@testable import BrowserCore
import Foundation
import Testing
@testable import Orbit

struct PaletteRankingR2Tests {
    private func tab(_ title: String, url: String, scope: Int = 0, detail: String = "This Space") -> BrowserPaletteResult {
        .init(id: "tab:\(url)", title: title, detail: detail, section: .tabs, action: .tab(TabID(), windowID: nil, spaceID: nil), sourceURL: URL(string: url)!, scopePriority: scope)
    }

    @Test("Explicit input stays first and present across a broad result cap")
    func inputAndCap() {
        let candidates = (0..<100).map { tab("Example \($0)", url: "https://site\($0).test/") }
        for limit in [1, 2, 40] {
            let rows = BrowserPaletteRanking.results(query: "e", mode: .newTab, resolver: .init(), candidates: candidates, history: [], actions: [], limit: limit)
            #expect(rows.first?.id == "search")
            #expect(rows.filter { $0.id == "search" }.count == 1)
            #expect(rows.count == limit)
        }
    }

    @Test("Exact open URL outranks navigation, strong host prefix outranks arbitrary substring")
    func strongMatches() {
        let other = tab("Article about cats", url: "https://animals.test/cat")
        let exact = tab("Reference", url: "https://www.catalog.test/")
        let rows = BrowserPaletteRanking.results(query: "https://www.catalog.test", mode: .newTab, resolver: .init(), candidates: [other, exact], history: [], actions: [])
        #expect(rows.first?.id == exact.id)
        #expect(rows.contains { $0.id == "address" })
        let prefix = BrowserPaletteRanking.results(query: "cat", mode: .newTab, resolver: .init(), candidates: [other, exact], history: [], actions: [])
        #expect(prefix.first?.id == exact.id)
        let edit = BrowserPaletteRanking.results(query: "cat", mode: .currentTab, resolver: .init(), candidates: [other, exact], history: [], actions: [])
        #expect(edit.first?.id == "search")
    }

    @Test("Scope labels never match and quality sorts tabs before window proximity")
    func labelsAndQuality() {
        let generic = tab("Reference", url: "https://other.test/", detail: "Other Window")
        #expect(BrowserPaletteRanking.results(query: "Other Window", mode: .newTab, resolver: .init(), candidates: [generic], history: [], actions: []).allSatisfy { $0.section != .tabs })
        let exact = tab("Reference guide", url: "https://docs.test/", scope: 2)
        let local = tab("A reference guide appendix", url: "https://local.test/")
        let rows = BrowserPaletteRanking.results(query: "Reference guide", mode: .newTab, resolver: .init(), candidates: [local, exact], history: [], actions: [])
        #expect(rows.first?.id == exact.id)
    }

    @Test("Explicit hosts cannot be hijacked by lookalikes, paths or archived prefix matches")
    func authoritativeDestinations() {
        let lookalike = tab("Repository", url: "https://github.com.evil.example/")
        for query in ["github.com", "https://github.com", "https://github.co"] {
            let rows = BrowserPaletteRanking.results(query: query, mode: .newTab, resolver: .init(), candidates: [lookalike], history: [], actions: [])
            #expect(rows.first?.id == "address")
        }
        let strong = tab("Repository", url: "https://github.com/")
        let capped = BrowserPaletteRanking.results(query: "git", mode: .newTab, resolver: .init(), candidates: [strong], history: [], actions: [], limit: 2)
        #expect(capped.first?.id == strong.id)
        #expect(capped.last?.id == "search")
    }

    @Test("Search destinations do not increment typed intent and palette launcher actions are hidden")
    func intentAndCommands() {
        let search = BrowserPaletteResult(id: "search", title: "Example", detail: "Search", section: .search, action: .navigate(URL(string: "https://www.google.com/search?q=example")!))
        #expect(!BrowserPaletteRanking.recordsTypedVisit(search))
        let copiedSearch = BrowserPaletteResult(id: "history", title: "Example", detail: "", section: .history, action: search.action)
        #expect(!BrowserPaletteRanking.recordsTypedVisit(copiedSearch))
        let command = BrowserPaletteResult(id: "command:newTab", title: "New Tab", detail: "", section: .commands, action: .command(.newTab))
        #expect(BrowserPaletteRanking.results(query: "", mode: .newTab, resolver: .init(), candidates: [], history: [], actions: [command]).isEmpty)
    }

    @Test("Canonical URL deduplication removes history variants and the explicit address duplicate")
    func canonicalHistoryDeduplication() {
        let profile = ProfileID()
        let history = ["https://alpha.test", "https://alpha.test/"].map {
            BrowserHistorySuggestion(profileID: profile, url: URL(string: $0)!, title: "Alpha reference", faviconReference: nil,
                                     visitCount: 2, typedCount: 1, lastVisitedAt: Date(), score: 6)
        }
        let rows = BrowserPaletteRanking.results(query: "alpha", mode: .newTab, resolver: .init(), candidates: [], history: history, actions: [])
        #expect(rows.filter { $0.section == .history }.count == 1)
        let explicit = BrowserPaletteRanking.results(query: "https://alpha.test", mode: .newTab, resolver: .init(), candidates: [], history: history, actions: [])
        #expect(explicit.filter { $0.section == .history }.isEmpty)
        #expect(explicit.first?.id == "address")
    }

    @Test("Bidi controls and invisible newlines are escaped in display without changing navigation URLs")
    func displayControls() {
        let url = URL(string: "https://example.test/%E2%80%AEabc%0A")!
        let display = BrowserSuggestionText.displayURL(url)
        #expect(display.contains("\\u{202E}"))
        #expect(display.contains("\\u{000A}"))
        #expect(!display.contains("\u{202E}"))
        #expect(url.absoluteString.contains("%E2%80%AE"))
    }
}
