import BrowserCore
@testable import BrowserEngine
import CryptoKit
import Foundation
import Testing

@MainActor
private final class PrivacyPasswordStore: BrowserPasswordStore {
    var rows: [ProfileID: [BrowserPasswordRecord]] = [:]
    func list(profileID: ProfileID) async throws -> [BrowserPasswordRecord] { rows[profileID] ?? [] }
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

/// Same Codable shape as the sealed BrowserPasswordSync state, to stage a cache written by an
/// earlier build (an unscrubbed tombstone).
private struct StagedState: Codable {
    struct Binding: Codable { var id: UUID; var fields: [String: Data] }
    var device: String
    var entries: [BrowserPasswordSyncEntry]
    var baseline: [ProfileID: [Binding]]
}

@MainActor
struct PasswordSyncPrivacyTests {
    private let secrets = ["synthetic-user", "synthetic-secret", "fixture.invalid", "login"]

    private func check(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        // Never print credential expressions or values in assertion diagnostics.
        #expect(condition, sourceLocation: sourceLocation)
    }
    private func row(_ user: String = "synthetic-user", password: String = "synthetic-secret",
                     realm: String = "https://fixture.invalid/", origin: String = "https://fixture.invalid/login",
                     action: String = "", scheme: Int32 = 0) -> BrowserPasswordRecord {
        BrowserPasswordRecord(primaryKey: .init(signonRealm: realm, originURL: origin, usernameElement: "user",
            usernameValue: user, passwordElement: "pass"), actionURL: action, passwordValue: password,
            dateCreated: 13_000_000_000_000_001, datePasswordModified: 13_000_000_000_000_100, scheme: scheme)
    }
    private func entry(_ row: BrowserPasswordRecord, profile: ProfileID, time: Int64 = 1) throws -> BrowserPasswordSyncEntry {
        let id = UUID(), stamp = BrowserPasswordSyncEntry.Stamp(time: time, device: "synthetic-device")
        let fields = try BrowserPasswordSyncEntry.values(row).mapValues { BrowserPasswordSyncEntry.Field(bytes: $0, stamp: stamp) }
        return BrowserPasswordSyncEntry(id: id, profileID: profile, aliases: [id], matches: [BrowserPasswordSyncEntry.match(row)],
                                        fields: fields, life: stamp)
    }
    private func root() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("password-privacy-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    /// No field, match key or alias of the entry carries any credential text.
    private func secretFree(_ entry: BrowserPasswordSyncEntry) -> Bool {
        let text = entry.fields.values.map { String(decoding: $0.bytes, as: UTF8.self) }.joined()
            + entry.matches.flatMap { $0 }.joined()
        return !secrets.contains { text.contains($0) }
    }

    @Test("A deleted password uploads a scrubbed tombstone, and the other Mac still removes it")
    func deletionScrubsAndConverges() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        let a = try BrowserPasswordSync(cache: .init(destination: root.appendingPathComponent("a"), key: key), fullScanInterval: 0)
        let b = try BrowserPasswordSync(cache: .init(destination: root.appendingPathComponent("b"), key: key), fullScanInterval: 0)
        defer { Task { await a.stop(); await b.stop() } }
        let first = PrivacyPasswordStore(), second = PrivacyPasswordStore()
        first.rows[p] = [row()]
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        check(second.rows[p]?.count == 1)
        first.rows[p] = []
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        let uploaded = try await cloud.exchange([])
        check(uploaded.count == 1 && uploaded[0].deleted && uploaded[0].isScrubbed && secretFree(uploaded[0]))
        // The CloudKit record built from it validates and round-trips.
        check(try BrowserPasswordSyncEntry.fromCloud(uploaded[0].cloudRecord()) == uploaded[0])
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        check(second.rows[p]?.isEmpty == true)
        // Both replicas settle; a further cycle changes nothing and nothing comes back.
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        check(first.rows[p]?.isEmpty == true && second.rows[p]?.isEmpty == true)
        check(try await cloud.exchange([]) == uploaded)
        // Re-adding the same credential later creates a live entry again.
        first.rows[p] = [row()]
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        check(second.rows[p]?.count == 1)
    }

    @Test("A concurrent edit after the deletion cannot put a secret back into the tombstone")
    func mergeStaysScrubbedAndCommutes() throws {
        let p = ProfileID()
        let live = try entry(row(), profile: p, time: 10)
        var tombstone = live
        tombstone.tombstone(at: .init(time: 20, device: "mac-a"))
        check(tombstone.deleted && tombstone.isScrubbed && secretFree(tombstone))
        var edited = live
        edited.fields["password"] = .init(bytes: try BrowserPasswordSyncEntry.encodeValue("synthetic-secret-edit"),
                                          stamp: .init(time: 30, device: "mac-b"))
        var left = tombstone, right = edited
        try left.merge(edited); try right.merge(tombstone)
        check(left == right && left.deleted && left.isScrubbed && secretFree(left))
        // Merging with the original live copy is idempotent.
        var again = left
        try again.merge(live)
        check(again == left)
        // Deduplication keeps distinct scrubbed tombstones apart (they share no identity).
        var other = try entry(row("synthetic-user-2"), profile: p, time: 10)
        other.tombstone(at: .init(time: 21, device: "mac-a"))
        check(try BrowserPasswordSyncEntry.merged([left, other]).count == 2)
    }

    @Test("A tombstone cached by an earlier build is scrubbed on the next run")
    func legacyTombstoneScrubbedOnNextRun() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        let cache = BrowserPasswordSyncCache(destination: root.appendingPathComponent("a"), key: key)
        var legacy = try entry(row(), profile: p, time: 10)
        legacy.deleted = true
        legacy.life = .init(time: 20, device: "synthetic-device")
        check(!legacy.isScrubbed)
        try cache.save(StagedState(device: "synthetic-device", entries: [legacy], baseline: [:]))
        let sync = try BrowserPasswordSync(cache: cache, fullScanInterval: 0)
        defer { Task { await sync.stop() } }
        try await sync.synchronize(store: PrivacyPasswordStore(), profiles: [p], transport: cloud)
        let stored = try cache.load(StagedState.self)
        check(stored?.entries.count == 1 && stored?.entries.allSatisfy { $0.deleted && $0.isScrubbed && secretFree($0) } == true)
        let uploaded = try await cloud.exchange([])
        check(uploaded.count == 1 && uploaded[0].isScrubbed)
    }

    @Test("Remote entries must be web credentials")
    func remoteValidationTable() throws {
        let p = ProfileID()
        let cases: [(BrowserPasswordRecord, Bool)] = [
            (row(), true),
            (row(realm: "http://fixture.invalid/", origin: "http://fixture.invalid/"), true),
            (row(realm: "https://fixture.invalid/Synthetic Realm", origin: "https://fixture.invalid/", scheme: 1), true),
            (row(action: "https://fixture.invalid/submit"), true),
            (row(realm: "javascript:alert(1)"), false),
            (row(origin: "javascript:alert(1)"), false),
            (row(action: "javascript:alert(1)"), false),
            (row(realm: "file:///", origin: "file:///private/tmp/form.html"), false),
            (row(realm: "chrome://settings/", origin: "chrome://settings/passwords"), false),
            (row(realm: "android://synthetic@com.example.app/", origin: "android://synthetic@com.example.app/"), false),
            (row(realm: "data:text/html,form", origin: "data:text/html,form"), false),
            (row(realm: "https:///", origin: "https:///login"), false),
            (row(origin: "ftp://fixture.invalid/"), false),
        ]
        for (index, item) in cases.enumerated() {
            #expect(try entry(item.0, profile: p).isAcceptableRemote == item.1, "case \(index)")
        }
        var tombstone = try entry(row(realm: "javascript:alert(1)"), profile: p)
        tombstone.tombstone(at: .init(time: 5, device: "synthetic-device"))
        check(tombstone.isAcceptableRemote)
    }

    @Test("An invalid remote entry is dropped; valid ones still apply")
    func invalidRemoteEntryIsDropped() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        _ = try await cloud.exchange([try entry(row("synthetic-bad", realm: "javascript:alert(1)", origin: "javascript:alert(1)"), profile: p),
                                      try entry(row("synthetic-good"), profile: p)])
        let sync = try BrowserPasswordSync(cache: .init(destination: root.appendingPathComponent("b"), key: SymmetricKey(size: .bits256)),
                                           fullScanInterval: 0)
        defer { Task { await sync.stop() } }
        let store = PrivacyPasswordStore()
        try await sync.synchronize(store: store, profiles: [p], transport: cloud)
        check(store.rows[p]?.map(\.primaryKey.usernameValue) == ["synthetic-good"])
    }
}
