import AppKit
import BrowserCore
import BrowserEngine
import CryptoKit

/// Profile-scoped extension access inside the sidebar address. Actions retain a stable anchor
/// after the transient menu closes; the native engine owns installation and popup contents.
@MainActor
final class BrowserExtensionsController<Engine: BrowserEngine> {
    private var pressure: BrowserMemoryPressure?
    private weak var owner: BrowserWindowController<Engine>?
    private var toolbarObservation: BrowserExtensionObservation?
    private var toolbarProfile: ProfileID?
    private var registryRetry: Task<Void, Never>?
    private var pinnedButtons: [NSButton] = []
    private var buttonsByProfile: [ProfileID: [NSButton]] = [:]
    private var previewProfile: ProfileID?
    @MainActor
    private final class TabInventory {
        weak var surface: Engine.Surface?
        let generation: UInt64
        let items: [BrowserExtensionSummary]
        init(surface: Engine.Surface, items: [BrowserExtensionSummary]) {
            self.surface = surface; generation = surface.documentGeneration; self.items = items
        }
    }
    private var tabInventories = BrowserCostCache<ObjectIdentifier, TabInventory>(budget: 2 * 1024 * 1024)
    private var profileInventories = BrowserCostCache<ProfileID, [BrowserExtensionSummary]>(budget: 2 * 1024 * 1024)
    /// Optional metadata injection for the confined Chromium presentation probe. Production
    /// always reads the engine registry; fixture buttons never dispatch engine actions.
    var presentationInventory: ((ProfileID) -> [BrowserExtensionSummary])?
    private var pinOrder: [ProfileID: [String]] = [:]
    private weak var selectedSurface: Engine.Surface?
    private var iconImages = BrowserCostCache<String, NSImage>(budget: 1024 * 1024)

    private var generation: UInt64?
    private var selectionEpoch: UInt64 = 0

    init(owner: BrowserWindowController<Engine>) {
        self.owner = owner
        pressure = BrowserMemoryPressure { [weak self] in self?.releaseMemory() }
    }

    func install() {
        guard let owner else { return }
        owner.siteControls.extensionContextMenu = { [weak self] item, surface in
            self?.contextMenu(for: item, surface: surface)
        }
        owner.developerToolbar.extensionContextMenu = { [weak self, weak owner] id in
            guard let self, let owner, let surface = owner.session.selectedSurface,
                  let items = try? owner.engine.extensions?.installedExtensions(on: surface),
                  let item = items.first(where: { $0.id == id }) else { return nil }
            return contextMenu(for: item, surface: surface)
        }
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
            var attempt = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(BrowserExtensionRetryPolicy.delay(attempt: attempt))) } catch { return }
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
                attempt = min(11, attempt + 1)
            }
        }
    }

    private static func inventoryCost(_ items: [BrowserExtensionSummary]) -> Int {
        items.reduce(128) { total, item in
            let actions = [item.actionState, item.defaultActionState].compactMap { $0 }
            return total + 256 + item.id.utf8.count + item.name.utf8.count + item.version.utf8.count
                + (item.iconPNGBase64?.utf8.count ?? 0) + (item.actionBadgeText?.utf8.count ?? 0)
                + actions.reduce(0) { $0 + $1.title.utf8.count + $1.badgeText.utf8.count + ($1.iconPNGBase64?.utf8.count ?? 0) }
        }
    }

    private func icon(for item: BrowserExtensionSummary) -> NSImage? {
        guard let encoded = item.actionState?.iconPNGBase64 ?? item.iconPNGBase64, encoded.count < 512 * 1024,
              let data = Data(base64Encoded: encoded) else { return nil }
        let key = ((previewProfile ?? selectedSurface?.profileID)?.rawValue.uuidString ?? "")
            + item.id + Data(SHA256.hash(data: data)).base64EncodedString()
        if let image = iconImages.value(for: key) { return image }
        guard let image = BrowserIconRaster.image(data: data, pixels: 32, size: 16) else { return nil }
        iconImages.insert(image, for: key, cost: BrowserIconRaster.cost(image) + key.utf8.count)
        return image
    }

    private func renderPinnedIcons() {
        guard let owner else { return }
        let surface = owner.session.selectedSurface
        let profile = previewProfile ?? surface?.profileID ?? owner.session.activeProfileID
        for key in tabInventories.keys where tabInventories.peekValue(for: key)?.surface.map(owner.owns) != true {
            tabInventories.remove(key)
        }
        for profile in profileInventories.keys where owner.session.catalog?.profiles.contains(where: { $0.id == profile }) != true {
            profileInventories.remove(profile)
        }
        let items: [BrowserExtensionSummary]
        if let profile, let presentationInventory { items = presentationInventory(profile) }
        else if let profile, let host = owner.engine.extensions, host.supportsPinning {
            do {
                if let surface, surface.profileID == profile, previewProfile == nil {
                    items = try host.installedExtensions(on: surface)
                    tabInventories.insert(TabInventory(surface: surface, items: items), for: ObjectIdentifier(surface), cost: Self.inventoryCost(items))
                } else { items = try host.installedExtensions(in: profile) }
                profileInventories.insert(items, for: profile, cost: Self.inventoryCost(items))
            }
            catch {
                if let surface, surface.profileID == profile, previewProfile == nil {
                    let cached = tabInventories.value(for: ObjectIdentifier(surface))
                    if cached?.surface === surface, cached?.generation == surface.documentGeneration {
                        items = cached?.items ?? []
                    } else {
                        // Keep the icon inventory, but never borrow another tab's action values.
                        items = (profileInventories.value(for: profile) ?? []).map { item in
                            var item = item
                            item.actionState = nil; item.actionBadgeText = nil
                            return item
                        }
                    }
                } else {
                    pinnedButtons = buttonsByProfile[profile] ?? []
                    owner.sidebar.extensionsContainer.setPinnedButtons(pinnedButtons)
                    return
                }
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
        owner.developerToolbar.updateExtensions(pinned)
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
                action.image = OrbitIcon.image(sfName: "puzzlepiece.extension", pointSize: 16, accessibilityDescription: item.name)
            }
            // Pending selection blocks actions without washing out already decoded pixels.
            (action.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
            action.toolTip = item.actionState?.title ?? item.name
            action.setAccessibilityValue(item.actionState?.badgeText ?? item.actionBadgeText ?? "")
            let badge: BrowserExtensionBadgeView
            if let existing = action.subviews.compactMap({ $0 as? BrowserExtensionBadgeView }).first { badge = existing }
            else {
                badge = BrowserExtensionBadgeView()
                badge.install(on: action, iconSize: 16)
            }
            badge.text = item.actionState?.badgeText ?? item.actionBadgeText
            badge.backgroundARGB = item.actionState?.badgeBackgroundColor
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
        for (view, item) in zip(pinnedButtons, pinned) {
            view.isEnabled = surface?.profileID == profile && surface != nil && previewProfile == nil
                && owner.acceptsCommands && item.actionState?.isEnabled != false
        }
        owner.sidebar.extensionsContainer.setPinnedButtons(pinnedButtons)
        owner.sidebar.addressContainer.needsLayout = true
        if let surface { owner.engine.extensions?.setActionAnchor(owner.siteControls.actionAnchor, on: surface) }
    }

    func releaseMemory() {
        iconImages.removeAll()
        tabInventories.removeAll()
        profileInventories.removeAll()
        let active = previewProfile ?? selectedSurface?.profileID
        buttonsByProfile = buttonsByProfile.filter { $0.key == active }
    }

    var cacheStatistics: [String: Int] {
        return ["iconEntries": iconImages.count, "iconBytes": iconImages.cost, "tabSnapshots": tabInventories.count, "profileSnapshots": profileInventories.count,
                "bytes": tabInventories.cost + profileInventories.cost]
    }

    func close() {
        iconImages.removeAll()
        registryRetry?.cancel()
        registryRetry = nil
        toolbarObservation?.cancel()
        toolbarObservation = nil
        toolbarProfile = nil
        buttonsByProfile.removeAll()
        tabInventories.removeAll()
        profileInventories.removeAll()
        previewProfile = nil
        presentationInventory = nil
    }

    func contextMenu(for item: BrowserExtensionSummary, surface: Engine.Surface) -> NSMenu? {
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
            let alert = OrbitFloatingMaterial.alert()
            alert.messageText = String(format: uiText("Remove %@?"), item.name)
            alert.addButton(withTitle: uiText("Remove")); alert.addButton(withTitle: uiText("Cancel"))
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn, valid() else { return }
                do { try host.remove(extensionID: item.id, in: surface.profileID) }
                catch { owner.session.onError?(error) }
            }
        }
        menu.addAction(item.isPinned == true ? uiText("Unpin") : uiText("Pin"), enabled: host.supportsPinning) { [weak owner, weak surface] in
            guard valid(), let owner, let surface else { return }
            do { try host.setPinned(item.isPinned != true, extensionID: item.id, in: surface.profileID) }
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

/// Keep fast startup retries, then probe at most once per minute on a failing profile.
/// Ordinary renders can still subscribe immediately when navigation makes it ready.
enum BrowserExtensionRetryPolicy {
    static func delay(attempt: Int) -> Double {
        min(60, 0.05 * pow(2, Double(min(11, max(0, attempt)))))
    }
}
