import BrowserCore
import Foundation
import Testing
import WebKit

@testable import Orbit

struct NativeTestWaitTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Test-only deadlines can be increased on loaded hosts without delaying successful waits.
/// Async predicates have the same deadline, including an IPC reply that never arrives.
@MainActor
func waitForNativeState(
    _ expectation: String,
    timeout: TimeInterval? = nil,
    observed: @escaping @MainActor () -> String = { "predicate is false" },
    fileID: String = #fileID,
    line: Int = #line,
    timing: NativeTestDeadlineTiming = .live,
    until predicate: @escaping @MainActor () async throws -> Bool
) async throws {
    let environment = ProcessInfo.processInfo.environment
    let requestedScale = Double(environment["ORBIT_TEST_TIMEOUT_SCALE"] ?? "") ?? 1
    let scale = requestedScale.isFinite ? min(10, max(1, requestedScale)) : 1
    let seconds = timeout ?? (environment["CI"] == nil ? 30 : 60) * scale
    guard seconds.isFinite && seconds > 0 else {
        throw NativeTestWaitTimeout(description: "Invalid test wait timeout: \(seconds)")
    }
    let started = timing.now()
    let deadline = started + .seconds(seconds)
    while true {
        try Task.checkCancellation()
        let duration = timing.now().duration(to: deadline).components
        let remaining = max(0.000_001, Double(duration.attoseconds) / 1e18 + Double(duration.seconds))
        if try await withNativeTestDeadline(expectation, timeout: remaining, observed: observed,
                                           fileID: fileID, line: line, timing: timing, operation: predicate) { return }
        guard timing.now() < deadline else {
            throw NativeTestWaitTimeout(
                description:
                    "\(fileID):\(line): waited \(timing.now() - started) for \(expectation); observed: \(observed())"
            )
        }
        // Resume polling from the main run loop.
        // The timer is only a polling cadence; success depends on state, never a fixed delay.
        await withCheckedContinuation { continuation in
            let timer = Timer(timeInterval: 0.02, repeats: false) { _ in
                continuation.resume()
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

@MainActor
func nativeWebViewState(_ view: WKWebView) -> String {
    "title=\(view.title ?? "nil"), path=\(view.url?.path ?? "nil"), loading=\(view.isLoading), back=\(view.canGoBack), forward=\(view.canGoForward)"
}

@MainActor
func nativeFindState(_ controller: PreviewWindowController) -> String {
    guard let surface = controller.session.selectedSurface else { return "no selected surface" }
    let state = controller.findSession.state
    return
        "final=\(String(describing: state?.isFinal)), error=\(String(describing: state?.error)), query=\(state?.query ?? "nil"), matchCase=\(String(describing: state?.matchCase)), generation=\(surface.findDocumentGeneration), \(nativeWebViewState(surface.webView))"
}

@MainActor
func nativeDownloadState(_ snapshot: BrowserDownloadSnapshot?) -> String {
    guard let snapshot else { return "no download snapshot" }
    return
        "state=\(snapshot.state.rawValue), revision=\(snapshot.revision), received=\(snapshot.receivedBytes), total=\(String(describing: snapshot.totalBytes)), availability=\(snapshot.fileAvailability), failure=\(String(describing: snapshot.failure))"
}
