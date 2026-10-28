import Foundation
import Testing

@MainActor
private final class NativeWaitProbe {
    var ready = false
    var callback: CheckedContinuation<Bool, Never>?
    var lateOperationFinished = false
}

extension NativeWebKitTests {
@MainActor
struct NativeTestWaitTests {
    @Test("A wait returns immediately when its predicate already holds")
    func alreadySatisfied() async throws {
        var checks = 0
        let now = ContinuousClock.now
        let timing = NativeTestDeadlineTiming(now: { now }, schedule: { seconds, _ in
            #expect(seconds == 0.1)
            return {}
        })
        try await waitForNativeState("already satisfied", timeout: 0.1, timing: timing) {
            checks += 1
            return true
        }
        #expect(checks == 1)
    }

    @Test("A wait services the main run loop until the observed state changes")
    func servicesRunLoop() async throws {
        let state = NativeWaitProbe()
        let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
            MainActor.assumeIsolated { state.ready = true }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        try await waitForNativeState("timer delivery", timeout: 2) { state.ready }
    }

    @Test("A deadline failure names the expectation and last observed state")
    func timeoutDiagnostics() async throws {
        do {
            try await waitForNativeState(
                "popup selection", timeout: 0.04, observed: { "selected=source" }
            ) { false }
            Issue.record("An unsatisfied predicate must time out")
        } catch let error as NativeTestWaitTimeout {
            #expect(error.description.contains("popup selection"))
            #expect(error.description.contains("selected=source"))
            #expect(error.description.contains("NativeTestWaitTests.swift:"))
        }
    }

    @Test("Cancellation stops polling without waiting for the deadline")
    func cancellation() async throws {
        let state = NativeWaitProbe()
        let task = Task { @MainActor in
            try await waitForNativeState("cancelled wait", timeout: 2) {
                state.ready = true
                return false
            }
        }
        try await waitForNativeState("polling starts before cancellation", timeout: 2) {
            state.ready
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("A cancelled wait must throw")
        } catch is CancellationError {}
    }

    @Test("A non-cancellable IPC predicate times out and a late callback is harmless")
    func suspendedPredicateDeadline() async throws {
        let state = NativeWaitProbe()
        var now = ContinuousClock.now
        var timeoutCallback: NativeTestDeadlineTiming.Callback?
        let timing = NativeTestDeadlineTiming(now: { now }, schedule: { seconds, callback in
            #expect(seconds == 0.04)
            timeoutCallback = callback
            return {}
        })
        let task = Task { @MainActor in
            try await waitForNativeState("synthetic IPC reply", timeout: 0.04,
                                         observed: { "callback pending" }, timing: timing) {
                let result = await withCheckedContinuation { state.callback = $0 }
                state.lateOperationFinished = true
                return result
            }
        }
        try await waitForNativeState("synthetic IPC installed before timeout", timeout: 2) {
            state.callback != nil && timeoutCallback != nil
        }
        now += .milliseconds(41)
        let expire = try #require(timeoutCallback)
        timeoutCallback = nil
        expire()
        do {
            try await withNativeTestDeadline("expired IPC wait returns", timeout: 2) {
                try await task.value
            }
            Issue.record("A missing callback must fail, rather than hang or report success")
        } catch let error as NativeTestWaitTimeout {
            #expect(error.description.contains("synthetic IPC reply"))
            #expect(error.description.contains("callback pending"))
        }
        let callback = try #require(state.callback)
        #expect(!state.lateOperationFinished)
        state.callback = nil
        callback.resume(returning: true)
        try await waitForNativeState("late callback drained", timeout: 2) { state.lateOperationFinished }
    }

    @Test("Cancellation returns while a non-cancellable IPC callback remains pending")
    func suspendedPredicateCancellation() async throws {
        let state = NativeWaitProbe()
        let task = Task { @MainActor in
            try await waitForNativeState("cancelled IPC reply", timeout: 2) {
                await withCheckedContinuation { state.callback = $0 }
            }
        }
        try await waitForNativeState("IPC operation starts", timeout: 2) { state.callback != nil }
        task.cancel()
        do {
            try await withNativeTestDeadline("cancelled wait returns", timeout: 1) { try await task.value }
            Issue.record("Cancellation must fail the wait")
        } catch is CancellationError {}
        let callback = try #require(state.callback)
        state.callback = nil
        callback.resume(returning: true)
    }

    @Test("An operation returning after its deadline fails even before the overdue timer fires")
    func synchronousOverrunDeadline() async throws {
        // The timer is held until after the result: executor scheduling cannot win this race.
        var now = ContinuousClock.now
        var timeoutCallback: NativeTestDeadlineTiming.Callback?
        var timerInvalidated = false
        let timing = NativeTestDeadlineTiming(now: { now }, schedule: { seconds, callback in
            #expect(seconds == 0.01)
            timeoutCallback = callback
            return { timerInvalidated = true }
        })
        var operationReturned = false
        do {
            _ = try await withNativeTestDeadline("over-budget operation", timeout: 0.01, timing: timing) {
                now += .milliseconds(11)
                operationReturned = true
                return true
            }
            Issue.record("An overdue success must fail even when timer delivery is delayed")
        } catch let error as NativeTestWaitTimeout {
            #expect(error.description.contains("over-budget operation"))
        }
        #expect(operationReturned)
        #expect(timerInvalidated)
        let lateTimer = try #require(timeoutCallback)
        timeoutCallback = nil
        lateTimer()
    }
}
}
