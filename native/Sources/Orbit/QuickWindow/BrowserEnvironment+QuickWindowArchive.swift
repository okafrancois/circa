import BrowserCore
import BrowserEngine
import Foundation

extension BrowserEnvironment {
    func captureQuickWindowForReopening(_ controller: BrowserQuickWindowWindowController<Engine>, surface: Engine.Surface) {
        // The engine's ephemeral profile policy is the same privacy boundary as HISTORY.
        guard engine.profile(for: controller.profileID).persistence == .persistent,
              let url = surface.currentURL, url.absoluteString != "about:blank" else { return }
        let date = Date()
        let tab = BrowserOrganizedTab(id: controller.archiveID, url: url, pageTitle: surface.navigationState.title,
                                      createdAt: date, lastActiveAt: date)
        pendingQuickWindowArchives[controller.archiveID] = .init(tab: tab, profileID: controller.profileID,
            spaceID: controller.sourceSpaceID, origin: .today, reason: .closed, archivedAt: date)
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
