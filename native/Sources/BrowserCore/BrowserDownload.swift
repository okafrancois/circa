import Foundation

/// A download keeps its original profile even after its source occurrence or window disappears.
/// These source identifiers are provenance values, never leases on a living UI object.
public struct BrowserDownloadOwner: Equatable, Sendable {
    public let profileID: ProfileID
    public let sourceWindowID: WindowID?
    public let sourceOccurrenceID: TabOccurrenceID?

    public init(
        profileID: ProfileID, sourceWindowID: WindowID? = nil,
        sourceOccurrenceID: TabOccurrenceID? = nil
    ) {
        self.profileID = profileID
        self.sourceWindowID = sourceWindowID
        self.sourceOccurrenceID = sourceOccurrenceID
    }
}

/// Engine identifiers are deliberately absent: they need not be unique across engines or profiles.
public struct BrowserDownloadKey: Hashable, Sendable {
    public let id: UUID
    public let profileID: ProfileID
    public let lifetime: UUID

    public init(id: UUID, profileID: ProfileID, lifetime: UUID) {
        self.id = id
        self.profileID = profileID
        self.lifetime = lifetime
    }
}

/// Capture this value when building a widget or menu; never rebuild it from current selection.
public struct BrowserDownloadContext: Equatable, Sendable {
    public let key: BrowserDownloadKey
    public let revision: UInt64

    public init(key: BrowserDownloadKey, revision: UInt64) {
        self.key = key
        self.revision = revision
    }
}

public enum BrowserDownloadState: String, Codable, Equatable, Sendable {
    case awaitingDestination
    case running
    case paused
    case interrupted
    case complete
    case cancelled
    case failed

    public var isTerminal: Bool {
        self == .complete || self == .cancelled || self == .failed
    }

    /// Adapters may omit intermediate callbacks, including for an empty synchronous download.
    /// A terminal outcome cannot be rewritten; file availability has a separate metadata path.
    public func canTransition(to next: BrowserDownloadState) -> Bool {
        !isTerminal && (next != .awaitingDestination || self == .awaitingDestination)
    }
}

public enum BrowserDownloadAction: String, Codable, Equatable, Sendable {
    case cancel
    case pause
    case resume
}

/// These describe actual engine controls, not a promise that every engine implements them.
/// Resume requires a living engine handle or engine resume data owned solely by the adapter.
public struct BrowserDownloadCapabilities: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let cancel = Self(rawValue: 1 << 0)
    public static let pause = Self(rawValue: 1 << 1)
    public static let resume = Self(rawValue: 1 << 2)

    public func supports(_ action: BrowserDownloadAction) -> Bool {
        switch action {
        case .cancel: contains(.cancel)
        case .pause: contains(.pause)
        case .resume: contains(.resume)
        }
    }
}

/// Missing or moved output is independent of whether the engine completed the transfer.
public enum BrowserDownloadFileAvailability: String, Codable, Equatable, Sendable {
    case unknown
    case available
    case missing
}

/// Deliberately contains no engine message, URL, path, suggested filename, or resume data.
public enum BrowserDownloadFailure: String, Codable, Error, Equatable, Sendable {
    case network
    case destinationUnavailable
    case permissionDenied
    case engineFailure
}

/// Rejections are technical categories safe to display in default diagnostic logs.
public enum BrowserDownloadError: String, Codable, Error, Equatable, Sendable {
    case coordinatorStopped
    case duplicateID
    case duplicateTransfer
    case unknownDownload
    case profileMismatch
    case staleLifetime
    case staleRevision
    case staleSequence
    case invalidUpdate
    case invalidTransition
    case terminalState
    case activeDownload
    case unsupportedOperation
    case invalidState
    case actionPending
    case cancellationRequested
    case transferRejected
    case revisionExhausted
}

/// A full, in-memory engine report. Sequences start above zero and increase for this lifetime,
/// including across resume. Received bytes are cumulative, never inferred from expected bytes.
/// Unknown engine totals must be normalized to nil, not zero or a negative sentinel.
/// Adapters discard callbacks from retired native attempts before reporting a genuine outcome.
/// Cancellation intent or its control acknowledgement cannot override a fresh terminal report.
public struct BrowserDownloadUpdate: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let key: BrowserDownloadKey
    public let sequence: UInt64
    public let state: BrowserDownloadState
    public let receivedBytes: Int64
    public let totalBytes: Int64?
    public let capabilities: BrowserDownloadCapabilities
    public let currentURL: URL?
    public let destinationURL: URL?
    public let fileAvailability: BrowserDownloadFileAvailability
    public let failure: BrowserDownloadFailure?

    public init(
        key: BrowserDownloadKey, sequence: UInt64, state: BrowserDownloadState,
        receivedBytes: Int64 = 0, totalBytes: Int64? = nil,
        capabilities: BrowserDownloadCapabilities = [], currentURL: URL? = nil,
        destinationURL: URL? = nil, fileAvailability: BrowserDownloadFileAvailability = .unknown,
        failure: BrowserDownloadFailure? = nil
    ) {
        self.key = key
        self.sequence = sequence
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.capabilities = capabilities
        self.currentURL = currentURL
        self.destinationURL = destinationURL
        self.fileAvailability = fileAvailability
        self.failure = failure
    }

    public var description: String { "BrowserDownloadUpdate(state: \(state.rawValue), sequence: \(sequence))" }
    public var debugDescription: String { description }
}

/// Immutable presentation data, intentionally not Codable and never a durable history schema.
/// URLs and filenames are transient RAM metadata. Default descriptions redact all of them.
public struct BrowserDownloadSnapshot: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let key: BrowserDownloadKey
    public let owner: BrowserDownloadOwner
    public let revision: UInt64
    public let sequence: UInt64
    public let suggestedFilename: String
    public let state: BrowserDownloadState
    public let receivedBytes: Int64
    public let totalBytes: Int64?
    public let capabilities: BrowserDownloadCapabilities
    public let currentURL: URL?
    public let destinationURL: URL?
    public let fileAvailability: BrowserDownloadFileAvailability
    public let failure: BrowserDownloadFailure?
    public let pendingAction: BrowserDownloadAction?
    public let isCancellationRequested: Bool
    /// The engine accepted the cancel command; a terminal transfer report may still be pending.
    public let isCancellationAccepted: Bool
    public let controlError: BrowserDownloadError?

    /// Optional for transfers restored from older history files.
    public let startedAt: Date?
    public let completedAt: Date?

    public var context: BrowserDownloadContext { .init(key: key, revision: revision) }

    /// Expected lengths can be estimates; neither this fraction nor completion rewrites bytes.
    public var progressFraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    public func canPerform(_ action: BrowserDownloadAction) -> Bool {
        guard !state.isTerminal, capabilities.supports(action) else { return false }
        if action == .cancel { return pendingAction != .cancel && !isCancellationAccepted }
        guard !isCancellationRequested, pendingAction == nil else { return false }
        switch action {
        case .cancel: return true
        case .pause: return state == .running
        case .resume: return state == .paused || state == .interrupted
        }
    }

    public init(
        key: BrowserDownloadKey, owner: BrowserDownloadOwner, revision: UInt64, sequence: UInt64,
        suggestedFilename: String, state: BrowserDownloadState, receivedBytes: Int64,
        totalBytes: Int64?, capabilities: BrowserDownloadCapabilities,
        currentURL: URL?, destinationURL: URL?, fileAvailability: BrowserDownloadFileAvailability,
        failure: BrowserDownloadFailure?, pendingAction: BrowserDownloadAction?,
        isCancellationRequested: Bool, controlError: BrowserDownloadError?,
        isCancellationAccepted: Bool = false, startedAt: Date? = nil, completedAt: Date? = nil
    ) {
        self.key = key
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.owner = owner
        self.revision = revision
        self.sequence = sequence
        self.suggestedFilename = suggestedFilename
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.capabilities = capabilities
        self.currentURL = currentURL
        self.destinationURL = destinationURL
        self.fileAvailability = fileAvailability
        self.failure = failure
        self.pendingAction = pendingAction
        self.isCancellationRequested = isCancellationRequested
        self.isCancellationAccepted = isCancellationAccepted
        self.controlError = controlError
    }

    public var description: String { "BrowserDownloadSnapshot(state: \(state.rawValue), revision: \(revision))" }
    public var debugDescription: String { description }
}
