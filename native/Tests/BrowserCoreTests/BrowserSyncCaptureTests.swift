import Foundation
import Testing
@testable import BrowserCore

struct BrowserSyncCaptureTests {
    private func legacy(_ projection: BrowserSyncProjection, baseline: [String: [String: Data]]) throws -> BrowserSyncProjection {
        var entries = projection.entries
        for (parent, ids) in projection.lists {
            var previous: BrowserSyncOrder?
            for (index, id) in ids.enumerated() {
                let old = try baseline[id]?["placement"].map { try JSONDecoder().decode(BrowserSyncPlacement.self, from: $0) }
                let next = try ids.dropFirst(index + 1).compactMap { nextID -> BrowserSyncOrder? in
                    guard let bytes = baseline[nextID]?["placement"] else { return nil }
                    let placement = try JSONDecoder().decode(BrowserSyncPlacement.self, from: bytes)
                    return placement.parent == parent && (previous.map { $0 < placement.order } ?? true) ? placement.order : nil
                }.first
                let order: BrowserSyncOrder
                if let old, old.parent == parent, previous.map({ $0 < old.order }) ?? true {
                    order = old.order
                } else { order = .between(previous, next) }
                let placement = BrowserSyncPlacement(parent: parent, root: projection.roots[id] ?? parent, order: order)
                entries[id, default: [:]]["placement"] = try BrowserSyncReplica.encodeValue(placement)
                previous = order
            }
        }
        var result = projection
        result.entries = entries
        result.lists = [:]
        return result
    }

    private struct Random: RandomNumberGenerator {
        var state: UInt64 = 42
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test("Capture preserves exact placement bytes and records across randomized concurrent edits")
    func equivalence() throws {
        var random = Random()
        var replica = BrowserSyncReplica(device: "local")
        for round in 0..<100 {
            var projection = BrowserSyncProjection()
            for id in (0..<80).map(String.init).shuffled(using: &random) {
                if random.next() % 5 == 0 { continue }
                let parent = "parent-\(random.next() % 4)"
                projection.entries[id] = ["title": Data("\(round % 3)".utf8)]
                projection.lists[parent, default: []].append(id)
                projection.roots[id] = "root"
            }
            if round % 3 == 0 {
                var peer = replica
                try peer.capture(projection, now: Date(timeIntervalSince1970: Double(round + 100)))
                var records = Array(peer.records.values)
                for index in records.indices {
                    records[index].life = .init(time: records[index].life.time, device: "peer")
                    records[index].fields = records[index].fields.mapValues {
                        .init(value: $0.value, stamp: .init(time: $0.stamp.time, device: "peer"))
                    }
                }
                try replica.merge(records)
                if round % 2 == 0 { try replica.acknowledge(projection) }
            }
            var expected = replica
            let now = Date(timeIntervalSince1970: Double(round + 200))
            try expected.capture(legacy(projection, baseline: replica.baseline), now: now)
            try replica.capture(projection, now: now)
            #expect(replica.baseline == expected.baseline)
            #expect(replica.records == expected.records)
        }
    }

    @Test("Unchanged capture timing at representative sibling counts")
    func timing() throws {
        for count in [62, 200, 1000] {
            var projection = BrowserSyncProjection()
            let ids = (0..<count).map(String.init)
            projection.lists["root"] = ids
            for id in ids { projection.entries[id] = [:] }
            var replica = BrowserSyncReplica(device: "benchmark")
            try replica.capture(projection)
            let start = ContinuousClock.now
            try replica.capture(projection)
            let elapsed = start.duration(to: .now)
            print("capture siblings=\(count) elapsed=\(elapsed)")
            #expect(elapsed < .seconds(2))
        }
    }
}
