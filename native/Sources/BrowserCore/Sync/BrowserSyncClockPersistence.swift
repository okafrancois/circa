import CryptoKit
import Foundation

/// Each barrier replaces exactly one file. Content changes commit the complete legacy
/// replica (including tick); clock-only changes commit a record bound to those exact bytes.
/// Consequently no intermediate state combines a new clock with uncommitted content.
struct BrowserSyncClockPersistence: Sendable {
    private var content: Data?
    private var replicaDigest: Data?
    private var tick: Int64?
    private var destination: URL?
    private(set) var writes = 0
    private(set) var bytesWritten = 0
    private(set) var replicaWrites = 0

    static func clockURL(_ destination: URL) -> URL { destination.appendingPathExtension("clock") }

    private static func contentBytes(_ state: BrowserSyncState) throws -> Data {
        var normalized = state
        normalized.replica.tick = 0
        return try BrowserSyncReplica.encodeValue(normalized)
    }

    // 32-byte replica digest, 8-byte big-endian tick, 32-byte integrity digest.
    // The binding also rejects stale records after migration, replacement or device reset.
    static func loadTick(for replica: Data, at destination: URL) -> Int64? {
        guard let bytes = try? BrowserPermissionFile.load(clockURL(destination), maximumBytes: 72),
              bytes.count == 72,
              bytes.prefix(32) == Data(SHA256.hash(data: replica)),
              bytes.suffix(32) == Data(SHA256.hash(data: bytes.prefix(40))) else { return nil }
        let value = bytes[32..<40].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int64(exactly: value)
    }

    init(state: BrowserSyncState, destination: URL) {
        // Seed only from a complete reload equal to the caller's state. This avoids a
        // full rewrite on restart without trusting arbitrary in-memory initialization.
        if let bytes = try? BrowserPermissionFile.load(destination, maximumBytes: 64 * 1024 * 1024),
           let loaded = try? BrowserSyncState.load(destination),
           let expected = try? BrowserSyncReplica.encodeValue(state),
           let actual = try? BrowserSyncReplica.encodeValue(loaded), expected == actual {
            content = try? Self.contentBytes(state)
            replicaDigest = Data(SHA256.hash(data: bytes))
            // A previous process may have died after rename but before directory
            // sync. Force the first barrier to synchronize this directory again,
            // using a tiny clock write even when the reloaded state is unchanged.
            tick = nil
            self.destination = destination
        }
    }

    mutating func save(_ state: BrowserSyncState, to destination: URL,
                       write: (Data, URL, Int) throws -> Void = { bytes, url, limit in
                           try BrowserPermissionFile.save(bytes, to: url, maximumBytes: limit)
                       }) throws {
        let next = try Self.contentBytes(state)
        let clockOnly = content == next && self.destination == destination && replicaDigest != nil
        // Match the legacy full-state size limit even when only its clock changed.
        guard next.count - 1 + String(state.replica.tick).utf8.count <= 64 * 1024 * 1024 else {
            throw BrowserPermissionFile.Failure.tooLarge
        }
        if clockOnly && tick == state.replica.tick { return }
        let bytes: Data, target: URL, digest: Data
        if clockOnly, let currentDigest = replicaDigest {
            digest = currentDigest
            var value = UInt64(state.replica.tick).bigEndian
            var record = digest
            withUnsafeBytes(of: &value) { record.append(contentsOf: $0) }
            record.append(contentsOf: SHA256.hash(data: record))
            bytes = record
            target = Self.clockURL(destination)
        } else {
            bytes = try BrowserSyncReplica.encodeValue(state)
            digest = Data(SHA256.hash(data: bytes))
            target = destination
        }
        // A failed write, even after rename, must be retried durably. Do not seed
        // from the filesystem again after an uncertain barrier in this writer.
        content = nil; replicaDigest = nil; tick = nil; self.destination = nil
        try write(bytes, target, clockOnly ? 72 : 64 * 1024 * 1024)
        content = next; replicaDigest = digest; tick = state.replica.tick
        self.destination = destination
        writes += 1; bytesWritten += bytes.count
        if !clockOnly { replicaWrites += 1 }
    }
}
