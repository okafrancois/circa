import AppKit
import BrowserCore
import BrowserEngine
import Darwin

/// Confined, opt-in product measurement. No installed source app or Keychain provider is used.
@MainActor
enum SunsetImportProbe {
    static let bundleID = "lab.orbit.orbit.import-arc-sunset"
    private static var alert: NSAlert?

    static func run<Engine: BrowserEngine>(environment: BrowserEnvironment<Engine>, root: URL,
                                          action: String) async -> [String: Any] {
        guard Bundle.main.bundleIdentifier == bundleID,
              let target = ArcImportLiveTarget(environment: environment) else { return ["failed": true] }
        if action == "light" || action == "dark" {
            NSApp.appearance = NSAppearance(named: action == "dark" ? .darkAqua : .aqua)
            guard let data = try? Data(contentsOf: root.appendingPathComponent("sunset-report.json")),
                  let report = try? JSONDecoder().decode(ArcImportReport.self, from: data) else { return ["failed": true] }
            alert?.window.orderOut(nil)
            let panel = ArcImportAlertPresenter.confirmationAlert(report)
            panel.layout(); panel.window.center(); panel.window.makeKeyAndOrderFront(nil)
            alert = panel
            return ["alertWindow": panel.window.windowNumber]
        }
        if action == "check" {
            let document = await environment.store.sessionDocument()
            var visits = 0
            for profile in document.profiles {
                visits += (try? await environment.historyRecorder.visits(for: profile.id, limit: 100_000).count) ?? 0
            }
            return ["profiles": document.profiles.count, "spaces": document.spaces.count,
                    "tabs": document.organization.tabs.count, "folders": document.organization.folders.count,
                    "archive": document.organization.archive.count, "history": visits]
        }
        let presenter = Presenter()
        let coordinator = ArcImportCoordinator(presenter: presenter, defaultSource: root.deletingLastPathComponent().appendingPathComponent("ArcSource")) { source in
            ArcImporter(source: source, probe: BrowserImportRunningProbe(running: { false }))
        }
        var maximumGap = 0.0, ticks = 0
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ProcessInfo.processInfo.systemUptime
                maximumGap = max(maximumGap, now - previous)
                previous = now; ticks += 1
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        await coordinator.start(target: target)?.value
        let seconds = ProcessInfo.processInfo.systemUptime - start
        await Task.yield()
        heartbeat.cancel()
        if let report = presenter.report, let bytes = try? JSONEncoder().encode(report) {
            try? bytes.write(to: root.appendingPathComponent("sunset-report.json"))
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        var result: [String: Any] = ["seconds": seconds, "peakRSSBytes": usage.ru_maxrss,
            "longestMainThreadGapSeconds": maximumGap, "heartbeatTicks": ticks,
            "progressUpdates": presenter.updates, "failed": presenter.outcome == nil]
        if let outcome = presenter.outcome {
            result["backupID"] = outcome.backupID
            result["historyInserted"] = outcome.historyInserted
        }
        return result
    }

    private final class Presenter: ArcImportPresenting {
        let progress = ArcImportAlertPresenter()
        var report: ArcImportReport?
        var outcome: ArcImportOutcome?
        var updates = 0
        func chooseSourceDirectory() async -> URL? { nil }
        func askToQuitArc() async -> Bool { false }
        func showProgress(_ value: ArcImportProgress, onCancel: @escaping @MainActor () -> Void) {
            updates += 1; progress.showProgress(value, onCancel: onCancel)
        }
        func hideProgress() { progress.hideProgress() }
        func confirmReducedImport(_ report: ArcImportReport, excluding parts: ArcImportExclusions) async -> Bool { false }
        func confirm(_ report: ArcImportReport) async -> Bool { self.report = report; return true }
        func showCompletion(_ outcome: ArcImportOutcome) { self.outcome = outcome }
        func showFailure(_ error: ArcImportError?) {}
    }
}
