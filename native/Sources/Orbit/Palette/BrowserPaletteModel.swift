import BrowserCore
import Foundation

/// Result identities include the authority needed for activation, never just a URL.
enum BrowserPaletteAction: Equatable {
    case navigate(URL)
    case tab(TabID, windowID: UUID?, spaceID: SpaceID?)
    case archive(TabID)
    case command(BrowserCommandID)
}

enum BrowserPaletteSection: String, CaseIterable {
    case address = "Go to", tabs = "Switch to Tab", pinned = "Pinned & Favorites"
    case history = "History", commands = "Orbit actions", archive = "Archived Tabs", search = "Search"

    var localizedTitle: String { uiText(rawValue) }
}

struct BrowserPaletteResult: Identifiable, Equatable {
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
    var actionLabel: String {
        if section == .tabs { return uiText("Switch to Tab") }
        switch action {
        case .tab: return uiText("Switch to Tab")
        case .archive: return uiText("Restore Tab")
        case .navigate: return section == .search ? uiText("Search") : uiText("Open")
        case .command: return uiText("Open")
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
    static func results(query: String, mode: BrowserPaletteMode, resolver: AddressResolver,
                        candidates: [BrowserPaletteResult], history: [BrowserHistorySuggestion],
                        actions: [BrowserPaletteResult], limit: Int = 40) -> [BrowserPaletteResult] {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return [] }
        let destination = try? resolver.resolve(input)
        let typed: BrowserPaletteResult?
        switch destination {
        case .page(let url):
            typed = .init(id: "address", title: BrowserSuggestionText.displayURL(url), detail: uiText("Go to URL"), section: .address, action: .navigate(url))
        case .search(let url, let text):
            typed = .init(id: "search", title: text, detail: uiFormat("Search with %@", resolver.searchEngine.displayName), section: .search, action: .navigate(url))
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
            .init(id: "history:\($0.url.absoluteString)", title: $0.title.isEmpty ? BrowserSuggestionText.displayURL($0.url) : $0.title,
                  detail: BrowserSuggestionText.displayURL($0.url), section: .history, action: .navigate($0.url),
                  faviconReference: $0.faviconReference)
        }
        var rows = matches.filter { $0.section == .tabs || $0.section == .pinned }
        rows += historyRows
        let commandRows = actions.enumerated().compactMap { index, result -> (BrowserPaletteResult, Int, Int)? in
            guard result.action != .command(.newTab), result.action != .command(.openCommandBar),
                  let score = commandScore(input, result: result) else { return nil }
            return (result, score, index)
        }.sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }.map(\.0)
        if input.isEmpty {
            let basic = commandRows.filter { $0.action == .command(.newWindow) || $0.action == .command(.newIncognitoWindow) || $0.action == .command(.manageExtensions) || $0.action == .command(.addExtension) }
            rows = basic + rows + commandRows.filter { !basic.contains($0) }
        } else { rows += commandRows }
        rows += matches.filter { $0.section == .archive }
        // The explicit input is always present, including after truncating broad matches.
        if let typed {
            let strong = mode == .newTab && limit > 1 ? rows.firstIndex { isStrongMatch($0, query: input, destination: destination) } : nil
            if let strong { rows.insert(rows.remove(at: strong), at: 0); rows.insert(typed, at: 1) }
            else if case .search = destination, input.count >= 3, limit > 1, let command = commandRows.first,
                    (commandScore(input, result: command) ?? 0) >= 600 {
                rows.removeAll { $0.id == command.id }
                rows.insert(command, at: 0)
                rows.insert(typed, at: 1)
            }
            else { rows.insert(typed, at: 0) }
        }
        if input.isEmpty { return Array(rows.prefix(min(limit, 8))) }
        return Array(rows.prefix(limit))
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

    static func localCandidates(_ snapshot: BrowserOrganizationSnapshot) -> [BrowserPaletteResult] {
        snapshot.allTabs.map {
            .init(id: "tab:\($0.id.rawValue)", title: $0.title ?? BrowserSuggestionText.displayURL($0.url),
                  detail: BrowserSuggestionText.displayURL($0.url), section: $0.isLoadedInThisWindow ? .tabs : .pinned,
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
            let label = tab.windowID == windowID ? (tab.spaceID == spaceID ? uiText("This Space") : uiText("Other Space")) : uiText("Other Window")
            return .init(id: "tab:\(tab.id.rawValue)", title: logical[tab.id]?.resolvedTitle ?? BrowserSuggestionText.displayURL(tab.url),
                         detail: BrowserSuggestionText.displayURL(tab.url) + " · " + label, section: .tabs,
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
                    result.append(.init(id: "tab:\(id.rawValue)", title: tab.resolvedTitle ?? BrowserSuggestionText.displayURL(tab.url),
                                        detail: BrowserSuggestionText.displayURL(tab.url), section: .pinned,
                                        action: .tab(id, windowID: nil, spaceID: space), sourceURL: tab.url))
                }
            }
        }
        for favorites in document.organization.favorites where favorites.profileID == profileID { append(favorites.items, in: nil) }
        for sections in document.organization.spaces where spaces.contains(sections.spaceID) { append(sections.pinned, in: sections.spaceID) }
        result += document.organization.archive.filter { $0.profileID == profileID }.map {
            .init(id: "archive:\($0.id.rawValue)", title: $0.tab.resolvedTitle ?? BrowserSuggestionText.displayURL($0.tab.url),
                  detail: BrowserSuggestionText.displayURL($0.tab.url), section: .archive, action: .archive($0.id), sourceURL: $0.tab.url)
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
        }
    }
}
