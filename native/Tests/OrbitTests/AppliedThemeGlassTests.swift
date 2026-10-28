import AppKit
import QuartzCore
import BrowserCore
import BrowserEngineConformance
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite("Applied theme native materials", .serialized)
@MainActor
struct AppliedThemeGlassTests {
    @Test("Native public glass, frosted fallback, tint range and accessibility operate on the decorative fill")
    func nativeMaterial() throws {
        let fill = OrbitThemeFillView(materialRole: .windowShell)
        fill.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        var theme = BrowserSpaceThemePresets.default
        theme.surface = .init(material: .liquidGlass, transparency: 1)
        fill.apply(OrbitSpaceThemes.rendered(theme))
        let material = try #require(fill.materialView)
        #expect(material.material == .hudWindow && material.blendingMode == .behindWindow)
        let floating = OrbitFloatingSidebarBackdrop(frame: NSRect(x: 0, y: 0, width: 228, height: 540))
        floating.fill.apply(OrbitSpaceThemes.rendered(theme))
        floating.layoutSubtreeIfNeeded()
        if #available(macOS 26.0, *) {
            #expect((floating.fill.liquidGlassView as? NSGlassEffectView)?.cornerRadius == floating.cornerRadius)
        }
        let glass = fill.liquidGlassView
        let resolved = OrbitGlassStyle.resolve(role: .windowShell, isDark: false, isActive: true,
            reduceTransparency: false, increaseContrast: false, surface: theme.surface)
        fill.applyMaterialStyle(resolved)
        #expect(abs(fill.glassStyle.tintOpacity - 0.12) < 0.0001)
        #expect(fill.alphaValue == 1 && fill.layer?.opacity == 1)
        if #available(macOS 26.0, *) {
            let native = try #require(glass as? NSGlassEffectView)
            #expect(native.style == .clear && native.cornerRadius == 0)
            #expect(fill.usesNativeLiquidGlass && !material.isHidden)
            #expect(native.hitTest(.zero) == nil)
        } else {
            #expect(glass == nil && !material.isHidden)
        }
        for materialChoice in BrowserThemeSurface.Material.allCases {
            theme.surface?.material = materialChoice
            fill.apply(OrbitSpaceThemes.rendered(theme))
            fill.applyMaterialStyle(.resolve(role: .windowShell, isDark: true, isActive: false,
                reduceTransparency: false, increaseContrast: false, surface: theme.surface))
            #expect(fill.materialView === material && fill.liquidGlassView === glass)
            #expect(fill.glassStyle.usesMaterial == (materialChoice != .solid))
            #expect(material.material == (materialChoice == .liquidGlass ? .hudWindow : .underWindowBackground))
            for preferences in [(true, false), (false, true)] {
                fill.applyMaterialStyle(.resolve(role: .windowShell, isDark: false, isActive: true,
                    reduceTransparency: preferences.0, increaseContrast: preferences.1, surface: theme.surface))
                #expect(fill.glassStyle.tintOpacity == 1 && material.isHidden)
                #expect(glass?.isHidden != false)
            }
        }
        let shield = OrbitThemeFillView(frame: fill.bounds)
        shield.apply(OrbitSpaceThemes.rendered(theme))
        #expect(shield.materialView == nil && shield.liquidGlassView == nil && shield.glassStyle.tintOpacity == 1)
        let card = BrowserContentCardView()
        card.present(NSView())
        #expect(card.clipBackground?.alpha == 1)
        #expect(fill.hitTest(.zero) == nil)
    }

    @Test("Transparency exposes a substantial material contribution in both appearances; fallback is opaque")
    func materialContribution() {
        for dark in [false, true] {
            var previous: Float = -1
            for level in [0.0, 0.35, 0.65, 1.0] {
                let style = OrbitGlassStyle.resolve(role: .windowShell, isDark: dark, isActive: true,
                    reduceTransparency: false, increaseContrast: false,
                    surface: .init(material: .liquidGlass, transparency: level))
                let contribution = (1 - style.tintOpacity) * (1 - style.readabilityOpacity)
                #expect(contribution > previous)
                previous = contribution
                if level >= 0.65 { #expect(contribution > 0.45) }
                let fallback = OrbitGlassStyle.resolve(role: .windowShell, isDark: dark, isActive: true,
                    reduceTransparency: true, increaseContrast: false,
                    surface: .init(material: .liquidGlass, transparency: level))
                #expect(!fallback.usesMaterial && fallback.tintOpacity == 1 && fallback.readabilityOpacity == 0)
            }
            let implicit = OrbitGlassStyle.resolve(role: .windowShell, isDark: dark, isActive: true,
                reduceTransparency: false, increaseContrast: false)
            let explicit = OrbitGlassStyle.resolve(role: .windowShell, isDark: dark, isActive: true,
                reduceTransparency: false, increaseContrast: false, surface: BrowserThemeSurface())
            #expect(implicit == explicit && implicit.usesMaterial)
        }
    }

    @Test("Surface strength fades with Space colors, while swipe and accessibility cancel stale fades")
    func surfaceTransition() throws {
        let fill = OrbitThemeFillView(materialRole: .windowShell)
        var theme = BrowserSpaceThemePresets.default
        theme.surface = .init(material: .liquidGlass, transparency: 0.25)
        fill.apply(OrbitSpaceThemes.rendered(theme))
        let tint = try #require(fill.layer?.sublayers?.first { $0.zPosition == 1 })
        let material = try #require(fill.materialView)
        theme.surface?.transparency = 0.9
        fill.apply(OrbitSpaceThemes.rendered(theme), fade: 0.24)
        let fade = try #require(tint.animation(forKey: OrbitThemeFillView.themeFadeKey) as? CABasicAnimation)
        #expect(fade.keyPath == "opacity" && fade.duration == 0.24)
        #expect(fill.materialView === material && !material.isHidden)
        fill.applyInteractiveTheme(OrbitSpaceThemes.rendered(theme))
        #expect(tint.animation(forKey: OrbitThemeFillView.themeFadeKey) == nil)
        theme.surface?.transparency = 0.4
        fill.apply(OrbitSpaceThemes.rendered(theme), fade: 0.24)
        #expect(tint.animation(forKey: OrbitThemeFillView.themeFadeKey) != nil)
        fill.applyMaterialStyle(.resolve(role: .windowShell, isDark: false, isActive: true,
            reduceTransparency: true, increaseContrast: false, surface: theme.surface))
        #expect(tint.animation(forKey: OrbitThemeFillView.themeFadeKey) == nil)
        #expect(tint.opacity == 1 && material.isHidden)
    }

    @Test("Changing grain strength reuses the tiled backing instead of redrawing every swipe frame")
    func grainStrengthIsComposited() throws {
        let fill = OrbitThemeFillView(materialRole: .windowShell)
        fill.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        var theme = OrbitTokens.SpaceTheme.default
        theme.texture = .grain
        theme.textureIntensity = 0.1
        fill.apply(theme)
        let host = try #require(fill.layer?.sublayers?.first { $0.zPosition == 1 })
        let grain = try #require(host.sublayers?.compactMap { $0 as? OrbitGrainLayer }.first)
        grain.displayIfNeeded()
        for strength in [0.2, 0.6, 0, 0.9] {
            theme.textureIntensity = strength
            fill.applyInteractiveTheme(theme)
            #expect(!grain.needsDisplay())
            #expect(abs(grain.opacity - Float(strength)) < 0.0001)
        }
    }

    @Test("Color changes, swatches, removing colors and captured swipe fills keep the applied surface")
    func editorAndCapturedBlend() throws {
        var source = BrowserSpaceThemePresets.default
        source.surface = .init(material: .liquidGlass, transparency: 0.78)
        var editor = OrbitThemeEditorState(theme: source)
        editor.pick(at: CGPoint(x: 0.5, y: 0.5))
        editor.chooseSwatch(1)
        editor.setIntensity(0.7)
        editor.setMode(.dark)
        #expect(editor.theme.surface == source.surface)
        editor.removeColor()
        #expect(editor.theme.surface == source.surface)
        editor.setTransparency(.nan)
        editor.setTransparency(1.01)
        #expect(editor.theme.surface == source.surface)
        let view = OrbitThemeEditorView(state: editor)
        view.surfaceMaterial.selectItem(at: BrowserThemeSurface.Material.allCases.firstIndex(of: .solid)!)
        _ = view.surfaceMaterial.sendAction(view.surfaceMaterial.action!, to: view.surfaceMaterial.target)
        #expect(view.state.theme.surface?.material == .solid)
        #expect(!view.surfaceTransparency.isEnabled)
        var target = source
        target.surface = .init(material: .frosted, transparency: 0.35)
        let shell = OrbitWindowShell()
        shell.apply(theme: OrbitSpaceThemes.rendered(source), animated: false)
        let material = shell.themeFill.materialView
        let glass = shell.themeFill.liquidGlassView
        for p in [0.0, 0.25, 0.75, 1.0] {
            shell.applySpaceSwipeBlend(.init(source: OrbitSpaceThemes.rendered(source), destination: OrbitSpaceThemes.rendered(target), progress: p))
            #expect(shell.themeFill.theme.surface == (p == 1 ? target.surface : source.surface))
            #expect(shell.themeFill.materialView === material && shell.themeFill.liquidGlassView === glass)
            #expect(shell.themeFill.theme == shell.floatingBackdrop.fill.theme)
        }
        shell.applySpaceSwipeBlend(nil)
        #expect(shell.themeFill.theme == OrbitSpaceThemes.rendered(source))
    }

    @Test("Appearance changes are queued for a captured Space, persist on reload and reject stale form selections")
    func settingsQueue() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SyntheticEngine())
        defer { environment.autoArchive.scheduler.stop() }
        _ = try await environment.initialContext.value
        let model = BrowserSettingsModel(environment: environment, profileID: nil, shortcuts: [])
        await model.reload()
        let profile = try #require(model.selectedProfileID)
        let space = try #require(model.appearanceSpaceID)
        let other = try await environment.store.createSpace(name: "Other", profileID: profile)
        await model.reload()
        // Construct a hidden synthetic product controller; never order or activate a window.
        let controller = try await environment.makeWindow(spaceID: space)
        defer { controller.window?.close() }
        #expect(controller.window?.isVisible == false)
        let beforeSession = controller.session.snapshot
        let beforeSettings = await environment.settings.store.snapshot()
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .liquidGlass)
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, transparency: 0.9)
        await model.waitForPendingActions()
        #expect(model.errorMessage == nil)
        let applied = try #require(try await environment.store.spaceTheme(space))
        #expect(applied.surface == .init(material: .liquidGlass, transparency: 0.9))
        #expect(controller.windowShell.theme.surface == applied.surface)
        #expect(controller.windowShell.themeFill.theme.surface == applied.surface)
        #expect(controller.session.snapshot?.activeSpaceID == beforeSession?.activeSpaceID)
        #expect(controller.window?.alphaValue == 1)
        #expect(controller.window?.isOpaque == !controller.windowShell.themeFill.glassStyle.usesMaterial)
        var solid = applied
        solid.surface?.material = .solid
        controller.windowShell.apply(theme: OrbitSpaceThemes.rendered(solid), animated: false)
        #expect(controller.window?.isOpaque == true && controller.window?.backgroundColor.alphaComponent == 1)
        #expect(controller.windowShell.themeFill.materialView?.isHidden == true)
        #expect(controller.windowShell.themeFill.liquidGlassView?.isHidden != false)
        #expect(controller.contentCard.clipBackground?.alpha == 1)
        controller.windowShell.apply(theme: OrbitSpaceThemes.rendered(applied), animated: false)
        #expect(controller.window?.isVisible == false)
        let restored = try BrowserStore(restoring: BrowserSessionDocument.decode(await environment.store.sessionDocument().encoded()))
        #expect(try await restored.spaceTheme(space) == applied)
        let reopened = BrowserSettingsModel(environment: environment, profileID: profile, shortcuts: [])
        await reopened.reload()
        #expect(reopened.catalog.spaces.first(where: { $0.id == space })?.theme == applied)
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, transparency: 0.1)
        model.selectAppearanceSpace(other)
        await model.waitForPendingActions()
        #expect(try await environment.store.spaceTheme(space) == applied)
        #expect(try await environment.store.spaceTheme(other) == nil)
        #expect(await environment.settings.store.snapshot() == beforeSettings)
        #expect(model.errorMessage != nil)
        model.selectAppearanceSpace(space)
        let secondProfile = await environment.store.createProfile(name: "Second")
        model.queueAppearanceSurfaceEdit(spaceID: space, profileID: profile, material: .solid)
        model.selectProfile(secondProfile)
        await model.waitForPendingActions()
        #expect(try await environment.store.spaceTheme(space) == applied)

        controller.openThemeEditor(for: space, animated: false)
        let editor = try #require(controller.themeEditor)
        #expect(editor.panel?.isVisible == false)
        editor.view.surfaceTransparency.doubleValue = 0.45
        _ = editor.view.surfaceTransparency.sendAction(editor.view.surfaceTransparency.action!, to: editor.view.surfaceTransparency.target)
        #expect(controller.windowShell.themeFill.theme.surface?.transparency == 0.45)
        editor.close(animated: false)
        await editor.waitUntilFinished()
        await controller.session.waitForPendingCommands()
        #expect(try await environment.store.spaceTheme(space)?.surface?.transparency == 0.45)
        controller.openThemeEditor(for: space, animated: false)
        let reopenedEditor = try #require(controller.themeEditor)
        #expect(reopenedEditor.draft.surface?.transparency == 0.45)
        reopenedEditor.close(animated: false)
        await reopenedEditor.waitUntilFinished()
    }
}
}
