import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

@Suite("Theme palette and synchronized paint", .serialized)
@MainActor
struct ThemeParityTests {
    @Test("The critically damped response matches the visible interval and never overshoots")
    func transition() {
        var last = 0.0
        var lower = 0.0, upper = 0.0
        for i in 0...600 {
            let t = Double(i) / 1000, p = OrbitThemeTransition.progress(at: t)
            #expect(p >= last && p <= 1)
            if last < 0.02 && p >= 0.02 { lower = t }
            if last < 0.98 && p >= 0.98 { upper = t }
            last = p
            let state = OrbitThemeTransition.spring.state(after: t, displacement: -1, velocity: 0)
            #expect(abs(1 + state.displacement - p) < 1e-9)
        }
        #expect(abs((upper - lower) - 0.184) < 0.011)
    }

    @Test("All foreground consumers resolve one token, including overlays and opposite system appearances")
    func consumers() throws {
        for hex: UInt32 in [0x203F98, 0xB8F478, 0x7F7F7F, 0x808080] {
            let color = OrbitSpaceThemes.color(BrowserThemeColor(hex: hex))
            let theme = OrbitTokens.SpaceTheme(stops: [color], mode: .automatic, texture: .none, textureIntensity: 0)
            let accent = OrbitSpaceThemes.accent(for: theme)
            let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 720))
            let field = NSTextField(string: "synthetic.test")
            sidebar.addressContainer.installField(field)
            let urlIcon = OrbitGlyphButton(glyph: OrbitGlyph.reload, label: "Synthetic icon")
            sidebar.addressContainer.installAccessory(urlIcon)
            let navigation = OrbitGlyphButton(glyph: OrbitGlyph.reload, label: "Synthetic navigation")
            sidebar.navigationContainer.install([navigation])
            sidebar.applyAccent(accent)
            let row = SidebarTabRow(item: .init(id: TabID(), title: "Synthetic tab", selected: true))
            row.accent = accent
            let newTab = SidebarNewTabRow()
            newTab.accent = accent
            let card = BrowserContentCardView()
            card.themeForeground = accent.foreground
            let actual: [OrbitThemeForeground.Consumer: NSColor] = [
                .sidebarText: try #require(row.titleLabel.textColor), .icons: row.closeButton.tint,
                .urlText: try #require(field.textColor), .urlIcons: urlIcon.tint,
                .newTab: try #require(newTab.label.textColor), .footer: sidebar.footer.libraryButton.tint,
                .spaceTitle: try #require(sidebar.page.titleLabel.textColor), .buttons: sidebar.footer.plusButton.tint,
                .scrollIndicators: sidebar.page.scrollView.scrollerKnobStyle == .dark ? NSColor(srgbRed: 32.0/255, green: 32.0/255, blue: 32.0/255, alpha: 1) : NSColor(srgbRed: 244.0/255, green: 244.0/255, blue: 244.0/255, alpha: 1),
                .frameEdges: try #require(card.frameEdgeColor).withAlphaComponent(1)
            ]
            #expect(actual.count == OrbitThemeForeground.Consumer.allCases.count)
            for dark in [false, true] {
                let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
                let expected = OrbitThemeForeground.color(on: color)
                #expect(navigation.disabledTint.resolved(for: appearance).withAlphaComponent(1) == expected)
                #expect(sidebar.footer.plusButton.disabledTint.resolved(for: appearance).withAlphaComponent(1) == expected)
                for (role, value) in actual {
                    #expect(value.resolved(for: appearance) == expected, "consumer \(role)")
                }
                let over = OrbitSpaceThemes.accent(accent, over: [.white], iconHover: .black)
                #expect(over.foreground.resolved(for: appearance) == expected)
            }
            let neighbor = BrowserSpace(id: SpaceID(), profileID: ProfileID(), name: "Synthetic neighboring Space")
            sidebar.showSpaceSwipe(offset: -60, space: neighbor, content: .init(entries: []), destinationAccent: .defaultPurple)
            sidebar.applyAccent(accent)
            func labels(_ view: NSView) -> [NSTextField] {
                view.subviews.flatMap { (($0 as? NSTextField).map { [$0] } ?? []) + labels($0) }
            }
            let title = try #require(labels(sidebar).first { $0.stringValue == neighbor.name })
            let appearance = try #require(NSAppearance(named: .aqua))
            #expect(title.textColor?.resolved(for: appearance) == accent.foreground.resolved(for: appearance))
        }
    }

    @Test("Colour interpolation paints the sidebar, frame, foreground and mesh on one progress value")
    func blend() throws {
        let a = OrbitSpaceThemes.rendered(.radial(colors: [BrowserThemeColor(hex: 0x0040FF)]))
        let b = OrbitSpaceThemes.rendered(.radial(colors: [BrowserThemeColor(hex: 0xC8FF92), .init(hex: 0xFFDDAA), .init(hex: 0xEEAAFF)]))
        let appearance = try #require(NSAppearance(named: .aqua))
        let point = CGPoint(x: 0.21, y: 0.73)
        for p: CGFloat in [0, 0.2, 0.5, 0.8, 1] {
            let theme = SpaceSwipeThemeBlend(source: a, destination: b, progress: p).theme
            let actual = OrbitThemeGradient.color(theme, at: point, appearance: appearance)
            let x = OrbitThemeGradient.color(a, at: point, appearance: appearance)
            let y = OrbitThemeGradient.color(b, at: point, appearance: appearance)
            #expect(abs(actual.redComponent - (x.redComponent + (y.redComponent - x.redComponent) * p)) < 0.002)
        }
    }

    @Test("One colour stays flat, two use a 43 degree ramp, three respond independently on both axes")
    func gradients() throws {
        let colors = [BrowserThemeColor(hex: 0xE0BEDF), .init(hex: 0xE9BACD), .init(hex: 0xB5E0BE)]
        let one = OrbitSpaceThemes.rendered(.radial(colors: Array(colors.prefix(1))))
        let two = OrbitSpaceThemes.rendered(.radial(colors: Array(colors.prefix(2))))
        let three = OrbitSpaceThemes.rendered(.radial(colors: colors, intensity: 1))
        #expect(one.stops.count == 1 && one.meshCorners == nil)
        #expect(two.stops.count == 2 && two.meshCorners == nil && two.angle.light == 43)
        #expect(three.meshCorners?.count == 4)
        let a = OrbitThemeMesh.weights(at: .zero), x = OrbitThemeMesh.weights(at: CGPoint(x: 1, y: 0)), y = OrbitThemeMesh.weights(at: CGPoint(x: 0, y: 1))
        #expect(abs(a[0] - x[0]) > 0.5 && abs(a[1] - y[1]) > 0.8)
        for i in colors.indices {
            var changed = colors
            changed[i] = .init(hex: 0xA0C0F0)
            #expect(OrbitThemeMesh.corners(.radial(colors: changed)) != OrbitThemeMesh.corners(.radial(colors: colors)))
        }
    }

    @Test("The radial grid matches calibrated rendered colours within Delta E 1")
    func paletteGrid() {
        let samples: [(Double, Double, UInt32)] = [
            (0, 0.2, 0x8B393C),
            (0, 0.6, 0xF44F57),
            (0, 0.95, 0xE7CACB),
            (45, 0.2, 0x846F35),
            (45, 0.6, 0xE9BE45),
            (45, 0.95, 0xE3DCC9),
            (90, 0.2, 0x568233),
            (90, 0.6, 0x8AE43E),
            (90, 0.95, 0xD3E2C9),
            (135, 0.2, 0x1A8349),
            (135, 0.6, 0x00E672),
            (135, 0.95, 0xC6E3D0),
            (180, 0.2, 0x1A8382),
            (180, 0.6, 0x00E6E4),
            (180, 0.95, 0xC6E3E2),
            (225, 0.2, 0x3A5085),
            (225, 0.6, 0x527FE9),
            (225, 0.95, 0xCAD1E4),
            (270, 0.2, 0x663C85),
            (270, 0.6, 0xAA58EA),
            (270, 0.95, 0xD8CBE4),
            (315, 0.2, 0x8B3973),
            (315, 0.6, 0xF44FC5),
            (315, 0.95, 0xE7CADD),
        ]
        func lab(_ c: BrowserThemeColor) -> [Double] {
            let rgb = [c.red, c.green, c.blue].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            let xyz = [(0.4124564 * rgb[0] + 0.3575761 * rgb[1] + 0.1804375 * rgb[2]) / 0.95047,
                       0.2126729 * rgb[0] + 0.7151522 * rgb[1] + 0.0721750 * rgb[2],
                       (0.0193339 * rgb[0] + 0.1191920 * rgb[1] + 0.9503041 * rgb[2]) / 1.08883]
            let f = xyz.map { $0 > 0.008856 ? pow($0, 1.0 / 3) : 7.787 * $0 + 16.0 / 116 }
            return [116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])]
        }
        for (angle, radius, hex) in samples {
            let p = CGPoint(x: 0.5 + cos(angle * .pi / 180) * radius / 2, y: 0.5 + sin(angle * .pi / 180) * radius / 2)
            let picked = OrbitThemeFieldMapping.color(at: p)
            let back = OrbitThemeFieldMapping.position(of: picked)
            #expect(hypot(back.x - p.x, back.y - p.y) < 0.002)
            let actual = BrowserSpaceTheme.radial(colors: [picked]).light.stops[0]
            let delta = sqrt(zip(lab(actual), lab(BrowserThemeColor(hex: hex))).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
            #expect(delta < 1, "angle \(angle), radius \(radius), Delta E \(delta)")
        }
    }

    @Test("Old records decode without a palette version and preserve baked colours through mode and grain edits")
    func compatibility() throws {
        let old = BrowserSpaceTheme.composed(colors: [.init(hex: 0xAB93AC)])
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("paletteVersion"))
        let decoded = try JSONDecoder().decode(BrowserSpaceTheme.self, from: data)
        #expect(decoded == old)
        #expect(decoded.recomposed(noise: 0.7, mode: .dark).light == old.light)
        let fresh = BrowserSpaceTheme.radial(colors: [.init(hex: 0x0080FF)])
        #expect(try JSONDecoder().decode(BrowserSpaceTheme.self, from: JSONEncoder().encode(fresh)) == fresh)
    }
}
