import BrowserCore
import Foundation

/// In-memory LRU of remote suggestion responses, so erasing and retyping a draft shows the
/// provider's answer at once instead of waiting for the debounce and another round trip.
/// Entries are keyed by provider, profile and query, expire after `lifetime`, and are never
/// written to disk. Private windows never fetch suggestions, so they never reach this cache.
@MainActor
final class BrowserSearchSuggestionCache {
    struct Key: Hashable {
        let engine: SearchEngine
        let profileID: ProfileID
        let query: String
    }

    static let shared = BrowserSearchSuggestionCache()

    let capacity: Int
    let lifetime: TimeInterval
    var clock: () -> TimeInterval
    private var entries: [Key: (values: [String], stored: TimeInterval)] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    init(capacity: Int = 50, lifetime: TimeInterval = 60,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = max(0, capacity)
        self.lifetime = lifetime
        self.clock = clock
    }

    var count: Int { entries.count }

    func values(for key: Key) -> [String]? {
        guard let entry = entries[key] else { return nil }
        guard clock() - entry.stored < lifetime else { remove(key); return nil }
        touch(key)
        return entry.values
    }

    func store(_ values: [String], for key: Key) {
        guard capacity > 0 else { return }
        entries[key] = (values, clock())
        touch(key)
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }

    func removeAll() { entries = [:]; order = [] }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func remove(_ key: Key) {
        entries[key] = nil
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
    }
}
