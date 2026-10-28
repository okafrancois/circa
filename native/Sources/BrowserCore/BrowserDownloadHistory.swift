import Foundation

/// Durable terminal metadata only. Engine handles, source URLs and resume data never enter history.
public struct BrowserDownloadHistoryRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let profileID: ProfileID
    public let filename: String
    public let state: BrowserDownloadState
    public let receivedBytes: Int64
    public let totalBytes: Int64?
    public let destinationURL: URL?
    public let failure: BrowserDownloadFailure?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(_ snapshot: BrowserDownloadSnapshot) {
        id = snapshot.key.id
        profileID = snapshot.owner.profileID
        filename = snapshot.suggestedFilename
        state = snapshot.state
        receivedBytes = snapshot.receivedBytes
        totalBytes = snapshot.totalBytes
        destinationURL = snapshot.destinationURL
        failure = snapshot.failure
        startedAt = snapshot.startedAt
        completedAt = snapshot.completedAt
    }

    public var isValid: Bool {
        state.isTerminal && receivedBytes >= 0 && (totalBytes.map { $0 >= 0 } ?? true)
            && (destinationURL.map { $0.isFileURL && ($0.path as NSString).isAbsolutePath } ?? true)
            && (state != .failed || failure != nil)
    }
}

/// Atomic, private per-session history. A damaged or future document is never overwritten on load.
public final class BrowserDownloadHistoryStore {
    private struct Document: Codable { var version = 1; var records: [BrowserDownloadHistoryRecord] }
    public private(set) var records: [BrowserDownloadHistoryRecord]
    private let destination: URL

    public init(destination: URL) throws {
        self.destination = destination
        if FileManager.default.fileExists(atPath: destination.path) {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: destination))
            guard document.version == 1, document.records.allSatisfy(\.isValid),
                  Set(document.records.map(\.id)).count == document.records.count else {
                throw BrowserDownloadError.invalidUpdate
            }
            records = document.records
        } else { records = [] }
    }

    public func save(_ records: [BrowserDownloadHistoryRecord]) throws {
        guard records != self.records else { return }
        guard records.allSatisfy(\.isValid), Set(records.map(\.id)).count == records.count else {
            throw BrowserDownloadError.invalidUpdate
        }
        let data = try JSONEncoder().encode(Document(records: records))
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        self.records = records
    }
}
