import AppKit
import BrowserCore
import BrowserEngine

/// Profile-scoped extension access inside the sidebar address. Actions retain a stable anchor
/// after the transient menu closes; the native engine owns installation and popup contents.
@MainActor
final class BrowserExtensionsController<Engine: BrowserEngine> {
    private weak var owner: BrowserWindowController<Engine>?
    private var toolbarObservation: BrowserExtensionObservation?
    private var toolbarProfile: ProfileID?
    private var registryRetry: Task<Void, Never>?
    private var pinnedButtons: [NSButton] = []
    private var buttonsByProfile: [ProfileID: [NSButton]] = [:]
    private var previewProfile: ProfileID?
    /// Optional metadata injection for the confined Chromium presentation probe. Production
    /// always reads the engine registry; fixture buttons never dispatch engine actions.
    var presentationInventory: ((ProfileID) -> [BrowserExtensionSummary])?
    private var pinOrder: [ProfileID: [String]] = [:]
    private weak var selectedSurface: Engine.Surface?
    private var generation: UInt64?
    private var selectionEpoch: UInt64 = 0

    init(owner: BrowserWindowController<Engine>) {
        self.owner = owner
    }

    func install() {
        guard let owner else { return }
        let strip = owner.sidebar.extensionsContainer
        owner.sidebar.addressContainer.installAccessory(strip, onHover: true, order: 10)
        owner.sidebar.extensionsContainer.isAvailable = owner.engine.extensionManagement != nil && !owner.isPrivateWindow
    }

    func render() {
        guard let owner else { return }
        let surface = owner.session.selectedSurface
        if let previewProfile, previewProfile != owner.session.activeProfileID { return }
        let profile = surface?.profileID ?? owner.session.activeProfileID
        let liveProfiles = Set(owner.session.catalog?.profiles.map(\.id) ?? [])
        buttonsByProfile = buttonsByProfile.filter { liveProfiles.contains($0.key) }
        if selectedSurface !== surface || generation != surface?.documentGeneration || !owner.acceptsCommands {
            selectionEpoch &+= 1
            selectedSurface = surface
            generation = surface?.documentGeneration
        }
        owner.sidebar.extensionsContainer.isAvailable = owner.engine.extensionManagement != nil && !owner.isPrivateWindow
        if toolbarProfile != profile {
            registryRetry?.cancel()
            registryRetry = nil
            toolbarObservation?.cancel()
            toolbarObservation = nil
            toolbarProfile = profile
        }
        // Chromium creates the profile asynchronously. A refused startup subscription must
        // be retried once navigation makes the registry ready, even in the same profile.
        if toolbarObservation == nil, owner.acceptsCommands,
           let profile, let host = owner.engine.extensions, host.supportsPinning {
            let observation = try? host.observeChanges(in: profile) { [weak self] in
                guard self?.toolbarProfile == profile else { return }
                self?.renderPinnedIcons()
            }
            if toolbarProfile == profile, owner.session.activeProfileID == profile {
                toolbarObservation = observation
                if observation == nil { retryRegistry(in: profile) }
            } else { observation?.cancel() }
        }
        renderPinnedIcons()
    }

    /// Metadata is synchronous and profile scoped; prepare the destination's known icons before
    /// deferred CEF activation. A source registry callback cannot overwrite this presentation.
    func preview(in profile: ProfileID) {
        previewProfile = profile
        renderPinnedIcons()
    }

    func finishPreview() {
        previewProfile = nil
        render()
    }

    private func retryRegistry(in profile: ProfileID) {
        guard registryRetry == nil else { return }
        registryRetry = Task { [weak self] in
            var delay = 0.05
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard let owner, owner.acceptsCommands, toolbarProfile == profile,
                      owner.session.activeProfileID == profile else { registryRetry = nil; return }
                render()
                guard !Task.isCancelled else { return }
                if toolbarObservation != nil {
                    registryRetry = nil
                    owner.siteControls.extensionInventoryBecameReady(in: profile)
                    return
                }
                delay = min(1, delay * 2)
            }
        }
    }

    private func icon(for item: BrowserExtensionSummary) -> NSImage? {
        guard let encoded = item.iconPNGBase64, encoded.count < 512 * 1024,
              let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }

    private func renderPinnedIcons() {
        guard let owner else { return }
        let surface = owner.session.selectedSurface
        let profile = previewProfile ?? surface?.profileID ?? owner.session.activeProfileID
        let items: [BrowserExtensionSummary]
        if let profile, let presentationInventory { items = presentationInventory(profile) }
        else if let profile, let host = owner.engine.extensions, host.supportsPinning {
            do { items = try host.installedExtensions(in: profile) }
            catch {
                // Never show another profile's icons while this registry is starting. Previously
                // decoded destination pixels remain usable without a clear/recreate frame.
                pinnedButtons = buttonsByProfile[profile] ?? []
                owner.sidebar.extensionsContainer.setPinnedButtons(pinnedButtons)
                return
            }
        } else {
            items = []
        }
        let availablePins = items.filter { $0.isEnabled && $0.hasAction && $0.isPinned == true }
        let pinned: [BrowserExtensionSummary]
        if let profile {
            let ids = Set(availablePins.map(\.id))
            let runtime = owner.settingsPreferences?.runtime
            let saved = runtime?.extensionPinOrder(for: profile) ?? pinOrder[profile] ?? []
            var order = saved.filter { ids.contains($0) }
            order.append(contentsOf: availablePins.map(\.id).filter { !order.contains($0) })
            let changed = pinOrder[profile] != order
            pinOrder[profile] = order
            if changed, saved != order, !owner.isPrivateWindow {
                runtime?.saveExtensionPinOrder(order, profileID: profile) { [weak owner] error in
                    owner?.session.onError?(error)
                }
            }
            pinned = order.compactMap { id in availablePins.first { $0.id == id } }
        } else { pinned = [] }
        var existing: [String: NSButton] = [:]
        for view in profile.flatMap({ buttonsByProfile[$0] }) ?? [] {
            existing[view.accessibilityIdentifier()] = view
        }
        let identifiers = Set(pinned.map { "pinned-extension-" + $0.id })
        for view in pinnedButtons where !identifiers.contains(view.accessibilityIdentifier() ?? "") {
            view.removeFromSuperview()
        }
        pinnedButtons = pinned.map { item in
            let identifier = "pinned-extension-" + item.id
            let action: NSButton
            if let current = existing[identifier] {
                // Native popups retain this view as their anchor. An icon or badge
                // update must not detach it while the popup is opening or visible.
                action = current
            } else {
                let created = SiteControlButton("", identifier: identifier) { [weak self] in
                    guard let self, self.presentationInventory == nil, let owner = self.owner, owner.acceptsCommands,
                          let surface = owner.session.selectedSurface, surface.profileID == profile,
                          self.previewProfile == nil, let anchor = self.pinnedButtons.first(where: {
                              $0.accessibilityIdentifier() == identifier
                          }) else { return }
                    do { try owner.engine.extensions?.performAction(extensionID: item.id, on: surface, anchor: anchor) }
                    catch { owner.session.onError?(error) }
                }
                created.imagePosition = .imageOnly
                created.imageScaling = .scaleProportionallyDown
                created.isBordered = false
                owner.sidebar.extensionsContainer.addSubview(created)
                action = created
            }
            if let image = icon(for: item) { action.image = image }
            else if action.image == nil {
                action.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: item.name)
            }
            // Pending selection blocks actions without washing out already decoded pixels.
            (action.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
            action.toolTip = item.name
            action.setAccessibilityLabel(item.name)
            if let action = action as? SiteControlButton {
                action.contextMenuBuilder = { [weak self, weak surface] in
                    guard let self, let surface else { return nil }
                    return contextMenu(for: item, surface: surface)
                }
            }
            return action
        }
        if let profile { buttonsByProfile[profile] = pinnedButtons }
        for view in pinnedButtons { view.isEnabled = surface?.profileID == profile && surface != nil && previewProfile == nil && owner.acceptsCommands }
        owner.sidebar.extensionsContainer.setPinnedButtons(pinnedButtons)
        owner.sidebar.addressContainer.needsLayout = true
        if let surface { owner.engine.extensions?.setActionAnchor(owner.siteControls.actionAnchor, on: surface) }
    }

    func close() {
        registryRetry?.cancel()
        registryRetry = nil
        toolbarObservation?.cancel()
        toolbarObservation = nil
        toolbarProfile = nil
        buttonsByProfile.removeAll()
        previewProfile = nil
        presentationInventory = nil
    }

    private func contextMenu(for item: BrowserExtensionSummary, surface: Engine.Surface) -> NSMenu? {
        guard let owner, let host = owner.engine.extensions else { return nil }
        let epoch = selectionEpoch, document = surface.documentGeneration
        let valid: () -> Bool = { [weak self, weak owner, weak surface] in
            guard let self, let owner, let surface else { return false }
            return owner.acceptsCommands && owner.session.selectedSurface === surface && owner.owns(surface)
                && self.selectionEpoch == epoch && surface.documentGeneration == document
        }
        guard valid() else { return nil }
        let menu = SiteActionMenu()
        menu.addAction(item.name, enabled: false) {}
        menu.addItem(.separator())
        menu.addAction(uiText("Remove from Orbit")) { [weak owner, weak surface] in
            guard valid(), let owner, let surface, let window = owner.window else { return }
            let alert = NSAlert()
            alert.messageText = String(format: uiText("Remove %@?"), item.name)
            alert.addButton(withTitle: uiText("Remove")); alert.addButton(withTitle: uiText("Cancel"))
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn, valid() else { return }
                do { try host.remove(extensionID: item.id, in: surface.profileID) }
                catch { owner.session.onError?(error) }
            }
        }
        menu.addAction(uiText("Unpin"), enabled: host.supportsPinning) { [weak owner, weak surface] in
            guard valid(), let owner, let surface else { return }
            do { try host.setPinned(false, extensionID: item.id, in: surface.profileID) }
            catch { owner.session.onError?(error) }
        }
        menu.addItem(.separator())
        if let manager = owner.engine.extensionManagement {
            menu.addAction(uiText("Manage Extension")) { [weak owner, weak surface] in
                guard valid(), let owner, let surface else { return }
                do { try manager.openDetails(extensionID: item.id, on: surface) }
                catch { owner.session.onError?(error) }
            }
        }
        menu.addAction(uiText("View Web Permissions")) { [weak owner] in
            guard valid(), let owner else { return }
            owner.siteControls.show()
        }
        return menu
    }

    func show() {
        guard let owner, owner.acceptsCommands, owner.session.selectedSurface != nil else { return }
        render()
        owner.siteControls.toggle()
    }
}
