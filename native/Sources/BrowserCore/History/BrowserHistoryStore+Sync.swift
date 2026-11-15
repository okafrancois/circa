import Foundation
import SQLite3

extension BrowserHistoryStore {
    func syncCutoff() throws -> Date {
        guard let database else { return .distantPast }
        return Date(timeIntervalSince1970: Double(try database.scalarText("SELECT cutoff FROM historySyncState")) ?? Date.distantPast.timeIntervalSince1970)
    }

    func syncDeletions() throws -> [BrowserHistorySyncDeletion] {
        guard let database else { return [] }
        let version = try database.scalarText("PRAGMA data_version")
        if let cache = deletionCache, cache.revision == database.tombstoneRevision, cache.dataVersion == version { return cache.values }
        let rows = try database.prepare("SELECT payload FROM historySyncEvents WHERE kind=1")
        defer { sqlite3_finalize(rows) }
        var result: [BrowserHistorySyncDeletion] = []
        while try database.next(rows) {
            let event = try JSONDecoder().decode(BrowserHistorySyncEvent.self, from: Data(database.text(rows, 0).utf8))
            if let deletion = event.deletion { result.append(deletion) }
        }
        deletionCache = (database.tombstoneRevision, version, result)
        return result
    }

    func appendSyncEvent(_ event: BrowserHistorySyncEvent) throws {
        guard let database else { return }
        if event.deletion != nil { database.tombstoneRevision &+= 1 }
        let cutoff = BrowserHistorySyncSchema.cutoff(Date())
        if cutoff > lastHistoryJournalPrune {
            try database.execute("DELETE FROM historySyncEvents WHERE expires<?", [.number(cutoff.timeIntervalSince1970)])
            try database.pruneSyncBatches(before: cutoff)
            try database.execute("DELETE FROM historySyncVersions WHERE id IN (SELECT id FROM visits WHERE time<?)", [.number(cutoff.timeIntervalSince1970)])
            lastHistoryJournalPrune = cutoff
        }
        // History outside the upload window remains local until enabled sync runs maintenance.
        guard event.expires >= cutoff else { return }
        try database.execute("INSERT OR IGNORE INTO historySyncEvents(id,payload,expires,kind,visit) VALUES(?,?,?,?,?)",
            [.text(event.id.uuidString), .text(String(decoding: try BrowserSyncReplica.encodeValue(event), as: UTF8.self)),
             .number(event.expires.timeIntervalSince1970), .number(event.deletion == nil ? 0 : 1)]
            + (event.visit.map { [.text($0.id.uuidString)] } ?? [.null]))
        if let visit = event.visit {
            try database.execute("INSERT OR REPLACE INTO historySyncVersions VALUES(?,?,?)",
                [.text(visit.id.uuidString), .number(event.time.timeIntervalSince1970), .text(event.id.uuidString)])
        }
    }

    public func historySyncNeedsApply(_ batches: [BrowserHistorySyncBatch], now: Date = Date()) throws -> Bool {
        guard let database else { return false }
        let relevant = batches.filter { $0.profileID == profileID && !$0.isRetraction }
        if max(BrowserHistorySyncSchema.cutoff(now), relevant.map(\.cutoff).max() ?? .distantPast) > (try syncCutoff()) { return true }
        for batch in relevant {
            // A batch this store retracted is known: re-applying it would only retract it again.
            let row = try database.prepare("SELECT 1 FROM historySyncBatches WHERE id=?1 UNION ALL SELECT 1 FROM historySyncRetired WHERE id=?1")
            defer { sqlite3_finalize(row) }
            try database.bind(row, [.text(batch.id.uuidString)])
            if try !database.next(row) { return true }
        }
        return false
    }

    /// Durable, immutable record packing. Only enabled sync calls this maintenance path.
    /// Existing history, imports and subsequent metadata revisions all enter the same journal.
    public func historySyncBatches(now: Date = Date(), forcePacking: Bool = true) throws -> [BrowserHistorySyncBatch] {
        guard let database else { return [] }
        let changes = database.withHandle { sqlite3_total_changes64($0) }
        let dataVersion = try database.scalarText("PRAGMA data_version")
        let requestedCutoff = BrowserHistorySyncSchema.cutoff(now)
        if let cache = syncBatchCache, now < syncBatchCacheDeadline,
           (!forcePacking || syncBatchCacheDeadline == .distantFuture), cache.changes == changes, cache.dataVersion == dataVersion, requestedCutoff <= cache.cutoff {
            return cache.batches
        }
        // Publish only after COMMIT; deferred journal rows impose a cache deadline.
        syncBatchCache = nil
        var deferredUntil: Date?
        let result = try database.transaction {
            let previous = try syncCutoff()
            let cutoff = max(previous, BrowserHistorySyncSchema.cutoff(now))
            // Day-granular: an unchanged cutoff has nothing to expire (no visit scan, no favicon GC).
            if cutoff > previous { try advanceSyncCutoff(cutoff) }
            let rows = try database.prepare("SELECT payload FROM historySyncEvents WHERE batch IS NULL ORDER BY rowid LIMIT 5000")
            var events: [BrowserHistorySyncEvent] = []
            do {
                defer { sqlite3_finalize(rows) }
                while try database.next(rows) {
                    events.append(try JSONDecoder().decode(BrowserHistorySyncEvent.self, from: Data(database.text(rows, 0).utf8)))
                }
            }
            // Journal rows are already durable; defer only ordinary light traffic. Deletions
            // publish immediately, and termination can explicitly flush the remaining rows.
            if !forcePacking, events.count < 100, !events.contains(where: { $0.deletion != nil }),
               let oldest = events.map(\.time).min(), now.timeIntervalSince(oldest) < 60 {
                deferredUntil = oldest.addingTimeInterval(60)
                events = []
            }
            var batches = try BrowserHistorySyncBatch.pack(profileID: profileID, cutoff: cutoff, events: events)
            if batches.isEmpty && cutoff > previous {
                batches = [BrowserHistorySyncBatch(profileID: profileID, cutoff: cutoff, events: [])]
            }
            for batch in batches {
                try saveSyncBatch(batch)
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
            // Retracted batches travel as local notices until they would have expired anyway.
            let retired = try database.prepare("SELECT id FROM historySyncRetired WHERE expires>=?")
            defer { sqlite3_finalize(retired) }
            try database.bind(retired, [.number(cutoff.timeIntervalSince1970)])
            while try database.next(retired) {
                if let id = UUID(uuidString: database.text(retired, 0)) { result.append(.retraction(of: id, profileID: profileID)) }
            }
            return result
        }
        if try deferredUntil != nil || database.scalarText("SELECT COUNT(*) FROM historySyncEvents WHERE batch IS NULL") == "0" {
            syncBatchCacheDeadline = deferredUntil ?? .distantFuture
            syncBatchCache = (database.withHandle { sqlite3_total_changes64($0) }, dataVersion, try syncCutoff(), result)
        }
        return result
    }

    private func saveSyncBatch(_ batch: BrowserHistorySyncBatch) throws {
        guard let database else { return }
        let bytes = try batch.encoded()
        try batch.validate(encodedSize: bytes.count)
        try database.execute("INSERT OR IGNORE INTO historySyncBatches VALUES(?,?,?)",
            [.text(batch.id.uuidString), .text(String(decoding: bytes, as: UTF8.self)), .number(batch.expires.timeIntervalSince1970)])
        guard database.changes > 0 else { return }
        // Which saved batches carry a visit: a deletion retracts exactly those.
        for visit in batch.events.compactMap(\.visit) {
            try database.execute("INSERT OR IGNORE INTO historySyncBatchVisits VALUES(?,?,?)",
                [.text(batch.id.uuidString), .text(visit.id.uuidString), .number(visit.visitedAt.timeIntervalSince1970)])
        }
    }

    private func advanceSyncCutoff(_ cutoff: Date) throws {
        guard let database else { return }
        try database.execute("UPDATE historySyncState SET cutoff=MAX(cutoff,?)", [.number(cutoff.timeIntervalSince1970)])
        _ = try deleteRows(clause: "time<?", values: [.number(cutoff.timeIntervalSince1970)], purgeSyncJournal: false)
        try database.execute("DELETE FROM historySyncEvents WHERE expires<?", [.number(cutoff.timeIntervalSince1970)])
        try database.pruneSyncBatches(before: cutoff)
        try database.execute("DELETE FROM historySyncVersions WHERE id NOT IN (SELECT id FROM visits)")
    }

    /// All predicates are admitted before any visits, independent of server delivery order.
    /// A replay or metadata revision cannot resurrect a deleted identity or inflate counters.
    @discardableResult public func applyHistorySync(_ batches: [BrowserHistorySyncBatch], now: Date = Date()) throws -> Bool {
        guard let database else { return false }
        let relevant = batches.filter { $0.profileID == profileID && !$0.isRetraction }
        for batch in relevant { try batch.validate() }
        applyingHistorySync = true
        defer { applyingHistorySync = false }
        return try database.transaction {
            let cutoff = max(try syncCutoff(), BrowserHistorySyncSchema.cutoff(now), relevant.map(\.cutoff).max() ?? .distantPast)
            let oldCutoff = try syncCutoff()
            if cutoff > oldCutoff { try advanceSyncCutoff(cutoff) }
            var incoming: [BrowserHistorySyncBatch] = []
            for batch in relevant where batch.expires >= cutoff {
                guard try database.scalarInt("SELECT COUNT(*) FROM historySyncRetired WHERE id=?", [.text(batch.id.uuidString)]) == 0 else { continue }
                let rows = try database.prepare("SELECT payload FROM historySyncBatches WHERE id=?")
                let exists: Bool
                do {
                    defer { sqlite3_finalize(rows) }
                    try database.bind(rows, [.text(batch.id.uuidString)])
                    exists = try database.next(rows)
                    if exists, Data(database.text(rows, 0).utf8) != (try batch.encoded()) { throw BrowserSyncError.invalidRecord }
                }
                if !exists { incoming.append(batch) }
            }
            for batch in incoming {
                for event in batch.events where event.deletion != nil && event.expires >= cutoff {
                    try appendSyncEvent(event)
                    guard let deletion = event.deletion else { continue }
                    var clauses = [deletion.endInclusive ? "time<=?" : "time<?"], values: [HistoryValue] = [.number(deletion.end.timeIntervalSince1970)]
                    if let id = deletion.visitID { clauses = ["id=?"]; values = [.text(id.uuidString)] }
                    if let site = deletion.site {
                        let hosts = BrowserHistorySyncDeletion.isHashedSite(site) ? try database.sites(matching: site) : [site]
                        guard !hosts.isEmpty else { continue }
                        clauses.append("site IN (" + hosts.map { _ in "?" }.joined(separator: ",") + ")")
                        values += hosts.map(HistoryValue.text)
                    }
                    if let start = deletion.start { clauses.append("time>=?"); values.append(.number(start.timeIntervalSince1970)) }
                    _ = try deleteRows(clause: clauses.joined(separator: " AND "), values: values)
                }
            }
            var barriers = BrowserHistorySyncBarriers(try syncDeletions())
            var deletedContent: [UUID] = []
            for batch in incoming {
                for event in batch.events {
                    guard let visit = event.visit, visit.visitedAt >= cutoff else { continue }
                    // A deleted visit must not stay in this store, even inside a saved batch.
                    guard !barriers.matches(visit) else {
                        if deletedContent.last != batch.id { deletedContent.append(batch.id) }
                        continue
                    }
                    let rows = try database.prepare("SELECT time,event FROM historySyncVersions WHERE id=?")
                    let newer: Bool
                    do {
                        defer { sqlite3_finalize(rows) }
                        try database.bind(rows, [.text(visit.id.uuidString)])
                        if try database.next(rows) {
                            newer = (sqlite3_column_double(rows, 0), database.text(rows, 1)) < (event.time.timeIntervalSince1970, event.id.uuidString)
                        } else { newer = true }
                    }
                    guard newer else { continue }
                    _ = try insert([visit])
                    _ = try updateMetadata(visitID: visit.id, title: visit.title, faviconReference: visit.faviconReference)
                    try appendSyncEvent(event)
                    try database.execute("UPDATE historySyncEvents SET batch=? WHERE id=?", [.text(batch.id.uuidString), .text(event.id.uuidString)])
                }
                try saveSyncBatch(batch)
                for event in batch.events where event.deletion != nil {
                    try database.execute("UPDATE historySyncEvents SET batch=? WHERE id=?", [.text(batch.id.uuidString), .text(event.id.uuidString)])
                }
                // Journal rows still waiting for upload (a survivor of a batch retracted here) are
                // already published in this batch: adopt it instead of uploading them again.
                for event in batch.events where event.visit != nil {
                    try database.execute("UPDATE historySyncEvents SET batch=? WHERE id=? AND batch IS NULL", [.text(batch.id.uuidString), .text(event.id.uuidString)])
                }
            }
            if !deletedContent.isEmpty {
                try database.execute("CREATE TEMP TABLE deletedContent(id TEXT PRIMARY KEY)")
                defer { try? database.execute("DROP TABLE deletedContent") }
                for id in deletedContent { try database.execute("INSERT OR IGNORE INTO deletedContent VALUES(?)", [.text(id.uuidString)]) }
                try database.retractSyncBatches(in: "deletedContent")
            }
            return !incoming.isEmpty || oldCutoff != cutoff
        }
    }
}
