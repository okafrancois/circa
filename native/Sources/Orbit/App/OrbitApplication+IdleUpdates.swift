import AppKit
import BrowserEngine

extension OrbitApplication {
    private var updateSurfaces: [ActiveEngine.Surface] {
        let environments = [environment].compactMap { $0 } + privateWindows.values.map(\.environment)
        return environments.flatMap { environment in
            environment.liveControllers.flatMap { $0.session.ownedSurfaces }
                + environment.quickWindows.values.compactMap(\.surface) + environment.rescue.surfaces
        }.filter { !$0.isDisposed }
    }

    func configureIdleUpdates() {
        let source = OrbitIdleUpdateSignalsSource()
        updater.idleSignals = { [weak self, source] in
            guard let self else { return .init() }
            let media = updateSurfaces.contains { surface in
                guard let state = surface.pagePerformance?.lifecycle() else { return true }
                return state.playingMedia || state.playingVideo || state.audioContextRunning
                    || state.audible || state.pictureInPicture || state.capturing != 0 || state.webRTC
            }
            return source.sample(mediaPlaying: media || environment?.downloads.hasActiveTransfers == true
                || privateWindows.values.contains { $0.environment.downloads.hasActiveTransfers }
                || NSApp.modalWindow != nil || isStartingUp || settingsWindow?.model.isRequestingDefaultBrowser == true)
        }
        updater.mediaPreventsAutomaticInstallation = { [weak self] in
            guard let self else { return true }
            let surfaces = updateSurfaces
            for surface in surfaces {
                if surface.isSuspended { continue }
                let state = await surface.requestMediaState()
                if state.playback == .playing || state.playback == .unknown || state.camera == .active
                    || state.microphone == .active || state.isAudible == true || state.isAudioPlaying == true { return true }
            }
            // A newly created window/document is checked on the next tick.
            return Set(surfaces.map(ObjectIdentifier.init)) != Set(updateSurfaces.map(ObjectIdentifier.init))
        }
    }
}
