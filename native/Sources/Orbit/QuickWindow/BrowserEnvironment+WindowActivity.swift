import BrowserCore
import BrowserEngine

extension BrowserEnvironment {
    /// Remembers the active window and Space at once, and writes them to settings after
    /// `windowActivityDelay` without further changes: a run of Space switches or swipes costs one
    /// write. Saving the session, resigning active and quitting flush the pending value.
    func recordActiveWindow(_ controller: BrowserWindowController<Engine>) {
        guard !isFinalizing, let snapshot = controller.session?.snapshot else { return }
        lastUsedSpaceID = snapshot.activeSpaceID
        if let activity = lastRecordedWindowActivity, activity.0 == snapshot.id && activity.1 == snapshot.activeSpaceID { return }
        lastRecordedWindowActivity = (snapshot.id, snapshot.activeSpaceID)
        pendingWindowActivity = (snapshot.id, snapshot.activeSpaceID)
        windowActivityDebounce?.cancel()
        let delay = windowActivityDelay
        windowActivityDebounce = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            windowActivityDebounce = nil
            writePendingWindowActivity()
        }
    }

    /// Writes any pending activity now and waits until every queued activity write finished.
    func flushWindowActivity() async {
        windowActivityDebounce?.cancel()
        windowActivityDebounce = nil
        writePendingWindowActivity()
        await windowActivitySave?.value
    }

    private func writePendingWindowActivity() {
        guard let (windowID, spaceID) = pendingWindowActivity else { return }
        pendingWindowActivity = nil
        let previous = windowActivitySave
        windowActivitySave = Task { [weak self] in
            await previous?.value
            guard let self, !settings.isUnavailable else { return }
            do { try await settings.store.setLastActiveWindow(windowID, spaceID: spaceID) }
            catch {
                if let activity = lastRecordedWindowActivity, activity.0 == windowID && activity.1 == spaceID {
                    lastRecordedWindowActivity = nil
                }
            } // Optional activity metadata never invalidates the tab session.
        }
    }
}
