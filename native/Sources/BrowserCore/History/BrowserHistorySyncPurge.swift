import Foundation
import SQLite3

/// Deleted history leaves no URL or title in the sync journal. Journal rows of deleted visits go,
/// and so does every saved batch that carried one of them: such a batch is recorded in
/// `historySyncRetired` (a local retraction notice that the transport turns into a remote delete)
/// and the surviving rows it held are queued again, so the next packing republishes them in new
/// batches. Tombstones stay: they hold no URL, title or plain host.
extension HistoryDatabase {
    /// `table` is a temporary table whose `id` column lists deleted visit identities.
    func purgeSyncJournal(deletedVisits table: String) throws {
        try execute("CREATE TEMP TABLE purgedBatches AS SELECT DISTINCT batch AS id FROM historySyncBatchVisits WHERE visit IN (SELECT id FROM \(table))")
        defer { try? execute("DROP TABLE purgedBatches") }
        try execute("DELETE FROM historySyncEvents WHERE visit IN (SELECT id FROM \(table))")
        try execute("DELETE FROM historySyncVersions WHERE id IN (SELECT id FROM \(table))")
        try retractSyncBatches(in: "purgedBatches")
    }

    /// Drops the saved batches listed in `table` (column `id`), remembers them until they would
    /// have expired, and queues their remaining journal rows for republication.
    func retractSyncBatches(in table: String) throws {
        try execute("INSERT OR REPLACE INTO historySyncRetired SELECT id,expires FROM historySyncBatches WHERE id IN (SELECT id FROM \(table))")
        try execute("DELETE FROM historySyncBatchVisits WHERE batch IN (SELECT id FROM \(table))")
        try execute("DELETE FROM historySyncBatches WHERE id IN (SELECT id FROM \(table))")
        try execute("UPDATE historySyncEvents SET batch=NULL WHERE batch IN (SELECT id FROM \(table))")
    }

    func pruneSyncBatches(before cutoff: Date) throws {
        let value = HistoryValue.number(cutoff.timeIntervalSince1970)
        try execute("DELETE FROM historySyncBatchVisits WHERE batch IN (SELECT id FROM historySyncBatches WHERE expires<?)", [value])
        try execute("DELETE FROM historySyncBatches WHERE expires<?", [value])
        try execute("DELETE FROM historySyncRetired WHERE expires<?", [value])
    }

    /// Stored hosts that a hashed site tombstone designates (normally zero or one).
    func sites(matching site: String) throws -> [String] {
        let rows = try prepare("SELECT DISTINCT site FROM visits")
        defer { sqlite3_finalize(rows) }
        var result: [String] = []
        while try next(rows) {
            let host = text(rows, 0)
            if BrowserHistorySyncDeletion.site(site, matches: host) { result.append(host) }
        }
        return result
    }

    /// One-time cleanup for stores written by earlier builds (migration to version nine).
    func sanitizeSyncJournal() throws {
        let cutoff = Double(try scalarText("SELECT cutoff FROM historySyncState")) ?? Date.distantPast.timeIntervalSince1970
        // Visits deleted before this build: their journal rows and batches still name them.
        // Rows older than the cutoff are expiry maintenance, not deletions, and expire by themselves.
        try execute("CREATE TEMP TABLE orphanedVisits(id TEXT PRIMARY KEY)")
        defer { try? execute("DROP TABLE orphanedVisits") }
        try execute("""
            INSERT OR IGNORE INTO orphanedVisits SELECT visit FROM historySyncEvents
            WHERE kind=0 AND visit IS NOT NULL AND expires>=? AND visit NOT IN (SELECT id FROM visits)
            """, [.number(cutoff)])
        try execute("""
            INSERT OR IGNORE INTO orphanedVisits SELECT visit FROM historySyncBatchVisits
            WHERE time>=? AND visit NOT IN (SELECT id FROM visits)
            """, [.number(cutoff)])
        try purgeSyncJournal(deletedVisits: "orphanedVisits")

        // Site tombstones that still carry the plain host: rewrite the journal rows, and retract
        // every saved batch holding the plain form so the rewritten rows are published instead.
        let rows = try prepare("SELECT payload FROM historySyncEvents WHERE kind=1")
        var rewritten: [BrowserHistorySyncEvent] = []
        do {
            defer { sqlite3_finalize(rows) }
            while try next(rows) {
                let event = try JSONDecoder().decode(BrowserHistorySyncEvent.self, from: Data(text(rows, 0).utf8))
                if let hashed = event.hashingSite() { rewritten.append(hashed) }
            }
        }
        for event in rewritten {
            try execute("UPDATE historySyncEvents SET payload=? WHERE id=?",
                [.text(String(decoding: try BrowserSyncReplica.encodeValue(event), as: UTF8.self)), .text(event.id.uuidString)])
        }
        try execute("CREATE TEMP TABLE plainSiteBatches(id TEXT PRIMARY KEY)")
        defer { try? execute("DROP TABLE plainSiteBatches") }
        try execute("""
            INSERT OR IGNORE INTO plainSiteBatches SELECT b.id FROM historySyncBatches b, json_each(b.payload,'$.events') e
            WHERE json_type(e.value,'$.deletion.site')='text'
            AND substr(json_extract(e.value,'$.deletion.site'),1,\(BrowserHistorySyncDeletion.hashedSitePrefix.count))!='\(BrowserHistorySyncDeletion.hashedSitePrefix)'
            """)
        try retractSyncBatches(in: "plainSiteBatches")
    }
}
