import BrowserCore
import Foundation

/// Runs only inside the explicitly admitted synthetic product probe. Uses a separate synthetic
/// target so backup restoration never races the application's own session persistence.
@MainActor
enum ChromiumImportProbe {
    private struct Usage: OrbitTargetUsageProbe {
        func isInUse(sessionFile: URL) -> Bool { false }
    }
    static func run(root: URL) async -> [String: Any] {
        let source = root.appendingPathComponent("ImportSource")
        let session = root.appendingPathComponent("ImportProbe/session.json")
        let snapshots = root.appendingPathComponent("ImportSnapshots")
        do {
            try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
            let descriptor = ChromiumImportRegistry.descriptors[0]
            let adapter = ChromiumBrowserImportAdapter(descriptor: descriptor, installationID: UUID(),
                profile: .init(directory: "Default", name: "Synthetic"),
                placement: ChromiumImportDiscovery.placement(browser: descriptor.name, profile: "Synthetic"))
            var importer = BrowserImportOrchestrator(source: source, probe: BrowserImportRunningProbe(running: { false }), snapshotParent: snapshots)
            importer.adapter = adapter
            let target = try ArcOfflineImportTarget(sessionFile: session, usage: Usage(), separatedFrom: source)
            let outcome: ArcImportOutcome
            do { outcome = try await importer.apply(try await importer.prepare(for: target), to: target) }
            catch { await target.close(); throw error }
            let document = await target.sessionDocument()
            let profiles = document.profiles.count, spaces = document.spaces.count
            let folders = document.organization.folders.count
            let pinnedURLs = document.organization.tabs.filter { $0.pinnedURL != nil }.count
            await target.close()
            var visits = 0
            for profile in document.profiles {
                let history = try BrowserHistoryStore(profileID: profile.id, policy: .persistent, directory: target.location.historyDirectory)
                visits += try await history.visits(limit: 100).count
                try await history.close()
            }
            try ArcImportBackups.restore(outcome.backupID, at: target.location, usage: Usage())
            let restored = !FileManager.default.fileExists(atPath: session.path)
            return ["profiles": profiles, "spaces": spaces, "folders": folders, "pinnedURLs": pinnedURLs,
                    "historyInserted": outcome.historyInserted, "historyVerified": visits, "rollback": restored]
        } catch { return ["failed": true] }
    }
}
