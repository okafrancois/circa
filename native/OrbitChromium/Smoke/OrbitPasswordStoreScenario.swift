import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation
import CryptoKit
import OrbitChromiumBridge

/// Hermetic bridge/store qualification. Only verdicts, never credentials, enter evidence.
@MainActor
enum OrbitPasswordStoreScenario {
    static func run(engine: ChromiumBrowserEngine, record: (String, String, [String: Any]) -> Void) async {
        func check(_ id: String, _ value: Bool) { record("password-store." + id, value ? "proven" : "failed", [:]) }
        guard let store = engine.passwordStore else { check("available", false); return }
        await syncRoundTrip(engine: engine, store: store, check: check)
        let profile = ProfileID(), other = ProfileID()
        do {
            check("empty", try await store.list(profileID: profile).isEmpty)
            let stream = try await store.changes(profileID: profile)
            var iterator = stream.makeAsyncIterator()
            var row = BrowserPasswordRecord(primaryKey: .init(signonRealm: "https://fixture.test/", originURL: "https://fixture.test/login",
                usernameElement: "user", usernameValue: "fixture🧪\0user", passwordElement: "pass"), actionURL: "https://fixture.test/submit",
                passwordValue: "Synthetic\0secret🔑", dateCreated: 13_000_000_000_000_001,
                dateLastUsed: 13_000_000_000_000_002, datePasswordModified: 13_000_000_000_000_003)
            try await store.add(row, profileID: profile)
            check("add-observed", await iterator.next() == .changed)
            let rows = try await store.list(profileID: profile)
            let value = rows.first
            check("round-trip", rows.count == 1 && value?.primaryKey == row.primaryKey && value?.passwordValue == row.passwordValue
                && value?.actionURL == row.actionURL && value?.dateCreated == row.dateCreated
                && value?.dateLastUsed == row.dateLastUsed && value?.datePasswordModified == row.datePasswordModified
                && value?.scheme == row.scheme && value?.blockedByUser == false)
            check("profile-isolation", try await store.list(profileID: other).isEmpty)
            do { try await store.add(row, profileID: profile); check("duplicate-conflict", false) }
            catch BrowserPasswordStoreError.conflict { check("duplicate-conflict", true) }
            row.passwordValue = "Synthetic-replaced"; row.datePasswordModified += 1
            try await store.update(row, replacing: row.primaryKey, profileID: profile)
            check("update-observed", await iterator.next() == .changed)
            check("update", try await store.list(profileID: profile).first?.passwordValue == row.passwordValue)
            let old = row.primaryKey
            row.primaryKey.usernameValue = "renamed"; row.primaryKey.originURL = "https://fixture.test/new-login"
            row.primaryKey.usernameElement = "new-user"; row.primaryKey.passwordElement = "new-pass"
            row.primaryKey.signonRealm = "https://new.fixture.test/"; row.scheme = 1
            try await store.update(row, replacing: old, profileID: profile)
            check("key-update-observed", await iterator.next() == .changed)
            let renamed = try await store.list(profileID: profile)
            check("key-update", renamed.count == 1 && renamed.first?.primaryKey == row.primaryKey && renamed.first?.scheme == 1)
            let blocked = BrowserPasswordRecord(primaryKey: .init(signonRealm: "https://never.fixture.test/",
                originURL: "https://never.fixture.test/", usernameElement: "", usernameValue: "", passwordElement: ""), blockedByUser: true)
            try await store.add(blocked, profileID: profile)
            check("blocklist-observed", await iterator.next() == .changed)
            try await store.remove(row.primaryKey, profileID: profile)
            check("remove-observed", await iterator.next() == .changed)
            let remaining = try await store.list(profileID: profile)
            check("blocklist-preserved", remaining.count == 1 && remaining.first?.primaryKey == blocked.primaryKey && remaining.first?.blockedByUser == true)
            do { try await store.update(row, replacing: old, profileID: profile); check("missing-conflict", false) }
            catch BrowserPasswordStoreError.conflict { check("missing-conflict", true) }
            let privateEngine = ChromiumBrowserEngine(persistence: .ephemeral, hostedWhenAvailable: true)
            let privateProfile = ProfileID()
            await privateEngine.profileReady(privateProfile)
            check("private-refused", privateEngine.passwordStore == nil && ACRPasswordStoreOpen(privateEngine.profileToken(for: privateProfile)) == 0)
            await privateEngine.shutdown()
            // A dedicated handle is closed with an outstanding read: exactly one cancellation.
            let handle = ACRPasswordStoreOpen(engine.profileToken(for: profile))
            check("second-handle", handle != 0)
            let cancelled: Int32 = await withCheckedContinuation { continuation in
                let box = Unmanaged.passRetained(CancellationProbe(continuation))
                let accepted = ACRPasswordStoreList(handle, { context, status, _, _ in
                    guard let context else { return }
                    Unmanaged<CancellationProbe>.fromOpaque(context).takeRetainedValue().continuation.resume(returning: status)
                }, box.toOpaque())
                if accepted == 1 { ACRPasswordStoreClose(handle) }
                else { box.takeRetainedValue().continuation.resume(returning: 0) }
            }
            check("pending-cancelled", cancelled == -2)
            try await store.remove(blocked.primaryKey, profileID: profile)
            check("final-empty", try await store.list(profileID: profile).isEmpty)
            let teardownHandle = ACRPasswordStoreOpen(engine.profileToken(for: profile))
            let revoked = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            revoked.initialize(to: 0)
            defer {
                ACRPasswordStoreClose(teardownHandle)
                revoked.deinitialize(count: 1); revoked.deallocate()
            }
            check("teardown-observer", ACRPasswordStoreObserve(teardownHandle, { context, event in
                context?.assumingMemoryBound(to: Int32.self).pointee = event
            }, revoked) == 1)
            try await engine.removeProfile(profile)
            let refused = ACRPasswordStoreList(teardownHandle, { _, _, _, _ in }, nil) == 0
            check("profile-teardown-revoked", revoked.pointee == 3 && refused)
            let closed = await iterator.next()
            let finished = await iterator.next()
            check("stream-closed", closed == .closed && finished == nil)
            try await engine.removeProfile(other)
        } catch {
            // Error values and credential contents are intentionally not interpolated.
            check("unexpected-error", false)
        }
    }

    private static func syncRoundTrip(engine: ChromiumBrowserEngine, store: any BrowserPasswordStore,
                                      check: (String, Bool) -> Void) async {
        guard let option = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--orbit-data-root=") }) else {
            check("sync-confinement", false); return
        }
        let root = URL(fileURLWithPath: String(option.dropFirst("--orbit-data-root=".count))).appendingPathComponent("PasswordSyncSmoke")
        let logical = ProfileID(), localA = ProfileID(), localB = ProfileID()
        let key = SymmetricKey(size: .bits256)
        do {
            let a = try BrowserPasswordSync(cache: .init(destination: root.appendingPathComponent("a.sealed"), key: key))
            let b = try BrowserPasswordSync(cache: .init(destination: root.appendingPathComponent("b.sealed"), key: key))
            defer { a.stop(); b.stop() }
            let first = SmokeMappedPasswordStore(store: store, local: localA), second = SmokeMappedPasswordStore(store: store, local: localB)
            let cloud = BrowserPasswordSyncMemoryCloud()
            var row = BrowserPasswordRecord(primaryKey: .init(signonRealm: "https://sync-fixture.invalid/", originURL: "https://sync-fixture.invalid/login",
                usernameElement: "user", usernameValue: "synthetic-sync-user", passwordElement: "pass"),
                passwordValue: "synthetic-sync-secret", dateCreated: 13_000_000_000_000_001, datePasswordModified: 13_000_000_000_000_002)
            try await first.add(row, profileID: logical)
            try await a.synchronize(store: first, profiles: [logical], transport: cloud)
            try await b.synchronize(store: second, profiles: [logical], transport: cloud)
            let fetched = try await second.list(profileID: logical)
            check("sync-engine-add", fetched.count == 1 && fetched.first?.passwordValue == row.passwordValue)
            let oldKey = row.primaryKey
            row.primaryKey.usernameValue = "synthetic-sync-renamed"; row.passwordValue = "synthetic-sync-updated"; row.datePasswordModified += 100
            try await second.update(row, replacing: oldKey, profileID: logical)
            try await b.synchronize(store: second, profiles: [logical], transport: cloud)
            try await a.synchronize(store: first, profiles: [logical], transport: cloud)
            let updated = try await first.list(profileID: logical)
            check("sync-engine-update", updated.count == 1 && updated.first?.primaryKey == row.primaryKey && updated.first?.passwordValue == row.passwordValue)
            try await first.remove(row.primaryKey, profileID: logical)
            try await a.synchronize(store: first, profiles: [logical], transport: cloud)
            try await b.synchronize(store: second, profiles: [logical], transport: cloud)
            check("sync-engine-delete", try await second.list(profileID: logical).isEmpty)
            var clean = true
            for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                let bytes = try Data(contentsOf: file)
                for secret in ["synthetic-sync-user", "synthetic-sync-secret", "sync-fixture.invalid", "synthetic-sync-renamed", "synthetic-sync-updated"] {
                    if bytes.range(of: Data(secret.utf8)) != nil { clean = false }
                }
            }
            check("sync-cache-sealed", clean)
            try await engine.removeProfile(localA); try await engine.removeProfile(localB)
            try FileManager.default.removeItem(at: root)
        } catch { check("sync-unexpected-error", false) }
    }

}

private final class CancellationProbe {
    let continuation: CheckedContinuation<Int32, Never>
    init(_ continuation: CheckedContinuation<Int32, Never>) { self.continuation = continuation }
}


@MainActor
private final class SmokeMappedPasswordStore: BrowserPasswordStore {
    let store: any BrowserPasswordStore
    let local: ProfileID
    init(store: any BrowserPasswordStore, local: ProfileID) { self.store = store; self.local = local }
    func list(profileID: ProfileID) async throws -> [BrowserPasswordRecord] { try await store.list(profileID: local) }
    func add(_ row: BrowserPasswordRecord, profileID: ProfileID) async throws { try await store.add(row, profileID: local) }
    func update(_ row: BrowserPasswordRecord, replacing key: BrowserPasswordKey, profileID: ProfileID) async throws { try await store.update(row, replacing: key, profileID: local) }
    func remove(_ key: BrowserPasswordKey, profileID: ProfileID) async throws { try await store.remove(key, profileID: local) }
    func changes(profileID: ProfileID) async throws -> AsyncStream<BrowserPasswordStoreChange> { try await store.changes(profileID: local) }
}
