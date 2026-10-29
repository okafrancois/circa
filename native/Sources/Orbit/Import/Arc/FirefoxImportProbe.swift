import BrowserCore
import BrowserEngine
import Foundation

/// Dormant synthetic endpoint: verifies the product's stored import and independently exercises
/// its reader/orchestrator/undo using a separate offline target. No event injection is needed.
@MainActor
enum FirefoxImportProbe {
    private struct OfflineUsage: OrbitTargetUsageProbe {
        func isInUse(sessionFile: URL) -> Bool { false }
    }
    static func run(root: URL, store: BrowserStore) async -> [String: Any] {
        do {
            guard let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
                  configuration.usesMockKeychain else { throw BrowserAuthenticationImportError.invalidState }
            let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration))
            let document = await store.sessionDocument()
            if run.status.phase == .restored { return ["restored": true, "profiles": document.profiles.count] }
            let history = try BrowserHistoryStore(profileID: run.status.profileID, policy: .persistent, directory: root.appendingPathComponent("History"))
            let visits = try await history.visits(limit: 100).count
            try await history.close()
            let source = root.appendingPathComponent("ImportSource")
            let snapshots = root.appendingPathComponent("ImportSnapshots")
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            let descriptor = FirefoxImportRegistry.descriptors[0]
            let adapter = FirefoxBrowserImportAdapter(descriptor: descriptor, installationID: UUID(),
                profile: .init(directory: "Profiles/default", name: "Synthetic"),
                placement: ChromiumImportDiscovery.placement(browser: descriptor.name, profile: "Synthetic"))
            var importer = BrowserImportOrchestrator(source: source, probe: BrowserImportRunningProbe(running: { false }), snapshotParent: snapshots)
            importer.adapter = adapter
            let target = try ArcOfflineImportTarget(sessionFile: root.appendingPathComponent("ImportProbe/session.json"), usage: OfflineUsage(), separatedFrom: source)
            do {
                let outcome = try await importer.apply(importer.prepare(for: target), to: target)
                await target.close()
                try ArcImportBackups.restore(outcome.backupID, at: target.location, usage: OfflineUsage())
                return ["phase": run.status.phase.rawValue, "profiles": document.profiles.count,
                    "spaces": document.spaces.filter { $0.profileID == run.status.profileID }.count,
                    "folders": document.organization.folders.count, "history": visits,
                    "pins": document.organization.tabs.filter { $0.pinnedURL != nil }.count,
                    "structuralHistory": outcome.historyInserted, "undo": !FileManager.default.fileExists(atPath: target.location.sessionFile.path)]
            } catch { await target.close(); throw error }
        } catch { return ["failed": true] }
    }
}
