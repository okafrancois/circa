import AppKit
import BrowserCore
import BrowserEngine

/// Window-owned feature object. Every delayed action is tied to the exact surface, committed
/// document generation and selection epoch; switching A → B → A never revives old actions.
@MainActor
final class BrowserSiteControls<Engine: BrowserEngine> {
    typealias Surface = Engine.Surface
    private weak var owner: (any BrowserSiteControlsHost<Engine>)?
    let policy = BrowserSitePermissionPolicy(store: BrowserSitePermissionStore.ephemeral())
    var preferences = try! BrowserSitePreferenceStore()
    private weak var lastSelectedSurface: Surface?
    var onPreferencesChange: (() -> Void)?
    private(set) var mediaStates: [ObjectIdentifier: BrowserMediaState] = [:]
    /// Sidebar integration hook. Unknown audibility/mute remain nil; playing is not audible.
    var onMediaStateChange: ((Surface, BrowserMediaState) -> Void)?
    /// Injectable presentation boundary for hidden synthetic tests and alternative hosts.
    var permissionPrompt: ((BrowserSiteOrigin, [BrowserSitePermission]) async -> BrowserSitePermissionChoice)?
    private let button = SiteControlButton("", identifier: "site-controls", onPress: {})
    private var extensionObservation: BrowserExtensionObservation?
    private var extensionTiles: [String: ControlCenterActionTile] = [:]
    private var displayedExtensionIDs: [String] = []
    private var displayedPinStates: [String: Bool] = [:]
    private var hasPendingPinChange = false
    private var engineObserver: BrowserHookRegistration?
    private let panel = BrowserSitePopover()
    private weak var presentationAnchor: NSView?
    private var sharePicker: NSSharingServicePicker?
    private let permissionPanel = BrowserSitePopover()
    private var pendingPermission: ((BrowserSitePermissionChoice) -> Void)?
    /// The document whose request the pending prompt answers.
    private var pendingPermissionSurface: ObjectIdentifier?
    private var selection: ObjectIdentifier?
    private var generation: UInt64?
    private var epoch: UInt64 = 0
    private var isShowingSiteControls = false
    private var presentationGeneration: UInt64 = 0
    private var presentationTask: Task<Void, Never>?
    /// Injectable snapshot boundary for hidden delayed-presentation tests.
    var presentationSettings: ((BrowserSiteOrigin, ProfileID) async -> [BrowserSitePermission: BrowserSitePermissionSetting])?
    /// Explicit owned presentations, independent of AppKit's unrelated child windows.
    var isPopoverShown: Bool { panel.popover.isShown || permissionPanel.popover.isShown }
    func extensionInventoryBecameReady(in profile: ProfileID) {
        guard isShowingSiteControls, panel.popover.isShown,
              owner?.siteControlSurface?.profileID == profile else { return }
        if !refreshExtensionPins() { show(presentationAnchor: presentationAnchor) }
    }
    private func refreshExtensionPins() -> Bool {
        guard hasPendingPinChange else { return false }
        hasPendingPinChange = false
        guard let surface = owner?.siteControlSurface, let host = owner?.engine.extensions,
              let installed = try? host.installedExtensions(in: surface.profileID) else { return false }
        let items = installed.filter { $0.isEnabled && $0.hasAction }
        guard !items.isEmpty, items.map(\.id) == displayedExtensionIDs,
              items.contains(where: { displayedPinStates[$0.id] != ($0.isPinned == true) }) else { return false }
        for item in items {
            guard let tile = extensionTiles[item.id] else { return false }
            tile.setPinned(item.isPinned == true)
            displayedPinStates[item.id] = item.isPinned == true
        }
        onPreferencesChange?()
        return true
    }
    private var mediaTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var mediaRefreshNeeded: Set<ObjectIdentifier> = []
    var permissionsUnavailable = false
    private(set) var statusMessage: String?

    init(owner: any BrowserSiteControlsHost<Engine>) {
        self.owner = owner
        panel.usesOrbitStyle = true
        panel.onWillClose = { [weak self] in self?.invalidateSitePresentation() }
        button.image = OrbitGlyph.siteControlCenter
        button.setAccessibilityLabel(siteText("controls", "Site Controls"))
        button.isBordered = false
        button.toolTip = siteText("controls", "Site Controls")
        button.onPress = { [weak self] in self?.toggle() }
        policy.onPersistenceFailure = { [weak self] choice in
            self?.statusMessage = choice == .block
                ? siteText("error.blockNotSaved", "Blocked for this session, but the setting could not be saved. The previous setting may return after relaunch.")
                : siteText("error.allowNotSaved", "The setting could not be saved. The new access was denied.")
        }
        policy.onPersistedDecision = { [weak self, weak owner] profileID, origin, permissions, setting in
            self?.statusMessage = nil
            guard let service = owner?.engine as? any BrowserSitePermissionAvailability else { return }
            for permission in permissions {
                await service.setSitePermission(setting, permission: permission, origin: origin, profileID: profileID)
            }
        }
    }

    func install() {
        if engineObserver == nil {
            engineObserver = owner?.engineEventHooks.observe { [weak self] surface, event in
                guard let self else { return }
                switch event {
                case .navigationStarted: navigationWillStart(surface)
                case .stateChanged: render()
                case .navigationCommitted, .navigationFinished, .navigationFailed, .navigatedWithinDocument: break
                }
            }
        }
        owner?.installSiteControlsButton(button)
    }

    func render() {
        guard let owner else { return }
        let surface = owner.siteControlSurface
        if lastSelectedSurface !== surface {
            if let previous = lastSelectedSurface, owner.owns(previous), !owner.siteControlsClosed {
                let settings = preferences.preferences(url: previous.navigationState.committedURL, profileID: previous.profileID)
                previous.updateAutomaticPictureInPicture(isSelected: false, allowed: settings.automaticPictureInPicture && owner.allowsAutomaticPictureInPicture)
            }
            lastSelectedSurface = surface
            surface?.updateAutomaticPictureInPicture(isSelected: true, allowed: true)
        }
        if !owner.allowsAutomaticPictureInPicture {
            for background in owner.siteControlSurfaces where background !== surface {
                background.updateAutomaticPictureInPicture(isSelected: false, allowed: false)
            }
        }
        let key = surface.map(ObjectIdentifier.init)
        if selection != key || generation != surface?.findDocumentGeneration || owner.siteControlsClosed {
            epoch &+= 1
            statusMessage = nil
            selection = key
            generation = surface?.findDocumentGeneration
            cancelPermission()
            stopObservingExtensions()
            panel.close()
        }
        button.isEnabled = surface != nil && !owner.isPreparingForTermination
        button.toolTip = permissionsUnavailable ? siteText("permissions.unavailableShort", "Permissions unavailable — session kept") : siteText("controls", "Site Controls")
        let ownedKeys = Set(owner.siteControlSurfaces.map(ObjectIdentifier.init))
        mediaStates = mediaStates.filter { ownedKeys.contains($0.key) }
        for key in Array(mediaTasks.keys) where !ownedKeys.contains(key) {
            mediaTasks.removeValue(forKey: key)?.cancel()
            mediaRefreshNeeded.remove(key)
        }
        if let surface { refreshMedia(surface) }
    }

    func navigationWillStart(_ surface: Surface) {
        if let owner, owner.isSitePermissionTarget(surface) {
            epoch &+= 1
            statusMessage = nil
            cancelPermission()
            stopObservingExtensions()
            panel.close()
        }
    }

    private func isCurrent(_ surface: Surface, generation: UInt64, epoch: UInt64) -> Bool {
        guard let owner else { return false }
        return self.epoch == epoch && !owner.isPreparingForTermination && owner.isSitePermissionTarget(surface)
            && surface.findDocumentGeneration == generation
    }

    func request(_ request: BrowserPermissionRequest, from surface: Surface) async -> BrowserPermissionDecision {
        guard let owner, owner.isSitePermissionTarget(surface),
              let committed = surface.navigationState.committedURL,
              let committedOrigin = BrowserSiteOrigin(url: committed),
              BrowserSiteOrigin(requestOrigin: request.origin) == committedOrigin else { return .deny }
        let generation = surface.findDocumentGeneration
        let epoch = epoch
        let decision = await policy.resolve(request, profileID: surface.profileID,
            isCurrent: { [weak self, weak surface] in
                guard let self, let surface else { return false }
                return self.isCurrent(surface, generation: generation, epoch: epoch)
            }, prompt: { [weak self, weak surface] origin, permissions in
                guard let self else { return .dismiss }
                self.owner?.prepareForSiteControlsPresentation()
                let key = surface.map(ObjectIdentifier.init)
                pendingPermissionSurface = key
                defer { if pendingPermissionSurface == key { pendingPermissionSurface = nil } }
                if let presenter = self.permissionPrompt { return await presenter(origin, permissions) }
                return await self.prompt(origin: origin, permissions: permissions)
            })
        if decision == .deny, let message = statusMessage, isCurrent(surface, generation: generation, epoch: epoch), owner.window?.isKeyWindow == true {
            showMessage(message)
        }
        if decision == .grant || !isCurrent(surface, generation: generation, epoch: epoch) { statusMessage = nil }
        return decision
    }

    private func prompt(origin: BrowserSiteOrigin, permissions: [BrowserSitePermission]) async -> BrowserSitePermissionChoice {
        guard pendingPermission == nil, owner?.window?.isVisible == true, owner?.window?.isKeyWindow == true else { return .dismiss }
        panel.close()
        return await withCheckedContinuation { continuation in
            pendingPermission = { continuation.resume(returning: $0) }
            permissionPanel.onClose = { [weak self] in self?.finishPermission(.dismiss) }
            let prompt = SitePermissionPromptView(origin: origin, permissions: permissions) { [weak self] choice in
                // Notification refusal removes the prompt immediately; other choices retain
                // the native dismissal. Appearance continues to use the native animation.
                let immediate: Bool
                if case .block = choice { immediate = permissions == [.notifications] }
                else { immediate = false }
                self?.finishPermission(choice, animating: immediate ? false : nil)
            }
            present(permissionPanel, rows: [prompt])
        }
    }

    private func finishPermission(_ choice: BrowserSitePermissionChoice, animating: Bool? = nil) {
        let completion = pendingPermission
        pendingPermission = nil
        permissionPanel.onClose = nil
        permissionPanel.close(animating: animating)
        completion?(choice)
    }

    func cancelPermission() { invalidateSitePresentation(); finishPermission(.dismiss) }

    /// True while a prompt is open for a request of `surface` (a tab or the window's Peek).
    func hasPendingPermission(for surface: Surface) -> Bool {
        pendingPermissionSurface == ObjectIdentifier(surface)
    }

    func refreshMedia(_ surface: Surface) {
        let key = ObjectIdentifier(surface)
        guard mediaTasks[key] == nil else {
            mediaRefreshNeeded.insert(key)
            return
        }
        let generation = surface.findDocumentGeneration
        mediaTasks[key] = Task { [weak self, weak surface] in
            guard let self else { return }
            guard let surface else { mediaTasks.removeValue(forKey: key); mediaRefreshNeeded.remove(key); return }
            let state = await surface.requestMediaState()
            defer {
                mediaTasks.removeValue(forKey: key)
                if mediaRefreshNeeded.remove(key) != nil, !Task.isCancelled, owner?.owns(surface) == true {
                    refreshMedia(surface)
                }
            }
            guard !Task.isCancelled, !surface.isDisposed, owner?.owns(surface) == true,
                  surface.findDocumentGeneration == generation else { return }
            let previous = mediaStates[key]
            mediaStates[key] = state
            onMediaStateChange?(surface, state)
            if previous != state, isShowingSiteControls, panel.popover.isShown,
               owner?.siteControlSurface === surface { show() }
        }
    }

    var actionAnchor: NSView { button }

    var canShow: Bool {
        pendingPermission == nil && owner?.acceptsCommands == true && owner?.siteControlSurface != nil
    }

    private func invalidateSitePresentation() {
        hasPendingPinChange = false
        presentationGeneration &+= 1
        presentationTask?.cancel()
        presentationTask = nil
        isShowingSiteControls = false
        stopObservingExtensions()
    }

    private func canPresent(_ surface: Surface, document: UInt64, selection: UInt64, request: UInt64) -> Bool {
        !Task.isCancelled && presentationGeneration == request && isShowingSiteControls &&
            owner?.acceptsCommands == true && owner?.owns(surface) == true &&
            isCurrent(surface, generation: document, epoch: selection)
    }

    func toggle(presentationAnchor: NSView? = nil) {
        guard pendingPermission == nil else { return }
        if panel.popover.isShown { panel.close() }
        else { show(presentationAnchor: presentationAnchor) }
    }

    func show(presentationAnchor: NSView? = nil) {
        invalidateSitePresentation()
        self.presentationAnchor = presentationAnchor
        guard pendingPermission == nil, let owner, let surface = owner.siteControlSurface,
              owner.owns(surface), owner.acceptsCommands else { return }
        // Cancel synchronously at the native action, before the asynchronous model lookup.
        owner.prepareForSiteControlsPresentation()
        isShowingSiteControls = true
        let generation = surface.findDocumentGeneration
        let epoch = epoch
        let request = presentationGeneration
        let url = surface.navigationState.committedURL
        let origin = url.flatMap(BrowserSiteOrigin.init(url:))
        presentationTask = Task { [weak self, weak surface] in
            guard let self, let surface,
                  canPresent(surface, document: generation, selection: epoch, request: request) else { return }
            defer { if presentationGeneration == request { presentationTask = nil } }
            let settings: [BrowserSitePermission: BrowserSitePermissionSetting]
            let relevant: Set<BrowserSitePermission>
            if let origin {
                if let snapshot = presentationSettings { settings = await snapshot(origin, surface.profileID) }
                else { settings = await policy.store.snapshot(origin: origin, profileID: surface.profileID) }
                relevant = await policy.store.relevantPermissions(origin: origin, profileID: surface.profileID)
            } else { settings = [:]; relevant = [] }
            guard canPresent(surface, document: generation, selection: epoch, request: request) else { return }
            let media = await surface.requestMediaState()
            guard canPresent(surface, document: generation, selection: epoch, request: request) else { return }
            let model = BrowserSiteControlsModel(url: url, zoom: surface.pageZoom, permissions: settings,
                media: media, capabilities: owner.engine.capabilities, canClearData: owner.engine is any BrowserSiteOriginDataAccess)
            var visible = relevant
            if media.camera == .active || media.camera == .muted { visible.insert(.camera) }
            if media.microphone == .active || media.microphone == .muted { visible.insert(.microphone) }
            show(model: model, surface: surface, generation: generation, epoch: epoch, presentation: request,
                 relevantPermissions: visible)
        }
    }

    private func show(model: BrowserSiteControlsModel, surface: Surface, generation: UInt64, epoch: UInt64,
                      presentation: UInt64, relevantPermissions: Set<BrowserSitePermission>) {
        guard canPresent(surface, document: generation, selection: epoch, request: presentation) else { return }
        var rows: [NSView] = [BrowserSitePopover.label(model.origin?.value ?? siteText("internalPage", "Internal Page"), title: true),
                              BrowserSitePopover.label(model.connectionText, secondary: true)]
        if model.connection == .https {
            rows.append(BrowserSitePopover.label(siteText("certificate.unavailable", "Certificate details are not available with this engine adapter."), secondary: true))
        }
        if model.media.camera == .active || model.media.camera == .muted {
            rows.append(BrowserSitePopover.label(model.media.camera == .active ? siteText("media.cameraActive", "Camera in use") : siteText("media.cameraPaused", "Camera paused"), secondary: true))
        }
        if model.media.microphone == .active || model.media.microphone == .muted {
            rows.append(BrowserSitePopover.label(model.media.microphone == .active ? siteText("media.microphoneActive", "Microphone in use") : siteText("media.microphonePaused", "Microphone paused"), secondary: true))
        }
        if model.media.playback == .playing {
            rows.append(BrowserSitePopover.label(model.media.isAudible == true ? siteText("media.audible", "Playing audio") : siteText("media.playing", "Playing media"), secondary: true))
        }
        let valid: @MainActor () -> Bool = { [weak self, weak surface] in
            guard let self, let surface else { return false }
            return self.isCurrent(surface, generation: generation, epoch: epoch)
        }
        rows.append(SiteControlButton(String(format: siteText("zoom.reset", "Zoom: %@ — Reset"), "\(model.zoomPercent)%"), identifier: "site-zoom") { [weak self, weak surface] in
            guard valid(), let surface else { return }
            surface.performZoom(.reset)
            self?.panel.close()
        })
        let audio = SiteControlButton(model.media.isAudioMuted == true ? siteText("audio.unmute", "Unmute Tab") : siteText("audio.mute", "Mute Tab"),
                                      identifier: "site-audio") { [weak self, weak surface] in
            guard valid(), let surface else { return }
            do { try surface.setAudioMuted(model.media.isAudioMuted != true) }
            catch { self?.showMessage(siteText("audio.failed", "Could not change the tab’s sound.")) }
            self?.refreshMedia(surface)
            self?.panel.close()
        }
        audio.isEnabled = model.canMute
        rows.append(audio)
        if !model.canMute { rows.append(BrowserSitePopover.label(siteText("audio.unavailable", "Sound control is not available with this engine adapter."), secondary: true)) }
        if let origin = model.origin, let owner {
            let supported = (owner.engine as? any BrowserSitePermissionAvailability)?.supportedSitePermissions
                ?? (owner.engine.capabilities.contains(.mediaCapturePermissions) ? [.camera, .microphone] : [])
            for permission in [BrowserSitePermission.camera, .microphone, .geolocation, .notifications, .clipboardRead, .autoplay, .sound, .popupsAndRedirects, .automaticDownloads, .screenSharing, .midi] {
                rows.append(BrowserSitePopover.permissionRow(permission, setting: model.permissions[permission] ?? .ask,
                    enabled: !permissionsUnavailable && supported.contains(permission)
                        && BrowserSitePermissionPolicy.isTrustworthy(origin)) { [weak self, weak surface] setting in
                    guard valid(), let self, let surface else { return }
                    Task { await changePermission(setting, permission: permission, origin: origin, surface: surface, valid: valid) }
                })
            }
            rows.append(BrowserSitePopover.label(siteText("permissions.liveChanges", "Changes apply to this profile. Revoking camera, microphone or location access may reload the site to stop its current use."), secondary: true))
            rows.append(SiteControlButton(siteText("permissions.reset", "Reset Permissions"), identifier: "site-reset") { [weak self, weak surface] in
                guard valid(), let self, let surface else { return }
                Task { await resetPermissions(origin: origin, surface: surface, valid: valid) }
            })
            let data = SiteControlButton(siteText("data.open", "Cookies and Site Data…"), identifier: "site-data") { [weak self, weak surface] in
                guard valid(), let self, let surface else { return }
                showData(origin: origin, surface: surface, valid: valid)
            }
            data.isEnabled = model.canClearData
            rows.append(data)
        }
        let detailRows = rows
        let installed = appendExtensionRows(to: &rows, surface: surface, valid: valid)
        if permissionsUnavailable {
            rows.append(BrowserSitePopover.label(siteText("permissions.unavailable", "Permissions unavailable. Access is denied and the existing file is kept. Windows and tabs are still saved."), secondary: true))
        } else if let statusMessage { rows.append(BrowserSitePopover.label(statusMessage, secondary: true)) }
        guard canPresent(surface, document: generation, selection: epoch, request: presentation) else { return }
        observeExtensionInventory(on: surface, valid: valid) { [weak self] in
            guard self?.isShowingSiteControls == true, self?.presentationGeneration == presentation else { return }
            if self?.refreshExtensionPins() != true { self?.show() }
        }
        panel.onClose = { [weak self, weak surface] in
            self?.invalidateSitePresentation()
            guard valid(), let self, let surface, self.owner?.window?.isKeyWindow == true else { return }
            _ = surface.focusDocument()
        }
        guard canPresent(surface, document: generation, selection: epoch, request: presentation) else {
            stopObservingExtensions()
            return
        }
        let center = makeControlCenter(model: model, surface: surface, rows: rows, detailRows: detailRows,
                                       installed: installed, relevantPermissions: relevantPermissions, valid: valid)
        present(panel, rows: [center])
    }

    func changePermission(_ setting: BrowserSitePermissionSetting, permission: BrowserSitePermission,
                          origin: BrowserSiteOrigin, surface: Surface, valid: @escaping @MainActor () -> Bool) async {
        guard valid(), owner?.owns(surface) == true else { return }
        var message: String?
        do {
            try await policy.store.set(setting, for: [permission], origin: origin, profileID: surface.profileID)
        } catch {
            message = setting == .allow
                ? siteText("error.allowUnconfirmed", "The permission could not be confirmed as saved. Check the setting after relaunch.")
                : siteText("error.revokeNotSaved", "Revoked for this session, but the setting could not be saved. The previous setting may return after relaunch.")
        }
        if let service = owner?.engine as? any BrowserSitePermissionAvailability, message == nil || setting != .allow {
            await service.setSitePermission(setting, permission: permission, origin: origin, profileID: surface.profileID)
        }
        guard valid() else { return }
        statusMessage = message
        show()
    }

    func resetPermissions(origin: BrowserSiteOrigin, surface: Surface, valid: @escaping @MainActor () -> Bool) async {
        guard valid(), owner?.owns(surface) == true else { return }
        var message: String?
        do {
            try await policy.store.reset(origin: origin, profileID: surface.profileID)
        } catch {
            message = siteText("error.resetNotSaved", "Permissions were reset for this session, but could not be saved. The previous settings may return after relaunch.")
        }
        if let service = owner?.engine as? any BrowserSitePermissionAvailability {
            await service.revokeSitePermission(nil, origin: origin, profileID: surface.profileID)
        }
        guard valid() else { return }
        statusMessage = message
        show()
    }

    private func showData(origin: BrowserSiteOrigin, surface: Surface, valid: @escaping @MainActor () -> Bool) {
        invalidateSitePresentation()
        guard let service = owner?.engine as? any BrowserSiteOriginDataAccess else { return }
        present(panel, rows: [BrowserSitePopover.label(origin.value, title: true),
                             BrowserSitePopover.label(siteText("data.loading", "Loading site data…"), secondary: true)])
        Task { [weak self, weak surface] in
            guard let self, let surface else { return }
            let summary = await service.siteData(origin: origin, profileID: surface.profileID)
            guard valid() else { return }
            let scope = summary.domains.joined(separator: ", ")
            let remove = SiteControlButton(siteText("data.clear", "Clear This Data"), identifier: "site-clear-data") { [weak self, weak surface] in
                guard valid(), let self, let surface else { return }
                Task {
                    guard valid() else { return }
                    do {
                        try await service.clearSiteData(origin: origin, profileID: surface.profileID, expectedDomains: summary.domains)
                    } catch {
                        guard valid() else { return }
                        showMessage(siteText("data.failed", "Site data could not be fully cleared. Reopen Site Data and try again."))
                        return
                    }
                    guard valid() else { return }
                    showMessage(siteText("data.cleared", "Data cleared. Reload the site to refresh its session."))
                }
            }
            remove.isEnabled = summary.isAvailable && summary.recordCount > 0
            var rows: [NSView] = [BrowserSitePopover.label(origin.value, title: true)]
            if !summary.isAvailable {
                rows.append(BrowserSitePopover.label(siteText("data.unavailable", "Site data is unavailable. Try again when the site has loaded."), secondary: true))
            } else if let count = summary.cookieCount, let hasStorage = summary.hasStorage {
                rows.append(BrowserSitePopover.label(count == 1 ? siteText("data.oneCookie", "1 cookie") : String(format: siteText("data.cookieCount", "%ld cookies"), count)))
                rows.append(BrowserSitePopover.label(hasStorage ? siteText("data.storagePresent", "Site storage is present") : siteText("data.noStorage", "No site storage")))
                rows.append(BrowserSitePopover.label(String(format: siteText("data.chromiumScope", "Cookies for %@ and its subdomains, and storage for this origin, will be cleared in this profile. The site will reload and you may be signed out. Permissions are kept."), scope), secondary: true))
            } else {
                rows.append(BrowserSitePopover.label(summary.recordCount == 0 ? siteText("data.none", "No stored data.") : String(format: siteText("data.domains", "Domains: %@"), scope)))
                rows.append(BrowserSitePopover.label(siteText("data.scope", "Clearing covers every origin and subdomain of these domains, in this profile only. Connections to these sites may close. Permissions are kept."), secondary: true))
            }
            rows.append(remove)
            present(panel, rows: rows)
        }
    }

    private func present(_ panel: BrowserSitePopover, rows: [NSView]) {
        owner?.presentSiteControls(panel, rows: rows, button: presentationAnchor ?? button)
    }

    private func showMessage(_ message: String) {
        invalidateSitePresentation()
        present(panel, rows: [BrowserSitePopover.label(message)])
    }
}

extension BrowserSiteControls {
    /// The compact Orbit surface uses the same validated operations as the detailed SITE-DATA
    /// presentation. Deferred Boost and Capture controls have no tiles.
    private func makeControlCenter(model: BrowserSiteControlsModel, surface: Surface, rows: [NSView], detailRows: [NSView],
                                   installed: [BrowserExtensionSummary], relevantPermissions: Set<BrowserSitePermission>,
                                   valid: @escaping @MainActor () -> Bool) -> OrbitSiteControlCenterView {
        let actions = rows.compactMap { $0 as? SiteControlButton }
        func action(_ identifier: String) -> SiteControlButton? {
            actions.first { $0.accessibilityIdentifier() == identifier }
        }
        let share = SiteControlButton("", identifier: "site-share", onPress: {})
        share.image = OrbitGlyph.symbol("square.and.arrow.up", pointSize: 19, weight: .regular)
        share.setAccessibilityLabel(uiText("Share"))
        share.toolTip = uiText("Share")
        share.onPress = { [weak self, weak surface] in
            guard valid(), let self, let surface, let url = surface.navigationState.committedURL else { return }
            panel.close()
            let picker = NSSharingServicePicker(items: [url])
            sharePicker = picker
            picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        var tiles: [NSView] = []
        extensionTiles = [:]
        displayedExtensionIDs = installed.filter { $0.isEnabled && $0.hasAction }.map(\.id)
        displayedPinStates = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0.isPinned == true) })
        if let host = owner?.engine.extensions {
            for item in installed where item.isEnabled && item.hasAction {
                let original = action("extension-action-" + item.id)
                let tile = SiteControlButton("", identifier: "extension-action-" + item.id) { original?.onPress?() }
                tile.setAccessibilityLabel(item.name)
                tile.toolTip = item.name
                if let encoded = item.iconPNGBase64, encoded.count < 512 * 1024,
                   let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
                    image.size = NSSize(width: 16, height: 16); tile.image = image
                } else { tile.image = OrbitGlyph.symbol("puzzlepiece.extension", pointSize: 16) }
                tile.isEnabled = original?.isEnabled == true
                let pin: NSButton?
                if host.supportsPinning {
                    let pinButton = ControlCenterPinButton(identifier: "pin-extension-" + item.id) { [weak self, weak surface] in
                        guard valid(), let self, let surface else { return }
                        do {
                            let current = try host.installedExtensions(in: surface.profileID).first { $0.id == item.id }
                            hasPendingPinChange = true
                            try host.setPinned(current?.isPinned != true, extensionID: item.id, in: surface.profileID)
                        }
                        catch { hasPendingPinChange = false; showMessage(siteText("extensions.failed", "The extension could not be changed. Open Manage Extensions for details.")) }
                    }
                    pinButton.image = OrbitGlyph.symbol("pin.fill", pointSize: 9)
                    pinButton.setAccessibilityLabel(item.isPinned == true ? uiText("Unpin") : uiText("Pin"))
                    pinButton.toolTip = item.isPinned == true ? uiText("Unpin") : uiText("Pin")
                    pin = pinButton
                } else { pin = nil }
                let container = ControlCenterActionTile(button: tile, pin: pin, pinned: item.isPinned == true)
                extensionTiles[item.id] = container
                tiles.append(container)
            }
        }
        if let store = action("extensions-store") {
            let add = SiteControlButton("", identifier: "extensions-store") { store.onPress?() }
            add.image = OrbitGlyph.symbol("plus", pointSize: 18, weight: .regular)
            add.setAccessibilityLabel(uiText("Add Extension")); add.toolTip = uiText("Add Extension")
            tiles.append(ControlCenterActionTile(button: add))
        }
        let manager = action("extensions-manage")
        let manage = SiteControlButton(uiText("Manage"), identifier: "extensions-manage") { manager?.onPress?() }
        manage.isEnabled = manager?.isEnabled == true
        var settings: [NSView] = []
        if let origin = model.origin, let owner {
            let url = surface.navigationState.committedURL
            let preferences = preferences.preferences(url: url, profileID: surface.profileID)
            settings.append(ControlCenterSettingButton(title: uiText("Developer Mode"),
                subtitle: preferences.developerMode ? uiText("On") : uiText("Off"), symbol: "hammer.fill",
                identifier: "site-developer-mode", active: preferences.developerMode) { [weak self, weak surface] in
                guard valid(), let self, let surface else { return }
                var next = self.preferences.preferences(url: url, profileID: surface.profileID)
                next.developerMode.toggle()
                do { try self.preferences.set(next, url: url, profileID: surface.profileID); onPreferencesChange?(); show() }
                catch { showMessage(uiText("The site preference could not be saved.")) }
            })
            if model.connection == .https {
              settings.append(ControlCenterSettingButton(title: uiText("Automatic Picture-In-Picture"),
                subtitle: preferences.automaticPictureInPicture ? uiText("Allowed") : uiText("Blocked"),
                symbol: "gearshape.fill", identifier: "site-automatic-pip", active: preferences.automaticPictureInPicture) { [weak self, weak surface] in
                guard valid(), let self, let surface else { return }
                var next = self.preferences.preferences(url: url, profileID: surface.profileID)
                next.automaticPictureInPicture.toggle()
                do { try self.preferences.set(next, url: url, profileID: surface.profileID); show() }
                catch { showMessage(uiText("The site preference could not be saved.")) }
              })
            }
            let supported = (owner.engine as? any BrowserSitePermissionAvailability)?.supportedSitePermissions
                ?? (owner.engine.capabilities.contains(.mediaCapturePermissions) ? [.camera, .microphone] : [])
            let symbols: [(BrowserSitePermission, String)] = [(.camera, "camera.fill"), (.microphone, "mic.fill"),
                (.geolocation, "location.fill"), (.notifications, "bell.fill"), (.clipboardRead, "doc.on.clipboard"),
                (.sound, "speaker.wave.2"), (.popupsAndRedirects, "macwindow.on.rectangle"),
                (.automaticDownloads, "arrow.down.circle"), (.screenSharing, "rectangle.on.rectangle"), (.midi, "pianokeys")]
            for (permission, symbol) in symbols where supported.contains(permission) && relevantPermissions.contains(permission) {
                let picker = ControlCenterPermissionPicker(permission: permission,
                    setting: model.permissions[permission] ?? .ask, symbol: symbol) { [weak self, weak surface] value in
                    guard valid(), let self, let surface else { return }
                    Task { await changePermission(value, permission: permission, origin: origin, surface: surface, valid: valid) }
                }
                picker.isEnabled = !permissionsUnavailable && BrowserSitePermissionPolicy.isTrustworthy(origin)
                settings.append(picker)
            }
        }
        let secure = OrbitSiteControlCenterView.connectionButton(isSecure: model.connection == .https) { [weak self] in
            guard valid(), let self else { return }
            invalidateSitePresentation()
            present(panel, rows: [BrowserSitePopover.label(model.origin?.value ?? uiText("Internal Page"), title: true),
                                  BrowserSitePopover.label(model.connectionText)])
        }
        let more = OrbitSiteControlCenterView.footerButton(symbol: "ellipsis", label: uiText("More"),
                                                          identifier: "site-more", onPress: {})
        more.onPress = { [weak self, weak more] in
            guard valid(), let self, let more else { return }
            let menu = SiteActionMenu()
            menu.addAction(uiText("Site Settings…")) { [weak self] in
                guard valid(), let self else { return }
                invalidateSitePresentation(); present(panel, rows: detailRows)
            }
            if let data = action("site-data") {
                menu.addAction(data.title, enabled: data.isEnabled) { data.onPress?() }
            }
            menu.addItem(.separator())
            for id in ["site-zoom", "site-audio", "site-reset"] {
                if let operation = action(id) {
                    menu.addAction(operation.title, enabled: operation.isEnabled) { operation.onPress?() }
                }
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY), in: more)
        }
        return OrbitSiteControlCenterView(topActions: [ControlCenterActionTile(button: share, dark: true)],
            tiles: tiles, settings: settings, manage: manage, secure: secure, more: more,
            status: permissionsUnavailable ? siteText("permissions.unavailable", "Permissions unavailable. Access is denied and the existing file is kept. Windows and tabs are still saved.") : statusMessage)
    }

    /// Uses the selected live surface, including Peek/Little Orbit. Revalidates after
    /// confirmation so switching tabs, profiles or windows cannot retarget a mutation.
    @discardableResult
    func appendExtensionRows(to rows: inout [NSView], surface: Surface,
                             valid: @escaping @MainActor () -> Bool) -> [BrowserExtensionSummary] {
        if let manager = owner?.engine.extensionManagement {
            rows.append(SiteControlButton(siteText("extensions.manage", "Manage Extensions…"), identifier: "extensions-manage") { [weak self, weak surface] in
                guard valid(), let self, let surface else { return }
                self.panel.close()
                do { try manager.openManagement(on: surface) }
                catch { self.showMessage(siteText("extensions.managerFailed", "Could not open the extension manager.")) }
            })
        }
        guard let host = owner?.engine.extensions else {
            rows.append(BrowserSitePopover.label(siteText("extensions.controlsUnavailable",
                "Native extension controls require an updated Chromium build."), secondary: true))
            return []
        }
        do {
            let installed = try host.installedExtensions(in: surface.profileID)
            rows.append(BrowserSitePopover.label(siteText("extensions.title", "Extensions")))
            if installed.isEmpty {
                rows.append(BrowserSitePopover.label(siteText("extensions.empty", "No extensions in this profile."), secondary: true))
            }
            for item in installed {
                rows.append(BrowserSitePopover.label(item.name))
                if host.supportsActions && item.isEnabled && item.hasAction {
                    rows.append(SiteControlButton(siteText("extensions.openAction", "Open Extension"), identifier: "extension-action-" + item.id) { [weak self, weak surface] in
                        guard valid(), let self, let surface else { return }
                        self.panel.close()
                        do { try host.performAction(extensionID: item.id, on: surface, anchor: self.button) }
                        catch { self.showMessage(siteText("extensions.actionFailed", "The extension action could not be opened.")) }
                    })
                }
                rows.append(SiteControlButton(item.isEnabled ? siteText("extensions.disable", "Disable") : siteText("extensions.enable", "Enable"),
                    identifier: "extension-toggle-" + item.id) { [weak self, weak surface] in
                    guard valid(), let self, let surface else { return }
                    self.panel.close()
                    do { try host.setEnabled(!item.isEnabled, extensionID: item.id, in: surface.profileID) }
                    catch { self.showMessage(siteText("extensions.failed", "The extension could not be changed. Open Manage Extensions for details.")) }
                })
                rows.append(SiteControlButton(siteText("extensions.remove", "Remove…"), identifier: "extension-remove-" + item.id) { [weak self, weak surface] in
                    guard valid(), let self, let surface, let window = self.owner?.window else { return }
                    self.panel.close()
                    let alert = NSAlert()
                    alert.messageText = String(format: siteText("extensions.removeConfirm", "Remove %@?"), item.name)
                    alert.informativeText = siteText("extensions.removeInfo", "This removes the extension from this profile.")
                    alert.addButton(withTitle: siteText("extensions.removeAccept", "Remove"))
                    alert.addButton(withTitle: siteText("extensions.cancel", "Cancel"))
                    alert.beginSheetModal(for: window) { [weak self, weak surface] response in
                        guard response == .alertFirstButtonReturn, valid(), let self, let surface else { return }
                        do { try host.remove(extensionID: item.id, in: surface.profileID) }
                        catch { self.showMessage(siteText("extensions.failed", "The extension could not be changed. Open Manage Extensions for details.")) }
                    }
                })
            }
            if !host.supportsActions {
                rows.append(BrowserSitePopover.label(siteText("extensions.actionsPending", "Extension action popups are not available in this build."), secondary: true))
            }
            rows.append(SiteControlButton(siteText("extensions.store", "Chrome Web Store…"), identifier: "extensions-store") { [weak self, weak surface] in
                guard valid(), let self, let surface, let owner = self.owner else { return }
                self.panel.close()
                owner.openExtensionStore(from: surface)
            })
            return installed
        } catch {
            rows.append(BrowserSitePopover.label(siteText("extensions.loading", "Extensions are not ready for this profile. Try again shortly."), secondary: true))
            return []
        }
    }
}

extension BrowserSiteControls {
    func stopObservingExtensions() {
        extensionObservation?.cancel()
        extensionObservation = nil
    }
    /// Per-presentation subscription. Never replaces the service's legacy callback.
    func observeExtensionInventory(on surface: Surface, valid: @escaping @MainActor () -> Bool,
                                   refresh: @escaping @MainActor () -> Void) {
        stopObservingExtensions()
        guard let host = owner?.engine.extensions else { return }
        let profileID = surface.profileID
        extensionObservation = try? host.observeChanges(in: profileID) { [weak self, weak surface] in
            guard let self, let surface, surface.profileID == profileID, valid(),
                  self.owner?.owns(surface) == true, self.owner?.siteControlsClosed == false else { return }
            refresh()
        }
    }
}
