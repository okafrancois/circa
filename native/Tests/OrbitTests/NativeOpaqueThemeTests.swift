import AppKit
import BrowserCore
import BrowserEngineConformance
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Space theme fills and window glass", .serialized)
@MainActor
struct NativeOpaqueThemeTests {
    @Test("Theme gradient source retains its full-strength colors")
    func opaquePaint() throws {
        let model = BrowserSpaceTheme.composed(colors: [.init(hex: 0xee2200)], intensity: 1, mode: .light)
        let theme = OrbitSpaceThemes.rendered(model)
        let sidebar = OrbitFloatingSidebarBackdrop(frame: NSRect(x: 0, y: 0, width: 180, height: 220))
        let fill = OrbitThemeFillView(frame: sidebar.bounds)
        sidebar.fill.apply(theme)
        fill.apply(theme)
        for view in [fill] {
            view.appearance = NSAppearance(named: .aqua)
            view.viewDidChangeEffectiveAppearance()
            view.layoutSubtreeIfNeeded()
            #expect(view.subviews.isEmpty)
            let expected = try #require(NSColor(cgColor: view.resolvedStops[0])?.usingColorSpace(.sRGB))
            let context = try #require(CGContext(data: nil, width: 180, height: 220, bitsPerComponent: 8,
                bytesPerRow: 180 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            // The gradient must cover the transparent backing completely.
            try #require(view.layer).render(in: context)
            let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            let offset = (110 * 180 + 90) * 4
            #expect(bytes[offset + 3] == 255)
            for (index, component) in [expected.redComponent, expected.greenComponent, expected.blueComponent].enumerated() {
                #expect(abs(Double(bytes[offset + index]) - Double(component * 255)) <= 2)
            }
        }
    }

    @Test("Settings opens the color editor; controls retain colors, intensity, grain and modes")
    func settingsEditor() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let (space, profile) = try await environment.initialContext.value
        let theme = BrowserSpaceTheme.composed(colors: [.init(hex: 0xee2200), .init(hex: 0x2222ee)],
                                               intensity: 0.91, noise: 0.63, mode: .light)
        try await environment.store.setSpaceTheme(theme, for: space)
        let browser = try await environment.makeWindow(spaceID: space)
        let model = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await model.reload()
        let settings = BrowserSettingsWindowController(model: model)
        defer { browser.window?.close(); settings.window?.close() }
        settings.openThemeEditor(for: space, animated: false)
        let editor = try #require(settings.themeEditor)
        #expect(editor.draft == theme)
        #expect(browser.window?.isOpaque == false)
        #expect(browser.windowShell.themeFill.theme.model == theme)
        #expect(editor.view.subviews.compactMap { $0 as? NSPopUpButton }.isEmpty)
        #expect(editor.view.subviews.compactMap { $0 as? NSSlider }.isEmpty)
        #expect(editor.view.modeButtons.count == 3)
        var state = editor.view.state
        state.setIntensity(0.81)
        state.setNoise(0.75)
        state.setMode(.dark)
        #expect(state.theme.colors == theme.colors)
        #expect(state.theme.intensity == 0.81 && state.theme.noise == 0.75 && state.theme.mode == .dark)
        #expect(await environment.themeEditors.finishAll())
    }
}
}
