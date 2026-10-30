import BrowserCore
import BrowserEngine
import Foundation

extension BrowserEnvironment {
    func captureQuickWindowForReopening(_ controller: BrowserQuickWindowWindowController<Engine>, surface: Engine.Surface,
                                        reason: BrowserArchivedTab.Reason = .closed) {
        // The engine's ephemeral profile policy is the same privacy boundary as HISTORY.
        guard engine.profile(for: controller.profileID).persistence == .persistent,
              let url = surface.currentURL, url.absoluteString != "about:blank" else { return }
        let date = quickWindowClock()
        let tab = BrowserOrganizedTab(id: controller.archiveID, url: url, pageTitle: surface.navigationState.title,
                                      createdAt: controller.archiveOpenedAt, lastActiveAt: date)
        pendingQuickWindowArchives[controller.archiveID] = .init(tab: tab, profileID: controller.profileID,
            spaceID: controller.sourceSpaceID, origin: .quickWindow, reason: reason, archivedAt: date)
    }

    func startQuickWindowArchiveTimer() {
        guard quickWindowArchiveTimer == nil, !quickWindows.isEmpty, !isFinalizing else { return }
        quickWindowArchiveTimer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self else { return }
                await sweepQuickWindowArchives()
            }
        }
    }

    /// One environment sweep; tests inject wall time and invoke it without waiting.
    func sweepQuickWindowArchives() async {
        guard !isFinalizing, !settingsRemovalIsRunning, !quickWindowArchiveSweepInProgress,
              let interval = settings.document.quickWindowArchiveThreshold.interval else { return }
        quickWindowArchiveSweepInProgress = true
        defer { quickWindowArchiveSweepInProgress = false }
        let now = quickWindowClock()
        for controller in Array(quickWindows.values) {
            guard now.timeIntervalSince(controller.archiveOpenedAt) >= interval,
                  controller.beginAutoArchive() else { continue }
            defer { controller.endAutoArchive() }
            guard let surface = controller.surface else { continue }
            captureQuickWindowForReopening(controller, surface: surface, reason: .automatic)
            do {
                try await flushQuickWindowArchives()
                try await persistSettingsRemovalSession()
                guard !controller.isClosed, !isFinalizing, !controller.isPreparingForTermination else { continue }
                controller.retire()
                controller.window?.close()
            } catch { onPersistenceError?(error) }
        }
    }

    func scheduleQuickWindowArchiveSave() {
        let previous = quickWindowArchiveSave
        quickWindowArchiveSave = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do { try await persistPendingQuickWindowArchives(); scheduleSave() }
            catch { onPersistenceError?(error) } // Retain the pending records for retry.
        }
    }

    func flushQuickWindowArchives() async throws {
        await quickWindowArchiveSave?.value
        try await persistPendingQuickWindowArchives()
    }

    private func persistPendingQuickWindowArchives() async throws {
        for record in Array(pendingQuickWindowArchives.values) {
            // A user's profile deletion owns its pending snapshots too. Quarantine is
            // retryable; a finished deletion must neither resurrect data nor block Quit.
            if await store.isSettingsProfileBeingRemoved(record.profileID) { continue }
            let catalog = await store.catalogSnapshot()
            guard catalog.profiles.contains(where: { $0.id == record.profileID }) else {
                if pendingQuickWindowArchives[record.id] == record { pendingQuickWindowArchives[record.id] = nil }
                continue
            }
            do { try await store.archiveQuickWindow(record) }
            catch {
                if await store.isSettingsProfileBeingRemoved(record.profileID) { continue }
                if await !store.catalogSnapshot().profiles.contains(where: { $0.id == record.profileID }) {
                    if pendingQuickWindowArchives[record.id] == record { pendingQuickWindowArchives[record.id] = nil }
                    continue
                }
                throw error
            }
            if pendingQuickWindowArchives[record.id] == record { pendingQuickWindowArchives[record.id] = nil }
        }
    }
}
