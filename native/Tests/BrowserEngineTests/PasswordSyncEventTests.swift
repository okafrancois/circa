import BrowserCore
@testable import BrowserEngine
import CryptoKit
import Foundation
import Testing

/// Notifies like the engine store: every committed write yields `.changed` to live observers.
@MainActor
private final class NotifyingPasswordStore: BrowserPasswordStore {
    var rows: [ProfileID: [BrowserPasswordRecord]] = [:]
    var lists = 0
    var muted = false
    private var listeners: [ProfileID: [AsyncStream<BrowserPasswordStoreChange>.Continuation]] = [:]
    func list(profileID: ProfileID) async throws -> [BrowserPasswordRecord] { lists += 1; return rows[profileID] ?? [] }
    func add(_ row: BrowserPasswordRecord, profileID: ProfileID) async throws {
        guard !(rows[profileID] ?? []).contains(where: { $0.primaryKey == row.primaryKey }) else { throw BrowserPasswordStoreError.conflict }
        rows[profileID, default: []].append(row); notify(profileID)
    }
    func update(_ row: BrowserPasswordRecord, replacing key: BrowserPasswordKey, profileID: ProfileID) async throws {
        guard let index = rows[profileID]?.firstIndex(where: { $0.primaryKey == key }) else { throw BrowserPasswordStoreError.conflict }
        rows[profileID]?[index] = row; notify(profileID)
    }
    func remove(_ key: BrowserPasswordKey, profileID: ProfileID) async throws {
        rows[profileID]?.removeAll { $0.primaryKey == key }; notify(profileID)
    }
    func changes(profileID: ProfileID) async throws -> AsyncStream<BrowserPasswordStoreChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { listeners[profileID, default: []].append($0) }
    }
    private func notify(_ profile: ProfileID) {
        guard !muted else { return }
        for listener in listeners[profile] ?? [] { listener.yield(.changed) }
    }
}

private final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func fire() { lock.withLock { value += 1 } }
}

@MainActor
struct PasswordSyncEventTests {
    private func row(_ user: String = "synthetic-user", password: String = "synthetic-secret", modified: Int64 = 13_000_000_000_000_100) -> BrowserPasswordRecord {
        BrowserPasswordRecord(primaryKey: .init(signonRealm: "https://fixture.invalid/", originURL: "https://fixture.invalid/login",
            usernameElement: "user", usernameValue: user, passwordElement: "pass"), passwordValue: password,
            dateCreated: 13_000_000_000_000_001, datePasswordModified: modified)
    }
    private func root() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("password-sync-event-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func modified(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
    private func waitFor(_ signals: Signals, above count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while signals.count <= count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func idleCyclesListNothingAndLocalEditsWakeAndConverge() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        let a = try BrowserPasswordSync(cache: .init(destination: root.appendingPathComponent("a"), key: key))
        let b = try BrowserPasswordSync(cache: .init(destination: root.appendingPathComponent("b"), key: key))
        defer { Task { await a.stop(); await b.stop() } }
        let signals = Signals()
        await a.setLocalChangeHandler { signals.fire() }
        let first = NotifyingPasswordStore(), second = NotifyingPasswordStore()
        try await first.add(row(), profileID: p)
        // First cycle: full scan and application (drops its observers, asks for a follow-up).
        let before = signals.count
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        #expect(signals.count > before)
        // Follow-up: re-subscribes and lists once; afterwards the store is not listed at all.
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        let lists = first.lists, sealed = try modified(root.appendingPathComponent("a"))
        for _ in 0..<5 { try await a.synchronize(store: first, profiles: [p], transport: cloud) }
        #expect(first.lists == lists)
        #expect(await a.listCalls == lists)
        #expect(try modified(root.appendingPathComponent("a")) == sealed)
        // A local edit notifies, wakes the runtime and is sent by the next cycle.
        let edit = row(password: "synthetic-new", modified: 13_000_000_000_000_200)
        let woken = signals.count
        try await first.update(edit, replacing: edit.primaryKey, profileID: p)
        try await waitFor(signals, above: woken)
        #expect(signals.count > woken)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        #expect(first.lists > lists)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        #expect(second.rows[p]?.first?.passwordValue == edit.passwordValue)
        // A remote edit reaches A without any local notification (fast path still applies it).
        var remote = edit; remote.passwordValue = "synthetic-remote"; remote.datePasswordModified = 13_000_000_000_000_300
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        try await second.update(remote, replacing: remote.primaryKey, profileID: p)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        #expect(first.rows[p]?.first?.passwordValue == remote.passwordValue)
        // Deletions converge both ways.
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        let removed = signals.count
        try await first.remove(remote.primaryKey, profileID: p)
        try await waitFor(signals, above: removed)
        try await a.synchronize(store: first, profiles: [p], transport: cloud)
        try await b.synchronize(store: second, profiles: [p], transport: cloud)
        #expect(first.rows[p]?.isEmpty == true && second.rows[p]?.isEmpty == true)
    }

    @Test func slowRescanCatchesAMissedNotification() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256), p = ProfileID(), cloud = BrowserPasswordSyncMemoryCloud()
        let a = try BrowserPasswordSync(cache: .init(destination: root.appendingPathComponent("a"), key: key), fullScanInterval: 600)
        defer { Task { await a.stop() } }
        let store = NotifyingPasswordStore(), reader = NotifyingPasswordStore()
        let start = Date()
        try await a.synchronize(store: store, profiles: [p], transport: cloud, now: start)
        try await a.synchronize(store: store, profiles: [p], transport: cloud, now: start.addingTimeInterval(1))
        store.muted = true
        try await store.add(row(), profileID: p)
        try await a.synchronize(store: store, profiles: [p], transport: cloud, now: start.addingTimeInterval(2))
        #expect(try await cloud.exchange([]).isEmpty)
        try await a.synchronize(store: store, profiles: [p], transport: cloud, now: start.addingTimeInterval(601))
        let b = try BrowserPasswordSync(cache: .init(destination: root.appendingPathComponent("b"), key: key))
        defer { Task { await b.stop() } }
        try await b.synchronize(store: reader, profiles: [p], transport: cloud)
        #expect(reader.rows[p]?.count == 1)
    }
}
