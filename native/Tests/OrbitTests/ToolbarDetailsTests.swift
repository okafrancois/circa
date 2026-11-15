import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@Suite("Toolbar details", .serialized)
@MainActor
struct ToolbarDetailsTests {
    @Test("Host-only display removes the port, path and query; switching keeps the committed URL")
    func formatting() {
        let url = URL(string: "http://127.0.0.1:8765/t1.html?q=1#part")!
        let view = BrowserToolbarAddressView()
        view.url = url
        #expect(view.displayText.string == "127.0.0.1:8765/t1.html?q=1#part")
        view.showsFullURL = false
        #expect(view.displayText.string == "127.0.0.1")
        #expect(view.accessibilityValue() as? String == url.absoluteString)
        view.showsFullURL = true
        #expect(view.displayText.string.hasSuffix("#part"))
    }

    @Test("Full URL defaults on for older documents and survives a store reopen")
    func persistence() async throws {
        let old = try JSONDecoder().decode(BrowserInteractionPreferences.self, from: Data("{}".utf8))
        #expect(old.toolbarShowsFullURL)
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("settings.json")
        let runtime = BrowserSettingsRuntime(store: try BrowserSettingsStore(destination: file))
        try await runtime.setToolbarShowsFullURL(false)
        let reopened = try BrowserSettingsStore(destination: file)
        #expect(!(await reopened.snapshot()).interaction.toolbarShowsFullURL)
    }

    @Test("Pinned buttons and badge move between the sidebar and toolbar without replacing the popup anchor")
    func placement() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.openTab(url: URL(string: "https://toolbar.invalid/page")!)
        await owner.session.waitForPendingCommands()
        owner.extensionControls.presentationInventory = { _ in
            [.init(id: "fixture", name: "Fixture", version: "1", isEnabled: true, hasAction: true,
                   isPinned: true, actionBadgeText: "7")]
        }
        owner.extensionControls.render()
        let button = try #require(owner.sidebar.extensionsContainer.subviews.compactMap { $0 as? NSButton }.first)
        let badge = try #require(button.subviews.compactMap { $0 as? BrowserExtensionBadgeView }.first)
        #expect(badge.text == "7" && !badge.isHidden)
        owner.setToolbarVisible(true)
        #expect(owner.optionalToolbar.pinnedButtons.first === button)
        #expect(button.superview === owner.optionalToolbar && !button.isHidden)
        #expect(owner.sidebar.extensionsContainer.visiblePinCount == 0)
        owner.extensionControls.render()
        #expect(button.superview === owner.optionalToolbar)
        owner.setToolbarVisible(false)
        #expect(button.superview === owner.sidebar.extensionsContainer)
        #expect(owner.optionalToolbar.pinnedButtons.isEmpty && badge.text == "7")
    }

    @Test("At 700 points both extensions remain and the truncated URL stays centred")
    func narrowLayout() {
        let toolbar = BrowserOptionalToolbar()
        toolbar.frame.size.width = 500
        toolbar.setPinnedButtons([NSButton(), NSButton()])
        toolbar.update(url: URL(string: "https://example.invalid/" + String(repeating: "long/", count: 20)), canGoBack: true, canGoForward: true)
        toolbar.layoutSubtreeIfNeeded()
        #expect(toolbar.pinnedButtons.map { $0.frame.midX } == [370, 406])
        #expect(toolbar.pinnedButtons.allSatisfy { !$0.isHidden })
        let text = toolbar.address
        let left = text.frame.minX + text.textInset
        let right = text.frame.maxX - BrowserOptionalToolbar.Metrics.pillPaddingX
        #expect(abs((left + right) / 2 - 250) < 0.1)
        #expect(right < toolbar.pinnedButtons[0].frame.minX)
    }

    @Test("The production registry keeps supported address actions in order before toolbar settings")
    func menuOrder() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let router = BrowserWindowRouter(create: { id in try await environment.makeWindow(id: id) },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { $0.performAcceptedCommand($1) })
        BrowserWindowCommands.install(in: registry)
        defer { router.shutdown() }
        let id = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let owner = try #require(router.windows[id])
        owner.openTab(url: URL(string: "https://toolbar.invalid/page")!)
        await owner.session.waitForPendingCommands()
        let menu = try #require(owner.makeAddressContextMenu(toolbar: true))
        #expect(menu.items.dropLast(2).compactMap { $0.identifier?.rawValue } == [BrowserCommandID.copyURL, .share, .capture, .captureFullPage, .manageExtensions].map(\.rawValue))
        #expect(menu.items.suffix(2).map(\.title) == ["Hide Full URL", "Hide Toolbar"])
    }

    @Test("Address menus expose toolbar-only URL formatting and the sidebar offers Show as Toolbar")
    func menusAndTint() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.session.close(); owner.window?.close() }
        owner.openTab(url: URL(string: "https://toolbar.invalid/page")!)
        await owner.session.waitForPendingCommands()
        let menu = try #require(owner.makeAddressContextMenu(toolbar: false))
        #expect(menu.items.map(\.title) == ["Show as Toolbar"])
        menu.performActionForItem(at: 0)
        await owner.session.waitForPendingCommands()
        let shown = try #require(owner.makeAddressContextMenu(toolbar: true))
        #expect(shown.items.map(\.title) == ["Hide Full URL", "Hide Toolbar"])
        shown.performActionForItem(at: 0)
        await Task.yield()
        #expect(!owner.optionalToolbar.address.showsFullURL)
        #expect(owner.makeAddressContextMenu(toolbar: true)?.items.first?.title == "Show Full URL")
        let surface = try #require(owner.session.selectedSurface)
        #expect(surface.observesPageTint)
        surface.pageTint = .init(red: 16, green: 20, blue: 24)
        surface.onChange?()
        #expect(owner.optionalToolbar.pageTint == surface.pageTint)
        #expect(owner.optionalToolbar.foreground == .white)
        surface.pageTint = .init(red: 255, green: 255, blue: 255)
        surface.onChange?()
        #expect(owner.optionalToolbar.foreground == .black)
        owner.setToolbarVisible(false)
        #expect(!surface.observesPageTint)
    }
}
