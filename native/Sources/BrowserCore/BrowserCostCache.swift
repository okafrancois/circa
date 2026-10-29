/// Owner-isolated LRU storage. Costs include payload and keys; oversized values are never
/// admitted. Callers may retain displayed values independently of the disposable working set.
public struct BrowserCostCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let cost: Int
        var access: UInt64
    }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public let budget: Int
    public let countLimit: Int
    public private(set) var cost = 0
    public var count: Int { entries.count }
    public var keys: [Key] { Array(entries.keys) }
    public var values: [Value] { entries.values.map(\.value) }

    public init(budget: Int, countLimit: Int = 4096) {
        self.budget = max(0, budget)
        self.countLimit = max(0, countLimit)
    }

    public func peekValue(for key: Key) -> Value? { entries[key]?.value }

    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        return entry.value
    }

    public mutating func insert(_ value: Value, for key: Key, cost requestedCost: Int) {
        remove(key)
        let requestedCost = max(1, requestedCost)
        guard requestedCost <= budget, countLimit > 0 else { return }
        while cost > budget - requestedCost || entries.count >= countLimit {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
        clock &+= 1
        entries[key] = Entry(value: value, cost: requestedCost, access: clock)
        cost += requestedCost
    }

    public mutating func remove(_ key: Key) {
        if let entry = entries.removeValue(forKey: key) { cost -= entry.cost }
    }

    public mutating func removeAll() {
        entries.removeAll()
        cost = 0
    }
}

