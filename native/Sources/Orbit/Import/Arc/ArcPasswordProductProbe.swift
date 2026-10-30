import AppKit
import BrowserCore
import BrowserEngine
import Foundation

/// Opt-in synthetic product harness. Reports counts only and never queries system storage.
@MainActor
enum ArcPasswordProductProbe {
    static let bundleID = "lab.orbit.orbit.import-arc-passwords"
    static var isEnabled: Bool { Bundle.main.bundleIdentifier == bundleID && activeSiteSessionConfiguration()?.usesMockKeychain == true }
    static var autoConfirm = false
    private static var alert: NSAlert?
    private static func recordedJobID(root: URL) throws -> UUID? {
        if let id = try ArcPasswordImportJournal.activeID(root: root) { return id }
        let file = root.appendingPathComponent("password-probe-job.json")
        if let data = try? Data(contentsOf: file) { return try JSONDecoder().decode(UUID.self, from: data) }
        if let id = try? ArcSiteSessionImport(dataRoot: root).latestPasswordJobID {
            try JSONEncoder().encode(id).write(to: file, options: .atomic)
            return id
        }
        return nil
    }
    static func present(_ value: NSAlert) {
        alert?.window.orderOut(nil); alert = value
        value.layout(); value.window.center(); value.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func run(application: OrbitApplication, action: String, appearance: String) async -> [String: Any] {
        guard isEnabled, let environment = application.environment, let configuration = activeSiteSessionConfiguration(),
              let store = environment.engine.passwordStore else { return ["failed": true] }
        let root = configuration.dataRoot
        do {
            if action == "capture" {
                guard let window = alert?.window, NSApp.windows.contains(where: { $0 === window }), window.isVisible,
                      let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return ["failed": true] }
                window.displayIfNeeded()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { return ["failed": true] }
                try png.write(to: root.appendingPathComponent("password-alert.png"), options: .atomic)
                return ["alertWindow": window.windowNumber, "captured": true]
            }
            if action == "import" {
                guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("password-probe-started").path) else { return ["duplicateRefused": true] }
                try Data().write(to: root.appendingPathComponent("password-probe-started"), options: .withoutOverwriting)
                guard let profile = await environment.store.catalogSnapshot().profiles.first?.id else { return ["failed": true] }
                let csv = Data("url,username,password\nhttps://fixture.test/equal,equal,synthetic-equal\nhttps://fixture.test/conflict,conflict,synthetic-orbit\nhttps://unrelated.test/,unrelated,synthetic-unrelated\n".utf8)
                _ = try await BrowserPasswordImporter.importCSV(csv, to: store, profileID: profile)
                application.orbitImport = ArcImportCoordinator(presenter: Presenter(root: root),
                    defaultSource: OrbitImportLaunchOptions.source(CommandLine.arguments)) { source in
                        ArcImporter(source: source, probe: BrowserImportRunningProbe(running: { false }))
                    }
                autoConfirm = true
                application.startArcImport()
                return ["started": true]
            }
            if action == "restore" {
                autoConfirm = true
                application.startArcSiteSessionImport(restoring: true)
                return ["restoreStarted": true]
            }
            if action == "check" || action == "edit" {
                var total = 0, blocked = 0, edited = 0
                let profiles = await environment.store.catalogSnapshot().profiles
                for profile in profiles {
                    let rows = try await store.list(profileID: profile.id)
                    total += rows.count; blocked += rows.filter(\.blockedByUser).count
                    if action == "edit", let row = rows.first(where: { $0.primaryKey.usernameValue == "new" }) {
                        var value = row; value.passwordValue = "synthetic-edited-after-import"
                        try await store.update(value, replacing: row.primaryKey, profileID: profile.id); edited += 1
                    }
                }
                var result: [String: Any] = ["storeRows": total, "blocklisted": blocked, "edited": edited]
                if let id = try recordedJobID(root: root) {
                    let job = try ArcPasswordImportPreparation.open(id, configuration: configuration)
                    result["phase"] = job.phase.rawValue
                    result["added"] = job.counts.added; result["alreadyPresent"] = job.counts.alreadyPresent
                    result["kept"] = job.counts.kept; result["skipped"] = job.counts.skipped
                    result["removed"] = job.counts.removed; result["retained"] = job.counts.retained
                }
                return result
            }
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            let panel: NSAlert
            if action == "confirmation" {
                let report = try JSONDecoder().decode(ArcImportReport.self, from: Data(contentsOf: root.appendingPathComponent("password-probe-report.json")))
                panel = ArcImportAlertPresenter.confirmationAlert(report)
            } else if action == "review-result" {
                // Presentation-only input: recapture copy without replaying an import.
                let counts = try JSONDecoder().decode(ArcPasswordImportJournal.Counts.self,
                    from: Data(contentsOf: root.appendingPathComponent("password-review-counts.json")))
                var sessions = ArcSiteSessionResult(); sessions.profiles = 2
                panel = ArcSiteSessionAlerts.resultAlert(sessions, passwords: counts)!
            } else if action == "restart-confirmation" || action == "restore-confirmation" {
                panel = ArcSiteSessionAlerts.confirmationAlert(orbitRunning: false, restoring: action == "restore-confirmation")
            } else if action == "missing" || action == "denied" {
                panel = ArcSiteSessionAlerts.resultAlert(nil, failed: true)!
            } else {
                guard let id = try recordedJobID(root: root) else { return ["failed": true] }
                let job = try ArcPasswordImportPreparation.open(id, configuration: configuration)
                var counts = job.counts
                if action == "zero" { counts = .init(); counts.added = 1 }
                var sessions = ArcSiteSessionResult()
                sessions.profiles = Set(job.rows.map(\.profile)).count
                sessions.restored = action == "restored"
                panel = ArcSiteSessionAlerts.resultAlert(action == "zero" ? nil : sessions,
                    passwords: counts, restored: action == "restored")!
            }
            present(panel)
            return ["alertWindow": panel.window.windowNumber]
        } catch { return ["failed": true] }
    }
    private final class Presenter: ArcImportPresenting {
        let root: URL
        init(root: URL) { self.root = root }
        func chooseSourceDirectory() async -> URL? { nil }
        func askToQuitArc() async -> Bool { false }
        func showProgress(_ progress: ArcImportProgress, onCancel: @escaping @MainActor () -> Void) {}
        func hideProgress() {}
        func confirmReducedImport(_ report: ArcImportReport, excluding parts: ArcImportExclusions) async -> Bool { false }
        func confirm(_ report: ArcImportReport) async -> Bool {
            do { try JSONEncoder().encode(report).write(to: root.appendingPathComponent("password-probe-report.json")); return true }
            catch { return false }
        }
        func showCompletion(_ outcome: ArcImportOutcome) {}
        func showFailure(_ error: ArcImportError?) {}
    }
}
