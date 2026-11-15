import AppKit
import BrowserCore
import BrowserEngine
@testable import BrowserShell
import Testing
@testable import Orbit

@Suite("Optional toolbar")
@MainActor
struct OptionalToolbarTests {
    @Test("The address drops the scheme, sets the host in semibold and keeps the full URL for accessibility")
    func addressText() throws {
        let url = URL(string: "http://127.0.0.1:8765/fullscreen.html?q=1")!
        let text = BrowserToolbarAddressView.displayText(for: url, foreground: .black)
        #expect(text.string == "127.0.0.1:8765/fullscreen.html?q=1")
        let host = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let path = try #require(text.attribute(.font, at: 10, effectiveRange: nil) as? NSFont)
        #expect(host.pointSize == 13 && path.pointSize == 13)
        let hostWeight = (host.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        let pathWeight = (path.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat
        #expect((hostWeight ?? 0) > (pathWeight ?? 0))
        let toolbar = BrowserOptionalToolbar()
        toolbar.update(url: url, canGoBack: true, canGoForward: false)
        #expect(toolbar.address.accessibilityValue() as? String == url.absoluteString)
        #expect(toolbar.address.toolTip == nil)
    }

    @Test("Controls sit at the measured positions and the address is centred in the card")
    func layout() {
        let toolbar = BrowserOptionalToolbar()
        toolbar.frame = CGRect(x: 0, y: 0, width: 590, height: BrowserOptionalToolbar.height)
        toolbar.update(url: URL(string: "http://127.0.0.1:8765/fullscreen.html"), canGoBack: false, canGoForward: false)
        toolbar.layoutSubtreeIfNeeded()
        #expect(BrowserOptionalToolbar.height == 33)
        #expect(toolbar.back.image === OrbitGlyph.back)
        #expect(toolbar.forward.image === OrbitGlyph.forward)
        #expect(toolbar.reload.image === OrbitGlyph.reload)
        typealias M = BrowserOptionalToolbar.Metrics
        #expect(toolbar.back.frame.midX == M.back.x && toolbar.forward.frame.midX == M.forward.x && toolbar.reload.frame.midX == M.reload.x)
        #expect(toolbar.site.frame.midX == 590 - M.siteFromRight.x && toolbar.split.frame.midX == 590 - M.splitFromRight.x)
        #expect([toolbar.back, toolbar.forward, toolbar.reload, toolbar.site, toolbar.split].allSatisfy { abs($0.frame.midY - 16) <= 0.5 })
        let address = toolbar.address
        let textStart = address.frame.minX + address.textInset
        let textCenter = textStart + address.naturalTextWidth / 2
        #expect(abs(textCenter - 295) <= 0.5)
        let pill = address.convert(address.pillFrame, to: toolbar)
        #expect(pill.height == 24 && pill.midY == 16)
        #expect(abs(pill.minX - (textStart - 5.5)) < 0.01 && abs(pill.maxX - (textStart + address.naturalTextWidth + 5.5)) < 0.01)
    }

    @Test("A long address truncates between the history and site controls")
    func narrowLayout() {
        let toolbar = BrowserOptionalToolbar()
        toolbar.frame = CGRect(x: 0, y: 0, width: 300, height: BrowserOptionalToolbar.height)
        toolbar.update(url: URL(string: "https://example.test/" + String(repeating: "segment/", count: 30)), canGoBack: true, canGoForward: true)
        toolbar.layoutSubtreeIfNeeded()
        let pill = toolbar.address.convert(toolbar.address.pillFrame, to: toolbar)
        #expect(pill.minX >= toolbar.reload.frame.maxX)
        #expect(pill.maxX <= toolbar.site.frame.minX)
    }

    @Test("Hover and press drive the address fill; a press opens the Command Bar")
    func addressInteraction() {
        let old = OrbitMotionPreferences.overrideReducedMotion
        OrbitMotionPreferences.overrideReducedMotion = true
        defer { OrbitMotionPreferences.overrideReducedMotion = old }
        let toolbar = BrowserOptionalToolbar()
        var opened = 0
        toolbar.onAddress = { opened += 1 }
        toolbar.update(url: URL(string: "https://example.test/"), canGoBack: false, canGoForward: false)
        #expect(toolbar.address.pillOpacity == 0)
        toolbar.address.setHovered(true)
        #expect(toolbar.address.pillOpacity == BrowserOptionalToolbar.Ink.hover)
        toolbar.address.setPressed(true)
        #expect(toolbar.address.pillOpacity == BrowserOptionalToolbar.Ink.pressed)
        toolbar.address.setPressed(false)
        toolbar.address.setHovered(false)
        #expect(toolbar.address.pillOpacity == 0)
        #expect(toolbar.address.accessibilityPerformPress())
        #expect(opened == 1)
    }

    @Test("Ink follows the page colour: black on light pages, white on dark ones, dimmed when disabled")
    func ink() throws {
        let toolbar = BrowserOptionalToolbar()
        toolbar.updateTint(BrowserPageTint(red: 253, green: 253, blue: 253))
        toolbar.update(url: URL(string: "https://example.test/"), canGoBack: false, canGoForward: true)
        let back = try #require(toolbar.back.contentTintColor?.usingColorSpace(.sRGB))
        let forward = try #require(toolbar.forward.contentTintColor?.usingColorSpace(.sRGB))
        #expect(back.redComponent == 0 && back.alphaComponent == BrowserOptionalToolbar.Ink.disabledIcon)
        #expect(forward.redComponent == 0 && forward.alphaComponent == BrowserOptionalToolbar.Ink.icon)
        toolbar.updateTint(BrowserPageTint(red: 20, green: 20, blue: 24))
        #expect(toolbar.foreground == .white)
    }

    @Test("The interaction preference decodes old documents and persists the toolbar choice")
    func persistence() async throws {
        let old = try JSONDecoder().decode(BrowserInteractionPreferences.self,
                                           from: Data(#"{"warnBeforeQuitting":false,"playSoundEffects":true,"hapticFeedback":true}"#.utf8))
        #expect(!old.showsToolbar && !old.warnBeforeQuitting)
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("Orbit-TOOLBAR-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let runtime = BrowserSettingsRuntime(store: try BrowserSettingsStore(destination: file))
        await runtime.refresh()
        var published = 0
        runtime.onChange = { published += 1 }
        try await runtime.setShowsToolbar(true)
        #expect(runtime.document.interaction.showsToolbar && published >= 1)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(await reopened.snapshot().interaction.showsToolbar)
    }

    @Test("Sidebar geometry without the address row moves the content up 46 points")
    func sidebarGeometry() {
        let with = OrbitSidebarGeometry.resolve(.init(height: 640, favoriteCount: 1))
        let without = OrbitSidebarGeometry.resolve(.init(height: 640, favoriteCount: 1, showsAddress: false))
        #expect(without.addressFrame.minY == 36 && without.addressFrame.height == 0)
        #expect(with.favoritesFrame.minY - without.favoritesFrame.minY == 46)
        #expect(with.pageFrame.minY - without.pageFrame.minY == 46)
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeOptionalToolbarTests {
    private typealias Window = BrowserWindowController<PeekSyntheticEngine>

    private func makeWindow(_ environment: BrowserEnvironment<PeekSyntheticEngine>) async throws -> Window {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = try await environment.makeWindow()
        window.submitAddress("https://toolbar.test/page")
        await settle(window)
        return window
    }

    private func settle(_ window: Window) async {
        await window.session.waitForPendingCommands()
        await Task.yield()
        await window.session.waitForPendingCommands()
        window.window?.contentView?.layoutSubtreeIfNeeded()
    }

    @Test("Show/Hide Toolbar swaps the sidebar navigation for a card header in every window, without motion")
    func toggle() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let window = try await makeWindow(environment)
        let other = try await makeWindow(environment)
        defer { for item in [window, other] { item.session.close(); item.window?.close() } }
        #expect(window.contentCard.header == nil)
        #expect(!window.sidebar.addressContainer.isHidden)
        window.toggleToolbar()
        await settle(window)
        await settle(other)
        for item in [window, other] {
            #expect(item.isToolbarVisible)
            #expect(item.contentCard.header === item.optionalToolbar)
            #expect(item.contentCard.headerHeight == BrowserOptionalToolbar.height)
            #expect(item.sidebar.addressContainer.isHidden)
            #expect(item.sidebar.navigationContainer.buttons.dropFirst().allSatisfy { $0.isHidden })
            #expect(!item.sidebar.navigationContainer.buttons[0].isHidden)
        }
        #expect(environment.settings.document.interaction.showsToolbar)
        // No measurement yet: a web page shows the default white canvas, never the Space fill.
        #expect(window.optionalToolbar.pageTint == BrowserPageTint(red: 255, green: 255, blue: 255))
        #expect(window.optionalToolbar.address.accessibilityValue() as? String == "https://toolbar.test/page")
        #expect(window.optionalToolbar.layer?.animationKeys()?.isEmpty != false)
        window.toggleToolbar()
        await settle(window)
        await settle(other)
        for item in [window, other] {
            #expect(!item.isToolbarVisible)
            #expect(item.contentCard.header == nil && item.contentCard.headerHeight == 0)
            #expect(!item.sidebar.addressContainer.isHidden)
            #expect(item.sidebar.navigationContainer.buttons.allSatisfy { !$0.isHidden })
        }
    }

    @Test("A restored shown toolbar hides at once and a window render before the save cannot bring it back")
    func restoredHide() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        // A previous session saved the toolbar as shown; the window opens with it.
        try await environment.settings.setShowsToolbar(true)
        let window = try await makeWindow(environment)
        defer { window.session.close(); window.window?.close() }
        #expect(window.isToolbarVisible && window.contentCard.header === window.optionalToolbar)
        window.toggleToolbar()
        await window.session.waitForQueuedCommands()
        // Any session render re-applies the settings document; it must already hold the new choice.
        window.settingsPreferences?.renderSession(in: window)
        #expect(!window.isToolbarVisible)
        #expect(!environment.settings.document.interaction.showsToolbar)
        await settle(window)
        #expect(!window.isToolbarVisible && window.contentCard.header == nil)
        #expect(await environment.settings.store.snapshot().interaction.showsToolbar == false)
        window.toggleToolbar()
        await window.session.waitForQueuedCommands()
        window.settingsPreferences?.renderSession(in: window)
        #expect(window.isToolbarVisible)
        await settle(window)
        #expect(await environment.settings.store.snapshot().interaction.showsToolbar)
    }

    @Test("Without durable settings the toolbar choice still holds for the session")
    func unavailableSettings() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        environment.settings = BrowserSettingsRuntime(store: BrowserSettingsStore.unavailable())
        environment.settings.onChange = { [weak environment] in environment?.settingsDidChange() }
        let window = try await makeWindow(environment)
        defer { window.session.close(); window.window?.close() }
        window.toggleToolbar()
        await settle(window)
        window.settingsPreferences?.renderSession(in: window)
        #expect(window.isToolbarVisible && window.contentCard.header === window.optionalToolbar)
    }

    @Test("Developer Mode takes precedence and restoring ordinary mode brings the optional row back")
    func developerPrecedence() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let window = try await makeWindow(environment)
        defer { window.session.close(); window.window?.close() }
        window.setToolbarVisible(true)
        let surface = try #require(window.session.selectedSurface)
        var preferences = BrowserSitePreferences()
        preferences.developerMode = true
        try window.siteControls.preferences.set(preferences, url: surface.navigationState.committedURL, profileID: surface.profileID)
        window.renderPageHeader()
        #expect(window.contentCard.header === window.developerToolbar)
        preferences.developerMode = false
        try window.siteControls.preferences.set(preferences, url: surface.navigationState.committedURL, profileID: surface.profileID)
        window.renderPageHeader()
        #expect(window.contentCard.header === window.optionalToolbar)
    }

    @Test("Split View hides the window toolbar and keeps each pane's own header")
    func splitPanes() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let window = try await makeWindow(environment)
        defer { window.session.close(); window.window?.close() }
        window.toggleToolbar()
        await settle(window)
        #expect(window.contentCard.header === window.optionalToolbar)
        window.session.addSplitPane(url: URL(string: "https://right.toolbar.test/page")!)
        await settle(window)
        #expect(window.session.activeSplit != nil)
        #expect(window.contentCard.header == nil)
        #expect(window.sidebar.addressContainer.isHidden)
        let panes = window.split.view.subviews.compactMap { $0 as? BrowserSplitPaneView }
        #expect(panes.count == 2)
        #expect(panes.allSatisfy { !$0.back.isHidden && !$0.address.isHidden && !$0.close.isHidden })
    }

    @Test("Focusing the address with the toolbar shown opens the Command Bar instead of the hidden sidebar field")
    func focusAddress() async throws {
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let window = try await makeWindow(environment)
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown(); window.session.close(); window.window?.close() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { controller, action in controller.performAcceptedCommand(action) })
        window.palette.registry = registry
        window.toggleToolbar()
        await settle(window)
        #expect(window.isToolbarVisible && !window.palette.isPresented)
        window.focusAddress()
        await settle(window)
        #expect(window.palette.isPresented)
        withExtendedLifetime(registry) {}
        #expect(window.window?.firstResponder !== window.addressField.currentEditor() || window.addressField.currentEditor() == nil)
    }
}
}
