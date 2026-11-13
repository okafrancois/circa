import AppKit
import BrowserCore
import BrowserShell
import Testing
import WebKit
import WebKitEngine
@testable import Orbit

@Suite(.serialized) @MainActor
struct DaylightAppearanceTests {
    @Test("Owned windows remain Aqua while the application's website preference remains dark")
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

    @Test("Every planet keeps its daylight tint despite stored dark mode and dark system appearance")
    func spaceTints() {
        let dark = NSAppearance(named: .darkAqua)!
        for preset in BrandPalette.spaceGradients {
            var model = preset.theme(mode: .dark)
            model.dark.stops = Array(repeating: BrowserThemeColor(hex: 0x010101), count: 3)
            let theme = OrbitSpaceThemes.rendered(model)
            #expect(theme.mode == .light)
            for (stop, expected) in zip(theme.stops, model.light.stops) {
                #expect(stop.resolved(for: dark) == OrbitSpaceThemes.color(expected))
            }
        }
        #expect(OrbitFloatingMaterial.style(for: NSAppearance(named: .aqua)!).variant == .light)
        #expect(OrbitTokens.Color.Surface.commandBar.resolved(for: NSAppearance(named: .aqua)!) == NSColor(srgbRed: 249/255, green: 249/255, blue: 249/255, alpha: 1))
        #expect(OrbitSpaceThemes.privateWindow.stops.first == BrandPalette.paper)
    }

    @Test("The theme editor offers colour and grain controls without an appearance choice")
    func editor() {
        let view = OrbitThemeEditorView(state: .init(theme: BrandPalette.spaceGradients[3].theme(mode: .dark)))
        let labels = view.subviews.compactMap { $0.accessibilityLabel() }
        #expect(!labels.contains("Dark Appearance") && !labels.contains("Light Appearance") && !labels.contains("Automatic Appearance"))
        #expect(view.swatches.count == 9)
        #expect(view.grainDial.accessibilityLabel() == OrbitThemeEditorText.grain)
    }
}
