import CloudKit
import Foundation

/// Organization and history payloads travel in CloudKit's end-to-end encrypted values, so the
/// CloudKit operator never sees URLs, titles or settings. Builds before the sealed format wrote
/// a plaintext `payload` field: it is still read, and every save clears it on the server.
///
/// Mixed versions: an older build cannot read a sealed record. Its organization or history
/// zone then reports sync as unavailable until it updates; nothing is written in plaintext again.
public enum BrowserSyncSealedPayload {
    public static let field = "sealedPayload"
    public static let legacyField = "payload"

    /// The sealed bytes, or the legacy plaintext bytes written by an older build.
    public static func read(_ record: CKRecord) -> Data? {
        record.encryptedValues[field] as? Data ?? record[legacyField] as? Data
    }

    /// The record still carries a plaintext copy on the server and must be saved again.
    public static func isLegacy(_ record: CKRecord) -> Bool {
        record[legacyField] != nil
    }

    /// Writes the sealed value and deletes the plaintext field (a nil value is a changed key,
    /// so the next save removes it server-side even from a record rebuilt from system fields).
    public static func write(_ bytes: Data, to record: CKRecord) {
        record.encryptedValues[field] = bytes as CKRecordValue
        record[legacyField] = nil
    }
}

/// One-time rewrite of the records this Mac already cached in plaintext form. The marker sits
/// next to the transport cache, outside its persisted state, and is removed with the caches.
struct BrowserSyncSealedRewrite: Sendable {
    let marker: URL
    private(set) var isDone: Bool

    init(cache destination: URL) {
        marker = destination.appendingPathExtension("sealed-v1")
        isDone = FileManager.default.fileExists(atPath: marker.path)
    }

    mutating func markDone() throws {
        guard !isDone else { return }
        try BrowserPermissionFile.save(Data("1".utf8), to: marker, maximumBytes: 16)
        isDone = true
    }
}
