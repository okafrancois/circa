import BrowserCore
@testable import BrowserEngine
import CloudKit
import CryptoKit
import Foundation
import Testing

@MainActor
private final class SyncPasswordStore: BrowserPasswordStore {
    var rows: [ProfileID: [BrowserPasswordRecord]] = [:]
    var lists = 0
    func list(profileID: ProfileID) async throws -> [BrowserPasswordRecord] { lists += 1; return rows[profileID] ?? [] }
    func add(_ row: BrowserPasswordRecord, profileID: ProfileID) async throws {
        guard !(rows[profileID] ?? []).contains(where: { $0.primaryKey == row.primaryKey }) else { throw BrowserPasswordStoreError.conflict }
        rows[profileID, default: []].append(row)
    }
    func update(_ row: BrowserPasswordRecord, replacing key: BrowserPasswordKey, profileID: ProfileID) async throws {
        guard let index = rows[profileID]?.firstIndex(where: { $0.primaryKey == key }) else { throw BrowserPasswordStoreError.conflict }
        rows[profileID]?[index] = row
    }
    func remove(_ key: BrowserPasswordKey, profileID: ProfileID) async throws { rows[profileID]?.removeAll { $0.primaryKey == key } }
    func changes(profileID: ProfileID) async throws -> AsyncStream<BrowserPasswordStoreChange> { AsyncStream { _ in } }
}

private actor PasswordCloudDuringExchange: BrowserPasswordSyncTransport {
    let cloud: BrowserPasswordSyncMemoryCloud
    let edit: @MainActor @Sendable () -> Void
    init(cloud: BrowserPasswordSyncMemoryCloud, edit: @escaping @MainActor @Sendable () -> Void) { self.cloud = cloud; self.edit = edit }
    func exchange(_ entries: [BrowserPasswordSyncEntry]) async throws -> [BrowserPasswordSyncEntry] {
        let incoming = try await cloud.exchange(entries)
        await edit()
        return incoming
    }
    func stop() {}
}

@MainActor
struct PasswordSyncTests {
    private func check(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        // Never print credential expressions or values in assertion diagnostics.
        #expect(condition, sourceLocation: sourceLocation)
    }
    private func row(_ user: String = "synthetic-user", password: String = "synthetic-secret", modified: Int64 = 13_000_000_000_000_100) -> BrowserPasswordRecord {
        BrowserPasswordRecord(primaryKey: .init(signonRealm: "https://fixture.invalid/", originURL: "https://fixture.invalid/login",
            usernameElement: "user", usernameValue: user, passwordElement: "pass"), passwordValue: password,
            dateCreated: 13_000_000_000_000_001, datePasswordModified: modified)
    }
    private func cache(_ root: URL, _ name: String, _ key: SymmetricKey) -> BrowserPasswordSyncCache { .init(destination: root.appendingPathComponent(name), key: key) }
    private func root() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("password-sync-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    @Test func twoMacAddUpdateUsernameBlocklistAndDelete() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        let a = try BrowserPasswordSync(cache: cache(root, "a", key)), b = try BrowserPasswordSync(cache: cache(root, "b", key))
        defer { let currentA = a; Task { await currentA.stop(); await b.stop() } }
        let first = SyncPasswordStore(), second = SyncPasswordStore()
        try await first.add(row(), profileID: p)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        check(second.rows[p]?.count == 1)
        var edit = row(password: "synthetic-new", modified: 13_000_000_000_000_200)
        try await second.update(edit, replacing: edit.primaryKey, profileID: p)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        check(first.rows[p]?.first?.passwordValue == edit.passwordValue)
        let old = edit.primaryKey
        edit.primaryKey.usernameValue = "synthetic-renamed"
        try await first.update(edit, replacing: old, profileID: p)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        check(second.rows[p]?.count == 1 && second.rows[p]?.first?.primaryKey == edit.primaryKey)
        var never = row("", password: "")
        never.primaryKey.signonRealm = "https://never.invalid/"; never.blockedByUser = true
        try await second.add(never, profileID: p)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        check(first.rows[p]?.contains(where: { $0.blockedByUser }) == true)
        try await first.remove(edit.primaryKey, profileID: p)
        try await second.remove(never.primaryKey, profileID: p)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        check(first.rows[p]?.isEmpty == true && second.rows[p]?.isEmpty == true)
    }

    @Test func firstMergeDuplicatesNewerPasswordAndFieldConflicts() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        let a = try BrowserPasswordSync(cache: cache(root, "a", key)), b = try BrowserPasswordSync(cache: cache(root, "b", key))
        defer { let currentA = a; Task { await currentA.stop(); await b.stop() } }
        let first = SyncPasswordStore(), second = SyncPasswordStore()
        let older = row(), newer = row(password: "synthetic-newer", modified: 13_000_000_000_000_300)
        var duplicate = older; duplicate.primaryKey.originURL += "?duplicate"
        first.rows[p] = [older, duplicate]; second.rows[p] = [newer, row("distinct")]
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        check(first.rows[p]?.count == 2 && second.rows[p]?.count == 2)
        check(first.rows[p]?.first(where: { $0.primaryKey.usernameValue == older.primaryKey.usernameValue })?.passwordValue == newer.passwordValue)
        var local = first.rows[p]![0]; local.actionURL = "https://fixture.invalid/new-action"
        try await first.update(local, replacing: local.primaryKey, profileID: p)
        var remote = second.rows[p]!.first(where: { $0.primaryKey == local.primaryKey })!
        remote.passwordValue = "synthetic-concurrent"; remote.datePasswordModified += 100
        try await second.update(remote, replacing: remote.primaryKey, profileID: p)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        let final = first.rows[p]!.first(where: { $0.primaryKey == local.primaryKey })!
        check(final.actionURL == local.actionURL && final.passwordValue == remote.passwordValue)
    }

    @Test func offlineEditCannotResurrectTombstoneAndRestartKeepsIdentity() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        var a = try BrowserPasswordSync(cache: cache(root, "a", key))
        let b = try BrowserPasswordSync(cache: cache(root, "b", key)), first = SyncPasswordStore(), second = SyncPasswordStore()
        defer { let currentA = a; Task { await currentA.stop(); await b.stop() } }
        first.rows[p] = [row()]
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        await a.stop(); a = try BrowserPasswordSync(cache: cache(root, "a", key))
        first.rows[p] = []
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        second.rows[p]?[0].passwordValue = "synthetic-offline-change"
        second.rows[p]?[0].datePasswordModified += 500
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        check(second.rows[p]?.isEmpty == true)
        let count = try await cloud.exchange([]).count
        check(count == 1)
    }

    @Test func privateUnknownProfilesAndMissingSchemaFailClosed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sync = try BrowserPasswordSync(cache: cache(root, "a", SymmetricKey(size: .bits256)))
        defer { Task { await sync.stop() } }
        let store = SyncPasswordStore(), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud(schemaAvailable: false)
        store.rows[p] = [row()]
        try await sync.synchronize(store: store, profiles: [p], isPrivate: true, transport: cloud)
        check(store.lists == 0 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        await #expect(throws: BrowserSyncError.unavailable) { try await sync.synchronize(store: store, profiles: [p], transport: cloud) }
        check(store.rows[p]?.count == 1)
        let other = BrowserPasswordSyncMemoryCloud()
        try await sync.synchronize(store: store, profiles: [], transport: other)
        check(store.rows.keys.count == 1)
    }

    @Test func accountAdmissionBeforeAndAfterExchange() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sync = try BrowserPasswordSync(cache: cache(root, "a", SymmetricKey(size: .bits256)))
        defer { Task { await sync.stop() } }
        let store = SyncPasswordStore(), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        store.rows[p] = [row()]
        var marker = BrowserSyncAccountMarker()
        try marker.admit("account-a")
        await #expect(throws: BrowserSyncError.signedOut) {
            try await sync.synchronize(store: store, profiles: [p], transport: cloud) { try marker.admit(nil) }
        }
        check(store.lists == 0)
        var admissions = 0
        await #expect(throws: BrowserSyncError.accountChanged) {
            try await sync.synchronize(store: store, profiles: [p], transport: cloud) {
                admissions += 1; try marker.admit(admissions == 1 ? "account-a" : "account-b")
            }
        }
        check(store.rows[p]?.count == 1)
        await sync.stop()
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
    }

    @Test func encryptedWireAndNoPlaintextAnywhereInCaches() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), local = cache(root, "replica", key), cloudCache = cache(root, "cloudkit", key)
        let sync = try BrowserPasswordSync(cache: local), store = SyncPasswordStore(), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        defer { Task { await sync.stop() } }
        store.rows[p] = [row()]
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
        let entries = try await cloud.exchange([]), entry = entries[0]
        let record = try entry.cloudRecord()
        check(record[BrowserPasswordSyncSchema.field] == nil && record.encryptedValues.allKeys() == [BrowserPasswordSyncSchema.field])
        check(try BrowserPasswordSyncEntry.fromCloud(record) == entry)
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver); archiver.finishEncoding()
        struct TransportFixture: Codable { var records: [BrowserPasswordSyncEntry]; var systemFields: Data; var engine: Data }
        // Exercise the same sealing path for the complete transport state, including opaque engine serialization.
        try cloudCache.save(TransportFixture(records: entries, systemFields: archiver.encodedData, engine: Data("synthetic-token".utf8)))
        check(try cloudCache.load(TransportFixture.self)?.records == entries)
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: file)
            for secret in ["synthetic-user", "synthetic-secret", "fixture.invalid", "synthetic-token"] {
                check(bytes.range(of: Data(secret.utf8)) == nil && bytes.range(of: Data(secret.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })) == nil)
            }
        }
        let encryptedFile = try Data(contentsOf: cloudCache.destination)
        for name in ["identity", "password"] {
            let field = entry.fields[name]!.bytes
            check(encryptedFile.range(of: field) == nil && encryptedFile.range(of: Data(field.base64EncodedString().utf8)) == nil)
        }
        var tampered = encryptedFile; tampered[tampered.count / 2] ^= 1
        try tampered.write(to: cloudCache.destination)
        var tamperRefused = false
        do { _ = try cloudCache.load(TransportFixture.self) } catch { tamperRefused = true }
        check(tamperRefused)
        let badKey = cache(root, "replica", SymmetricKey(size: .bits256))
        var refused = false
        do { _ = try badKey.load([String: String].self) } catch { refused = true }
        check(refused)
        record["payload"] = "plaintext" as CKRecordValue
        #expect(throws: BrowserSyncError.invalidRecord) { try BrowserPasswordSyncEntry.fromCloud(record) }
    }

    @Test func oldUsernameCanBecomeAnIndependentCredentialAndExplicitReaddSurvives() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sync = try BrowserPasswordSync(cache: cache(root, "a", SymmetricKey(size: .bits256)))
        defer { Task { await sync.stop() } }
        let cloud = BrowserPasswordSyncMemoryCloud(), p = ProfileID(), store = SyncPasswordStore()
        let initial = row(); store.rows[p] = [initial]
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
        var renamed = initial; renamed.primaryKey.usernameValue = "synthetic-renamed"
        store.rows[p] = [renamed]
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
        var independent = initial; independent.dateCreated += 500; independent.datePasswordModified += 500
        store.rows[p]?.append(independent)
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
        check(store.rows[p]?.count == 2)
        store.rows[p] = []
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
        independent.datePasswordModified += 500; store.rows[p] = [independent]
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
        check(store.rows[p]?.count == 1)
    }

    @Test func ambiguousUsernameEditPausesWithoutDeletingAnything() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sync = try BrowserPasswordSync(cache: cache(root, "a", SymmetricKey(size: .bits256)))
        defer { Task { await sync.stop() } }
        let cloud = BrowserPasswordSyncMemoryCloud(), p = ProfileID(), store = SyncPasswordStore()
        store.rows[p] = [row("first"), row("second")]
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
        store.rows[p] = [row("third"), row("fourth")]
        await #expect(throws: BrowserSyncError.localChange) { try await sync.synchronize(store: store, profiles: [p], transport: cloud) }
        check(store.rows[p]?.count == 2)
    }

    @Test func localEditDuringExchangeWinsWithoutBeingAcknowledgedAway() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), cloud = BrowserPasswordSyncMemoryCloud(), p = ProfileID()
        let a = try BrowserPasswordSync(cache: cache(root, "a", key)), b = try BrowserPasswordSync(cache: cache(root, "b", key))
        defer { let currentA = a; Task { await currentA.stop(); await b.stop() } }
        let first = SyncPasswordStore(), second = SyncPasswordStore()
        first.rows[p] = [row()]
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        let changing = PasswordCloudDuringExchange(cloud: cloud) {
            first.rows[p]?[0].passwordValue = "synthetic-inflight"
            first.rows[p]?[0].datePasswordModified += 1000
        }
        try await a.synchronize(store: first, profiles: [p], transport: changing)
        check(first.rows[p]?.first?.passwordValue == "synthetic-inflight")
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        check(second.rows[p]?.first?.passwordValue == "synthetic-inflight")
    }

    @Test func neverEntryDoesNotReplaceAnEmptyUsernameCredential() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sync = try BrowserPasswordSync(cache: cache(root, "a", SymmetricKey(size: .bits256)))
        defer { Task { await sync.stop() } }
        let cloud = BrowserPasswordSyncMemoryCloud(), p = ProfileID(), store = SyncPasswordStore()
        let credential = row("")
        var blocked = credential; blocked.blockedByUser = true; blocked.passwordValue = ""
        blocked.primaryKey.originURL += "?never"; blocked.datePasswordModified += 100
        store.rows[p] = [credential, blocked]
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
        check(store.rows[p]?.count == 2)
        check(store.rows[p]?.contains(where: { !$0.blockedByUser && $0.passwordValue == credential.passwordValue }) == true)
    }

    @Test func deterministicTieAndReplay() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let cloudA = BrowserPasswordSyncMemoryCloud(), cloudB = BrowserPasswordSyncMemoryCloud(), p = ProfileID()
        let key = SymmetricKey(size: .bits256)
        let a = try BrowserPasswordSync(cache: cache(root, "a", key)), b = try BrowserPasswordSync(cache: cache(root, "b", key))
        defer { let currentA = a; Task { await currentA.stop(); await b.stop() } }
        let first = SyncPasswordStore(), second = SyncPasswordStore()
        first.rows[p] = [row(password: "synthetic-tie-a")]; second.rows[p] = [row(password: "synthetic-tie-b")]
        try await a.synchronize(store: first, profiles: [p], transport: cloudA)
        try await b.synchronize(store: second, profiles: [p], transport: cloudB)
        let left = try await cloudA.exchange([]), right = try await cloudB.exchange([])
        let ab = try BrowserPasswordSyncEntry.merged(left + right), ba = try BrowserPasswordSyncEntry.merged(right + left)
        check(ab == ba && ab.count == 1)
        check(try BrowserPasswordSyncEntry.merged(ab + left + right + ab) == ab)
    }
}
