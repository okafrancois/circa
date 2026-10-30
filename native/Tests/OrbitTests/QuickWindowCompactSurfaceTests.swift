import AppKit
import BrowserShell
import BrowserCore
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Little Orbit compact surfaces", .serialized)
@MainActor
struct QuickWindowCompactSurfaceTests {
    @Test("Little Orbit keeps dark chrome and input over light and automatic source Spaces",
          arguments: [OrbitTokens.SpaceTheme.Mode.light, .automatic, .dark])
    func fixedDarkAppearance(mode: OrbitTokens.SpaceTheme.Mode) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let applicationAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = applicationAppearance }
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let little = try await environment.makeQuickWindow()
        defer { environment.retireQuickWindows() }
        var theme = OrbitTokens.SpaceTheme.default
        theme.mode = mode
        little.applyPreferences(searchEngine: .google, theme: theme)
        let window = try #require(little.window)
        #expect(OrbitAppearance.isDark(window.effectiveAppearance))
        #expect(OrbitAppearance.isDark(little.toolbar.fill.effectiveAppearance))
        #expect(little.toolbar.fill.theme == theme)
        #expect(little.addressField.font == BrandTextStyle.ui.font(size: 13, weight: .medium))
        let input = try #require(little.prepareCompactInput())
        #expect(OrbitAppearance.isDark(input.window.effectiveAppearance))
        #expect(OrbitAppearance.isDark(input.input.effectiveAppearance))
        #expect(input.input.textColor?.resolved(for: input.input.effectiveAppearance)
            == OrbitFloatingMaterial.body.resolved(for: NSAppearance(named: .darkAqua)!))
        little.showSpaceChooser([])
        #expect(little.spaceChooser != nil)
        #expect(OrbitAppearance.isDark(try #require(little.spaceChooser?.window.effectiveAppearance)))
        #expect(!input.window.isVisible && little.spaceChooser?.window.isVisible == false)
    }

    @Test("The compact input is a separate, bounded surface with five suggestions and no browser navigation")
    func compactInput() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let little = try await environment.makeQuickWindow()
        defer { environment.retireQuickWindows() }
        little.suggestionProvider = nil
        little.inputCandidates = (0..<5).map { index in
            let url = URL(string: "https://synthetic.invalid/page/\(index)")!
            return BrowserPaletteResult(id: "page-\(index)", title: "Synthetic page \(index)", detail: url.absoluteString,
                section: .pinned, action: .navigate(url))
        }
        let input = try #require(little.prepareCompactInput())
        #expect(input.preferredSize == NSSize(width: 490, height: 328))
        #expect(input.rows.count == 5)
        #expect(input.window !== little.window)
        #expect(!input.window.isVisible && little.window?.isVisible == false)
        #expect(little.surface?.requestedURLs.isEmpty == true)
        input.move(1)
        #expect(input.selectedIndex == 1)
        let identities = input.rows.map(\.id)
        input.render(input.rows)
        #expect(input.rows.map(\.id) == identities && input.selectedIndex == 1)
        little.retire()
        #expect(little.isClosed && !input.window.isVisible)
    }

    @Test("Typing preserves the draft and resolving it starts one navigation in the same Little document")
    func typedNavigation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let little = try await environment.makeQuickWindow()
        defer { environment.retireQuickWindows() }
        little.suggestionProvider = nil
        let input = try #require(little.prepareCompactInput())
        input.input.stringValue = "https://synthetic.invalid/typed"
        little.queryCompactInput(input.input.stringValue)
        let typed = try #require(input.rows.first)
        #expect(typed.title.contains("synthetic.invalid/typed"))
        little.render()
        #expect(input.input.stringValue == "https://synthetic.invalid/typed")
        let document = try #require(little.surface)
        let editor = NSTextView()
        #expect(input.control(input.input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        typed.accept() // A queued duplicate acceptance cannot start a second load.
        #expect(little.surface === document)
        #expect(document.requestedURLs == [URL(string: "https://synthetic.invalid/typed")!])
        #expect(little.opensWithDocument)
        #expect(!input.window.isVisible && little.window?.isVisible == false)
        #expect(little.window?.styleMask.contains(.resizable) == true)
        #expect(little.window?.minSize == OrbitTokens.Metrics.QuickWindow.minimumSize)
    }

    @Test("The Space chooser lists all profiles in sidebar order with icons and keeps same-profile promotion live")
    func chooseSpace() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let app = OrbitApplication(environment: environment, windowPresenter: { _, _ in })
        app.quickWindowPresenter = { _ in }
        defer { environment.retireQuickWindows(); app.windows.shutdown() }
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let main = try #require(app.activeBrowserWindow)
        let profile = try #require(main.session.activeProfileID)
        let destination = try await environment.store.createSpace(name: "Synthetic destination", profileID: profile)
        let foreign = await environment.store.createProfile(name: "Synthetic foreign profile")
        let foreignSpace = try await environment.store.createSpace(name: "Synthetic foreign Space", profileID: foreign)
        try await environment.store.moveSpace(foreignSpace, before: destination)
        let little = try await environment.makeQuickWindow(url: URL(string: "https://synthetic.invalid/live")!)
        app.configureQuickWindow(little)
        app.showQuickWindowSpaces(little)
        for _ in 0..<10 { await Task.yield() }
        let chooser = try #require(little.spaceChooser)
        let catalog = await environment.store.catalogSnapshot()
        #expect(chooser.rows.map(\.id) == catalog.spaces.map { $0.id.rawValue.uuidString })
        #expect(chooser.rows.allSatisfy { $0.image != nil && $0.iconBackground != nil })
        #expect(chooser.preferredSize.height == 46 + CGFloat(chooser.rows.count) * 46)
        #expect(chooser.selectedIndex == -1)
        chooser.onQuery?("Synthetic destination")
        #expect(chooser.rows.map(\.title) == ["Synthetic destination"])
        let surface = try #require(little.surface)
        let document = surface.webView
        chooser.rows[0].accept()
        await app.waitForQuickWindowCommands()
        #expect(little.isClosed)
        let target = try #require(app.windows.windows.values.first { $0.session.snapshot?.activeSpaceID == destination })
        #expect(target === main)
        #expect(app.windows.windows.count == 1)
        #expect(target.session.selectedSurface === surface)
        #expect(target.session.selectedSurface?.webView === document)
    }
}
}
