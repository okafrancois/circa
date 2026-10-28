import BrowserCore
import BrowserEngine

extension BrowserEnvironment {
    func recordActiveWindow(_ controller: BrowserWindowController<Engine>) {
        guard !isFinalizing, let snapshot = controller.session?.snapshot else { return }
        lastUsedSpaceID = snapshot.activeSpaceID
        if let activity = lastRecordedWindowActivity, activity.0 == snapshot.id && activity.1 == snapshot.activeSpaceID { return }
        lastRecordedWindowActivity = (snapshot.id, snapshot.activeSpaceID)
        let previous = windowActivitySave
        windowActivitySave = Task { [weak self] in
            await previous?.value
            guard let self, !settings.isUnavailable else { return }
            do { try await settings.store.setLastActiveWindow(snapshot.id, spaceID: snapshot.activeSpaceID) }
            catch {
                if let activity = lastRecordedWindowActivity, activity.0 == snapshot.id && activity.1 == snapshot.activeSpaceID {
                    lastRecordedWindowActivity = nil
                }
            } // Optional activity metadata never invalidates the tab session.
        }
    }
}
