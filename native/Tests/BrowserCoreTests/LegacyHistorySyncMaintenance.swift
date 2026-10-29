import Foundation
import SQLite3
@testable import BrowserCore

extension BrowserHistoryStore {
    func legacyHistorySyncBatches(now: Date = Date()) throws -> [BrowserHistorySyncBatch] {
        guard let database else { return [] }
        return try database.transaction {
            let previous = try syncCutoff()
            let cutoff = max(previous, BrowserHistorySyncSchema.cutoff(now))
            try legacyAdvanceSyncCutoff(cutoff)
            let rows = try database.prepare("SELECT payload FROM historySyncEvents WHERE batch IS NULL ORDER BY rowid LIMIT 5000")
            var events: [BrowserHistorySyncEvent] = []
            do {
                defer { sqlite3_finalize(rows) }
                while try database.next(rows) {
                    events.append(try JSONDecoder().decode(BrowserHistorySyncEvent.self, from: Data(database.text(rows, 0).utf8)))
                }
            }
            var batches = try BrowserHistorySyncBatch.pack(profileID: profileID, cutoff: cutoff, events: events)
            if batches.isEmpty && cutoff > previous {
                batches = [BrowserHistorySyncBatch(profileID: profileID, cutoff: cutoff, events: [])]
            }
            for batch in batches {
                try legacySaveSyncBatch(batch)
                for event in batch.events {
                    try database.execute("UPDATE historySyncEvents SET batch=? WHERE id=?", [.text(batch.id.uuidString), .text(event.id.uuidString)])
                }
            }
            // Do not let an oversized row permanently starve later visits in the journal.
            let packed = Set(batches.flatMap(\.events).map(\.id))
            for event in events where !packed.contains(event.id) {
                try database.execute("UPDATE historySyncEvents SET batch='local' WHERE id=?", [.text(event.id.uuidString)])
            }
            let saved = try database.prepare("SELECT payload FROM historySyncBatches")
            defer { sqlite3_finalize(saved) }
            var result: [BrowserHistorySyncBatch] = []
            while try database.next(saved) {
                result.append(try JSONDecoder().decode(BrowserHistorySyncBatch.self, from: Data(database.text(saved, 0).utf8)))
            }
            return result
        }
    }

    private func legacySaveSyncBatch(_ batch: BrowserHistorySyncBatch) throws {
        try batch.validate()
        try database?.execute("INSERT OR IGNORE INTO historySyncBatches VALUES(?,?,?)",
            [.text(batch.id.uuidString), .text(String(decoding: try batch.encoded(), as: UTF8.self)), .number(batch.expires.timeIntervalSince1970)])
    }

    private func legacyAdvanceSyncCutoff(_ cutoff: Date) throws {
        guard let database else { return }
        try database.execute("UPDATE historySyncState SET cutoff=MAX(cutoff,?)", [.number(cutoff.timeIntervalSince1970)])
        _ = try deleteRows(clause: "time<?", values: [.number(cutoff.timeIntervalSince1970)])
        try database.execute("DELETE FROM historySyncEvents WHERE expires<?", [.number(cutoff.timeIntervalSince1970)])
        try database.execute("DELETE FROM historySyncBatches WHERE expires<?", [.number(cutoff.timeIntervalSince1970)])
        try database.execute("DELETE FROM historySyncVersions WHERE id NOT IN (SELECT id FROM visits)")
    }

}
