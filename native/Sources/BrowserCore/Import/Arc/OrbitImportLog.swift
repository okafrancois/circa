import Foundation
import OSLog

/// Every diagnostic the importer emits. Closed set of phases, error codes and counts: no case can
/// carry a URL, title, profile/Space/folder name or path, so logs stay free of personal content.
public enum ArcImportLogEvent: Sendable, Equatable {
    case preparing
    case snapshotCaptured(historyDatabases: Int)
    case parsed(spaces: Int, favorites: Int, pinned: Int, folders: Int, today: Int, archived: Int)
    case historyCounted(importable: Int, filtered: Int)
    case interruptedImportDetected
    case backupCreated
    case applied(added: Int, present: Int, removedBefore: Int)
    case saved
    case historyChunk(profile: Int, inserted: Int, processed: Int)
    case historySkipped(profile: Int)
    case completed(added: Int, historyInserted: Int)
    case cancelled
    case failed(ArcImportError)
    case failedUnexpectedly

    public var message: String {
        switch self {
        case .preparing: return "arc-import prepare"
        case let .snapshotCaptured(count): return "arc-import snapshot historyDatabases=\(count)"
        case let .parsed(spaces, favorites, pinned, folders, today, archived):
            return "arc-import parsed spaces=\(spaces) favorites=\(favorites) pinned=\(pinned) folders=\(folders) today=\(today) archived=\(archived)"
        case let .historyCounted(importable, filtered): return "arc-import history importable=\(importable) filtered=\(filtered)"
        case .interruptedImportDetected: return "arc-import interrupted-import-detected"
        case .backupCreated: return "arc-import backup-created"
        case let .applied(added, present, removed): return "arc-import applied added=\(added) present=\(present) previouslyRemoved=\(removed)"
        case .saved: return "arc-import saved"
        case let .historyChunk(profile, inserted, processed):
            return "arc-import history-chunk profile=\(profile) inserted=\(inserted) processed=\(processed)"
        case let .historySkipped(profile): return "arc-import history-skipped profile=\(profile)"
        case let .completed(added, history): return "arc-import completed added=\(added) historyInserted=\(history)"
        case .cancelled: return "arc-import cancelled"
        case let .failed(error): return "arc-import failed code=\(error)"
        case .failedUnexpectedly: return "arc-import failed code=unexpected"
        }
    }
}

public protocol ArcImportLogging: Sendable {
    func log(_ event: ArcImportLogEvent)
}

/// Unified logging, public only because every message is a fixed format with counts.
public struct ArcImportSystemLog: ArcImportLogging {
    private static let logger = Logger(subsystem: "local.orbit", category: "import")
    public init() {}
    public func log(_ event: ArcImportLogEvent) {
        Self.logger.info("\(event.message, privacy: .public)")
    }
}
