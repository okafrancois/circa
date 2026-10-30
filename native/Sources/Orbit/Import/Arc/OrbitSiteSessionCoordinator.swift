import AppKit
import BrowserCore

@MainActor
enum ArcSiteSessionAlerts {
    static func confirm(orbitRunning: Bool, restoring: Bool) -> Bool {
        let alert = OrbitFloatingMaterial.alert()
        if restoring {
            alert.messageText = uiText("Restore Connections Before the Last Import?")
            alert.informativeText = uiText("Orbit will save your tabs and restart. Cookies and site storage will return to their state before the last import.")
        } else if orbitRunning {
            alert.messageText = uiText("Quit Arc to Import Your Connections")
            alert.informativeText = uiText("Arc must be closed to copy its connections. Orbit will then save your tabs and restart. Allow access to Arc Safe Storage when macOS asks. Existing Orbit connections are backed up before importing.")
        } else {
            alert.messageText = uiText("Import Connections from Arc?")
            alert.informativeText = uiText("Orbit will save your tabs and restart. Allow access to Arc Safe Storage when macOS asks. Arc connections replace matching cookies and site storage in the corresponding profiles. A backup lets you undo the import.")
        }
        alert.addButton(withTitle: uiText(restoring ? "Restore and Restart" : orbitRunning ? "Quit Arc" : "Import and Restart"))
        alert.addButton(withTitle: uiText("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func show(_ result: ArcSiteSessionResult?, failed: Bool = false) {
        let alert = OrbitFloatingMaterial.alert()
        if failed {
            alert.messageText = uiText("Connections Could Not Be Imported")
            alert.informativeText = uiText("Your existing connections were kept. Check that Arc is closed and allow Keychain access, then try again.")
        } else if let result {
            alert.messageText = uiText(result.restored ? "Connections Restored" : "Connections Imported")
            alert.informativeText = result.restored
                ? "\(result.profiles) " + uiText("profiles restored.")
                : "\(result.profiles) " + uiText("profiles and") + " \(result.cookies) " + uiText("cookies imported.")
            if result.failedProfiles > 0 {
                alert.informativeText += "\n\(result.failedProfiles) " + uiText("profiles could not be imported; their previous data was kept.")
            }
        } else { return }
        alert.addButton(withTitle: uiText("OK"))
        alert.runModal()
    }
}

extension OrbitApplication {
    /// `continuingArcImport`: second step of File › Import from Arc…; engines without offline
    /// session import (WebKit previews) end the import there silently.
    func startArcSiteSessionImport(restoring: Bool = false, continuingArcImport: Bool = false) {
        guard !isPreparingToQuit, !isImportingSiteSessions, !browserImport.isRunning, pendingBrowserImport == nil, pendingSiteSessionRequest == nil,
              let configuration = activeSiteSessionConfiguration(), let environment else {
            if !continuingArcImport { NSSound.beep() }
            return
        }
        isImportingSiteSessions = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isImportingSiteSessions = false }
            let importer = ArcSiteSessionImport(dataRoot: configuration.dataRoot)
            if restoring, !importer.hasBackup {
                showSiteSessionMessage("No Connection Backup", "There is no connection import backup to restore.")
                return
            }
            let source = OrbitImportLaunchOptions.source(ProcessInfo.processInfo.arguments)
            let usesPersonalArc = source.standardizedFileURL == ArcSourceSnapshot.defaultSourceRoot.standardizedFileURL
            let running = usesPersonalArc && !restoring
                ? NSRunningApplication.runningApplications(withBundleIdentifier: "company.thebrowser.Browser") : []
            guard ArcSiteSessionAlerts.confirm(orbitRunning: !running.isEmpty, restoring: restoring) else { return }
            // Only this explicit button press authorizes normal termination of the source app.
            for application in running { _ = application.terminate() }
            let deadline = ContinuousClock.now + .seconds(60)
            while running.contains(where: { !$0.isTerminated }) {
                guard ContinuousClock.now < deadline else {
                    showSiteSessionMessage("Arc Is Still Open", "Finish quitting Arc, then import your connections again.")
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            do {
                let pairs: [ArcSiteSessionProfile]
                if restoring { pairs = [] }
                else {
                    let ledgerURL = ArcImportDataLocation(sessionFile: configuration.sessionFile).ledgerFile
                    let ledger = try JSONDecoder().decode(BrowserImportLedger.self, from: Data(contentsOf: ledgerURL))
                    let catalog = await environment.store.catalogSnapshot()
                    let existing = Set(catalog.profiles.map(\.id))
                    pairs = ledger.profileTargets.compactMap { key, target in
                        guard let directory = key.directory, existing.contains(target) else { return nil }
                        return ArcSiteSessionProfile(sourceDirectory: directory, targetID: target)
                    }.sorted { $0.sourceDirectory < $1.sourceDirectory }
                    guard !pairs.isEmpty else { throw ArcSiteSessionImport.Failure.invalidProfile }
                }
                pendingSiteSessionRequest = .init(action: restoring ? .restore : .importSessions,
                    sourceRoot: source.appendingPathComponent("User Data", isDirectory: true), profiles: pairs)
                NSApp.terminate(nil)
            } catch {
                showSiteSessionMessage("Connections Could Not Be Imported", "Orbit could not find the imported Arc profiles. Choose File → Import from Arc… again.")
            }
        }
    }

    /// Called after the normal session save, before engine shutdown. A cancelled quit never
    /// leaves an import waiting to surprise the user on a later unrelated launch.
    func persistPendingSiteSessionImport() throws {
        guard let request = pendingSiteSessionRequest, let configuration = activeSiteSessionConfiguration() else { return }
        try ArcSiteSessionImport(dataRoot: configuration.dataRoot).schedule(request)
        wantsSiteSessionRelaunch = true
    }

    func presentSiteSessionImportOutcome() {
        guard OrbitLauncher.siteSessionResult != nil || OrbitLauncher.siteSessionFailed else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            ArcSiteSessionAlerts.show(OrbitLauncher.siteSessionResult, failed: OrbitLauncher.siteSessionFailed)
            OrbitLauncher.siteSessionResult = nil
            OrbitLauncher.siteSessionFailed = false
        }
    }

    private func showSiteSessionMessage(_ title: String, _ text: String) {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText(title)
        alert.informativeText = uiText(text)
        alert.addButton(withTitle: uiText("OK"))
        alert.runModal()
    }
}
