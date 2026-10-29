import BrowserCore
import BrowserEngine
import CryptoKit
import Foundation

/// Count-only verification of an explicitly generated export, after the normal native startup
/// password sink has applied its sealed run. This endpoint has no command/menu routing.
@MainActor
enum SafariImportProbe {
    private struct OfflineUsage: OrbitTargetUsageProbe {
        func isInUse(sessionFile: URL) -> Bool { false }
    }
    /// Also exercises the actual export reader/orchestrator inside the product executable, using
    /// an independent offline target so the application's session writer cannot race the undo.
    static func structuralRoundTrip(root: URL) async throws -> [String: Any] {
        let source = root.appendingPathComponent("ImportSource/Export.zip")
        let targetRoot = root.appendingPathComponent("ImportProbe")
        let snapshots = root.appendingPathComponent("ImportSnapshots")
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let adapter = SafariBrowserImportAdapter(installationID: UUID(), profile: .init(directory: "History", name: "Synthetic"),
            placement: ChromiumImportDiscovery.placement(browser: "Safari", profile: "Synthetic"), includeSharedData: true)
        var importer = BrowserImportOrchestrator(source: source, probe: BrowserImportRunningProbe(running: { false }), snapshotParent: snapshots)
        importer.adapter = adapter
        let target = try ArcOfflineImportTarget(sessionFile: targetRoot.appendingPathComponent("session.json"), usage: OfflineUsage(), separatedFrom: source)
        do {
            let preparation = try await importer.prepare(for: target)
            let counts = preparation.report.sourceCounts ?? [:]
            let outcome = try await importer.apply(preparation, to: target)
            let document = await target.sessionDocument()
            await target.close()
            try ArcImportBackups.restore(outcome.backupID, at: target.location, usage: OfflineUsage())
            return ["profiles": document.profiles.count, "spaces": document.spaces.count,
                "folders": document.organization.folders.count, "history": outcome.historyInserted,
                "passwordsDecoded": counts["passwords"] ?? 0, "unsupportedNotes": counts["notes"] ?? 0,
                "unsupportedOTP": counts["otp"] ?? 0, "undo": !FileManager.default.fileExists(atPath: target.location.sessionFile.path)]
        } catch { await target.close(); throw error }
    }
    static func run(root: URL, store: BrowserStore, passwords: (any BrowserPasswordStore)?) async -> [String: Any] {
        do {
            guard let configuration = activeSiteSessionConfiguration(), configuration.syntheticGuard != nil,
                  configuration.usesMockKeychain, let passwords else { throw BrowserAuthenticationImportError.invalidState }
            let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration))
            let document = await store.sessionDocument()
            if run.status.phase == .restored {
                return ["restored": true, "profiles": document.profiles.count]
            }
            let structural = try await structuralRoundTrip(root: root)
            let rows = try await passwords.list(profileID: run.status.profileID)
            let history = try BrowserHistoryStore(profileID: run.status.profileID, policy: .persistent, directory: root.appendingPathComponent("History"))
            let visits = try await history.visits(limit: 100)
            try await history.close()
            return ["structuralRoundTrip": structural, "phase": run.status.phase.rawValue, "profiles": document.profiles.count,
                "importedSpaces": document.spaces.filter { $0.profileID == run.status.profileID }.count,
                "folders": document.organization.folders.count,
                "pinnedURLs": document.organization.tabs.filter { $0.pinnedURL != nil }.count,
                "history": visits.count, "passwords": rows.count,
                "passwordVerified": rows.count == 1 && rows[0].passwordValue == "quoted,\"secret\"" && rows[0].primaryKey.usernameValue == "synthetic"]
        } catch { return ["failed": true] }
    }
}
