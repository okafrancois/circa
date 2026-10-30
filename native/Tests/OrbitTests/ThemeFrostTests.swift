import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct ThemeFrostTests {
    @Test("Native switch edits only Frost, publishes the draft, and retains it through color edits")
    func toggle() {
        let initial = BrowserSpaceTheme.radial(colors: [.init(hex: 0xFF5A5F), .init(hex: 0x7B4DFF)])
        let view = OrbitThemeEditorView(state: .init(theme: initial))
        var published: BrowserSpaceTheme?
        view.onChange = { published = $0.theme }
        #expect(view.frostSwitch.state == .off)
        #expect(view.frostSwitch.accessibilityLabel() == uiText("Frost"))
        #expect(view.frostSwitch.frame.minY > view.grainDial.frame.maxY)
        view.frostSwitch.state = .on
        _ = view.frostSwitch.sendAction(view.frostSwitch.action, to: view.frostSwitch.target)
        var expected = initial
        expected.frost = true
        #expect(published == expected)
        var state = view.state
        state.chooseSwatch(1)
        state.removeColor()
        state.removeColor()
        state.pick(at: CGPoint(x: 0.3, y: 0.5))
        #expect(state.theme.frost)
        view.frostSwitch.state = .off
        _ = view.frostSwitch.sendAction(view.frostSwitch.action, to: view.frostSwitch.target)
        #expect(published == initial)
    }

    @Test("Only the address, tiles, active tab and footer consume Frost")
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
            #expect(active.background.frost?.isHidden == !enabled)
            #expect(inactive.background.frost == nil)
            #expect(grid.tiles.first?.background.frost?.isHidden == !enabled)
            #expect(sidebar.footer.background.frost?.isHidden == !enabled)
            let background = try #require(sidebar.addressContainer.subviews.compactMap { $0 as? OrbitSurfaceBackgroundView }.first)
            #expect(background.frost?.isHidden == !enabled)
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

    @Test("Frosted controls retain live materials instead of caching an unblurred bitmap")
    func liveMaterial() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.wantsLayer = true
        let surface = OrbitSurfaceBackgroundView(cornerRadius: 8)
        surface.frame = view.bounds
        view.addSubview(surface)
        var model = BrowserSpaceThemePresets.default
        model.frost = true
        surface.applyFrost(OrbitSpaceThemes.accent(for: OrbitSpaceThemes.rendered(model)))
        #expect(SpaceSwipeRaster(view: view, scale: 1) == nil)
        #expect(surface.superview === view)
    }

    @Test("Frost follows paint progress and survives interruption without losing its material")
    func transition() throws {
        var on = BrowserSpaceThemePresets.default
        on.frost = true
        let source = OrbitSpaceThemes.rendered(on)
        let target = OrbitSpaceThemes.rendered(.radial(colors: [.init(hex: 0x141317)], mode: .dark))
        let surface = OrbitSurfaceBackgroundView(cornerRadius: 8)
        var identity: OrbitFrostView?
        for frame in 0...72 {
            let p = CGFloat(frame) / 72
            let painted = SpaceSwipeThemeBlend(source: source, destination: target, progress: p).theme
            #expect(abs(painted.frostAmount - (1 - p)) < 0.000001)
            surface.applyFrost(OrbitSpaceThemes.accent(for: painted))
            if let identity { #expect(surface.frost === identity) } else { identity = surface.frost }
            if p < 1 {
                #expect(surface.frost?.isHidden == false)
                #expect(surface.frost?.effect.state == .active)
            }
            #expect(surface.frost?.alphaValue == painted.frostAmount)
            let captured = SpaceSwipeThemeBlend.snapshot(painted, appearance: NSAppearance(named: .aqua)!)
            #expect(captured.frostAmount == painted.frostAmount)
        }
        #expect(surface.frost?.isHidden == true)
    }
}
