import BrowserCore
import Foundation

extension BrowserEnvironment {
    func moveSpaceToProfile(_ id: SpaceID, to profile: ProfileID, expectedProfileID: ProfileID) async throws {
        guard !settingsRemovalIsRunning, !isFinalizing else {
            throw BrowserTerminationPreparationError.commandsDidNotSettle
        }
        settingsRemovalIsRunning = true
        defer { settingsRemovalIsRunning = false }
        for controller in liveControllers { await controller.session.waitForPendingCommands() }
        try await flushQuickWindowArchives()
        let before = await store.sessionDocument()
        guard before.spaces.first(where: { $0.id == id })?.profileID == expectedProfileID else {
            throw BrowserStoreError.staleContext
        }
        guard before.profiles.contains(where: { $0.id == profile }) else { throw BrowserStoreError.profileMissing }
        guard profile != expectedProfileID else { return }
        try await persistSettingsRemovalSession()
        if let sessionFile {
            let location = ArcImportDataLocation(sessionFile: sessionFile)
            _ = try await Task.detached(priority: .utility) {
                try ArcImportBackups.createSessionBackup(at: location, document: before)
            }.value
        }
        try await store.moveSpaceToProfile(id, to: profile, expectedProfileID: expectedProfileID)
        for little in Array(quickWindows.values) where little.sourceSpaceID == id {
            if let surface = little.surface { captureQuickWindowForReopening(little, surface: surface) }
            little.retire()
            little.window?.close()
        }
        for controller in liveControllers {
            if controller.session.snapshot?.activeSpaceID == id {
                controller.peek.dismiss(animated: false, remember: false)
                controller.peek.forgetDismissed()
            }
            controller.session.refreshAfterSpaceProfileMove()
        }
        for controller in liveControllers { await controller.session.waitForPendingCommands() }
        try await flushQuickWindowArchives()
        try await persistSettingsRemovalSession()
    }
}
