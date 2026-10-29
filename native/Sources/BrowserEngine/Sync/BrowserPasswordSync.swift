import BrowserCore
import Foundation

public enum BrowserPasswordSyncSchema {
    public static let zone = "OrbitPasswords"
    public static let recordType = "OrbitPasswordV1"
    public static let field = "credential"
}

/// This entire value is sensitive. Only the opaque UUID is used outside encrypted storage.
public struct BrowserPasswordSyncEntry: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    struct Stamp: Codable, Sendable, Equatable, Comparable {
        var time: Int64
        var device: String
        static func < (a: Self, b: Self) -> Bool { (a.time, a.device) < (b.time, b.device) }
    }
    struct Field: Codable, Sendable, Equatable {
        var bytes: Data
        var stamp: Stamp
    }
    public let id: UUID
    public let profileID: ProfileID
    var version = 1
    var aliases: Set<UUID>
    // Historical match keys let an offline first-time replica find an edited credential.
    var matches: Set<[String]>
    var fields: [String: Field]
    var life: Stamp
    var deleted = false
    public var description: String { "BrowserPasswordSyncEntry(<redacted>)" }
    public var debugDescription: String { description }

    static func encodeValue<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func values(_ row: BrowserPasswordRecord) throws -> [String: Data] {
        let k = row.primaryKey
        return try ["identity": encodeValue([k.signonRealm, k.originURL, k.usernameElement, k.usernameValue, k.passwordElement, String(row.scheme)]),
            "password": encodeValue(row.passwordValue), "action": encodeValue(row.actionURL), "created": encodeValue(row.dateCreated),
            "used": encodeValue(row.dateLastUsed), "modified": encodeValue(row.datePasswordModified), "blocked": encodeValue(row.blockedByUser)]
    }
    static func match(_ row: BrowserPasswordRecord) -> [String] {
        [row.primaryKey.signonRealm, row.primaryKey.usernameElement, row.primaryKey.usernameValue, String(row.scheme), String(row.blockedByUser)]
    }
    func row() throws -> BrowserPasswordRecord {
        func value<T: Decodable>(_ name: String) throws -> T {
            guard let bytes = fields[name]?.bytes else { throw BrowserSyncError.invalidRecord }
            return try JSONDecoder().decode(T.self, from: bytes)
        }
        let identity: [String] = try value("identity")
        guard identity.count == 6, let scheme = Int32(identity[5]), (0...4).contains(scheme) else { throw BrowserSyncError.invalidRecord }
        return try BrowserPasswordRecord(primaryKey: .init(signonRealm: identity[0], originURL: identity[1],
            usernameElement: identity[2], usernameValue: identity[3], passwordElement: identity[4]),
            actionURL: value("action"), passwordValue: value("password"), dateCreated: value("created"),
            dateLastUsed: value("used"), datePasswordModified: value("modified"), blockedByUser: value("blocked"), scheme: scheme)
    }
    func owns(_ value: BrowserPasswordRecord) throws -> Bool {
        let current = try row()
        let key = Self.match(value)
        return Self.match(current) == key || (matches.contains(key) && current.dateCreated != 0 && current.dateCreated == value.dateCreated)
    }
    public func validate() throws {
        var bytes = try Self.encodeValue(self)
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        guard version == 1, aliases.contains(id), !matches.isEmpty, matches.allSatisfy({ $0.count == 5 }),
              fields.count == 7, bytes.count < 512 * 1024 else { throw BrowserSyncError.invalidRecord }
        _ = try row()
    }
    mutating func merge(_ other: Self) throws {
        try other.validate()
        guard profileID == other.profileID else { throw BrowserSyncError.invalidRecord }
        aliases.formUnion(other.aliases); matches.formUnion(other.matches)
        for (name, field) in other.fields {
            if let old = fields[name], !(old.stamp < field.stamp || (old.stamp == field.stamp && old.bytes.lexicographicallyPrecedes(field.bytes))) { continue }
            fields[name] = field
        }
        if life < other.life || (life == other.life && other.deleted) { life = other.life; deleted = other.deleted }
    }
    /// Deterministic first-time deduplication, including transitive aliases and identity edits.
    public static func merged(_ entries: [Self]) throws -> [Self] {
        struct Key: Hashable { var profile: ProfileID; var kind: Int; var parts: [String] }
        let ordered = entries.sorted { $0.id.uuidString < $1.id.uuidString }
        var parents = Array(ordered.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parents[index] != index { index = parents[index] }
            return index
        }
        var owners: [Key: Int] = [:]
        for (index, entry) in ordered.enumerated() {
            try entry.validate()
            let row = try entry.row()
            var keys = entry.aliases.map { Key(profile: entry.profileID, kind: 0, parts: [$0.uuidString]) }
            keys.append(Key(profile: entry.profileID, kind: 1, parts: Self.match(row)))
            if row.dateCreated != 0 {
                keys += entry.matches.map { Key(profile: entry.profileID, kind: 2, parts: $0 + [String(row.dateCreated)]) }
            }
            for key in keys {
                if let prior = owners[key] {
                    let a = root(index), b = root(prior)
                    parents[max(a, b)] = min(a, b)
                } else { owners[key] = index }
            }
        }
        var groups: [Int: Self] = [:]
        for (index, entry) in ordered.enumerated() {
            let group = root(index)
            if var current = groups[group] { try current.merge(entry); groups[group] = current }
            else { groups[group] = entry }
        }
        return groups.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

public protocol BrowserPasswordSyncTransport: Sendable {
    func exchange(_ entries: [BrowserPasswordSyncEntry]) async throws -> [BrowserPasswordSyncEntry]
    func stop() async
}

public actor BrowserPasswordSyncMemoryCloud: BrowserPasswordSyncTransport {
    private var entries: [BrowserPasswordSyncEntry] = []
    public var schemaAvailable: Bool
    public init(schemaAvailable: Bool = true) { self.schemaAvailable = schemaAvailable }
    public func exchange(_ incoming: [BrowserPasswordSyncEntry]) throws -> [BrowserPasswordSyncEntry] {
        guard schemaAvailable else { throw BrowserSyncError.unavailable }
        entries = try BrowserPasswordSyncEntry.merged(entries + incoming)
        return entries
    }
    public func stop() {}
}

/// Engine store is the local authority. The durable outbox/baseline is always AES-GCM sealed.
/// No decrypted credential, matching key or CKSyncEngine serialization is written to disk.
public actor BrowserPasswordSync {
    private struct Binding: Codable, Sendable {
        var id: UUID
        var fields: [String: Data]
    }
    private struct State: Codable, Sendable {
        var device = UUID().uuidString
        var entries: [BrowserPasswordSyncEntry] = []
        var baseline: [ProfileID: [Binding]] = [:]
    }
    private var state: State
    private let cache: BrowserPasswordSyncCache
    private var stopped = false
    private var running = false
    private var invalidated: Set<ProfileID> = []
    private var observers: [ProfileID: Task<Void, Never>] = [:]

    public init(cache: BrowserPasswordSyncCache) throws {
        self.cache = cache
        state = State()
    }
    public func stop() {
        stopped = true
        for task in observers.values { task.cancel() }
        observers.removeAll()
        // Release Swift strings promptly. Their copies cannot be reliably wiped.
        state = State()
    }
    deinit { for task in observers.values { task.cancel() } }

    public func synchronize(store: any BrowserPasswordStore, profiles: [ProfileID], isPrivate: Bool = false,
                            transport: any BrowserPasswordSyncTransport, now: Date = Date(),
                            admitted: @MainActor () async throws -> Void = {}) async throws {
        guard !isPrivate, !stopped, !running else { return }
        running = true
        // Keep decoded credentials only for this exchange/application, never between cycles.
        defer { state = State(); running = false }
        state = try cache.load(State.self) ?? State()
        try await admitted()
        for profile in observers.keys where !profiles.contains(profile) { observers.removeValue(forKey: profile)?.cancel() }
        for profile in profiles {
            invalidated.remove(profile)
            if observers[profile] == nil {
                let stream = try await store.changes(profileID: profile)
                // Secret-free notifications schedule a fresh list on the next bounded cycle.
                observers[profile] = Task { [weak self] in
                    for await change in stream {
                        guard !Task.isCancelled, change != .closed, let self, await self.invalidate(profile) else { break }
                    }
                }
            }
            try capture(try await store.list(profileID: profile), profile: profile, now: now)
        }
        try cache.save(state)
        let incoming = try await transport.exchange(state.entries)
        try Task.checkCancellation(); try await admitted()
        guard !stopped else { return }
        // Recapture edits that occurred during the exchange, before admitting remote values.
        for profile in profiles { try capture(try await store.list(profileID: profile), profile: profile, now: Date()) }
        state.entries = try BrowserPasswordSyncEntry.merged(state.entries + incoming)
        try cache.save(state)
        for profile in profiles {
            try await admitted()
            try await apply(store, profile: profile, admitted: admitted)
        }
        // Drain notifications received during admission/application without acknowledging
        // an unseen local edit. Periodic full lists also cover missed notifications.
        for profile in profiles where invalidated.remove(profile) != nil {
            try capture(try await store.list(profileID: profile), profile: profile, now: Date())
        }
        try cache.save(state)
    }

    private func invalidate(_ profile: ProfileID) -> Bool {
        guard !stopped else { return false }
        invalidated.insert(profile)
        return true
    }

    private func capture(_ rows: [BrowserPasswordRecord], profile: ProfileID, now: Date) throws {
        let old = state.baseline[profile] ?? []
        var remaining = old
        var bindings: [Binding] = []
        let time = Int64(now.timeIntervalSince1970 * 1_000_000) + 11_644_473_600_000_000
        let rowValues = try rows.map { try BrowserPasswordSyncEntry.values($0) }
        for (offset, row) in rows.enumerated() {
            let values = rowValues[offset]
            var index = remaining.firstIndex { $0.fields["identity"] == values["identity"] }
            if index == nil {
                // R10 omits durable row IDs. Admit a key edit only with unique, unchanged
                // creation/form metadata and exactly one replacement; ambiguity never guesses.
                let candidates = remaining.indices.filter { i in
                    guard let bytes = remaining[i].fields["identity"], let key = try? JSONDecoder().decode([String].self, from: bytes), key.count == 6 else { return false }
                    return row.dateCreated != 0 && remaining[i].fields["created"] == values["created"]
                        && key[0] == row.primaryKey.signonRealm && key[1] == row.primaryKey.originURL
                        && key[2] == row.primaryKey.usernameElement && key[4] == row.primaryKey.passwordElement && key[5] == String(row.scheme)
                        && !rowValues.contains(where: { $0["identity"] == bytes })
                }
                if row.dateCreated == 0 && remaining.contains(where: { binding in
                    guard let bytes = binding.fields["identity"], let old = try? JSONDecoder().decode([String].self, from: bytes), old.count == 6 else { return false }
                    return old[0] == row.primaryKey.signonRealm && old[1] == row.primaryKey.originURL
                        && old[2] == row.primaryKey.usernameElement && old[4] == row.primaryKey.passwordElement
                        && !rowValues.contains(where: { $0["identity"] == bytes })
                }) { throw BrowserSyncError.localChange }
                guard candidates.count <= 1 else { throw BrowserSyncError.localChange }
                if candidates.count == 1 {
                    let count = rows.filter { $0.dateCreated == row.dateCreated && $0.primaryKey.signonRealm == row.primaryKey.signonRealm
                        && $0.primaryKey.originURL == row.primaryKey.originURL }.count
                    guard count == 1 else { throw BrowserSyncError.localChange }
                    index = candidates[0]
                }
            }
            let prior = index.map { remaining.remove(at: $0) }
            let id = prior?.id ?? UUID()
            let existing = state.entries.firstIndex { $0.profileID == profile && $0.aliases.contains(id) }
            let modified = row.datePasswordModified > 0 ? row.datePasswordModified : row.dateCreated > 0 ? row.dateCreated : time
            let readded = prior == nil && state.baseline[profile] != nil && state.entries.contains {
                $0.profileID == profile && $0.deleted && ((try? $0.owns(row)) == true)
            }
            let initialStamp = BrowserPasswordSyncEntry.Stamp(time: readded ? time : modified, device: state.device)
            var entry = existing.map { state.entries[$0] } ?? BrowserPasswordSyncEntry(id: id, profileID: profile,
                aliases: [id], matches: [BrowserPasswordSyncEntry.match(row)], fields: [:], life: initialStamp)
            for (name, bytes) in values where prior?.fields[name] != bytes {
                // Password/time travel atomically by the engine's password modification clock.
                let stamp = BrowserPasswordSyncEntry.Stamp(time: name == "password" || name == "modified" || prior == nil ? modified : time, device: state.device)
                entry.fields[name] = .init(bytes: bytes, stamp: stamp)
            }
            entry.matches.insert(BrowserPasswordSyncEntry.match(row))
            if let existing { state.entries[existing] = entry } else { state.entries.append(entry) }
            bindings.append(Binding(id: entry.id, fields: values))
        }
        for binding in remaining {
            if let i = state.entries.firstIndex(where: { $0.profileID == profile && $0.aliases.contains(binding.id) }) {
                state.entries[i].deleted = true
                state.entries[i].life = .init(time: time, device: state.device)
            }
        }
        state.baseline[profile] = bindings
        state.entries = try BrowserPasswordSyncEntry.merged(state.entries)
    }

    private func apply(_ store: any BrowserPasswordStore, profile: ProfileID,
                       admitted: @MainActor () async throws -> Void) async throws {
        // Refuse to overwrite an edit made since the merge's authoritative capture.
        let actual = try await store.list(profileID: profile)
        var expected = state.baseline[profile] ?? []
        let values = try actual.map { try BrowserPasswordSyncEntry.values($0) }
        guard values.count == expected.count, values.allSatisfy({ v in expected.contains { $0.fields == v } }) else {
            try capture(actual, profile: profile, now: Date()); try cache.save(state)
            throw BrowserSyncError.localChange
        }
        // Ignore our own notifications until the authoritative post-write list is acknowledged.
        observers.removeValue(forKey: profile)?.cancel()
        for entry in state.entries where entry.profileID == profile {
            try Task.checkCancellation()
            guard !stopped else { return }
            let desired = try entry.row()
            let bound = expected.filter { entry.aliases.contains($0.id) }
            // Unchanged credentials need no engine write, network admission or disk flush.
            if entry.deleted && bound.isEmpty { continue }
            if !entry.deleted, bound.count == 1, bound[0].fields == (try BrowserPasswordSyncEntry.values(desired)) { continue }
            try await admitted()
            let rows = try await store.list(profileID: profile)
            try Task.checkCancellation()
            guard !stopped else { return }
            let currentValues = try rows.map { try BrowserPasswordSyncEntry.values($0) }
            guard currentValues.count == expected.count, currentValues.allSatisfy({ v in expected.contains { $0.fields == v } }) else {
                try capture(rows, profile: profile, now: Date()); try cache.save(state)
                throw BrowserSyncError.localChange
            }
            let candidates = try rows.filter { try entry.owns($0) }
            if entry.deleted {
                for row in candidates { try await store.remove(row.primaryKey, profileID: profile) }
            } else if let current = candidates.first(where: { $0.primaryKey == desired.primaryKey }) ?? candidates.first {
                if try BrowserPasswordSyncEntry.values(current) != BrowserPasswordSyncEntry.values(desired) {
                    try await store.update(desired, replacing: current.primaryKey, profileID: profile)
                }
                for row in candidates where row.primaryKey != current.primaryKey && row.primaryKey != desired.primaryKey {
                    try await store.remove(row.primaryKey, profileID: profile)
                }
            } else { try await store.add(desired, profileID: profile) }
            let candidateValues = try candidates.map { try BrowserPasswordSyncEntry.values($0) }
            expected.removeAll { binding in candidateValues.contains(binding.fields) }
            if !entry.deleted { expected.append(try Binding(id: entry.id, fields: BrowserPasswordSyncEntry.values(desired))) }
            state.baseline[profile] = expected
            try cache.save(state)
        }
        let rows = try await store.list(profileID: profile)
        let finalValues = try rows.map { try BrowserPasswordSyncEntry.values($0) }
        guard finalValues.count == expected.count, finalValues.allSatisfy({ v in expected.contains { $0.fields == v } }) else {
            try capture(rows, profile: profile, now: Date()); try cache.save(state)
            throw BrowserSyncError.localChange
        }
        state.baseline[profile] = try rows.compactMap { row in
            guard let entry = try state.entries.first(where: { try $0.profileID == profile && !$0.deleted && $0.owns(row) }) else { return nil }
            return try Binding(id: entry.id, fields: BrowserPasswordSyncEntry.values(row))
        }
    }
}
