import AppKit
import BrowserCore

@MainActor
enum ImportRecoveryAlert {
    /// Only used under the startup gate's exclusive data-directory and instance locks.
    struct OfflineUsage: OrbitTargetUsageProbe {
        func isInUse(sessionFile: URL) -> Bool { false }
    }
    static func recoverStructural(sessionFile: URL) throws {
        let location = ArcImportDataLocation(sessionFile: sessionFile)
        if let backup = try ArcImportBackups.interruptedImportBackup(at: location) {
            _ = (NSClassFromString("ACRApplication") as? NSApplication.Type)?.shared
            _ = choose()
            try ArcImportBackups.restore(backup, at: location, usage: OfflineUsage(), holdingLock: true)
        }
    }
    static func choose() -> BrowserImportRecovery.Choice {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        let alert = OrbitFloatingMaterial.alert()
        alert.alertStyle = .warning
        alert.messageText = uiText("An import was interrupted")
        alert.informativeText = uiText("Restore your data from before the import, or continue without the incomplete import. Your existing profiles will be kept.")
        alert.addButton(withTitle: uiText("Restore"))
        alert.addButton(withTitle: uiText("Continue without the import"))
        alert.buttons[0].keyEquivalent = "\r"
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn ? .continueWithoutImport : .restore
    }
    static func showQuarantineNotice() {
        let alert = OrbitFloatingMaterial.alert()
        alert.messageText = uiText("Your previous data is ready")
        alert.informativeText = uiText("The import could not be restored normally. Orbit recovered your previous data and moved the incomplete import aside for safekeeping.")
        alert.addButton(withTitle: uiText("OK"))
        alert.runModal()
    }
}
