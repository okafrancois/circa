import BrowserCore
import Foundation

/// Result identities include the authority needed for activation, never just a URL.
enum BrowserPaletteAction: Equatable, Sendable {
    case ask(BrowserAIModelChoice)
    case navigate(URL)
    case tab(TabID, windowID: UUID?, spaceID: SpaceID?)
    case archive(TabID)
    case command(BrowserCommandID)
}

enum BrowserPaletteSection: String, CaseIterable, Sendable {
    case address = "Go to", tabs = "Switch to Tab", pinned = "Pinned & Favorites"
    case history = "History", commands = "Circa actions", archive = "Archived Tabs", search = "Search"

    var localizedTitle: String { uiText(rawValue) }
}

struct BrowserPaletteResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let section: BrowserPaletteSection
    let action: BrowserPaletteAction
    var searchAliases: String = ""
    var sourceURL: URL? = nil
    var scopePriority: Int = 0
    var faviconReference: URL? = nil
    var shortcut: String = ""
    var remoteSuggestion: String? = nil

    var url: URL? {
        if case .navigate(let url) = action { return url }; return sourceURL
    }
    var symbol: String {
        if case .command(let id) = action { return BrowserDailyCommands.symbol(id) }
        switch section {
        case .address, .tabs, .pinned, .history: return "globe"
        case .commands: return "command"
        case .archive: return "archivebox"
        case .search: return "magnifyingglass"
        }
    }
    var inputSymbol: String { section == .history ? "clock" : symbol }

    var actionLabel: String {
        if section == .tabs { return uiText("Switch to Tab") }
        switch action {
        case .tab: return uiText("Switch to Tab")
        case .archive: return uiText("Restore Tab")
        case .navigate: return section == .search ? uiText("Search") : uiText("Open")
        case .command: return uiText("Open")
        case .ask: return uiText("Ask")
        }
    }
}

enum BrowserPaletteMode { case newTab, currentTab }

struct BrowserPaletteSelection {
    private(set) var index = 0
    mutating func reset() { index = 0 }
    mutating func move(_ delta: Int, count: Int) {
        guard count > 0 else { index = 0; return }
        index = ((index + delta) % count + count) % count
    }
    mutating func select(_ index: Int, count: Int) { self.index = min(max(0, index), max(0, count - 1)) }
}

/// Policy is intentionally local and deterministic; no network requests or remote images.
enum BrowserPaletteRanking {
    static let titleAndHostDeduplicationHosts: Set<String> = [
        "figma.com", "maps.google.com", "notion.so", "app.notion.com", "zoom.us",
        "opentable.com", "zillow.com", "github.com", "app.mode.com", "console.cloud.google.com"
    ]

    private struct TitleAndHost: Hashable {
        let title: String
        let host: String
    }

    private static func titleAndHost(_ result: BrowserPaletteResult) -> TitleAndHost? {
        guard result.section != .commands, result.section != .address, result.section != .search,
              !result.title.isEmpty, let host = result.url?.host?.lowercased(),
              titleAndHostDeduplicationHosts.contains(host) else { return nil }
        return TitleAndHost(title: result.title, host: host)
    }

    static func deduplicatingTitlesAndHosts(_ results: [BrowserPaletteResult]) -> [BrowserPaletteResult] {
        var seen: Set<TitleAndHost> = []
        return results.filter { result in titleAndHost(result).map { seen.insert($0).inserted } ?? true }
    }

    /// Search fields belong to a candidate revision, not to a comparison or keystroke.
    struct PreparedCandidate: Sendable {
        let result: BrowserPaletteResult
        let title: String
        let text: String
        let words: [Substring]
        let canonical: String?
        let host: String
        init(_ result: BrowserPaletteResult) {
            self.result = result
            title = BrowserSuggestionText.fold(result.title)
            text = title + " " + (result.url.map(BrowserSuggestionText.searchableURL) ?? "")
            words = title.split { !$0.isLetter && !$0.isNumber }
            canonical = result.url.map(canonicalURL)
            var value = BrowserSuggestionText.fold(result.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.host } ?? "")
            if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
            host = value
        }
    }

    static func results(query: String, mode: BrowserPaletteMode, resolver: AddressResolver,
                        candidates: [BrowserPaletteResult], history: [BrowserHistorySuggestion],
                        actions: [BrowserPaletteResult], limit: Int = 40, prepared: [PreparedCandidate]? = nil) -> [BrowserPaletteResult] {
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
        let terms = BrowserSuggestionText.terms(matchInput)
        let scoreTerms = BrowserSuggestionText.terms(input)
        let folded = BrowserSuggestionText.fold(input)
        let destinationKey: String?
        if case .page(let url) = destination { destinationKey = canonicalURL(url) } else { destinationKey = nil }
        var hostTerm = folded
        if let range = hostTerm.range(of: "://") { hostTerm = String(hostTerm[range.upperBound...]) }
        if hostTerm.hasPrefix("www.") { hostTerm = String(hostTerm.dropFirst(4)) }
        let fields = prepared ?? candidates.map(PreparedCandidate.init)
        var represented: Set<String> = []
        var decorated: [(result: BrowserPaletteResult, score: Int, offset: Int)] = []
        for (offset, field) in fields.enumerated() where terms.allSatisfy({ field.text.contains($0) }) {
            let result = field.result
            if result.section != .archive, let key = field.canonical { represented.insert(key) }
            let score: Int
            if input.isEmpty { score = 0 }
            else if result.section == .tabs, let destinationKey, field.canonical == destinationKey { score = 3000 }
            else if field.title == folded { score = 2000 }
            else if result.section == .tabs, destinationKey == nil, folded.count >= 3,
                    !folded.contains(where: \.isWhitespace), !hostTerm.isEmpty, field.host.hasPrefix(hostTerm) { score = 1000 }
            else { score = scoreTerms.allSatisfy { term in field.words.contains { $0.hasPrefix(term) } } ? 100 : 0 }
            decorated.append((result, score, offset))
        }
        // Pop only the unique prefix we can display. Deduplication happens while popping, so
        // arbitrarily many duplicate rows can never hide the next distinct candidate.
        func prefix(_ sections: Set<BrowserPaletteSection>, excluding: [BrowserPaletteResult] = []) -> [BrowserPaletteResult] {
            var heap = BrowserRankingHeap(decorated.filter { sections.contains($0.result.section) }) { a, b in
                if a.result.section != b.result.section { return a.result.section == .tabs }
                if a.score != b.score { return a.score > b.score }
                if a.result.scopePriority != b.result.scopePriority { return a.result.scopePriority < b.result.scopePriority }
                return a.offset < b.offset
            }
            var seen = Set(excluding.compactMap(titleAndHost))
            var output: [BrowserPaletteResult] = []
            while output.count < limit, let item = heap.popFirst() {
                if let key = titleAndHost(item.result), !seen.insert(key).inserted { continue }
                output.append(item.result)
            }
            return output
        }
        if case .page(let url) = destination { represented.insert(canonicalURL(url)) }
        let historyRows: [BrowserPaletteResult] = history.filter { represented.insert(canonicalURL($0.url)).inserted }.map {
            .init(id: "history:\($0.url.absoluteString)", title: $0.title.isEmpty ? displayURL($0.url) : $0.title,
                  detail: displayURL($0.url), section: .history, action: .navigate($0.url),
                  faviconReference: $0.faviconReference)
        }
        var rows = prefix([.tabs, .pinned])
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
        rows += prefix([.archive], excluding: rows)
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

    /// Keep local results and the explicit query, adding only distinct remote searches.
    @MainActor
    static func merging(_ remote: [String], into local: [BrowserPaletteResult], engine: SearchEngine) -> [BrowserPaletteResult] {
        var seenURLs = Set(local.compactMap { $0.url.map(canonicalURL) })
        var seenText = Set(local.filter { $0.section != .commands }.map { BrowserSearchSuggestions.identity($0.title) })
        let searches = remote.compactMap { text -> BrowserPaletteResult? in
            let url = engine.searchURL(for: text)
            guard seenText.insert(BrowserSearchSuggestions.identity(text)).inserted,
                  seenURLs.insert(canonicalURL(url)).inserted else { return nil }
            return .init(id: "remote:\(engine.rawValue):\(BrowserSearchSuggestions.identity(text))", title: text,
                         detail: "", section: .search, action: .navigate(url), remoteSuggestion: text)
        }
        let explicit = local.filter { $0.id == "search" }
        return Array((local.filter { $0.id != "search" } + searches).prefix(40 - explicit.count)) + explicit
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

    static func localCandidates(_ snapshot: BrowserOrganizationSnapshot) -> [BrowserPaletteResult] {
        snapshot.allTabs.map {
            .init(id: "tab:\($0.id.rawValue)", title: $0.title ?? displayURL($0.url),
                  detail: displayURL($0.url), section: $0.isLoadedInThisWindow ? .tabs : .pinned,
                  action: .tab($0.id, windowID: nil, spaceID: nil), sourceURL: $0.url)
        }
        // Archived tabs come from the document candidates: ORG-R2 replaced the snapshot's archive
        // copy by `archiveRevision`.
    }

    static func candidates(document: BrowserSessionDocument, profileID: ProfileID, windowID: WindowID,
                           spaceID: SpaceID, windowIDs: [WindowID: UUID]) -> [BrowserPaletteResult] {
        let spaces = Set(document.spaces.filter { $0.profileID == profileID }.map(\.id))
        let logical = Dictionary(uniqueKeysWithValues: document.organization.tabs.map { ($0.id, $0) })
        let open = document.tabs.filter { spaces.contains($0.spaceID) }.sorted {
            let a = $0.windowID == windowID ? ($0.spaceID == spaceID ? 0 : 1) : 2
            let b = $1.windowID == windowID ? ($1.spaceID == spaceID ? 0 : 1) : 2
            return a == b ? $0.occurrenceID.rawValue.uuidString < $1.occurrenceID.rawValue.uuidString : a < b
        }
        var seen: Set<TabID> = []
        var result = open.compactMap { tab -> BrowserPaletteResult? in
            guard windowIDs[tab.windowID] != nil, seen.insert(tab.id).inserted else { return nil }
            return .init(id: "tab:\(tab.id.rawValue)", title: logical[tab.id]?.resolvedTitle ?? displayURL(tab.url),
                         detail: displayURL(tab.url), section: .tabs,
                         action: .tab(tab.id, windowID: windowIDs[tab.windowID], spaceID: tab.spaceID), sourceURL: tab.url,
                         scopePriority: tab.windowID == windowID ? (tab.spaceID == spaceID ? 0 : 1) : 2)
        }
        let splits = Dictionary(uniqueKeysWithValues: document.organization.splits.map { ($0.id, $0) })
        let folders = Dictionary(uniqueKeysWithValues: document.organization.folders.map { ($0.id, $0) })
        func append(_ nodes: [BrowserOrganizationNode], in space: SpaceID?) {
            for node in nodes {
                switch node {
                case .split(let id): append(splits[id]?.tabIDs.map(BrowserOrganizationNode.tab) ?? [], in: space)
                case .folder(let id): append(folders[id]?.children ?? [], in: space)
                case .tab(let id):
                    guard seen.insert(id).inserted, let tab = logical[id] else { continue }
                    result.append(.init(id: "tab:\(id.rawValue)", title: tab.resolvedTitle ?? displayURL(tab.url),
                                        detail: displayURL(tab.url), section: .pinned,
                                        action: .tab(id, windowID: nil, spaceID: space), sourceURL: tab.url))
                }
            }
        }
        for favorites in document.organization.favorites where favorites.profileID == profileID { append(favorites.items, in: nil) }
        for sections in document.organization.spaces where spaces.contains(sections.spaceID) { append(sections.pinned, in: sections.spaceID) }
        result += document.organization.archive.filter { $0.profileID == profileID }.map {
            .init(id: "archive:\($0.id.rawValue)", title: $0.tab.resolvedTitle ?? displayURL($0.tab.url),
                  detail: displayURL($0.tab.url), section: .archive, action: .archive($0.id), sourceURL: $0.tab.url)
        }
        return result
    }
}

/// Display names are separate from persisted search-engine identifiers.
extension SearchEngine {
    var displayName: String {
        switch self {
        case .google: uiText("Google")
        case .duckDuckGo: uiText("DuckDuckGo")
        case .bing: uiText("Bing")
        case .perplexity: uiText("Perplexity")
        }
    }
}

/// Questions offer an explicit AI route while URL resolution remains authoritative.
enum BrowserPaletteQuestion {
    static func matches(_ text: String, resolver: AddressResolver) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        if case .page = try? resolver.resolve(value) { return false }
        return value.hasSuffix("?") || value.range(of: "^(how|what|why|when|where|which|who|can|should|is|are|does|do)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
