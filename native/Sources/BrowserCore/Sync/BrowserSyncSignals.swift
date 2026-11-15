import CloudKit
import Foundation
import Synchronization

/// Process-wide account generation. CloudKit posts `.CKAccountChanged` on any account
/// transition; every cached admission taken under an older generation is void.
public enum BrowserSyncAccountEpoch {
    private static let generation = Mutex<UInt64>(0)
    private static let observer: Void = {
        _ = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in
            BrowserSyncAccountEpoch.bump()
        }
    }()

    public static var current: UInt64 {
        _ = observer
        return generation.withLock { $0 }
    }

    public static func bump() { generation.withLock { $0 &+= 1 } }
}

/// A short-lived proof that the signed-in iCloud identity was verified. It never outlives
/// `lifetime`, an account-change notification, or an explicit reset after a failed check.
public struct BrowserSyncAdmission: Sendable {
    public static let lifetime = Duration.seconds(60)
    private var verified: (identity: String, at: ContinuousClock.Instant, epoch: UInt64)?
    public init() {}

    public func identity(now: ContinuousClock.Instant = .now, epoch: UInt64 = BrowserSyncAccountEpoch.current) -> String? {
        guard let verified, verified.epoch == epoch, now >= verified.at, now - verified.at < Self.lifetime else { return nil }
        return verified.identity
    }

    /// `epoch` must be read before the daemon query so a concurrent change voids the result.
    public mutating func record(_ identity: String?, epoch: UInt64, now: ContinuousClock.Instant = .now) {
        verified = identity.map { ($0, now, epoch) }
    }

    public mutating func reset() { verified = nil }
}

/// Persistent local stores announce committed edits so the sync runtime can wake instead of
/// polling. Delivery is a hint only; the runtime's safety timer covers any missed signal.
public enum BrowserSyncLocalChanges {
    public static let notification = Notification.Name("OrbitSyncLocalChange")
    public static func post() { NotificationCenter.default.post(name: notification, object: nil) }
}

public enum BrowserSyncRetry {
    /// CloudKit conditions that the sync engine retries itself. They must never tear down a
    /// transport or latch a permanent failure; the caller only backs off.
    public static func isTransient(_ error: any Error) -> Bool {
        guard let error = error as? CKError else { return false }
        switch error.code {
        case .networkFailure, .networkUnavailable, .requestRateLimited, .zoneBusy, .serviceUnavailable, .operationCancelled:
            return true
        default:
            return false
        }
    }

    /// Server-provided retry delay, when CloudKit throttles a request.
    public static func retryAfter(_ error: any Error) -> Duration? {
        guard let seconds = (error as? CKError)?.retryAfterSeconds, seconds > 0 else { return nil }
        return .milliseconds(Int64(min(seconds, 3600) * 1000))
    }
}

/// Decides when an explicit fetch/send round trip is required. Unchanged inputs, no unsent
/// records and no remote change since the last exchange skip the network entirely; a periodic
/// forced exchange still covers missed pushes.
public struct BrowserSyncExchangeGate: Sendable {
    public static let forcedInterval: TimeInterval = 300
    private var last: Date?
    private var revision = -1
    public init() {}

    public func canSkip(now: Date, remoteRevision: Int, inputsUnchanged: Bool, pendingSends: Bool) -> Bool {
        guard let last, inputsUnchanged, !pendingSends, revision == remoteRevision else { return false }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= 0 && elapsed < Self.forcedInterval
    }

    public mutating func exchanged(at now: Date, remoteRevision: Int) { last = now; revision = remoteRevision }
    public mutating func invalidate() { last = nil }
}
