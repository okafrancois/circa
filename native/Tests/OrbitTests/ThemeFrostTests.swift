import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct ThemeFrostTests {
    @Test("Theme editor exposes color controls without the retired material option")
    func retiredOption() {
        let view = OrbitThemeEditorView(state: .init(theme: BrowserSpaceThemePresets.default))
        #expect(view.subviews.compactMap { $0 as? NSSwitch }.isEmpty)
        #expect(view.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.stringValue != "Frost" })
        #expect(view.bounds.height == 522)
    }

    @Test("Legacy material choices do not add effects to sidebar controls")
    func surfaces() async throws {
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let window = try await store.createWindow(activeSpaceID: space)
        let context = try await store.captureContext(in: window)
        _ = try await store.openTab(url: URL(string: "https://fixture.invalid")!, from: context, activate: true)
        let tab = try #require(try await store.captureWindowState(in: window).organization.selectedTab)
        let grid = FavoritesGridView()
        grid.render([FavoriteTileItem(tab: tab)], profileID: profile)
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
        sidebar.favoritesContainer.addSubview(grid)
        let active = SidebarTabRow(item: .init(id: TabID(), title: "Synthetic", selected: true))
        let inactive = SidebarTabRow(item: .init(id: TabID(), title: "Synthetic", selected: false))
        let field = NSTextField(string: "fixture.invalid")
        sidebar.addressContainer.installField(field)
        var model = BrowserSpaceThemePresets.default
        for enabled in [true, false] {
            model.frost = enabled
            let accent = OrbitSpaceThemes.accent(for: OrbitSpaceThemes.rendered(model))
            sidebar.applyAccent(accent)
            active.accent = accent
            inactive.accent = accent
            #expect(active.background.frost == nil)
            #expect(inactive.background.frost == nil)
            #expect(grid.tiles.first?.background.frost == nil)
            #expect(sidebar.footer.background.frost == nil)
            let background = try #require(sidebar.addressContainer.subviews.compactMap { $0 as? OrbitSurfaceBackgroundView }.first)
            #expect(background.frost == nil)
        }
    }

    @Test("Window glass samples behind the window and remains enabled across theme edits")
    func sidebarBackdrop() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = OrbitWindowRootView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = root
        let shell = OrbitWindowShell()
        shell.prepare(window: window, root: root)
        for theme in [OrbitTokens.SpaceTheme.default, .amberCoral, .lavender] {
            shell.apply(theme: theme, animated: false)
            #expect(!window.isOpaque)
            #expect(shell.themeFill.tintOpacity > 0 && shell.themeFill.tintOpacity < 1)
            #expect(window.backgroundColor == .clear)
            #expect(shell.sidebarMaterial.blendingMode == .behindWindow)
            #expect(shell.sidebarMaterial.material == .sidebar)
            #expect(shell.sidebarMaterial.state == .active)
            let ink = OrbitSpaceThemes.accent(for: theme).foreground.resolved(for: window.effectiveAppearance)
            let expected: NSAppearance.Name = OrbitThemeForeground.isLight(on: ink) ? .aqua : .darkAqua
            #expect(shell.sidebarMaterial.appearance?.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(shell.floatingBackdrop.material.blendingMode == .withinWindow)
            #expect(shell.floatingBackdrop.material.material == .sidebar)
        }
    }

    @Test("Shared material protects both ink polarities at every stop and interpolant")
    func contrast() {
        let gradients: [[UInt32]] = [
            [0xFF8A7A, 0xFF5A5F, 0x7B4DFF], [0x6E9BFF, 0x2D5BFF, 0x1B2C8F],
            [0xFFE27A, 0xFF9F45, 0xFF5A5F], [0xA7F3D6, 0x3DCCA0, 0x2D5BFF],
            [0x3A3550, 0x1C1A26, 0x0E0E11], [0xF4ECFF, 0xD9C6FF, 0xB79BFF]
        ]
        var stops = gradients.map { $0.map { OrbitSpaceThemes.color(.init(hex: $0)) } }
        for theme in OrbitSpaceThemes.previewThemes {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                stops.append(OrbitThemeGradient.normalizedStops(theme.stops, appearance: NSAppearance(named: appearance)!)
                    .compactMap { NSColor(cgColor: $0) })
            }
        }
        for family in BrowserSpaceThemePresets.families {
            for color in family.swatches {
                for model in [BrowserSpaceTheme.composed(colors: [color]), .radial(colors: [color])] {
                    stops += [model.light.stops.map(OrbitSpaceThemes.color), model.dark.stops.map(OrbitSpaceThemes.color)]
                }
            }
        }
        stops += [BrowserSpaceThemePresets.default.light.stops.map(OrbitSpaceThemes.color),
                  BrowserSpaceThemePresets.default.dark.stops.map(OrbitSpaceThemes.color)]
        for variant in OrbitFloatingMaterial.Variant.allCases {
            var minimumBody = Double.infinity
            var minimumSecondary = Double.infinity
            for selected in [false, true] {
                for reduced in [false, true] {
                    let style = OrbitFloatingMaterial.Style(variant: variant, reducesTransparency: reduced, selectedSidebarSurface: selected)
                    for gradient in stops {
                        let pairs = zip(gradient, gradient.dropFirst() + [gradient.last!])
                        for (a, b) in pairs {
                            for step in 0...20 {
                                let fill = OrbitFloatingMaterial.composite(b, opacity: CGFloat(step) / 20, over: a)
                                for highlight in [false, true] {
                                    let background = style.background(over: fill, highlight: highlight)
                                    minimumBody = min(minimumBody, OrbitFloatingMaterial.contrast(style.body, background))
                                    minimumSecondary = min(minimumSecondary, OrbitFloatingMaterial.contrast(style.secondary, background))
                                    #expect(OrbitFloatingMaterial.contrast(style.body, background) >= 4.5)
                                    #expect(OrbitFloatingMaterial.contrast(style.secondary, background) >= 4.5)
                                }
                            }
                        }
                    }
                }
            }
            print("Frost \(variant): body minimum \(minimumBody), secondary minimum \(minimumSecondary)")
        }
    }

    @Test("Reduce Transparency uses the same opaque shared tokens")
    func reduceTransparency() throws {
        let view = OrbitFrostView()
        view.sidebarForeground = .white
        view.refresh(reduceTransparency: true)
        #expect(view.effect.isHidden)
        #expect(view.style.tintOpacity == 1)
        #expect(view.style.variant == .dark)
        #expect(view.style.background(over: .yellow) == view.style.tint)
        view.sidebarForeground = .black
        view.refresh(reduceTransparency: true)
        #expect(view.style.variant == .light)
        #expect(OrbitFloatingMaterial.contrast(view.style.background(over: .black), .white) == 1)
    }

    @Test("Legacy material choices stay inert throughout a Space transition")
    func transition() {
        var legacy = BrowserSpaceThemePresets.default
        legacy.frost = true
        let source = OrbitSpaceThemes.rendered(legacy)
        let target = OrbitSpaceThemes.rendered(.radial(colors: [.init(hex: 0x141317)], mode: .dark))
        let surface = OrbitSurfaceBackgroundView(cornerRadius: 8)
        for frame in 0...72 {
            let painted = SpaceSwipeThemeBlend(source: source, destination: target, progress: CGFloat(frame) / 72).theme
            #expect(painted.frostAmount == 0)
            surface.applyFrost(OrbitSpaceThemes.accent(for: painted))
            #expect(surface.frost == nil)
        }
    }
}
