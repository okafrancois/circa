@testable import BrowserCore
import Foundation
import Testing
@testable import Orbit

@Suite("Command Bar ranking equivalence")
struct CommandBarRankingTests {
    @Test("Four thousand recorded queries preserve every item, tie and duplicate at scale")
    func equivalence() {
        let titles = ["Synthetic résumé guide", "東京 guide", "مرحبا document", "Café planning", "Project report", "Release notes", "Maps", "Repository", "100% complete", "Symbols ~ ! ?"]
        let candidates: [BrowserPaletteResult] = (0..<1400).map { index in
            let url = URL(string: index % 7 == 0 ? "https://github.com/project/\(index)" : "https://site\(index % 31).test/article/\(index)")!
            return .init(id: "candidate-\(index)", title: titles[index % titles.count], detail: url.absoluteString,
                         section: index < 1000 ? .archive : (index % 3 == 0 ? .tabs : .pinned),
                         action: index < 1000 ? .archive(TabID()) : .tab(TabID(), windowID: nil, spaceID: nil), sourceURL: url, scopePriority: index % 4)
        }
        let actions: [BrowserPaletteResult] = [BrowserCommandID.newWindow, .newIncognitoWindow, .manageExtensions, .addExtension].map { id in
            .init(id: "command:\(id.rawValue)", title: id.rawValue, detail: "", section: .commands,
                  action: .command(id), searchAliases: id == .newWindow ? "new window|nouvelle fenetre" : id.rawValue)
        }
        let profile = ProfileID()
        let history = (0..<40).map { index in
            BrowserHistorySuggestion(profileID: profile, url: candidates[index * 7].url!, title: candidates[index * 7].title,
                faviconReference: nil, visitCount: index + 1, typedCount: index % 4,
                lastVisitedAt: Date(timeIntervalSince1970: Double(index)), score: Double(40 - index))
        }
        let prepared = candidates.map(BrowserPaletteRanking.PreparedCandidate.init)
        let seeds = ["", "s", "sy", "synthetic", "résumé", "cafe", "東京", "مرحبا", "~", "!", "?", "%", "new wndw", "nouv fen", "https://site1.test", "github.com", "report", "project", "100%", "synthetic guide", "café", "https://www.site1.test/", "new wndw", "nouv fen", "%7E", "[", "\\", "  café  "]
        var oldMS: [Double] = [], newMS: [Double] = []
        for index in 0..<4000 {
            let query = index >= 2000 ? (index % 2 == 0 ? "site\(index % 31).test/article/\(index % 1400)" : "candidate \(index)") : seeds[index % seeds.count] + (index % 3 == 0 ? " \(index % 31)" : "")
            let mode: BrowserPaletteMode = index % 2 == 0 ? .newTab : .currentTab
            let limit = [1, 2, 8, 40][index % 4]
            let start = ProcessInfo.processInfo.systemUptime
            let old = OriginalPaletteRanking.results(query: query, mode: mode, resolver: .init(), candidates: candidates, history: history, actions: actions, limit: limit)
            let middle = ProcessInfo.processInfo.systemUptime
            let new = BrowserPaletteRanking.results(query: query, mode: mode, resolver: .init(), candidates: candidates, history: history, actions: actions, limit: limit, prepared: prepared)
            oldMS.append((middle-start)*1000); newMS.append((ProcessInfo.processInfo.systemUptime-middle)*1000)
            #expect(old == new, "Recorded query \(index)")
        }
        oldMS.sort(); newMS.sort()
        print("CMDBAR_EQ queries=4000 candidates=1400 archive=1000 old_p50=\(oldMS[oldMS.count / 2]) old_p95=\(oldMS[Int(Double(oldMS.count - 1) * 0.95)]) old_max=\(oldMS.last!) new_p50=\(newMS[newMS.count / 2]) new_p95=\(newMS[Int(Double(newMS.count - 1) * 0.95)]) new_max=\(newMS.last!)")
    }
}

/// Frozen pre-optimization policy, used only as a behavioral oracle.
private enum OriginalPaletteRanking {
    static let titleAndHostDeduplicationHosts: Set<String> = [
        "figma.com", "maps.google.com", "notion.so", "app.notion.com", "zoom.us",
        "opentable.com", "zillow.com", "github.com", "app.mode.com", "console.cloud.google.com"
    ]

    private struct TitleAndHost: Hashable {
        let title: String
        let host: String
    }

    static func deduplicatingTitlesAndHosts(_ results: [BrowserPaletteResult]) -> [BrowserPaletteResult] {
        var seen: Set<TitleAndHost> = []
        return results.filter { result in
            guard result.section != .commands, result.section != .address, result.section != .search,
                  !result.title.isEmpty, let host = result.url?.host?.lowercased(),
                  titleAndHostDeduplicationHosts.contains(host) else { return true }
            return seen.insert(TitleAndHost(title: result.title, host: host)).inserted
        }
    }

    static func results(query: String, mode: BrowserPaletteMode, resolver: AddressResolver,
                        candidates: [BrowserPaletteResult], history: [BrowserHistorySuggestion],
                        actions: [BrowserPaletteResult], limit: Int = 40) -> [BrowserPaletteResult] {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return [] }
        let destination = try? resolver.resolve(input)
        let typed: BrowserPaletteResult?
        switch destination {
        case .page(let url):
            typed = .init(id: "address", title: displayURL(url), detail: uiText("Go to URL"), section: .address, action: .navigate(url))
        case .search(let url, let text):
            typed = .init(id: "search", title: text, detail: "", section: .search, action: .navigate(url))
        case nil: typed = nil
        }
        let matchInput = input.replacingOccurrences(of: "^https?://(www\\.)?|^www\\.", with: "", options: .regularExpression)
        let matches = candidates.enumerated().filter { _, result in
            BrowserSuggestionText.matches(matchInput, title: result.title, url: result.url)
        }.sorted { a, b in
            let left = matchScore(a.element, query: input, destination: destination)
            let right = matchScore(b.element, query: input, destination: destination)
            if a.element.section != b.element.section {
                return a.element.section == .tabs || (a.element.section == .pinned && b.element.section == .archive)
            }
            if left != right { return left > right }
            if a.element.scopePriority != b.element.scopePriority { return a.element.scopePriority < b.element.scopePriority }
            return a.offset < b.offset
        }.map(\.element)
        var represented = Set(matches.filter { $0.section != .archive }.compactMap { $0.url.map(canonicalURL) })
        if case .page(let url) = destination { represented.insert(canonicalURL(url)) }
        let historyRows: [BrowserPaletteResult] = history.filter { represented.insert(canonicalURL($0.url)).inserted }.map {
            .init(id: "history:\($0.url.absoluteString)", title: $0.title.isEmpty ? displayURL($0.url) : $0.title,
                  detail: displayURL($0.url), section: .history, action: .navigate($0.url),
                  faviconReference: $0.faviconReference)
        }
        var rows = matches.filter { $0.section == .tabs || $0.section == .pinned }
        rows += historyRows
        let hasPageMatches = !rows.isEmpty
        let isSingleTerm = BrowserSuggestionText.terms(input).count == 1
        let commandRows = actions.enumerated().compactMap { index, result -> (BrowserPaletteResult, Int, Int)? in
            guard result.action != .command(.newTab), result.action != .command(.openCommandBar),
                  let score = commandScore(input, result: result) else { return nil }
            // Short generic aliases such as "get extensions" cannot displace matching pages.
            if hasPageMatches, !input.isEmpty, isSingleTerm, score < 1000 { return nil }
            return (result, score, index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }.map(\.0)
        if input.isEmpty {
            let basic = commandRows.filter { $0.action == .command(.newWindow) || $0.action == .command(.newIncognitoWindow) || $0.action == .command(.manageExtensions) || $0.action == .command(.addExtension) }
            rows = basic + rows + commandRows.filter { !basic.contains($0) }
        } else { rows += commandRows }
        rows += matches.filter { $0.section == .archive }
        rows = deduplicatingTitlesAndHosts(rows)
        // URL input remains authoritative (an exact open URL may switch to its live tab).
        // Text matches autocomplete first; the explicit web search is always the last row.
        if let typed {
            if case .page = destination {
                if mode == .newTab, limit > 1,
                   let exact = rows.firstIndex(where: { isStrongMatch($0, query: input, destination: destination) }) {
                    rows.insert(rows.remove(at: exact), at: 0)
                    rows.insert(typed, at: 1)
                } else { rows.insert(typed, at: 0) }
                return Array(rows.prefix(limit))
            }
            if !hasPageMatches, input.count >= 3, let command = commandRows.first,
               (commandScore(input, result: command) ?? 0) >= 600 {
                rows.removeAll { $0.id == command.id }
                rows.insert(command, at: 0)
            }
            if rows.isEmpty { return [typed] }
            if limit == 1 { return Array(rows.prefix(1)) }
            return Array(rows.prefix(limit - 1)) + [typed]
        }
        return Array(rows.prefix(input.isEmpty ? min(limit, 8) : limit))
    }

    /// Palette-only presentation: keep the navigation URL and search index unchanged.
    static func displayURL(_ url: URL) -> String {
        let text = BrowserSuggestionText.displayURL(url)
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let range = text.range(of: "://") else { return text }
        var value = String(text[range.upperBound...])
        if value.hasPrefix("www.") { value.removeFirst(4) }
        if url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
           value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Match each localized phrase separately: unrelated aliases must not manufacture a match.
    /// Word prefixes and ordered subsequences allow "nouv fen" and "new wndw" without networking.
    static func commandScore(_ query: String, result: BrowserPaletteResult) -> Int? {
        let input = BrowserSuggestionText.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return 0 }
        let terms = BrowserSuggestionText.terms(input)
        guard !terms.isEmpty else { return nil }
        let phrases = [result.title] + result.searchAliases.components(separatedBy: "|")
        return phrases.compactMap { phrase -> Int? in
            let text = BrowserSuggestionText.fold(phrase)
            if text == input { return 1000 }
            if text.hasPrefix(input) { return 850 }
            let words = BrowserSuggestionText.terms(text)
            var cursor = words.startIndex
            var score = 750 - max(0, words.count - terms.count) * 8
            for term in terms {
                guard let index = words[cursor...].firstIndex(where: { word in
                    if word.hasPrefix(term) { return true }
                    guard term.count >= 3, term.first == word.first else { return false }
                    var remaining = term.makeIterator()
                    var next = remaining.next()
                    for character in word where character == next { next = remaining.next() }
                    return next == nil
                }) else { return nil }
                if terms.count == 1 && index != 0 { score = min(score, 500) }
                if !words[index].hasPrefix(term) { score -= 100 }
                cursor = words.index(after: index)
            }
            return score
        }.max()
    }

    /// Keep significant cached pages when a capped short SQL query returns a different slice.
    static func rankedHistory(_ suggestions: [BrowserHistorySuggestion], query: String, limit: Int = 12) -> [BrowserHistorySuggestion] {
        let first = BrowserHistoryMatching.terms(query).first?.bytes ?? []
        var seen: Set<String> = []
        let ranked = suggestions.map { item -> (BrowserHistorySuggestion, Int) in
            let url = Array(BrowserSuggestionText.searchableURL(item.url).utf8)
            let title = Array(BrowserSuggestionText.fold(item.title).utf8)
            let quality = url.withUnsafeBufferPointer { url in
                title.withUnsafeBufferPointer { BrowserHistoryMatching.bonus(searchURL: url, searchTitle: $0, first: first) }
            }
            return (item, quality)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.score != $1.0.score { return $0.0.score > $1.0.score }
            if $0.0.lastVisitedAt != $1.0.lastVisitedAt { return $0.0.lastVisitedAt > $1.0.lastVisitedAt }
            return $0.0.url.absoluteString < $1.0.url.absoluteString
        }
        return Array(ranked.compactMap { item, _ in seen.insert(canonicalURL(item.url)).inserted ? item : nil }.prefix(limit))
    }

    static func recordsTypedVisit(_ result: BrowserPaletteResult) -> Bool {
        guard result.section != .search, let url = result.url else { return false }
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.contains(where: { $0.name == "q" }),
           (host == "duckduckgo.com" || (host == "google.com" || host == "bing.com") && url.path == "/search") { return false }
        return true
    }

    static func canonicalURL(_ url: URL) -> String {
        // Exact URLs retain path/query/fragment distinctions; a default empty path equals '/'.
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if parts?.path.isEmpty == true { parts?.path = "/" }
        return parts?.url?.absoluteString ?? url.absoluteString
    }

    static func isStrongMatch(_ result: BrowserPaletteResult, query: String, destination: AddressDestination?) -> Bool {
        let text = BrowserSuggestionText.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return false }
        guard result.section == .tabs else { return false }
        if case .page(let url) = destination {
            // A typed destination is authoritative. Prefixes must never reinterpret a complete
            // host or an explicit URL as a lookalike host with a longer suffix.
            return result.url.map(canonicalURL) == canonicalURL(url)
        }
        if BrowserSuggestionText.fold(result.title) == text { return true }
        guard text.count >= 3, !text.contains(where: \.isWhitespace), let url = result.url else { return false }
        var host = BrowserSuggestionText.fold(URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? "")
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        var term = text
        if let range = term.range(of: "://") { term = String(term[range.upperBound...]) }
        if term.hasPrefix("www.") { term = String(term.dropFirst(4)) }
        return !term.isEmpty && host.hasPrefix(term)
    }

    private static func matchScore(_ result: BrowserPaletteResult, query: String, destination: AddressDestination?) -> Int {
        guard !query.isEmpty else { return 0 }
        if result.section == .tabs, case .page(let url) = destination, result.url.map(canonicalURL) == canonicalURL(url) { return 3000 }
        if BrowserSuggestionText.fold(result.title) == BrowserSuggestionText.fold(query) { return 2000 }
        if isStrongMatch(result, query: query, destination: destination) { return 1000 }
        let words = BrowserSuggestionText.fold(result.title).split { !$0.isLetter && !$0.isNumber }
        return BrowserSuggestionText.terms(query).allSatisfy { term in words.contains { $0.hasPrefix(term) } } ? 100 : 0
    }

}
