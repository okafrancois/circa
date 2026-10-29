import AppKit
import BrowserCore
import QuartzCore
import Testing
@testable import Orbit

@Suite("Space theme transition continuity", .serialized)
@MainActor
struct ThemeSwitchFlashTests {
    @Test("Every frame stays between the rendered endpoints across modes and publication", arguments: [false, true], [false, true])
    func frameColors(darkSystem: Bool, legacy: Bool) throws {
        let previous = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: darkSystem ? .darkAqua : .aqua)
        defer { NSApplication.shared.appearance = previous }
        func model(_ hex: UInt32, mode: BrowserSpaceTheme.Mode) throws -> BrowserSpaceTheme {
            let value = legacy
                ? BrowserSpaceTheme.composed(colors: [.init(hex: hex)], noise: 0, mode: mode)
                : BrowserSpaceTheme.radial(colors: [.init(hex: hex)], noise: 0, mode: mode)
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            if legacy { json["material"] = "liquidGlass" }
            return try JSONDecoder().decode(BrowserSpaceTheme.self, from: JSONSerialization.data(withJSONObject: json))
        }
        for modes: [BrowserSpaceTheme.Mode] in [[.dark, .automatic], [.automatic, .dark], [.light, .dark], [.dark, .light]] {
            let themes = try [model(0x794D91, mode: modes[0]), model(0x327F7C, mode: modes[1])].map(OrbitSpaceThemes.rendered)
            for reverse in [false, true] {
                let source = themes[reverse ? 1 : 0], target = themes[reverse ? 0 : 1]
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                      styleMask: [.titled], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let root = OrbitWindowRootView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
                window.contentView = root
                let shell = OrbitWindowShell()
                shell.prepare(window: window, root: root)
                defer { shell.onThemePaint = nil }
                func stops(_ theme: OrbitTokens.SpaceTheme) -> [NSColor] {
                    let appearance = OrbitAppearance.windowAppearance(for: theme.mode) ?? NSApplication.shared.effectiveAppearance
                    return OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance).map { NSColor(cgColor: $0)!.usingColorSpace(.sRGB)! }
                }
                let a = stops(source), b = stops(target)
                let gradient = try #require(shell.themeFill.layer?.sublayers?
                    .flatMap { $0.sublayers ?? [] }.compactMap { $0 as? CAGradientLayer }.first)
                shell.apply(theme: source, animated: false)
                var frames = 0
                shell.onThemePaint = { painted in
                    let actual = (gradient.colors as? [CGColor] ?? []).map { NSColor(cgColor: $0)!.usingColorSpace(.sRGB)! }
                    #expect(actual.count == 3)
                    for i in actual.indices {
                        let x = [a[i].redComponent, a[i].greenComponent, a[i].blueComponent]
                        let y = [b[i].redComponent, b[i].greenComponent, b[i].blueComponent]
                        let c = [actual[i].redComponent, actual[i].greenComponent, actual[i].blueComponent]
                        let d = zip(x, y).map { $1 - $0 }
                        let length = d.reduce(CGFloat(0)) { $0 + $1 * $1 }
                        let p = length == 0 ? 0 : min(1, max(0, zip(zip(c, x), d).reduce(CGFloat(0)) { $0 + ($1.0.0 - $1.0.1) * $1.1 } / length))
                        let error = zip(zip(c, x), d).map { abs($0.0.0 - ($0.0.1 + p * $0.1)) }.max()!
                        #expect(error < 2.0 / 255, "frame \(frames), legacy \(legacy), modes \(modes), reverse \(reverse)")
                    }
                    #expect(shell.floatingBackdrop.fill.theme == painted)
                    frames += 1
                }
                for frame in 0...72 {
                    let p = OrbitThemeTransition.progress(at: Double(frame) / 120)
                    shell.applySpaceSwipeBlend(.init(source: source, destination: target, progress: p))
                    if frame == 24 { shell.apply(theme: target, animated: false) }
                }
                shell.applySpaceSwipeBlend(nil)
                #expect(frames >= 74)
            }
        }
    }

    @Test("Retargeting freezes the last painted colour and geometry before an appearance change")
    func interruptedPaint() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let a = OrbitSpaceThemes.rendered(.composed(colors: [.init(hex: 0x794D91)], mode: .dark))
        let b = OrbitSpaceThemes.rendered(.composed(colors: [.init(hex: 0x327F7C)]))
        let painted = SpaceSwipeThemeBlend(source: a, destination: b, progress: 0.37).theme
        let captured = SpaceSwipeThemeBlend.snapshot(painted, appearance: light)
        for frame in 0...72 {
            let p = CGFloat(OrbitThemeTransition.progress(at: Double(frame) / 120))
            let next = SpaceSwipeThemeBlend(source: captured, destination: a, progress: p).theme
            for appearance in [light, dark] {
                let start = OrbitThemeGradient.representativeColor(painted, appearance: light)
                let end = OrbitThemeGradient.representativeColor(a, appearance: dark)
                let actual = OrbitThemeGradient.representativeColor(next, appearance: appearance)
                for (x, y, c) in [(start.redComponent, end.redComponent, actual.redComponent),
                                   (start.greenComponent, end.greenComponent, actual.greenComponent),
                                   (start.blueComponent, end.blueComponent, actual.blueComponent)] {
                    #expect(abs(c - (x + (y - x) * p)) < 2.0 / 255)
                }
            }
        }
    }

}
