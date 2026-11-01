import AppKit
import BrowserCore
import CryptoKit
import Foundation

/// Retained only in memory until normal save + CEF shutdown succeeds. Cancelling quit discards
/// snapshots and secrets. No source key or request containing secrets is persisted for restart.
final class BrowserImportOfflineJob: @unchecked Sendable {
    struct Authentication: Sendable {
        var snapshot: ChromiumAuthenticationSnapshot?
        var sourcePassword = Data()
        var targetPassword = Data()
    }
    let configuration: OrbitProductConfiguration
    let importer: BrowserImportOrchestrator?
    let preparation: BrowserImportPreparation?
    let adapter: (any BrowserImportSourceAdapter)?
    private var authentication: Authentication
    private var passwordCSV: Data?
    private var batch: [BrowserAuthenticationRun.Input]?
    private let elapsedBeforeApply: Double
    private let restoring: Bool
    var canCancel: Bool { !restoring }
    init(configuration: OrbitProductConfiguration, importer: BrowserImportOrchestrator? = nil,
         preparation: BrowserImportPreparation? = nil, adapter: (any BrowserImportSourceAdapter)? = nil,
         authentication: Authentication = .init(), passwordCSV: Data? = nil, restoring: Bool = false,
         batch: [BrowserAuthenticationRun.Input]? = nil, elapsedBeforeApply: Double = 0) {
        self.configuration = configuration; self.importer = importer; self.preparation = preparation
        self.adapter = adapter; self.authentication = authentication; self.passwordCSV = passwordCSV; self.restoring = restoring
        self.batch = batch; self.elapsedBeforeApply = elapsedBeforeApply
    }
    deinit { discard() }
    func discard() {
        preparation?.discard(); authentication.snapshot?.discard()
        for index in (batch ?? []).indices { batch?[index].discard() }
        batch = nil
        authentication.sourcePassword.resetBytes(in: 0..<authentication.sourcePassword.count)
        authentication.targetPassword.resetBytes(in: 0..<authentication.targetPassword.count)
        let csvCount = passwordCSV?.count ?? 0
        passwordCSV?.resetBytes(in: 0..<csvCount)
        passwordCSV = nil
    }
    static func authenticate(configuration: OrbitProductConfiguration, source: URL,
                             adapter: any BrowserImportSourceAdapter, probe: any ArcRunningProbe) throws -> Authentication {
        try Task.checkCancellation()
        var result = Authentication()
        if let chromium = adapter as? ChromiumBrowserImportAdapter {
            result.snapshot = try ChromiumAuthenticationSnapshot.capture(source: source, adapter: chromium, consent: true,
                parent: FileManager.default.temporaryDirectory, probe: probe)
            do {
                if configuration.usesMockKeychain {
                    result.sourcePassword = try BrowserImportUISynthetic.sourcePassword(configuration)
                } else {
                    result.sourcePassword = try ChromiumImportKeychain(boundary: OrbitSystemRecoverySecItems()).readSource(sourceID: adapter.descriptor.id, userConsented: true)
                }
            } catch { result.snapshot?.discard(); throw error }
        }
        do {
            switch configuration.secureStorage {
            case .mockKeychain: result.targetPassword = Data("mock_password".utf8)
            case .keychain(let service, let account):
                if !(adapter is SafariBrowserImportAdapter) {
                    result.targetPassword = try ArcSiteSessionKeychain(targetService: service, targetAccount: account).targetPassword()
                }
            }
            try Task.checkCancellation()
            return result
        } catch { result.snapshot?.discard(); throw error }
    }
    /// The launcher calls this only after ChromiumRuntime.run has returned and CEF has shut down.
    func run() async throws {
        defer { discard() }
        do {
            try Task.checkCancellation()
            try await performOffline()
            try Task.checkCancellation()
        } catch {
            guard !restoring, error is CancellationError || (error as? ArcImportError) == .cancelled else { throw error }
            // CEF is closed, so no later user edits exist. Cancel means discard this whole run.
            if try BrowserAuthenticationRun.exists(dataRoot: configuration.dataRoot) {
                let run = try BrowserAuthenticationRun.open(dataRoot: configuration.dataRoot, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration))
                if ![.verified, .restored].contains(run.status.phase) {
                    try run.restore(confirmDeletingLaterChanges: true, usage: ImportRecoveryAlert.OfflineUsage())
                }
            }
            try BrowserImportMetadata.writeResult(JSONEncoder().encode(BrowserImportResult(cancelled: true)), root: configuration.dataRoot)
        }
    }
    private func performOffline() async throws {
        try BrowserImportUISynthetic.checkpoint("ui-offline-ready", configuration: configuration)
        try Task.checkCancellation()
        let root = configuration.dataRoot
        if restoring {
            let run = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration))
            try run.restore(confirmDeletingLaterChanges: true, usage: ImportRecoveryAlert.OfflineUsage())
            try BrowserImportMetadata.writeResult(JSONEncoder().encode(BrowserImportResult(restored: true)), root: root)
            return
        }
        guard let importer, let preparation, let adapter else { throw BrowserAuthenticationImportError.invalidState }
        if try BrowserAuthenticationRun.exists(dataRoot: root) {
            let previous = try BrowserAuthenticationRun.open(dataRoot: root, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration))
            _ = try previous.archiveCompleted()
        }
        let key: SymmetricKey
        if configuration.usesMockKeychain { key = try ChromiumAuthenticationStartup.recoveryKey(configuration) }
        else {
            let product: OrbitNativeRecoveryKeyProvider.Product
            switch configuration.secureStorage {
            case .keychain(let service, _): product = service == "Orbit Live Safe Storage" ? .live : .daily
            case .mockKeychain: throw BrowserAuthenticationImportError.invalidState
            }
            if let existing = try? BrowserAuthenticationRunKey.load(dataRoot: root, product: product, backend: OrbitSystemRecoverySecItems()) { key = existing }
            else { key = try BrowserAuthenticationRunKey.prepare(dataRoot: root, product: product, backend: OrbitSystemRecoverySecItems(), userConsented: true) }
        }
        let target = try ArcOfflineImportTarget(sessionFile: configuration.sessionFile,
            usage: ImportRecoveryAlert.OfflineUsage(), separatedFrom: importer.source)
        do {
            let refreshed = await preparation.excluding([], for: target)
            let checkpoint: (String) throws -> Void = { point in
                try BrowserImportUISynthetic.checkpoint(point, configuration: self.configuration)
            }
            if adapter is ArcBrowserImportAdapter {
                _ = try await importer.apply(refreshed, to: target)
            } else if let batch {
                _ = try await BrowserAuthenticationRun.applyBatch(batch, importer: importer, target: target,
                    recoveryKey: key, elapsedBeforeApply: elapsedBeforeApply, checkpoint: checkpoint)
            } else if let safari = adapter as? SafariBrowserImportAdapter {
                _ = try await BrowserAuthenticationRun.applySafariExport(preparation: refreshed, importer: importer,
                    target: target, adapter: safari, consent: true, recoveryKey: key, checkpoint: checkpoint)
            } else if let firefox = adapter as? FirefoxBrowserImportAdapter {
                _ = try await BrowserAuthenticationRun.applyFirefox(preparation: refreshed, importer: importer,
                    target: target, adapter: firefox, passwordCSV: passwordCSV, consent: true,
                    targetPassword: authentication.targetPassword, recoveryKey: key, checkpoint: checkpoint)
            } else if let snapshot = authentication.snapshot {
                _ = try await BrowserAuthenticationRun.apply(preparation: refreshed, importer: importer, target: target,
                    authentication: snapshot, sourcePassword: authentication.sourcePassword,
                    targetPassword: authentication.targetPassword, recoveryKey: key, checkpoint: checkpoint)
            } else { throw BrowserAuthenticationImportError.invalidState }
            await target.close()
            try BrowserImportMetadata.writeResult(JSONEncoder().encode(BrowserImportResult(report: preparation.report, hasPasswordCSV: passwordCSV != nil, sourceID: adapter.descriptor.id)), root: root)
        } catch {
            await target.close()
            // The existing launch recovery gate owns any partially applied import. Never open CEF here.
            throw error
        }
    }
}

struct BrowserImportResult: Codable {
    var restored = false
    var cancelled: Bool? = nil
    var failed = false
    var report: ArcImportReport? = nil
    var hasPasswordCSV: Bool? = nil
    var sourceID: String? = nil
}

extension OrbitApplication {
    func startBrowserImport() { browserImport.start(application: self) }

    func presentBrowserImportResult() {
        BrowserImportUISynthetic.applyAppearance()
        guard let configuration = activeSiteSessionConfiguration(),
              let bytes = try? BrowserImportMetadata.readResult(root: configuration.dataRoot),
              let result = try? JSONDecoder().decode(BrowserImportResult.self, from: bytes) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !isPreparingToQuit else { return }
            let alert = OrbitFloatingMaterial.alert()
            if result.cancelled == true {
                alert.messageText = uiText("Import Cancelled")
                alert.informativeText = uiText("Nothing was kept from this import. Your previous session is ready.")
                alert.addButton(withTitle: uiText("OK"))
                alert.runModal()
                try? BrowserImportMetadata.removeResult(root: configuration.dataRoot)
                return
            }
            if result.failed {
                try? BrowserImportMetadata.removeResult(root: configuration.dataRoot)
                BrowserImportPicker().failure(BrowserAuthenticationImportError.invalidState)
                return
            }
            if result.sourceID == "arc", !result.restored {
                try? BrowserImportMetadata.removeResult(root: configuration.dataRoot)
                ArcImportFirstRunOffer.record(.accepted, at: ArcImportDataLocation(sessionFile: configuration.sessionFile))
                startArcSiteSessionImport(continuingArcImport: true)
                return
            }
            alert.messageText = result.restored ? uiText("Import Restored") : uiText("Import Complete")
            if result.restored {
                alert.informativeText = uiText("Your session from before the import is ready. The imported profile was removed.")
            } else if let run = try? BrowserAuthenticationRun.open(dataRoot: configuration.dataRoot, recoveryKey: ChromiumAuthenticationStartup.recoveryKey(configuration)), run.status.phase == .verified {
                alert.informativeText = BrowserImportText.completion(run.status.outcome,
                    passwords: run.status.passwords, cookies: run.status.cookies,
                    unsupportedPasswords: run.status.unsupportedPasswords, keptPasswords: run.status.passwordConflicts,
                    report: result.report, passwordCSV: result.hasPasswordCSV == true, sourceID: result.sourceID)
            } else {
                try? BrowserImportMetadata.removeResult(root: configuration.dataRoot)
                return
            }
            alert.addButton(withTitle: uiText("OK"))
            if !result.restored { alert.addButton(withTitle: uiText("Restore…")) }
            let restore = alert.runModal() == .alertSecondButtonReturn
            try? BrowserImportMetadata.removeResult(root: configuration.dataRoot)
            if restore, BrowserImportPicker().confirm(title: uiText("Restore Before This Import?"),
                message: uiText("Circa will save and restart. This replaces all session edits made after the import and removes the imported profile, including its passwords, cookies and history. Other profiles’ website data is kept."),
                button: uiText("Restore and Restart")) {
                pendingBrowserImport = BrowserImportOfflineJob(configuration: configuration, restoring: true)
                NSApp.terminate(nil)
            }
        }
    }
}
