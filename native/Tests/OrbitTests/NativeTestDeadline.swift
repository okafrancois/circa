import Foundation

/// Only test helpers use this seam: fixtures control monotonic time and timer delivery separately.
@MainActor
struct NativeTestDeadlineTiming {
    typealias Callback = @MainActor () -> Void
    let now: () -> ContinuousClock.Instant
    let schedule: (TimeInterval, @escaping Callback) -> Callback

    static var live: Self {
        Self(now: { ContinuousClock.now }, schedule: { seconds, callback in
            let timer = Timer(timeInterval: seconds, repeats: false) { _ in
                MainActor.assumeIsolated { callback() }
            }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        })
    }
}

/// A test deadline must return even when an IPC operation ignores Swift task cancellation.
/// A timed-out operation is cancelled and its late result is discarded. It may still finish in
/// WebKit, so callers must use isolated synthetic state and avoid retries on the same state.
@MainActor
func withNativeTestDeadline<Value: Sendable>(
    _ expectation: String,
    timeout: TimeInterval = 30,
    observed: @escaping @MainActor () -> String = { "operation has not returned" },
    fileID: String = #fileID,
    line: Int = #line,
    timing: NativeTestDeadlineTiming = .live,
    operation: @escaping @MainActor () async throws -> Value
) async throws -> Value {
    guard timeout.isFinite && timeout > 0 else {
        throw NativeTestWaitTimeout(description: "Invalid test operation timeout: \(timeout)")
    }
    let race = NativeTestDeadlineRace<Value>(timing: timing)
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            race.start(continuation, timeout: timeout, timeoutError: {
                NativeTestWaitTimeout(description:
                    "\(fileID):\(line): waited \(timeout)s for \(expectation); observed: \(observed())")
            }, operation: operation)
        }
    } onCancel: {
        Task { @MainActor in race.finish(.failure(CancellationError())) }
    }
}

@MainActor
private final class NativeTestDeadlineRace<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var cancelTimer: NativeTestDeadlineTiming.Callback?
    private var operationTask: Task<Void, Never>?
    private var deadline: ContinuousClock.Instant?
    private var timeoutError: (@MainActor () -> any Error)?
    private var isFinished = false
    private let timing: NativeTestDeadlineTiming

    init(timing: NativeTestDeadlineTiming) { self.timing = timing }

    func start(
        _ continuation: CheckedContinuation<Value, any Error>,
        timeout: TimeInterval,
        timeoutError: @escaping @MainActor () -> any Error,
        operation: @escaping @MainActor () async throws -> Value
    ) {
        guard !isFinished else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        deadline = timing.now() + .seconds(timeout)
        self.timeoutError = timeoutError
        cancelTimer = timing.schedule(timeout) { [self] in
            finish(.failure(timeoutError()))
        }
        operationTask = Task { @MainActor [self] in
            do {
                try Task.checkCancellation()
                let value = try await operation()
                try Task.checkCancellation()
                finishOperation(.success(value))
            } catch { finishOperation(.failure(error)) }
        }
    }

    private func finishOperation(_ result: Result<Value, any Error>) {
        guard !isFinished else { return }
        // The operation can occupy MainActor past the deadline, ahead of an overdue timer.
        // Timer delivery order must never turn an over-budget result into a successful wait.
        if let deadline, timing.now() >= deadline, let timeoutError {
            finish(.failure(timeoutError()))
        } else {
            finish(result)
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        guard !isFinished else { return }
        isFinished = true
        cancelTimer?()
        cancelTimer = nil
        deadline = nil
        timeoutError = nil
        operationTask?.cancel()
        operationTask = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
