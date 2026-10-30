import AppKit
import BrowserCore

/// Each private window owns a fresh memory-only environment and Chromium request context.
/// Its tabs, popups, history, permissions and downloads never borrow the normal services.
@MainActor
struct OrbitPrivateWindow {
    let scope: BrowserPrivateDomainScope<ActiveEngine>
    let lease: BrowserPrivateDomainLease
    let environment: OrbitEnvironment
}

extension OrbitApplication {
    func createPrivateCommandWindow() {
        guard !isPreparingToQuit, environment != nil else { return }
        let previous = privateWindowCommands
        privateWindowCommands = Task { [weak self] in
            await previous?.value
            guard let self, !isPreparingToQuit, let normal = environment else { return }
            if privateWindowFactory == nil {
                privateWindowFactory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { makePrivateEngine() })
            }
            guard let scope = privateWindowFactory?.makeScope() else { return }
            var lease: BrowserPrivateDomainLease?
            do {
                let acquired = try await scope.acquire()
                lease = acquired
                let memory = try scope.environment(for: acquired)
                guard !isPreparingToQuit else { try await scope.release(acquired); return }
                let id = UUID()
                privateWindows[id] = OrbitPrivateWindow(scope: scope, lease: acquired, environment: memory)
                guard windows.newWindow(id: id) != nil else { releasePrivateWindow(id); return }
                await windows.waitForPendingCommands()
                guard let controller = windows.windows[id] else { releasePrivateWindow(id); return }
                controller.palette.present(.newTab)
            } catch {
                if let lease { try? await scope.release(lease) }
                // The error contains no URL, cookie or other document content.
                FileHandle.standardError.write(Data("orbit: could not open the private window\n".utf8))
                NSSound.beep()
            }
        }
    }

    func waitForPrivateWindowCommands() async { await privateWindowCommands?.value }

    func releasePrivateWindow(_ id: UUID) {
        guard let owned = privateWindows.removeValue(forKey: id) else { return }
        privateWindowClosures[id] = Task { [weak self] in
            do { try await owned.scope.release(owned.lease) }
            catch {
                // The factory retains failed cleanup and retries before process shutdown.
                FileHandle.standardError.write(Data("orbit: private context cleanup will be retried\n".utf8))
            }
            self?.privateWindowClosures[id] = nil
        }
    }

    func closePrivateWindows() async {
        await waitForPrivateWindowCommands()
        for id in Array(privateWindows.keys) {
            windows.windows[id]?.window?.close()
            releasePrivateWindow(id)
        }
        for task in Array(privateWindowClosures.values) { await task.value }
        try? await privateWindowFactory?.retryQuarantinedScopes()
    }

    /// External links and Little Circa destinations must never inherit a private profile.
    func selectNormalWindowForExternalRequest() {
        let pendingPrivate = windows.selectedWindowID.flatMap { privateWindows[$0] } != nil
        guard pendingPrivate || windows.selectedWindow?.isPrivateWindow == true else { return }
        if let normal = windows.windows.values.first(where: { !$0.isPrivateWindow && !$0.session.isClosed }) {
            windows.activate(normal.id)
        } else {
            windows.newWindow()
        }
    }
}
