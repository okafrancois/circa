import AppKit
@testable import BrowserCore
import BrowserShell
import Foundation
import Testing
@testable import Orbit

// Space themes: stored Space themes in the shell, the theme editor and its undo step. Hidden windows only.

private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat) -> Bool { abs(a - b) <= tolerance }

private func components(_ color: BrowserThemeColor) -> [CGFloat] {
    let c = color.sRGB
    return [c.red, c.green, c.blue].map { CGFloat($0) * 255 }
}

private func components(_ hex: UInt32) -> [CGFloat] { components(BrowserThemeColor(hex: hex)) }

@MainActor private func rgb(_ color: NSColor, _ appearance: NSAppearance) -> [CGFloat] {
    let c = color.resolved(for: appearance)
    return [c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255]
}

private func near(_ a: [CGFloat], _ b: [CGFloat], _ tolerance: CGFloat = 2.5) -> Bool {
    zip(a, b).allSatisfy { close($0, $1, tolerance) }
}

@MainActor private func hsb(_ color: NSColor, _ appearance: NSAppearance) -> (CGFloat, CGFloat, CGFloat) {
    let c = color.resolved(for: appearance)
    return (c.hueComponent, c.saturationComponent, c.brightnessComponent)
}

/// Renders a layer-backed view into an sRGB bitmap; pixel reader in top-left points.
@MainActor
private func render(_ view: NSView) throws -> (Int, Int) -> [CGFloat] {
    let width = Int(view.bounds.width), height = Int(view.bounds.height)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    try #require(view.layer).render(in: context)
    let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                          count: width * height * 4))
    // Bitmap rows run top to bottom (flipped views render as on screen too).
    return { x, y in
        let offset = (y * width + x) * 4
        return [CGFloat(bytes[offset]), CGFloat(bytes[offset + 1]), CGFloat(bytes[offset + 2])]
    }
}

/// AppKit's own offscreen rendering of a hosted view (its subview layers included) into an sRGB
/// bitmap at 1 px/pt; pixel reader in top-left points.
@MainActor
private func snapshot(_ view: NSView) throws -> (Int, Int) -> [CGFloat] {
    let width = Int(view.bounds.width), height = Int(view.bounds.height)
    let base = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0))
    let bitmap = try #require(base.retagging(with: .sRGB))
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return { x, y in
        var pixel = [Int](repeating: 0, count: 4)
        bitmap.getPixel(&pixel, atX: x, y: y)
        return pixel.prefix(3).map { CGFloat($0) }
    }
}

@MainActor private let light = NSAppearance(named: .aqua)!
@MainActor private let dark = NSAppearance(named: .darkAqua)!
private let mauve = BrowserThemeColor(hex: 0xA88EAC)
private let coral = BrowserThemeColor(hex: 0xF25E6B)

/// Polls a main-actor condition (store commits are throttled and asynchronous).
@MainActor
private func eventually(_ timeout: Duration = .seconds(3), _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try await condition()
}

extension NativeWebKitTests {
@Suite("Space themes — rendering and accent", .serialized)
@MainActor
struct NativeSpaceThemeRenderingTests {
    @Test("A stored theme renders as dynamic stops with its mode, range, angle and grain; equal models share a fill")
    func conversion() {
        let model = BrowserSpaceTheme.composed(colors: [mauve, coral], intensity: 0.7, noise: 0.4)
        let theme = OrbitSpaceThemes.rendered(model)
        #expect(theme.model == model && theme.mode == .automatic && theme.texture == .grain && close(theme.textureIntensity, 0.4, 1e-9))
        #expect(theme.stops.count == 2 && theme.angle == .init(light: 43, dark: 43) && theme.stopRange == .fullDiagonal)
        for (index, stop) in theme.stops.enumerated() {
            #expect(near(rgb(stop, light), components(model.light.stops[index]), 0.6))
            #expect(near(rgb(stop, dark), components(model.dark.stops[index]), 0.6))
        }
        #expect(theme == OrbitSpaceThemes.rendered(model))
        #expect(theme != OrbitSpaceThemes.rendered(model.recomposed(intensity: 0.71)))
        #expect(OrbitSpaceThemes.rendered(model.recomposed(mode: .dark)).mode == .dark)
        #expect(OrbitSpaceThemes.rendered(model.recomposed(noise: 0)).texture == .none)
        // The default preset paints exactly the measured default gradient.
        let preset = OrbitSpaceThemes.rendered(BrowserSpaceThemePresets.default)
        #expect(preset.stopRange == OrbitTokens.SpaceTheme.default.stopRange)
        for (index, stop) in preset.stops.enumerated() {
            for appearance in [light, dark] {
                #expect(near(rgb(stop, appearance), rgb(OrbitTokens.SpaceTheme.default.stops[index], appearance), 0.6))
            }
        }
    }

    @Test("Offscreen fill: a stored gradient runs corner to corner at its angle, per appearance", arguments: [false, true])
    func gradientGeometry(isDark: Bool) throws {
        let size = CGSize(width: 1024, height: 640)
        var model = BrowserSpaceTheme.composed(colors: [mauve, coral])
        let view = OrbitThemeFillView(frame: NSRect(origin: .zero, size: size))
        view.appearance = isDark ? dark : light
        view.apply(OrbitSpaceThemes.rendered(model))
        view.layoutSubtreeIfNeeded()
        var pixel = try render(view)
        let stops = (isDark ? model.dark : model.light).stops.map(components)
        #expect(near(pixel(1, 1), stops[0], 3), "top-left is the first stop")
        #expect(near(pixel(size.intWidth - 2, size.intHeight - 2), stops[1], 3), "bottom-right is the last stop")
        let middle = zip(stops[0], stops[1]).map { ($0 + $1) / 2 }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        #expect(near(pixel(Int(center.x), Int(center.y)), middle, 4))
        #expect(close(OrbitThemeGradient.axisFraction(of: center, in: size), 0.5, 1e-6))
        // 135°: the axis starts at the top-right corner.
        model.light.angleDegrees = 135
        model.dark.angleDegrees = 135
        view.apply(OrbitSpaceThemes.rendered(model))
        view.layoutSubtreeIfNeeded()
        pixel = try render(view)
        #expect(near(pixel(size.intWidth - 2, 1), stops[0], 3), "top-right is the first stop at 135°")
        #expect(near(pixel(1, size.intHeight - 2), stops[1], 3), "bottom-left is the last stop at 135°")
        #expect(close(OrbitThemeGradient.axisFraction(of: CGPoint(x: size.width, y: 0), in: size, angleDegrees: 135), 0, 1e-6))
        #expect(close(OrbitThemeGradient.axisFraction(of: CGPoint(x: 0, y: size.height), in: size, angleDegrees: 135), 1, 1e-6))
    }

    @Test("The foreground shares one polarity while swatches keep their strong colour")
    func accentDerivation() throws {
        for model in [BrowserSpaceTheme.composed(colors: [mauve]), .composed(colors: [coral], intensity: 1), BrowserSpaceThemePresets.default] {
            let theme = OrbitSpaceThemes.rendered(model), accent = OrbitSpaceThemes.accent(for: theme)
            for appearance in [light, dark] {
                let expected = OrbitThemeForeground.color(on: OrbitThemeGradient.representativeColor(theme, appearance: appearance))
                #expect(accent.sidebarText.resolved(for: appearance) == expected)
                #expect(accent.icon.resolved(for: appearance) == expected)
            }
        }
        let greyish = OrbitSpaceThemes.accent(for: OrbitSpaceThemes.rendered(.composed(colors: [mauve])))
        #expect(near(rgb(greyish.strong, light), components(mauve), 0.6))
    }
}
}

extension NativeWebKitTests {
@Suite("Space themes — editor model", .serialized)
@MainActor
struct NativeSpaceThemeEditorStateTests {
    @Test("Field mapping inverts the declared handle colors")
    func fieldMapping() {
        let picked = OrbitThemeFieldMapping.color(at: CGPoint(x: 0.606, y: 0.118))
        #expect(picked.isValid)
        for point in [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.75), CGPoint(x: 0.5, y: 1)] {
            let back = OrbitThemeFieldMapping.position(of: OrbitThemeFieldMapping.color(at: point))
            #expect(near(components(OrbitThemeFieldMapping.color(at: back)), components(OrbitThemeFieldMapping.color(at: point)), 1))
        }
    }

    @Test("Pick, move, add, remove, swatches, pages, mode, intensity and grain edit the draft")
    func editing() throws {
        var state = OrbitThemeEditorState(theme: BrowserSpaceThemePresets.default)
        #expect(!state.hasColor && !state.canAddColor && !state.canRemoveColor && state.familyIndex == 0)
        state.setIntensity(0.2)
        state.setNoise(0.5)
        #expect(state.theme == BrowserSpaceThemePresets.default, "intensity and grain wait for a colour")
        state.setMode(.dark)
        #expect(state.theme.mode == .dark && state.theme.colors.isEmpty)
        state.pick(at: CGPoint(x: 0.606, y: 0.118))
        #expect(state.theme.colors.count == 1 && state.selectedIndex == 0 && state.theme.intensity == BrowserSpaceTheme.defaultIntensity)
        #expect(state.theme.mode == .dark)
        state.move(handle: 0, to: CGPoint(x: 0.2, y: 0.8))
        #expect(state.theme.colors == [OrbitThemeFieldMapping.color(at: CGPoint(x: 0.2, y: 0.8))])
        state.addColor()
        state.addColor()
        #expect(state.theme.colors.count == 3 && !state.canAddColor && state.selectedIndex == 2)
        state.addColor()
        #expect(state.theme.colors.count == 3)
        #expect(close(CGFloat(state.theme.colors[1].hsb.hue - state.theme.colors[0].hsb.hue), 30.0 / 360, 0.002))
        state.select(handle: 0)
        state.removeColor()
        #expect(state.theme.colors.count == 2 && state.selectedIndex == 1)
        state.setIntensity(0.4)
        state.setNoise(0.6)
        #expect(state.theme.intensity == 0.4 && state.theme.noise == 0.6)
        // A swatch replaces the selected colour of a multi-colour theme.
        state.chooseSwatch(3)
        #expect(state.theme.colors[1] == BrowserSpaceThemePresets.brand.swatches[3] && state.theme.presetID == nil)
        state.removeColor()
        state.chooseSwatch(8)
        #expect(state.theme.presetID == "brand.9" && state.selectedSwatch == 8 && state.theme.colors.count == 1)
        #expect(state.theme.intensity == 0.4 && state.theme.noise == 0.6 && state.theme.mode == .dark)
        state.showFamily(offset: 1)
        #expect(state.family.id == "pastel" && state.selectedSwatch == nil)
        state.showFamily(offset: 10)
        #expect(state.family.id == "greyscale")
        state.showFamily(offset: -10)
        #expect(state.family.id == "brand")
        state.nudge(handle: 0, hueDegrees: 360 + 10, saturation: 2)
        #expect(close(CGFloat(state.theme.colors[0].hsb.saturation), 1, 1e-9))
        state.removeColor()
        #expect(state.theme == { var d = BrowserSpaceThemePresets.default; d.mode = .dark; return d }())
        // A legacy Settings palette is a designed preset: "−" returns it to the default theme.
        var legacy = OrbitThemeEditorState(theme: try #require(BrowserSpacePalette.lavender.themeModel))
        #expect(!legacy.hasColor && legacy.canRemoveColor)
        legacy.removeColor()
        #expect(legacy.theme.presetID == BrowserSpaceThemePresets.defaultID && legacy.theme.mode == .light)
        #expect(BrowserSpacePalette.automatic.themeModel == nil)
        #expect(OrbitThemeEditorState(theme: try #require(BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.drab, index: 1))).familyIndex == 2)
    }
}
}

extension NativeWebKitTests {
@Suite("Space themes — window, editor and undo", .serialized)
@MainActor
struct NativeSpaceThemeWindowTests {
    @Test("Stored themes paint every window of the Space and win over the legacy Settings palette")
    func liveApplication() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        let profile = try #require(controller.session.activeProfileID)
        let other = try await environment.makeWindow(spaceID: space)
        defer { other.window?.close() }
        #expect(controller.windowShell.theme == .default)
        try await environment.settings.updateSpace(space) { $0.palette = .lavender }
        #expect(controller.windowShell.theme == .lavender, "a never-themed Space keeps its legacy palette")
        let model = BrowserSpaceTheme.composed(colors: [coral], mode: .light)
        _ = try await controller.session.setSpaceTheme(model, for: space, profileID: profile)
        for window in [controller, other] {
            window.session.refreshCatalog()
            await window.session.waitForPendingCommands()
            #expect(window.windowShell.theme == OrbitSpaceThemes.rendered(model))
            #expect(window.window?.appearance?.name == .aqua)
            #expect(window.resolvedSpaceTheme(for: space).model == model)
        }
        let accent = OrbitSpaceThemes.accent(for: OrbitSpaceThemes.rendered(model))
        #expect(near(rgb(controller.sidebar.page.list.accent.sidebarText, light), rgb(accent.sidebarText, light), 0.6))
        // Clearing returns the Space to its legacy palette, then the default.
        _ = try await controller.session.setSpaceTheme(nil, for: space, profileID: profile)
        controller.session.refreshCatalog()
        await controller.session.waitForPendingCommands()
        #expect(controller.windowShell.theme == .lavender)
        try await environment.settings.updateSpace(space) { $0.palette = .automatic }
        #expect(controller.windowShell.theme == .default)
        #expect(controller.window?.isVisible == false && other.window?.isVisible == false)
    }

    @Test("The Space context menus offer Edit Theme Color… after Rename")
    func contextMenus() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let button = try #require(controller.sidebar.footer.spaceButtons.first)
        // The footer menu is a custom panel (SidebarSpaceMenu), not an NSMenu on the button.
        let titles = controller.sidebar.footer.actions(for: button.space.id).map(\.title)
        #expect(titles.first == "Rename Space…")
        let rename = try #require(titles.firstIndex(of: "Rename Space…"))
        let theme = try #require(titles.firstIndex(of: "Edit Theme Color…"))
        #expect(rename < theme)
    }

    @Test("Editor geometry, live preview on every window, throttled store writes and one undo step")
    func editorSession() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let window = try #require(controller.window)
        window.setContentSize(CGSize(width: 1024, height: 640))
        window.contentView?.layoutSubtreeIfNeeded()
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        let other = try await environment.makeWindow(spaceID: space)
        defer { other.window?.close() }
        controller.openThemeEditor(for: space, animated: false)
        let editor = try #require(controller.themeEditor)
        let view = editor.view
        #expect(view.frame.size == CGSize(width: 356, height: 522) && editor.panel?.isVisible == false)
        let content = try #require(window.contentView)
        let card = controller.contentCard.convert(controller.contentCard.bounds, to: content)
        #expect(controller.themeEditorOrigin == CGPoint(x: card.minX + 13, y: 13))
        let frame = try #require(editor.panel?.frame)
        let expected = window.convertToScreen(NSRect(x: card.minX + 13, y: content.frame.maxY - 13 - 522, width: 356, height: 522))
        #expect(frame == expected)
        #expect(view.field.frame == NSRect(x: 8, y: 8, width: 340, height: 339))
        #expect(view.modeButtons.map { $0.frame.midX } == [138, 178, 218] && view.modeButtons.allSatisfy { $0.frame.midY == 48 })
        #expect(view.modeHighlight.frame == view.modeButtons[0].frame, "a never-themed Space is automatic")
        let swatchCenters = view.swatches.filter { !$0.isHidden }.map { $0.frame.midX }
        let expectedCenters = (0..<6).map { 60.0 + CGFloat($0) * 236.0 / 5.0 }
        #expect(swatchCenters == expectedCenters)
        #expect(view.swatches.filter { !$0.isHidden }.allSatisfy { $0.frame.midY == 380 && $0.discFrame.width == 24 })
        #expect([view.removeButton, view.addButton].map { $0.frame.midX } == [158, 198])
        #expect(!view.placeholder.isHidden && view.placeholder.stringValue == "Tap to pick a color for this space")
        #expect(!view.intensitySlider.isActive && view.intensitySlider.thumb.isHidden && view.grainDial.tick.isHidden)
        #expect(!view.addButton.isEnabled && !view.removeButton.isEnabled && !view.previousButton.isEnabled && view.nextButton.isEnabled)

        view.field.onPick?(CGPoint(x: 0.606, y: 0.118))
        let draft = editor.draft
        #expect(draft.colors.count == 1 && draft.colors[0] == OrbitThemeFieldMapping.color(at: CGPoint(x: 0.606, y: 0.118)))
        #expect(controller.windowShell.theme == OrbitSpaceThemes.rendered(draft))
        #expect(view.placeholder.isHidden && view.intensitySlider.isActive && !view.grainDial.tick.isHidden)
        #expect(close(view.intensitySlider.thumbCenterX, 0.78 * 224, 0.01))
        #expect(view.handles.count == 1 && close(view.handles[0].frame.midX, 8 + 0.606 * 340, 0.5))
        #expect(try await eventually { try await environment.store.spaceTheme(space) == draft })
        other.session.refreshCatalog()
        await other.session.waitForPendingCommands()
        #expect(other.windowShell.theme == OrbitSpaceThemes.rendered(draft))

        // More edits in the same session; the mode switch repaints the panel appearance instantly.
        view.swatches[3].performClick(nil)
        view.modeButtons[2].performClick(nil)
        view.grainDial.onChange?(0.5)
        #expect(editor.draft.presetID == "brand.mint" && editor.draft.mode == .dark && editor.draft.noise == 0.5)
        #expect(editor.panel?.appearance?.name == .darkAqua && controller.window?.appearance?.name == .darkAqua)
        let final = editor.draft

        // Closing writes the final draft and registers a single "Change Theme" step.
        editor.close(animated: false)
        await editor.waitUntilFinished()
        #expect(try await environment.store.spaceTheme(space) == final)
        #expect(editor.registeredChange == BrowserSpaceThemeChange(spaceID: space, profileID: try #require(controller.session.activeProfileID),
                                                                  before: nil, after: final))
        let manager = try #require(window.undoManager)
        try await Task.sleep(for: .milliseconds(50))
        #expect(manager.canUndo && manager.undoActionName == "Change Theme")
        #expect(try await eventually { controller.themeEditor == nil })
        #expect(controller.windowShell.theme == OrbitSpaceThemes.rendered(final))
        manager.undo()
        #expect(try await eventually { try await environment.store.spaceTheme(space) == nil })
        controller.session.refreshCatalog()
        await controller.session.waitForPendingCommands()
        #expect(controller.windowShell.theme == .default)
        #expect(manager.canRedo)
        manager.redo()
        #expect(try await eventually { try await environment.store.spaceTheme(space) == final })
    }

    @Test("A Space switch closes the editor and keeps what was picked; reopening starts from the stored theme")
    func spaceSwitchCloses() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PreviewEnvironment()
        let controller = try await environment.makeWindow()
        defer { controller.window?.close() }
        let first = try #require(controller.session.snapshot?.activeSpaceID)
        let profile = try #require(controller.session.activeProfileID)
        controller.createSpace(name: "Second", profileID: profile)
        await controller.session.waitForPendingCommands()
        controller.presentThemeEditor(for: first)
        await controller.session.waitForPendingCommands()
        let editor = try #require(controller.themeEditor)
        #expect(controller.session.snapshot?.activeSpaceID == first && editor.spaceID == first)
        editor.view.swatches[1].performClick(nil)
        let picked = editor.draft
        let second = try #require(controller.session.catalog?.spaces.first { $0.id != first }?.id)
        controller.activateSpace(second)
        await controller.session.waitForPendingCommands()
        #expect(editor.isClosed)
        await editor.waitUntilFinished()
        #expect(try await environment.store.spaceTheme(first) == picked)
        #expect(controller.windowShell.theme == .default, "the second Space shows its own theme")
        controller.openThemeEditor(for: second, animated: false)
        #expect(controller.themeEditor?.draft == BrowserSpaceThemePresets.default)
        controller.themeEditor?.close(animated: false)
    }

    @Test("Opening zooms from the anchor with the measured springs; reduced motion only fades")
    func presentationMotion() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let controller = try await PreviewEnvironment().makeWindow()
        defer { controller.window?.close() }
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        // The global preference is set and restored without suspending, so concurrently running
        // suites never observe the forced value.
        var previous = OrbitMotionPreferences.overrideReducedMotion
        OrbitMotionPreferences.overrideReducedMotion = false
        controller.openThemeEditor(for: space)
        OrbitMotionPreferences.overrideReducedMotion = previous
        let editor = try #require(controller.themeEditor)
        let layer = try #require(editor.view.layer)
        let zoom = try #require(layer.animation(forKey: OrbitThemeEditorController.scaleAnimationKey) as? CASpringAnimation)
        let fade = try #require(layer.animation(forKey: OrbitThemeEditorController.opacityAnimationKey) as? CASpringAnimation)
        #expect(close(zoom.stiffness, pow(2 * .pi / 0.305, 2), 0.01) && close(zoom.damping, 4 * .pi * 0.80 / 0.305, 0.01))
        #expect(close(fade.stiffness, pow(2 * .pi / 0.25, 2), 0.01) && close(fade.damping, 4 * .pi * 0.94 / 0.25, 0.01))
        editor.close(animated: false)
        await editor.waitUntilFinished()
        previous = OrbitMotionPreferences.overrideReducedMotion
        OrbitMotionPreferences.overrideReducedMotion = true
        controller.openThemeEditor(for: space)
        OrbitMotionPreferences.overrideReducedMotion = previous
        let reduced = try #require(controller.themeEditor)
        #expect(reduced !== editor)
        let reducedLayer = try #require(reduced.view.layer)
        #expect(reducedLayer.animation(forKey: OrbitThemeEditorController.scaleAnimationKey) == nil)
        let reducedFade = try #require(reducedLayer.animation(forKey: OrbitThemeEditorController.opacityAnimationKey))
        #expect(reducedFade.duration == OrbitTokens.Motion.reducedMotionCrossfade)
        reduced.close(animated: false)
        await reduced.waitUntilFinished()
        #expect(reduced.registeredChange == nil, "an untouched session registers no undo step")
    }

    @Test("Offscreen editor: swatch and handle colours, mode highlight and accessibility")
    func editorRenderingAndAccessibility() throws {
        let state = OrbitThemeEditorState(theme: BrowserSpaceTheme.composed(colors: [mauve], mode: .light,
                                                                            presetID: nil))
        let view = OrbitThemeEditorView(state: state)
        // Hosted like the product (a panel never ordered on screen) so AppKit builds the layer tree.
        let panel = OrbitThemeEditorPanel(content: view)
        defer { panel.contentView = nil }
        view.appearance = light
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        #expect(panel.isVisible == false)
        let pixel = try snapshot(view)
        for (button, preset) in zip(view.swatches.filter { !$0.isHidden }, BrandPalette.spaceGradients) {
            let middle = preset.locations[1]
            let pair = middle <= 0.5 ? (1, 2) : (0, 1)
            let t = (0.5 - preset.locations[pair.0]) / (preset.locations[pair.1] - preset.locations[pair.0])
            let a = preset.stops[pair.0], b = preset.stops[pair.1]
            let expected = BrowserThemeColor(red: a.red + (b.red - a.red) * t,
                                             green: a.green + (b.green - a.green) * t,
                                             blue: a.blue + (b.blue - a.blue) * t)
            #expect(near(pixel(Int(button.frame.midX), Int(button.frame.midY)), components(expected), 8), "\(preset.name)")
        }
        let handle = try #require(view.handles.first)
        #expect(near(pixel(Int(handle.frame.midX), Int(handle.frame.midY)), components(mauve), 3))
        #expect(near(pixel(Int(handle.frame.midX), Int(handle.frame.minY + 1.5)), [255, 255, 255], 6), "white ring")
        #expect(view.modeHighlight.frame == view.modeButtons[1].frame)
        // Accessibility: labelled controls, adjustable sliders, labelled swatches.
        #expect(view.accessibilityRole() == .popover && view.accessibilityLabel() == "Edit Theme Color")
        #expect(view.modeButtons.map { $0.accessibilityLabel() } == ["Automatic Appearance", "Light Appearance", "Dark Appearance"])
        #expect(view.modeButtons[2].toolTip == "Dark Appearance")
        #expect(view.swatches.first?.accessibilityLabel() == "Coral" && view.swatches.filter { !$0.isHidden }.last?.accessibilityLabel() == "Lilac")
        #expect(handle.accessibilityRole() == .slider && handle.accessibilityLabel() == "Color 1")
        #expect(handle.accessibilityValue() as? String == mauve.hexString)
        #expect(view.intensitySlider.accessibilityRole() == .slider && view.intensitySlider.accessibilityLabel() == "Intensity")
        #expect(view.intensitySlider.accessibilityValue() as? String == "78%")
        #expect(view.grainDial.accessibilityLabel() == "Grain" && view.grainDial.accessibilityValue() as? String == "0%")
        var edits: [OrbitThemeEditorState] = []
        view.onChange = { edits.append($0) }
        #expect(view.intensitySlider.accessibilityPerformIncrement())
        #expect(view.grainDial.accessibilityPerformIncrement())
        #expect(handle.accessibilityPerformIncrement())
        #expect(edits.count == 3 && close(CGFloat(edits[0].theme.intensity), 0.83, 1e-9) && close(CGFloat(edits[1].theme.noise), 0.05, 1e-9))
        #expect(close(CGFloat(edits[2].theme.colors[0].hsb.hue), CGFloat(mauve.hsb.hue) + 5.0 / 360, 1e-6))
        #expect(view.field.accessibilityLabel() == "Theme Colors")
        // Dark appearance resolves the control colours again.
        view.appearance = dark
        view.layoutSubtreeIfNeeded()
        #expect(view.modeHighlight.backgroundColor != nil)
        #expect(close(view.grainDial.value(at: CGPoint(x: view.grainDial.bounds.midX, y: 0)), 0, 1e-9))
    }
}
}

private extension CGSize {
    var intWidth: Int { Int(width) }
    var intHeight: Int { Int(height) }
}
