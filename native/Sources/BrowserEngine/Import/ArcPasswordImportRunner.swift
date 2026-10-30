import BrowserCore
import Foundation

/// Invoke only in the startup gate, before creating any window/page or starting sync.
@MainActor
public enum ArcPasswordImportRunner {
    private static func sameIdentity(_ a: BrowserPasswordRecord, _ b: ImportedBrowserPassword) -> Bool {
        a.primaryKey.signonRealm == b.realm && a.primaryKey.originURL == b.origin && a.primaryKey.usernameValue == b.username
    }
    private static func record(_ row: ImportedBrowserPassword) -> BrowserPasswordRecord {
        .init(primaryKey: .init(signonRealm: row.realm, originURL: row.origin, usernameElement: row.usernameElement,
            usernameValue: row.username, passwordElement: row.passwordElement), actionURL: row.action, passwordValue: row.password,
            dateCreated: row.created, dateLastUsed: row.lastUsed, datePasswordModified: row.modified, blockedByUser: row.blocked, scheme: row.scheme)
    }
    public static func run(_ journal: ArcPasswordImportJournal, store: any BrowserPasswordStore) async throws {
        guard [.pending, .applying, .undoPending].contains(journal.phase) else { return }
        guard journal.rows.allSatisfy({ !$0.credential.blocked || ($0.credential.username.isEmpty && $0.credential.password.isEmpty) }) else {
            throw BrowserAuthenticationImportError.invalidRecord
        }
        let restoring = journal.phase == .undoPending
        var listings: [ProfileID: [BrowserPasswordRecord]] = [:]
        for profile in Set(journal.rows.map(\.profile)) { listings[profile] = try await store.list(profileID: profile) }
        if journal.phase == .pending {
            var baseline = listings
            let states: [ArcPasswordImportJournal.State] = journal.rows.map { row in
                if let found = baseline[row.profile]?.first(where: { sameIdentity($0, row.credential) }) {
                    return journal.hash(found.passwordValue) == row.hash ? .present : .conflict
                }
                baseline[row.profile, default: []].append(record(row.credential))
                return .absent
            }
            try journal.baseline(states)
        }
        for (index, row) in journal.rows.enumerated() {
            try Task.checkCancellation()
            let found = listings[row.profile]?.first(where: { sameIdentity($0, row.credential) })
            if restoring {
                // An intent may have reached the store immediately before a crash. The absent
                // baseline plus matching hash establishes ownership under startup exclusion.
                guard row.state == .owned || row.state == .intent else { continue }
                if let found {
                    if journal.hash(found.passwordValue) == row.hash,
                       found.primaryKey == record(row.credential).primaryKey,
                       found.datePasswordModified == row.credential.modified {
                        try journal.checkpoint("password-before-remove:" + String(index))
                        try await store.remove(found.primaryKey, profileID: row.profile)
                        try journal.checkpoint("password-after-remove:" + String(index))
                        try journal.set(.removed, at: index)
                    } else { try journal.set(.retained, at: index) }
                } else { try journal.set(.removed, at: index) }
                continue
            }
            guard [.absent, .intent, .owned].contains(row.state) else { continue }
            if let found {
                if [.intent, .owned].contains(row.state), journal.hash(found.passwordValue) == row.hash {
                    try journal.set(.owned, at: index)
                } else { try journal.set(journal.hash(found.passwordValue) == row.hash ? .present : .conflict, at: index) }
            } else {
                try journal.set(.intent, at: index)
                let value = record(row.credential)
                try await store.add(value, profileID: row.profile)
                try journal.checkpoint("password-after-add:" + String(index))
                listings[row.profile, default: []].append(value)
                try journal.set(.owned, at: index)
            }
        }
        for profile in listings.keys {
            let actual = try await store.list(profileID: profile)
            for row in journal.rows where row.profile == profile {
                let found = actual.first { sameIdentity($0, row.credential) }
                if row.state == .owned {
                    guard let found, journal.hash(found.passwordValue) == row.hash else { throw BrowserAuthenticationImportError.verificationFailed }
                } else if row.state == .removed, found != nil { throw BrowserAuthenticationImportError.verificationFailed }
            }
        }
        try journal.checkpoint("password-verified")
        try journal.finish(restoring: restoring)
    }
}

/// Windows/pages and sync wait for application or the user's recovery decision. Import
/// failure must never prevent launch, including when the recovery key or journal is lost.
@MainActor
public enum BrowserPasswordStartupGate {
    public static func run(root: URL, open: (UUID) throws -> ArcPasswordImportJournal,
                           apply: (ArcPasswordImportJournal) async throws -> Void,
                           completed: (ArcPasswordImportJournal) throws -> Void = { _ in },
                           choose: () -> BrowserImportRecovery.Choice, startApplication: () -> Void) async {
        defer { startApplication() }
        var id: UUID?
        var journal: ArcPasswordImportJournal?
        do {
            guard let active = try ArcPasswordImportJournal.activeID(root: root) else { return }
            id = active
            let loaded = try open(active); journal = loaded
            if [.pending, .applying, .undoPending].contains(loaded.phase) { try await apply(loaded) }
            if [.complete, .restored].contains(loaded.phase) { try completed(loaded) }
            try ArcPasswordImportJournal.finishStartup(root: root)
        } catch {
            do { try ArcPasswordImportJournal.suspendStartup(root: root) }
            catch { try? ArcPasswordImportJournal.quarantine(root: root, id: nil) }
            try? journal?.abandon()
            // The pointer is durably retired before the alert; the backup still links to the
            // sealed ownership record for a later explicit Restore after Continue.
            switch choose() {
            case .continueWithoutImport:
                break
            case .restore:
                do {
                    guard let id else { throw BrowserAuthenticationImportError.invalidState }
                    let loaded = try journal ?? open(id)
                    try loaded.prepareUndo()
                    try await apply(loaded)
                    try completed(loaded)
                } catch { try? ArcPasswordImportJournal.quarantine(root: root, id: id) }
            }
        }
    }
}
