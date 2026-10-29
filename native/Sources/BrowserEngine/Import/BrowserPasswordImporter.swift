import BrowserCore
import Foundation

public struct BrowserPasswordImportCounts: Codable, Sendable, Equatable {
    public var imported = 0
    public var alreadyPresent = 0
    public var conflicts = 0
    public var unsupported = 0
    public var unrepresentedNotes = 0
    public var unrepresentedOTP = 0
    public var unrepresentedPasskeys = 0
    public init() {}
}

/// Adds only missing composite identities. Retrying after cancellation re-lists first, because a
/// cancelled bridge call may already have committed. Existing credentials are never overwritten.
@MainActor
public enum BrowserPasswordImporter {
    public static func apply(_ passwords: [ImportedBrowserPassword], to store: any BrowserPasswordStore,
                             profileID: ProfileID) async throws -> BrowserPasswordImportCounts {
        var existing = Dictionary(try await store.list(profileID: profileID).map { ($0.primaryKey, $0) }, uniquingKeysWith: { first, _ in first })
        var counts = BrowserPasswordImportCounts()
        for password in passwords {
            try Task.checkCancellation()
            let record = BrowserPasswordRecord(primaryKey: .init(signonRealm: password.realm, originURL: password.origin,
                usernameElement: password.usernameElement, usernameValue: password.username, passwordElement: password.passwordElement),
                actionURL: password.action, passwordValue: password.password, dateCreated: password.created, dateLastUsed: password.lastUsed,
                datePasswordModified: password.modified, blockedByUser: password.blocked, scheme: password.scheme)
            if let present = existing[record.primaryKey] {
                if present.passwordValue == record.passwordValue && present.blockedByUser == record.blockedByUser && present.scheme == record.scheme {
                    counts.alreadyPresent += 1
                } else { counts.conflicts += 1 }
            } else {
                try await store.add(record, profileID: profileID)
                existing[record.primaryKey] = record; counts.imported += 1
            }
        }
        let verified = Dictionary(try await store.list(profileID: profileID).map { ($0.primaryKey, $0) }, uniquingKeysWith: { first, _ in first })
        guard existing.allSatisfy({ key, value in
            verified[key]?.passwordValue == value.passwordValue && verified[key]?.blockedByUser == value.blockedByUser && verified[key]?.scheme == value.scheme
        }) else { throw BrowserAuthenticationImportError.verificationFailed }
        return counts
    }
    public static func importCSV(_ data: Data, to store: any BrowserPasswordStore, profileID: ProfileID) async throws -> BrowserPasswordImportCounts {
        let read = try BrowserPasswordCSV.read(data)
        var counts = try await apply(read.passwords, to: store, profileID: profileID)
        counts.unsupported = read.unsupported; counts.unrepresentedNotes = read.unrepresentedNotes
        counts.unrepresentedOTP = read.unrepresentedOTP; counts.unrepresentedPasskeys = read.unrepresentedPasskeys
        return counts
    }
}
