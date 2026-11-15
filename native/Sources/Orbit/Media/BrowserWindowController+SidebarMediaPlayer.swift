import AppKit
import BrowserCore
import BrowserEngine

/// The sidebar player: media still playing in a tab the user left keeps its controls above the
/// footer. The stack follows the user into every Space of the window and leaves out tabs shown
/// in a pane, cards the user closed and media in Picture in Picture.
extension BrowserWindowController {
    func installSidebarMediaPlayer() {
        onBackgroundMediaChange = { [weak self] in self?.renderSidebarMediaPlayer() }
        let player = sidebar.mediaPlayer
        player.onRestingHeightChange = { [weak self] in self?.sidebar.needsLayout = true }
        player.onBackToTab = { [weak self] id in self?.submitInput { $0.returnToMediaTab(id) } }
        player.onToggle = { [weak self] id in self?.submitInput { $0.toggleBackgroundMedia(id) } }
        player.onPrevious = { [weak self] id in
            self?.submitInput { $0.performBackgroundMediaAction(.previous, on: id) }
        }
        player.onNext = { [weak self] id in
            self?.submitInput { $0.performBackgroundMediaAction(.next, on: id) }
        }
        player.onReveal = { [weak self] in self?.refreshManualPiPCapabilities(force: true) }
        player.onSeek = { [weak self] id, seconds in
            self?.submitInput { owner in _ = owner.backgroundMedia.perform(.seek, on: id, seconds: seconds) }
        }
        player.onMute = { [weak self] id in
            self?.submitInput { owner in
                guard let muted = owner.backgroundMedia.session(for: id)?.isAudioMuted,
                      let surface = owner.session.surface(for: id) else { return }
                do { try surface.setAudioMuted(!muted) } catch { return }
                Task { [weak owner, weak surface] in
                    guard let surface else { return }
                    let audio = await surface.requestMediaState()
                    guard let owner, owner.session.surface(for: id) === surface else { return }
                    owner.backgroundMedia.updateAudio(audio, for: id)
                }
            }
        }
        player.onPiP = { [weak self] id in
            guard let self, let adapter = session.surface(for: id)?.manualPictureInPicture else { return }
            mediaPlayerState.pipTasks[id]?.cancel()
            mediaPlayerState.pipTasks[id] = Task { [weak self] in
                await adapter.toggle()
                self?.mediaPlayerState.pipTasks[id] = nil
            }
        }
        player.onClose = { [weak self] id in self?.submitInput { $0.closeBackgroundMedia(id) } }
    }

    func shutDownSidebarMediaPlayer() {
        onBackgroundMediaChange = nil
        mediaPlayerState.cancelObservers()
        sidebar.mediaPlayer.apply([])
    }

    func renderSidebarMediaPlayer() {
        guard backgroundMediaObserver != nil, !session.isClosed else {
            sidebar.mediaPlayer.apply([])
            return
        }
        let entries = backgroundMedia.sessions
        observePictureInPicture(entries.map(\.occurrenceID))
        refreshManualPiPCapabilities()
        let shown = mediaPlayerState.shown(entries.map { ($0.occurrenceID, $0.session) },
            visible: session.visibleOccurrenceIDs,
            pictureInPicture: { [session] id in session.surface(for: id)?.pagePerformance?.lifecycle()?.pictureInPicture == true })
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.occurrenceID, $0) })
        let items = shown.compactMap { id -> SidebarMediaPlayerItem? in
            guard let entry = byID[id] else { return nil }
            let presentation = mediaPresentation(id, tabID: entry.tabID)
            var item = SidebarMediaPlayerState.item(id: id, session: entry.session, title: presentation.title,
                favicon: presentation.favicon, pausedFromPlayer: mediaPlayerState.pausedFromPlayer.contains(id))
            item.trackIdentity = [entry.session.title, entry.session.artist, entry.session.album].joined(separator: "\u{0}")
            item.position = entry.session.position
            item.duration = entry.session.duration
            item.playbackRate = entry.session.playback == .playing ? entry.session.playbackRate : nil
            item.canSeek = entry.session.actions.contains(.seek)
            item.isMuted = entry.session.isAudioMuted
            item.pipFailure = session.surface(for: id)?.manualPictureInPicture?.failure ?? .rejected
            item.pip = session.surface(for: id)?.manualPictureInPicture?.state ?? .unavailable
            return item
        }
        // The window resolves a theme change's appearance only once its colour transition ends;
        // the card takes the destination Space's light or dark style at once.
        let appearance = OrbitAppearance.windowAppearance(for: windowShell.theme.mode)
        if sidebar.mediaPlayer.appearance != appearance { sidebar.mediaPlayer.appearance = appearance }
        sidebar.mediaPlayer.apply(items)
    }

    func refreshManualPiPCapabilities(force: Bool = false) {
        let ids = Set(backgroundMedia.sessions.map(\.occurrenceID))
        for id in Array(mediaPlayerState.pipTasks.keys) where !ids.contains(id) {
            mediaPlayerState.pipTasks.removeValue(forKey: id)?.cancel()
            mediaPlayerState.pipQueryTimes.removeValue(forKey: id)
        }
        for id in ids {
            guard let adapter = session.surface(for: id)?.manualPictureInPicture else { continue }
            adapter.onChange = { [weak self] in self?.renderSidebarMediaPlayer() }
            adapter.acknowledge(active: session.surface(for: id)?.pagePerformance?.lifecycle()?.pictureInPicture == true)
            guard mediaPlayerState.pipTasks[id] == nil,
                  force || Date().timeIntervalSince(mediaPlayerState.pipQueryTimes[id] ?? .distantPast) > 1 else { continue }
            mediaPlayerState.pipQueryTimes[id] = Date()
            mediaPlayerState.pipTasks[id] = Task { [weak self] in
                await adapter.refresh()
                self?.mediaPlayerState.pipTasks[id] = nil
            }
        }
    }

    /// The tab's sidebar title and icon while its Space is shown; the last known ones otherwise.
    private func mediaPresentation(_ id: TabOccurrenceID, tabID: TabID) -> (title: String, favicon: NSImage?) {
        if let item = session.organization?.tab(tabID), item.occurrenceID == id {
            let title = item.customTitle ?? sidebar.liveTitle(item).flatMap { $0.isEmpty ? nil : $0 }
                ?? item.pageTitle ?? item.url.host ?? SidebarListStrings.newTab
            mediaPlayerState.titles[id] = title
            if let favicon = sidebar.liveActivity(item).favicon { mediaPlayerState.favicons[id] = favicon }
        } else if mediaPlayerState.titles[id] == nil,
                  let title = session.surface(for: id)?.navigationState.title, !title.isEmpty {
            mediaPlayerState.titles[id] = title
        }
        return (mediaPlayerState.titles[id] ?? SidebarListStrings.newTab, mediaPlayerState.favicons[id])
    }

    /// Picture in Picture starts after the tab is left; its lifecycle change re-renders the stack.
    private func observePictureInPicture(_ ids: [TabOccurrenceID]) {
        let wanted = Set(ids)
        for (id, observer) in mediaPlayerState.lifecycleObservers where !wanted.contains(id) {
            observer.task.cancel()
            mediaPlayerState.lifecycleObservers.removeValue(forKey: id)
        }
        for id in ids {
            guard let surface = session.surface(for: id), let performance = surface.pagePerformance else { continue }
            let identity = ObjectIdentifier(surface)
            if mediaPlayerState.lifecycleObservers[id]?.surface == identity { continue }
            mediaPlayerState.lifecycleObservers[id]?.task.cancel()
            let stream = performance.changes()
            let task = Task { [weak self, weak surface] in
                var pictureInPicture = surface?.pagePerformance?.lifecycle()?.pictureInPicture == true
                for await change in stream {
                    guard !Task.isCancelled, let self else { return }
                    let next = change.state?.pictureInPicture ?? (surface?.pagePerformance?.lifecycle()?.pictureInPicture == true)
                    if next != pictureInPicture { pictureInPicture = next; renderSidebarMediaPlayer() }
                }
            }
            mediaPlayerState.lifecycleObservers[id] = (identity, task)
        }
    }

    func returnToMediaTab(_ id: TabOccurrenceID) {
        guard session.tabID(for: id) != nil else { return }
        hideLibrary()
        if let spaceID = session.spaceID(for: id), spaceID != session.snapshot?.activeSpaceID {
            session.activateSpace(spaceID)
        }
        session.selectOccurrence(id)
    }

    func toggleBackgroundMedia(_ id: TabOccurrenceID) {
        guard let media = backgroundMedia.session(for: id) else { return }
        let action: BrowserMediaAction = media.playback == .playing ? .pause : .play
        mediaPlayerState.willPerform(action, on: id)
        if performBackgroundMediaAction(action, on: id) != .performed {
            mediaPlayerState.didFail(action, on: id)
        }
        renderSidebarMediaPlayer()
    }

    /// Removes the card and stops the sound; the tab stays open.
    func closeBackgroundMedia(_ id: TabOccurrenceID) {
        mediaPlayerState.dismiss(id)
        if backgroundMedia.session(for: id)?.playback == .playing {
            performBackgroundMediaAction(.pause, on: id)
        }
        renderSidebarMediaPlayer()
    }
}
