import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@MainActor
private final class ExtensionControlProbe: BrowserExtensionHost {
    var supportsActions = false
    var supportsPinning = false
    var registryReady = true
    var observationAttempts = 0
    var actionStates: [ObjectIdentifier: BrowserExtensionActionState] = [:]
    var itemsByProfile: [ProfileID: [BrowserExtensionSummary]] = [:]
    let changes = BrowserExtensionChangeHub()
    var onExtensionsChange: ((ProfileID) -> Void)?
    var requestedProfiles: [ProfileID] = []
    var toggles: [(String, ProfileID, Bool)] = []
    var actionSurface: (any BrowserEngineSurface)?
    var actionAnchor: NSView?
    var pinChanges: [(String, ProfileID, Bool)] = []
    var managedSurface: (any BrowserEngineSurface)?
    var shortcutsSurface: (any BrowserEngineSurface)?
    var item = BrowserExtensionSummary(id: "abcdefghijklmnopabcdefghijklmnop", name: "Synthetic Extension",
                                       version: "1", isEnabled: true, hasAction: true)
    func observeChanges(in profileID: ProfileID, handler: @escaping () -> Void) throws -> BrowserExtensionObservation {
        observationAttempts += 1
        guard registryReady else { throw BrowserEngineError.unsupportedOperation }
        return changes.observe(in: profileID, handler: handler)
    }
    func installedExtensions(in profileID: ProfileID) throws -> [BrowserExtensionSummary] {
        requestedProfiles.append(profileID)
        guard registryReady else { throw BrowserEngineError.unsupportedOperation }
        return itemsByProfile[profileID] ?? [item]
    }
    func installedExtensions(on surface: any BrowserEngineSurface) throws -> [BrowserExtensionSummary] {
        var items = try installedExtensions(in: surface.profileID)
        if !items.isEmpty { items[0].actionState = actionStates[ObjectIdentifier(surface)] }
        return items
    }
    func setEnabled(_ enabled: Bool, extensionID: String, in profileID: ProfileID) throws {
        toggles.append((extensionID, profileID, enabled))
    }
    func setPinned(_ pinned: Bool, extensionID: String, in profileID: ProfileID) throws {
        pinChanges.append((extensionID, profileID, pinned))
    }
    func remove(extensionID: String, in profileID: ProfileID) throws { }
    func openManagement(on surface: any BrowserEngineSurface) throws { managedSurface = surface }
    func openShortcuts(on surface: any BrowserEngineSurface) throws { shortcutsSurface = surface }
    func performAction(extensionID: String, on surface: any BrowserEngineSurface, anchor: NSView) throws {
        actionSurface = surface
        actionAnchor = anchor
    }
}

@MainActor
private final class ExtensionControlContext {
    var isCurrent = true
}

extension NativeWebKitTests {
@Suite("Native extension controls", .serialized)
@MainActor
struct NativeExtensionControlsTests {
    @Test("Selected-tab badges update both anchors without replacing their views")
    func tabBadgesFollowSelection() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine(), host = ExtensionControlProbe()
        host.supportsPinning = true; host.item.isPinned = true
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.submitAddress("https://extensions.example.invalid/one")
        await owner.session.waitForPendingCommands()
        let one = try #require(owner.session.selectedSurface)
        host.actionStates[ObjectIdentifier(one)] = .init(title: "One", badgeText: "1", badgeBackgroundColor: 0xffff0000, isEnabled: true)
        owner.extensionControls.render()
        let anchor = try #require(owner.sidebar.extensionsContainer.subviews.compactMap { $0 as? NSButton }.first)
        let badge = try #require(anchor.subviews.compactMap { $0 as? BrowserExtensionBadgeView }.first)
        #expect(badge.text == "1")
        owner.openTab(url: URL(string: "https://extensions.example.invalid/two")!)
        await owner.session.waitForPendingCommands()
        let two = try #require(owner.session.selectedSurface)
        host.actionStates[ObjectIdentifier(two)] = .init(title: "Two", badgeText: "2", badgeBackgroundColor: 0xff0000ff, isEnabled: false)
        host.changes.emit(two.profileID)
        #expect(owner.sidebar.extensionsContainer.subviews.contains { $0 === anchor })
        #expect(badge.text == "2" && badge.backgroundARGB == 0xff0000ff)
        #expect(anchor.toolTip == "Two" && !anchor.isEnabled)
        let occurrence = try #require(owner.session.occurrenceID(for: one))
        owner.session.selectOccurrence(occurrence)
        await owner.session.waitForPendingCommands()
        owner.extensionControls.render()
        #expect(badge.text == "1" && anchor.isEnabled)
        try await environment.finalize()
    }

    @Test("A profile that becomes ready after startup still publishes live pins")
    func delayedRegistryPublishesPins() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine(), host = ExtensionControlProbe()
        host.supportsPinning = true
        host.registryReady = false
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://extensions.example.invalid")
        await window.session.waitForPendingCommands()
        #expect(host.observationAttempts > 0)
        host.item.isPinned = true
        host.registryReady = true
        let profile = try #require(window.session.selectedSurface?.profileID)
        for _ in 0..<100 {
            if !window.sidebar.extensionsContainer.subviews.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(window.sidebar.extensionsContainer.subviews.contains {
            $0.accessibilityIdentifier() == "pinned-extension-" + host.item.id
        })
        host.item.isPinned = false
        host.changes.emit(profile)
        #expect(window.sidebar.extensionsContainer.subviews.isEmpty)
        window.session.close()
        try await environment.finalize()
    }

    @Test("Space previews retain profile-owned pixels, survive an empty Space and restore after refusal")
    func spacePreviewIcons() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine(), host = ExtensionControlProbe()
        host.supportsPinning = true; host.item.isPinned = true
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let owner = try await environment.makeWindow()
        defer { owner.window?.close() }
        let first = try #require(owner.session.activeProfileID)
        owner.extensionControls.render()
        let firstButton = try #require(owner.sidebar.extensionsContainer.subviews.first)
        let other = await environment.store.createProfile(name: "Synthetic preview")
        owner.session.refreshCatalog()
        await owner.session.waitForPendingCommands()
        host.itemsByProfile[other] = [BrowserExtensionSummary(id: host.item.id, name: "Synthetic other", version: "1",
                                                             isEnabled: true, hasAction: true, isPinned: true)]
        owner.extensionControls.preview(in: other)
        let otherButton = try #require(owner.sidebar.extensionsContainer.subviews.first)
        #expect(firstButton !== otherButton)
        #expect((otherButton as? NSButton)?.cell.flatMap { $0 as? NSButtonCell }?.imageDimsWhenDisabled == false)
        host.registryReady = false
        owner.extensionControls.preview(in: first)
        #expect(owner.sidebar.extensionsContainer.subviews.first === firstButton)
        host.registryReady = true
        owner.extensionControls.finishPreview()
        #expect(owner.sidebar.extensionsContainer.subviews.first === firstButton)
        let empty = try await environment.store.createSpace(name: "Synthetic empty", profileID: first)
        owner.session.activateSpace(empty)
        await owner.session.waitForPendingCommands()
        owner.extensionControls.render()
        #expect(owner.session.selectedSurface == nil)
        #expect(owner.sidebar.extensionsContainer.subviews.first === firstButton)
        let otherSpace = try await environment.store.createSpace(name: "Synthetic other", profileID: other)
        owner.session.activateSpace(otherSpace)
        await owner.session.waitForPendingCommands()
        owner.submitAddress("https://example.net/")
        await owner.session.waitForPendingCommands()
        owner.extensionControls.render()
        #expect(owner.sidebar.extensionsContainer.subviews.first === otherButton)
        (otherButton as? SiteControlButton)?.onPress?()
        #expect(host.actionSurface?.profileID == other)
        owner.session.close()
        try await environment.finalize()
    }

    @Test("Controls target the exact profile and live surface; revoked context cannot mutate")
    func exactTargetAndRevocation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let host = ExtensionControlProbe()
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://extensions.example.invalid")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        let context = ExtensionControlContext()
        var rows: [NSView] = []
        window.siteControls.appendExtensionRows(to: &rows, surface: surface, valid: { context.isCurrent })
        #expect(host.requestedProfiles == [surface.profileID])
        let buttons = rows.compactMap { $0 as? SiteControlButton }
        let toggle = try #require(buttons.first { $0.accessibilityIdentifier() == "extension-toggle-" + host.item.id })
        let manager = try #require(buttons.first { $0.accessibilityIdentifier() == "extensions-manage" })
        toggle.onPress?()
        #expect(host.toggles.count == 1)
        #expect(host.toggles.first?.0 == host.item.id)
        #expect(host.toggles.first?.1 == surface.profileID)
        #expect(host.toggles.first?.2 == false)
        manager.onPress?()
        #expect((host.managedSurface as? SiteSyntheticSurface) === surface)
        host.supportsActions = true
        var actionRows: [NSView] = []
        window.siteControls.appendExtensionRows(to: &actionRows, surface: surface, valid: { context.isCurrent })
        let action = try #require(actionRows.compactMap { $0 as? SiteControlButton }.first {
            $0.accessibilityIdentifier() == "extension-action-" + host.item.id
        })
        action.onPress?()
        #expect((host.actionSurface as? SiteSyntheticSurface) === surface)
        #expect(host.actionAnchor?.window === window.window)
        #expect(host.actionAnchor !== action) // The anchor survives closing the popover.
        context.isCurrent = false
        host.actionSurface = nil
        action.onPress?()
        #expect(host.actionSurface == nil)
        host.managedSurface = nil
        toggle.onPress?()
        manager.onPress?()
        #expect(host.toggles.count == 1)
        #expect(host.managedSurface == nil)
        #expect(!buttons.contains { ($0.accessibilityIdentifier() ?? "").hasPrefix("extension-action-") })
        #expect(window.window?.isVisible == false)
        window.session.close()
        try await environment.finalize()
    }

    @Test("Pinned context actions target the selected profile and revoke after changing tabs")
    func pinnedContextRevocation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let host = ExtensionControlProbe()
        host.supportsActions = true
        host.supportsPinning = true
        host.item = BrowserExtensionSummary(id: host.item.id, name: host.item.name, version: "1",
                                            isEnabled: true, hasAction: true, isPinned: true)
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://extensions.example.invalid")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        window.extensionControls.render()
        let pin = try #require(window.sidebar.extensionsContainer.subviews.first as? SiteControlButton)
        let menu = try #require(pin.contextMenuBuilder?())
        let index = menu.indexOfItem(withTitle: "Unpin")
        #expect(index >= 0)
        menu.performActionForItem(at: index)
        #expect(host.pinChanges.count == 1)
        #expect(host.pinChanges.first?.1 == surface.profileID)
        #expect(host.pinChanges.first?.2 == false)
        window.session.openTab(url: URL(string: "https://other.example.invalid")!)
        await window.session.waitForPendingCommands()
        menu.performActionForItem(at: index)
        #expect(host.pinChanges.count == 1)
        window.session.close()
        try await environment.finalize()
    }

    @Test("Moving extension actions into the pill preserves their exclusion from private windows")
    func privateWindowHasNoExtensionActions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        engine.extensions = ExtensionControlProbe()
        let environment = BrowserEnvironment(engine: engine)
        environment.isPrivate = true
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://extensions.example.invalid")
        await window.session.waitForPendingCommands()
        window.extensionControls.render()
        window.sidebar.addressContainer.mouseEntered(with: NSEvent())
        #expect(!window.sidebar.extensionsContainer.isAvailable)
        #expect(window.sidebar.extensionsContainer.isHidden)
        window.session.close()
        try await environment.finalize()
    }

    @Test("A pinned popup anchor and its cached icon survive transient icon updates")
    func pinnedAnchorSurvivesIconUpdate() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let host = ExtensionControlProbe()
        host.supportsActions = true
        host.supportsPinning = true
        host.item = BrowserExtensionSummary(id: host.item.id, name: host.item.name, version: "1",
                                            isEnabled: true, hasAction: true, isPinned: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        host.item.iconPNGBase64 = try #require(bitmap.representation(using: .png, properties: [:])).base64EncodedString()
        engine.extensions = host
        let environment = BrowserEnvironment(engine: engine)
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://extensions.example.invalid")
        await window.session.waitForPendingCommands()
        window.extensionControls.render()
        let identifier = "pinned-extension-" + host.item.id
        let anchor = try #require(window.sidebar.extensionsContainer.subviews.first {
            $0.accessibilityIdentifier() == identifier
        } as? SiteControlButton)
        anchor.onPress?()
        #expect(host.actionAnchor === anchor)
        let cachedImage = try #require(anchor.image)
        host.item = BrowserExtensionSummary(id: host.item.id, name: "Updated icon", version: "1",
                                            isEnabled: true, hasAction: true, isPinned: true,
                                            iconPNGBase64: "aWNvbg==")
        window.extensionControls.render()
        #expect(anchor.image === cachedImage)
        #expect(anchor.superview === window.sidebar.extensionsContainer)
        #expect(window.sidebar.extensionsContainer.subviews.first {
            $0.accessibilityIdentifier() == identifier
        } === anchor)
        #expect(host.actionAnchor?.window === window.window)
        window.session.close()
        try await environment.finalize()
    }

    @Test("An old framework exposes an unavailable explanation with no active controls")
    func unavailableServices() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let window = try await environment.makeWindow()
        defer { window.window?.close() }
        window.submitAddress("https://extensions.example.invalid")
        await window.session.waitForPendingCommands()
        let surface = try #require(window.session.selectedSurface)
        var rows: [NSView] = []
        window.siteControls.appendExtensionRows(to: &rows, surface: surface, valid: { true })
        #expect(rows.count == 1)
        #expect(rows.compactMap { $0 as? NSButton }.isEmpty)
        #expect(window.window?.isVisible == false)
        window.session.close()
        try await environment.finalize()
    }
}
}
