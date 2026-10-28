import Foundation

/// Engine-independent steps of application termination, in this order:
/// 1. Commands are frozen by the application, then `settleTransfers` lets every live move finish:
///    recorded (the source placeholder is released), returned or rescued. The saved model then has
///    each live document exactly once.
/// 2. The application saves the session. A failed save cancels termination; nothing was detached.
/// 3. `detachAndShutDown` retires every window session with its model preserved (teardown never
///    mutates the saved session), closes the containers (Peek, Little Orbit, rescue holder), disposes
///    surfaces stranded by failed moves, then awaits the engine's `shutdown()` within a bound, so
///    the process exits only after native teardown (CEF: every `OnBeforeClose`) or the bound.
@MainActor
public enum BrowserTermination {
    public enum Outcome: Equatable, Sendable {
        /// The engine finished its asynchronous teardown.
        case engineShutDown
        /// The bound elapsed first. The application quits anyway; teardown is abandoned.
        case engineShutdownTimedOut
    }

    /// Waits until no move is in flight and the sessions drained their commands.
    public static func settleTransfers<Surface: BrowserSurface>(
        in sessions: [BrowserWindowSession<Surface>], timeout: Duration?
    ) async -> Bool {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while true {
            if BrowserSurfaceTransfers.inFlightCount == 0, !sessions.contains(where: \.hasPendingCommands) { return true }
            guard deadline.map({ ContinuousClock.now < $0 }) ?? true, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Call only after the session was saved: from here on nothing is persisted and every live
    /// surface of this engine is disposed. `strandedSurfaces` selects the stranded surfaces that
    /// belong to this engine.
    public static func detachAndShutDown<Surface: BrowserSurface>(
        sessions: [BrowserWindowSession<Surface>],
        containers: [BrowserSurfaceContainer<Surface>] = [],
        strandedSurfaces: (Surface) -> Bool = { _ in true },
        timeout: Duration,
        shutdownEngine: @escaping @MainActor () async -> Void
    ) async -> Outcome {
        for session in sessions { session.retireForApplicationTermination() }
        for container in containers { container.close() }
        BrowserSurfaceTransfers.disposeStranded(of: Surface.self, where: strandedSurfaces)
        return await withDeadline(timeout, shutdownEngine) ? .engineShutDown : .engineShutdownTimedOut
    }

    /// A nil deadline drains accepted work through completion without cancelling it.
    public static func withDeadline(
        _ timeout: Duration?, _ operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        if let timeout { return await withDeadline(timeout, operation) }
        await operation()
        return true
    }

    /// Runs `operation` and waits for it at most `timeout`. True when it finished in time. When
    /// the deadline wins, the operation's task is cancelled; a later completion is ignored.
    public static func withDeadline(
        _ timeout: Duration, _ operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        let race = DeadlineRace()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.work = Task { @MainActor in
                await operation()
                race.finish(true)
            }
            race.timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                race.finish(false)
            }
        }
    }

    @MainActor
    private final class DeadlineRace {
        var continuation: CheckedContinuation<Bool, Never>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?

        func finish(_ inTime: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            if inTime { timer?.cancel() } else { work?.cancel() }
            continuation.resume(returning: inTime)
        }
    }
}
