import BrowserCore
import Foundation
import OSLog

/// Observes a command without cancelling it or admitting later work out of order.
/// Kinds and steps are code-owned labels; callers must never supply browsing content.
@MainActor
final class BrowserSessionCommandDiagnostic {
    struct Report {
        let kind: String
        let windowID: String
        let elapsedSeconds: Double
        let step: String
    }

    private static let logger = Logger(subsystem: "local.orbit", category: "session-command")
    var step = "previous-command"
    private var watchdog: Task<Void, Never>?

    init(kind: String, delay: Duration, report: @escaping @MainActor (Report) -> Void,
         windowID: @escaping @MainActor () -> WindowID?) {
        let start = ContinuousClock.now
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            let elapsed = start.duration(to: .now).components
            let value = Report(kind: kind, windowID: windowID()?.rawValue.uuidString ?? "unassigned",
                elapsedSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18, step: step)
            Self.logger.error("Session command stalled: kind=\(value.kind, privacy: .public) window=\(value.windowID, privacy: .public) elapsed=\(value.elapsedSeconds, privacy: .public)s awaited=\(value.step, privacy: .public)")
            report(value)
        }
    }

    func finish() { watchdog?.cancel(); watchdog = nil }
    deinit { watchdog?.cancel() }
}

extension BrowserWindowSession {
    func trackCommand(kind: String) -> BrowserSessionCommandDiagnostic {
        BrowserSessionCommandDiagnostic(kind: kind, delay: commandWatchdogDelay,
            report: { [weak self] in self?.onCommandStall?($0) }, windowID: { [weak self] in self?.windowID })
    }
}
