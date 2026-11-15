import AppKit
import BrowserCore
import BrowserEngine

/// Each private window owns a fresh memory-only environment and Chromium request context.
/// Its tabs, popups, history, permissions and downloads never borrow the normal services.
@MainActor
struct OrbitPrivateWindow {
    let scope: BrowserPrivateDomainScope<ActiveEngine>
    let lease: BrowserPrivateDomainLease
    let environment: OrbitEnvironment
    /// The normal profile whose ad and tracker blocking switch and exceptions the window follows.
    let parent: ProfileID?
}

extension OrbitApplication {
    func createPrivateCommandWindow() {
        guard !isPreparingToQuit, environment != nil else { return }
        // The parent profile: the selected normal window's profile, or a private window's parent.
        let source = windows.selectedWindow
        let sourceParent = source.flatMap { privateWindows[$0.id]?.parent }
            ?? (source?.isPrivateWindow == false ? source?.session.activeProfileID : nil)
        let previous = privateWindowCommands
        privateWindowCommands = Task { [weak self] in
            await previous?.value
            guard let self, !isPreparingToQuit, let normal = environment else { return }
            if privateWindowFactory == nil {
                privateWindowFactory = BrowserPrivateDomainFactory(normalEnvironment: normal, build: { makePrivateEngine() })
            }
            guard let scope = privateWindowFactory?.makeScope() else { return }
            // Without private filtering the window opens without blocking or its row.
            let blocking = normal.contentBlocking?.supportsPrivateWindows == true ? normal.contentBlocking : nil
            var lease: BrowserPrivateDomainLease?
            do {
                let acquired = try await scope.acquire()
                lease = acquired
                let memory = try scope.environment(for: acquired)
                guard !isPreparingToQuit else { try await scope.release(acquired); return }
                let id = UUID()
                var parent = sourceParent
                if parent == nil { parent = try? await normal.initialContext.value.1 }
                privateWindows[id] = OrbitPrivateWindow(scope: scope, lease: acquired, environment: memory, parent: parent)
                // Blocking is in place before the window's first page: the engine applies the
                // private configuration in the browser process.
                if let blocking, let parent {
                    memory.privateContentBlocking = blocking
                    await blocking.openPrivateWindow(id, parent: parent)
                }
                guard windows.newWindow(id: id) != nil else { releasePrivateWindow(id); return }
                await windows.waitForPendingCommands()
                guard let controller = windows.windows[id] else { releasePrivateWindow(id); return }
                // Bang aliases are app-wide preferences; private navigation stays in this domain.
                controller.palette.bangSiteSearches = { [weak normal] in
                    normal?.settings.document.siteSearches ?? BrowserSiteSearch.builtIns
                }
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
        if let blocking = owned.environment.privateContentBlocking {
            // At once: a window opened right after the last one closed starts a fresh session.
            blocking.endPrivateWindow(id)
            Task { await blocking.synchronizePrivate() }
        }
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
