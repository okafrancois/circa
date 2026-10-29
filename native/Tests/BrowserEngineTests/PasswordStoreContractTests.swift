import BrowserCore
import BrowserEngine
import Testing

/// In-memory test double; production credentials always remain in the engine store.
@MainActor
private final class MockPasswordStore: BrowserPasswordStore {
    var rows: [ProfileID: [BrowserPasswordKey: BrowserPasswordRecord]] = [:]
    var listeners: [ProfileID: [AsyncStream<BrowserPasswordStoreChange>.Continuation]] = [:]
    func list(profileID: ProfileID) async throws -> [BrowserPasswordRecord] { Array(rows[profileID, default: [:]].values) }
    func add(_ record: BrowserPasswordRecord, profileID: ProfileID) async throws {
        guard rows[profileID]?[record.primaryKey] == nil else { throw BrowserPasswordStoreError.conflict }
        rows[profileID, default: [:]][record.primaryKey] = record; changed(profileID)
    }
    func update(_ record: BrowserPasswordRecord, replacing key: BrowserPasswordKey, profileID: ProfileID) async throws {
        guard rows[profileID]?[key] != nil,
              key == record.primaryKey || rows[profileID]?[record.primaryKey] == nil else { throw BrowserPasswordStoreError.conflict }
        rows[profileID]?[key] = nil; rows[profileID]?[record.primaryKey] = record; changed(profileID)
    }
    func remove(_ key: BrowserPasswordKey, profileID: ProfileID) async throws {
        guard rows[profileID]?[key] != nil else { throw BrowserPasswordStoreError.conflict }
        rows[profileID]?[key] = nil; changed(profileID)
    }
    func changes(profileID: ProfileID) async throws -> AsyncStream<BrowserPasswordStoreChange> {
        AsyncStream { listeners[profileID, default: []].append($0) }
    }
    private func changed(_ profileID: ProfileID) { listeners[profileID, default: []].forEach { $0.yield(.changed) } }
}

@Suite("Password store contract")
@MainActor
struct PasswordStoreContractTests {
    @Test("A consumer can reconcile key edits, blocklists and profile isolation")
    func reconciliation() async throws {
        let store: any BrowserPasswordStore = MockPasswordStore()
        let first = ProfileID(), second = ProfileID()
        var record = BrowserPasswordRecord(primaryKey: .init(signonRealm: "https://fixture.test/", originURL: "https://fixture.test/login",
            usernameElement: "user", usernameValue: "fixture", passwordElement: "pass"), passwordValue: "Synthetic\0secret🔑",
            dateCreated: 13_000_000_000_000_001, dateLastUsed: 13_000_000_000_000_002, datePasswordModified: 13_000_000_000_000_003)
        let stream = try await store.changes(profileID: first)
        var events = stream.makeAsyncIterator()
        try await store.add(record, profileID: first)
        #expect(await events.next() == .changed)
        #expect(try await store.list(profileID: second).isEmpty)
        let original = record.primaryKey
        record.primaryKey.usernameValue = "renamed"
        try await store.update(record, replacing: original, profileID: first)
        #expect(await events.next() == .changed)
        let saved = try #require(try await store.list(profileID: first).first)
        #expect(saved.primaryKey == record.primaryKey)
        #expect(saved.passwordValue == record.passwordValue)
        #expect(saved.dateCreated == record.dateCreated)
        record.primaryKey.usernameValue = ""; record.blockedByUser = true; record.passwordValue = ""
        try await store.add(record, profileID: first)
        try await store.remove(saved.primaryKey, profileID: first)
        let remaining = try await store.list(profileID: first)
        #expect(remaining.count == 1 && remaining.first?.blockedByUser == true)
        await #expect(throws: BrowserPasswordStoreError.conflict) { try await store.remove(original, profileID: first) }
    }

    @Test("Credential descriptions redact identity and password")
    func redaction() {
        let row = BrowserPasswordRecord(primaryKey: .init(signonRealm: "sensitive", originURL: "sensitive", usernameElement: "sensitive",
            usernameValue: "sensitive", passwordElement: "sensitive"), passwordValue: "sensitive")
        #expect(!String(describing: row).contains("sensitive"))
        #expect(!String(reflecting: row).contains("sensitive"))
    }
}
