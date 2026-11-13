import AppKit
import BrowserCore
import BrowserShell
import Testing
import WebKit
import WebKitEngine
@testable import Orbit

@Suite(.serialized) @MainActor
struct DaylightAppearanceTests {
    @Test("Settings and onboarding window classes remain Aqua while the application's website preference remains dark")
    func windowIsolation() throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        app.appearance = NSAppearance(named: .darkAqua)
        let window = OrbitDaylightWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let panel = OrbitDaylightPanel(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        for target in [window, panel] {
            target.appearance = NSAppearance(named: .darkAqua)
            #expect(!OrbitAppearance.isDark(target.effectiveAppearance))
            target.appearance = nil
            #expect(!OrbitAppearance.isDark(target.effectiveAppearance))
        }
        #expect(OrbitAppearance.isDark(app.effectiveAppearance))
    }


    @Test("The fallback website surface keeps the system preference inside a daylight window")
    func fallbackWebsiteIsolation() async throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        app.appearance = NSAppearance(named: .darkAqua)
        let surface = WebKitSurface(profileID: ProfileID(), dataStore: .nonPersistent())
        defer { surface.dispose() }
        let window = OrbitDaylightWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.contentView = surface.hostView
        #expect(!OrbitAppearance.isDark(window.effectiveAppearance))
        #expect(OrbitAppearance.isDark(surface.hostView.effectiveAppearance))
        app.appearance = NSAppearance(named: .aqua)
        for _ in 0..<20 where OrbitAppearance.isDark(surface.hostView.effectiveAppearance) { await Task.yield() }
        #expect(!OrbitAppearance.isDark(surface.hostView.effectiveAppearance))
        window.contentView = nil
    }

    @Test("Browser windows inherit automatic system appearance and accept fixed Space modes")
    func browserWindowAppearance() {
        let window = OrbitBrowserWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.appearance = OrbitAppearance.windowAppearance(for: .automatic, override: nil)
        #expect(window.appearance == nil)
        window.appearance = OrbitAppearance.windowAppearance(for: .light, override: nil)
        #expect(!OrbitAppearance.isDark(window.effectiveAppearance))
        window.appearance = OrbitAppearance.windowAppearance(for: .dark, override: nil)
        #expect(OrbitAppearance.isDark(window.effectiveAppearance))
        #expect(BrowserSpaceThemePresets.default.mode == .automatic)
        #expect(BrandPalette.spaceGradients[0].theme().mode == .automatic)
    }

    @Test("Space gradients resolve their stored dark variant")
    func spaceTints() {
        let dark = NSAppearance(named: .darkAqua)!
        for preset in BrandPalette.spaceGradients {
            var model = preset.theme(mode: .dark)
            model.dark.stops = Array(repeating: BrowserThemeColor(hex: 0x010101), count: 3)
            let theme = OrbitSpaceThemes.rendered(model)
            #expect(theme.mode == .dark)
            for (stop, expected) in zip(theme.stops, model.dark.stops) {
                #expect(stop.resolved(for: dark) == OrbitSpaceThemes.color(expected))
            }
        }
        #expect(OrbitFloatingMaterial.style(for: NSAppearance(named: .aqua)!).variant == .light)
        #expect(OrbitTokens.Color.Surface.commandBar.resolved(for: NSAppearance(named: .aqua)!) == NSColor(srgbRed: 249/255, green: 249/255, blue: 249/255, alpha: 1))
        #expect(OrbitSpaceThemes.privateWindow.mode == .dark)
        #expect(OrbitFloatingMaterial.style(for: dark).variant == .dark)
    }

    @Test("The theme editor offers automatic, light and dark appearance controls")
    func editor() {
        let view = OrbitThemeEditorView(state: .init(theme: BrandPalette.spaceGradients[3].theme(mode: .dark)))
        let labels = view.subviews.compactMap { $0.accessibilityLabel() }
        #expect(labels.contains(OrbitThemeEditorText.dark))
        #expect(labels.contains(OrbitThemeEditorText.light))
        #expect(labels.contains(OrbitThemeEditorText.automatic))
        #expect(view.modeButtons.count == 3)
        #expect(view.swatches.count == 9)
        #expect(view.grainDial.accessibilityLabel() == OrbitThemeEditorText.grain)
    }
}
