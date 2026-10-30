import AppKit
import BrowserCore
import BrowserShell
import BrowserEngineConformance
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct SidebarBrandFixTests {
    @Test("Paper update card preserves the prepared install action and localized copy")
    func updateCard() throws {
        let card = SidebarUpdateCard(frame: NSRect(x: 0, y: 0, width: 200, height: SidebarUpdateCard.height))
        card.layoutSubtreeIfNeeded()
        var restarts = 0
        card.onRestart = { restarts += 1 }
        #expect(card.restart.sendAction(card.restart.action, to: card.restart.target))
        #expect(restarts == 1)
        #expect(card.title.stringValue == uiText("An update is ready!"))
        #expect(card.body.stringValue == uiText("Click to restart"))
        #expect(card.restart.title == uiText("Restart and Update"))
        #expect(card.sticker.stringValue == uiText("New"))
        #expect(card.icon.image != nil)
        #expect(!card.clipsToBounds)
        #expect(card.sticker.frameRotation == 8)
        #expect(card.subviews.allSatisfy { !($0 is OrbitFrostView) })
        #expect(card.title.font?.fontName == BrandTextStyle.title.font(size: 17).fontName)
        #expect(card.restart.frame.maxY <= card.bounds.maxY)
    }

    @Test("Every built-in gradient gets the first passing tint step in both appearances and ink polarities")
    func minimalFrost() throws {
        var models = BrandPalette.spaceGradients.map { $0.theme() }
        models += [BrowserSpaceThemePresets.default]
        for family in BrowserSpaceThemePresets.families {
            for color in family.swatches {
                models += [.composed(colors: [color]), .radial(colors: [color])]
            }
        }
        for model in models {
            let theme = OrbitSpaceThemes.rendered(model)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: name))
                let stops = OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance).compactMap { NSColor(cgColor: $0) }
                let samples = zip(stops, stops.dropFirst()).flatMap { a, b in
                    (0...256).map { OrbitFloatingMaterial.composite(b, opacity: CGFloat($0) / 256, over: a) }
                }
                func passes(_ opacity: CGFloat, _ style: OrbitFloatingMaterial.Style) -> Bool {
                    var candidate = style
                    candidate.sidebarTintOpacity = opacity
                    return samples.allSatisfy { fill in
                        [false, true].allSatisfy { highlight in
                            let background = candidate.background(over: fill, highlight: highlight)
                            return [candidate.body, candidate.secondary].allSatisfy { OrbitFloatingMaterial.contrast($0, background) >= 4.5 }
                        }
                    }
                }
                for variant in OrbitFloatingMaterial.Variant.allCases {
                    let style = OrbitFloatingMaterial.Style(variant: variant, reducesTransparency: false)
                    let tint = OrbitSidebarFrost.opacity(theme: theme, appearance: appearance, style: style)
                    #expect(tint >= OrbitSidebarFrost.minimum && tint <= OrbitSidebarFrost.maximum)
                    #expect(passes(tint, style))
                    if tint > OrbitSidebarFrost.minimum {
                        #expect(!passes(tint - OrbitSidebarFrost.step, style))
                    }
                }
            }
        }
    }

    @Test("Theme changes recompute the tint and Reduce Transparency remains opaque")
    func frostRefresh() {
        let surface = OrbitSurfaceBackgroundView(cornerRadius: 8)
        var opacities: [CGFloat] = []
        for preset in [BrandPalette.spaceGradients[0], BrandPalette.spaceGradients[4], BrandPalette.spaceGradients[2]] {
            var model = preset.theme(); model.frost = true
            let theme = OrbitSpaceThemes.rendered(model)
            surface.applyFrost(OrbitSpaceThemes.accent(for: theme))
            #expect(surface.frost?.sidebarTheme == theme)
            let frost = surface.frost!
            #expect(frost.effect.appearance?.bestMatch(from: [.aqua, .darkAqua]) == (frost.style.variant == .dark ? .darkAqua : .aqua))
            opacities.append(frost.style.tintOpacity)
            surface.frost?.refresh(reduceTransparency: true)
            #expect(surface.frost?.style.tintOpacity == 1)
            #expect(surface.frost?.effect.isHidden == true)
        }
        #expect(Set(opacities).count > 1)
        let appearance = NSAppearance(named: .darkAqua)!
        let fresh = OrbitSpaceThemes.rendered(.radial(colors: [.init(hex: 0xADFF13)]))
        let opaque = OrbitFloatingMaterial.Style(variant: .dark, reducesTransparency: true)
        let tint = OrbitSidebarFrost.opacity(theme: fresh, appearance: appearance, style: opaque)
        let translucent = OrbitFloatingMaterial.Style(variant: .dark, reducesTransparency: false)
        #expect(OrbitSidebarFrost.passes(tint, samples: OrbitSidebarFrost.samples(fresh, appearance: appearance), style: translucent))
    }

    @Test("Coral retains its violet end through storage and native gradient rendering")
    func coralGradient() throws {
        let model = BrandPalette.spaceGradients[0].theme()
        let decoded = try JSONDecoder().decode(BrowserSpaceTheme.self, from: JSONEncoder().encode(model))
        #expect(decoded.light.stops.last == BrowserThemeColor(hex: 0x7B4DFF))
        #expect(decoded.light.angleDegrees == 80)
        let theme = OrbitSpaceThemes.rendered(decoded)
        let appearance = try #require(NSAppearance(named: .aqua))
        let fill = OrbitThemeFillView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        fill.appearance = appearance
        fill.apply(theme)
        #expect(fill.resolvedStops.last == OrbitSpaceThemes.color(.init(hex: 0x7B4DFF)).cgColor)
        let bottom = OrbitThemeGradient.color(theme, at: CGPoint(x: 0, y: 1), appearance: appearance).usingColorSpace(.sRGB)!
        #expect(bottom.blueComponent > bottom.redComponent)
        #expect(theme.angle.light == 80)
    }

    @Test("Welcome copy is independent of the number of steps and colour bands start fully drawn")
    func welcomeFirstFrame() throws {
        #expect(OrbitOnboardingText.welcomeBody == uiText("Let’s set up your browser. A few short steps, about a minute, and nothing leaves your Mac."))
        let welcome = OrbitOnboardingWelcomeView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        welcome.play()
        let vector = try #require(welcome.mark.subviews.last)
        let strokes = try #require(vector.layer?.sublayers?.compactMap { $0 as? CAShapeLayer })
        #expect(!strokes.isEmpty)
        for stroke in strokes {
            #expect(stroke.strokeEnd == 1)
            #expect(stroke.animation(forKey: "orbit.band.draw") == nil)
        }
        let colors = strokes.compactMap { $0.strokeColor }.compactMap(NSColor.init(cgColor:))
        #expect(colors.contains { color in
            let c = color.usingColorSpace(.sRGB)!
            return abs(c.redComponent - c.blueComponent) > 0.2
        })
    }

    @Test("Settings editor passes the actual Space name, including punctuation")
    func settingsThemeHeader() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [])
        try await model.createProfile(name: "Fixture")
        let profile = try #require(model.selectedProfileID)
        let id = try await model.createSpace(name: "Research · 2026", profile: profile)
        let controller = BrowserSettingsWindowController(model: model)
        defer { controller.themeEditor?.close(animated: false); controller.window?.close() }
        controller.openThemeEditor(for: id, animated: false)
        let editor = try #require(controller.themeEditor)
        #expect(editor.view.spaceName == "Research · 2026")
        #expect(editor.view.surfaceScope.stringValue == uiFormat("Theme · %@", "Research · 2026").localizedUppercase)
    }

    @Test("Removal artwork comes from the Space's emoji or symbol and has an explicit empty fallback")
    func removalArtwork() throws {
        for choice in [BrowserSpaceIcon.grapheme("🌿"), .systemSymbol("star.fill"), .none] {
            let image = SpaceIconImages.removalIcon(choice)
            #expect(image.size == NSSize(width: 64, height: 64))
            let alert = OrbitFloatingMaterial.alert()
            alert.icon = image
            #expect(alert.icon === image)
        }
    }

    @Test("Removal symbols use readable ink in the presenting window's appearance")
    func removalSymbolInk() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let image = SpaceIconImages.removalIcon(.systemSymbol("star.fill"), appearance: appearance)
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let center = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            #expect(center.alphaComponent > 0.9)
            #expect(name == .darkAqua ? center.redComponent > 0.8 : center.redComponent < 0.2)
        }
    }

    @Test("All default handlers must match before the checked status replaces the request")
    func defaultBrowserState() {
        let id = ProductIdentity.bundleIdentifier
        #expect(BrowserDefaultBrowserStatus(http: id, https: id, html: id).isOrbit)
        #expect(!BrowserDefaultBrowserStatus(http: id, https: id, html: "fixture.other").isOrbit)
        let confirmed = BrowserDefaultBrowserAction(isDefault: true, canRequest: false, request: {})
        let request = BrowserDefaultBrowserAction(isDefault: false, canRequest: true, request: {})
        #expect(confirmed.label == uiText("Default browser"))
        #expect(request.label == uiText("Make Default"))
    }
}
