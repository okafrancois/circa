import Foundation

/// Aggregated page state as stored in `pages`, with its folded search columns.
public struct BrowserHistoryIndexedPage: Sendable, Equatable {
    public let url: URL
    public let title: String
    public let faviconReference: URL?
    public let lastVisitedAt: Double
    public let visitCount: Int
    public let typedCount: Int
    public let searchURL: String
    public let searchTitle: String

    public init(url: URL, title: String, faviconReference: URL?, lastVisitedAt: Double, visitCount: Int,
                typedCount: Int, searchURL: String, searchTitle: String) {
        self.url = url
        self.title = title
        self.faviconReference = faviconReference
        self.lastVisitedAt = lastVisitedAt
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.searchURL = searchURL
        self.searchTitle = searchTitle
    }

    /// Worth keeping warm: typed at least once, visited repeatedly, or visited recently.
    public func isSignificant(now: Double) -> Bool {
        typedCount >= 1 || visitCount >= BrowserHistoryMemoryIndex.frequentVisits
            || lastVisitedAt >= now - BrowserHistoryMemoryIndex.recentInterval
    }
}

/// Bounded, per-profile in-memory index of significant pages. Immutable snapshots are built off
/// the main actor; the owner applies authoritative page aggregates after each committed write.
/// It holds browsing content only in memory and never logs it.
public struct BrowserHistoryMemoryIndex: Sendable {
    public static let defaultCapacity = 3000
    public static let frequentVisits = 3
    public static let recentInterval: Double = 30 * 86400

    private struct Entry: Sendable {
        var page: BrowserHistoryIndexedPage
        var searchURL: [UInt8]
        var searchTitle: [UInt8]
        var urlBytes: [UInt8]
        init(_ page: BrowserHistoryIndexedPage) {
            self.page = page
            searchURL = Array(page.searchURL.utf8)
            searchTitle = Array(page.searchTitle.utf8)
            urlBytes = Array(page.url.absoluteString.utf8)
        }
    }

    public let profileID: ProfileID
    public let capacity: Int
    private var entries: [Entry] = []
    private var positions: [String: Int] = [:]

    public var count: Int { entries.count }
    /// Upserts may temporarily exceed the capacity; the owner rebuilds to trim.
    public var needsTrim: Bool { entries.count > capacity + capacity / 4 }

    public init(profileID: ProfileID, pages: [BrowserHistoryIndexedPage], capacity: Int = BrowserHistoryMemoryIndex.defaultCapacity) {
        self.profileID = profileID
        self.capacity = capacity
        entries.reserveCapacity(min(pages.count, capacity))
        for page in pages.prefix(capacity) where positions[page.url.absoluteString] == nil {
            positions[page.url.absoluteString] = entries.count
            entries.append(Entry(page))
        }
    }

    public func contains(_ url: URL) -> Bool { positions[url.absoluteString] != nil }

    /// Applies an authoritative aggregate read back after a committed write.
    public mutating func upsert(_ page: BrowserHistoryIndexedPage, now: Double) {
        let key = page.url.absoluteString
        if let position = positions[key] { entries[position] = Entry(page); return }
        guard page.isSignificant(now: now) else { return }
        positions[key] = entries.count
        entries.append(Entry(page))
    }

    /// Same membership, bonus and ordering as `BrowserHistoryStore.suggestions(_:mode: .substring)`,
    /// restricted to the indexed pages.
    public func suggestions(_ query: String, limit: Int = 12, now: Date = Date()) -> [BrowserHistorySuggestion] {
        guard limit > 0 else { return [] }
        let terms = BrowserHistoryMatching.terms(query).filter { !$0.bytes.isEmpty }
        let first = terms.first?.bytes ?? []
        let timestamp = now.timeIntervalSince1970
        var ranked: [(bonus: Int, score: Double, index: Int)] = []
        for (index, entry) in entries.enumerated() {
            let quality: Int? = entry.searchURL.withUnsafeBufferPointer { url in
                entry.searchTitle.withUnsafeBufferPointer { title in
                    guard BrowserHistoryMatching.matches(searchURL: url, searchTitle: title, terms: terms) else { return nil }
                    return BrowserHistoryMatching.bonus(searchURL: url, searchTitle: title, first: first)
                }
            }
            guard let quality else { continue }
            let page = entry.page
            ranked.append((quality, BrowserHistoryMatching.frecency(visits: page.visitCount, typed: page.typedCount,
                                                                    last: page.lastVisitedAt, now: timestamp), index))
        }
        ranked.sort { a, b in
            if a.bonus != b.bonus { return a.bonus > b.bonus }
            if a.score != b.score { return a.score > b.score }
            let left = entries[a.index], right = entries[b.index]
            if left.page.lastVisitedAt != right.page.lastVisitedAt { return left.page.lastVisitedAt > right.page.lastVisitedAt }
            return left.urlBytes.lexicographicallyPrecedes(right.urlBytes)
        }
        return ranked.prefix(min(limit, 1000)).map { item in
            let page = entries[item.index].page
            return BrowserHistorySuggestion(profileID: profileID, url: page.url, title: page.title,
                faviconReference: page.faviconReference, visitCount: page.visitCount, typedCount: page.typedCount,
                lastVisitedAt: Date(timeIntervalSince1970: page.lastVisitedAt), score: item.score)
        }
    }
}
