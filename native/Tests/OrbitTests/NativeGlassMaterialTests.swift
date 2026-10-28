import AppKit
import QuartzCore
import Testing
@testable import Orbit

/// Hidden view tests: no application launch, engine, session directory or Keychain access.
extension NativeWebKitTests {
@Suite("Native glass shell material", .serialized)
@MainActor
struct NativeGlassMaterialTests {
    @Test("Either accessibility preference disables compositing in every appearance and activation state")
    func accessibilityFallback() {
        for role in [OrbitGlassRole.windowShell, .floatingSidebar, .opaque] {
            for dark in [false, true] {
                for active in [false, true] {
                    for preferences in [(true, false), (false, true), (true, true)] {
                        let style = OrbitGlassStyle.resolve(role: role, isDark: dark, isActive: active,
                            reduceTransparency: preferences.0, increaseContrast: preferences.1)
                        #expect(!style.usesMaterial && style.tintOpacity == 1)
                        #expect(style.emphasizesBoundary == preferences.1)
                    }
                }
            }
        }
    }

    @Test("Glass is explicit, behind-window and decorative; opaque document shields have no material")
    func materialBoundary() throws {
        let ordinary = OrbitThemeFillView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        #expect(ordinary.materialView == nil && ordinary.glassStyle.tintOpacity == 1)
        for role in [OrbitGlassRole.windowShell, .floatingSidebar] {
            let fill = OrbitThemeFillView(materialRole: role)
            fill.frame = ordinary.frame
            fill.applyMaterialStyle(.resolve(role: role, isDark: false, isActive: true,
                                            reduceTransparency: false, increaseContrast: false))
            fill.layoutSubtreeIfNeeded()
            let material = try #require(fill.materialView)
            #expect(material.blendingMode == .behindWindow && material.material == .hudWindow)
            #expect(material.state == .followsWindowActiveState && !material.isEmphasized)
            #expect(!material.isHidden && material.frame == fill.bounds)
            #expect(fill.subviews.first === material)
            #expect(fill.hitTest(CGPoint(x: 50, y: 50)) == nil)
            #expect(material.hitTest(CGPoint(x: 50, y: 50)) == nil)
            let tint = try #require(fill.layer?.sublayers?.first { $0.zPosition == 1 })
            #expect(tint.opacity == fill.glassStyle.tintOpacity)
            let fallback = OrbitGlassStyle.resolve(role: role, isDark: false, isActive: true,
                                                reduceTransparency: true, increaseContrast: false)
            fill.applyMaterialStyle(fallback)
            #expect(material.isHidden && tint.opacity == 1)
            #expect(fill.window == nil)
        }
    }

    @Test("Docked and floating surfaces share the default glass strength without an opaque inactive wash")
    func coherentActivation() {
        for dark in [false, true] {
            let active = OrbitGlassStyle.resolve(role: .windowShell, isDark: dark, isActive: true,
                                              reduceTransparency: false, increaseContrast: false)
            let floating = OrbitGlassStyle.resolve(role: .floatingSidebar, isDark: dark, isActive: true,
                                                reduceTransparency: false, increaseContrast: false)
            let inactive = OrbitGlassStyle.resolve(role: .windowShell, isDark: dark, isActive: false,
                                                reduceTransparency: false, increaseContrast: false)
            #expect(active == floating)
            #expect(active == inactive)
            #expect(abs(active.tintOpacity - 0.428) < 0.0001)
            #expect(active.usesMaterial)
        }
    }

    @Test("Space fills keep independent themes and floating corners without changing gradient coordinates")
    func isolationAndCorners() throws {
        let first = OrbitThemeFillView(materialRole: .windowShell)
        let second = OrbitThemeFillView(materialRole: .windowShell)
        let panel = OrbitFloatingSidebarBackdrop(frame: CGRect(x: 0, y: 0, width: 228, height: 630))
        first.apply(.lavender)
        second.apply(.amberCoral)
        panel.fill.apply(.lavender)
        panel.fill.windowFillSize = CGSize(width: 1024, height: 640)
        panel.fill.offsetInWindowFill = CGPoint(x: 5, y: 5)
        panel.cornerRadius = 12
        panel.layoutSubtreeIfNeeded()
        #expect(first.theme == .lavender && second.theme == .amberCoral)
        #expect(panel.fill.theme == first.theme)
        #expect(panel.fill.windowFillSize == CGSize(width: 1024, height: 640))
        #expect(panel.fill.offsetInWindowFill == CGPoint(x: 5, y: 5))
        #expect(panel.fill.layer?.cornerRadius == 12 && panel.fill.layer?.masksToBounds == true)
        #expect(first.layer?.cornerRadius == 0)
        #expect(panel.fill.materialView !== first.materialView)
        let edge = try #require(panel.fill.layer?.sublayers?.last as? CAShapeLayer)
        panel.fill.applyMaterialStyle(.resolve(role: .floatingSidebar, isDark: false, isActive: true,
                                              reduceTransparency: false, increaseContrast: true))
        panel.layoutSubtreeIfNeeded()
        #expect(edge.lineWidth == 2)
        #expect(panel.fill.materialView?.isHidden == true)
        #expect(second.theme == .amberCoral, "Accessibility does not mutate another window's theme")
    }

    @Test("Opaque accessibility fallback keeps default text and controls legible", arguments: [false, true])
    func opaqueContrast(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let source = OrbitSpaceThemes.accent(for: .default)
        let stops = try OrbitThemeGradient.normalizedStops(OrbitTokens.SpaceTheme.default.stops, appearance: appearance)
            .map { try #require(NSColor(cgColor: $0)?.usingColorSpace(.sRGB)) }
        let style = OrbitGlassStyle.resolve(role: .windowShell, isDark: isDark, isActive: true,
                                         reduceTransparency: true, increaseContrast: false)
        #expect(style.tintOpacity == 1 && !style.usesMaterial)
        // Native material contrast cannot be inferred by compositing raw desktop RGB values.
        // This analytical check covers only the opaque accessibility fallback.
        for floating in [false, true] {
            for index in 0...32 {
                let fraction = CGFloat(index) / 32
                let start = stops[0], end = stops[2]
                var background = NSColor(srgbRed: start.redComponent * (1 - fraction) + end.redComponent * fraction,
                    green: start.greenComponent * (1 - fraction) + end.greenComponent * fraction,
                    blue: start.blueComponent * (1 - fraction) + end.blueComponent * fraction, alpha: 1)
                if floating {
                    background = composite(OrbitTokens.Color.State.floatingSidebarDim.resolved(for: appearance), on: background)
                }
                for overlays in [[], [OrbitTokens.Color.State.standaloneButton],
                                 [OrbitTokens.Color.State.tabCurrent]] as [[NSColor]] {
                    let accent = OrbitSpaceThemes.accent(source, over: overlays)
                    let painted = overlays.reduce(background) { composite($1.resolved(for: appearance), on: $0) }
                    #expect(contrast(accent.sidebarText.resolved(for: appearance), painted) >= 4.5)
                    #expect(contrast(accent.icon.resolved(for: appearance), painted) >= 3)
                }
            }
        }
    }

    @Test("Theme tint preserves gradient order over opposite material colors and fallback removes backdrop influence")
    func gradientAndBackdropSeparation() throws {
        for dark in [false, true] {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            let stops = try OrbitThemeGradient.normalizedStops(OrbitTokens.SpaceTheme.default.stops, appearance: appearance)
                .map { try #require(NSColor(cgColor: $0)?.usingColorSpace(.sRGB)) }
            for fallback in [false, true] {
                let style = OrbitGlassStyle.resolve(role: .windowShell, isDark: dark, isActive: true,
                    reduceTransparency: fallback, increaseContrast: false)
                let alpha = CGFloat(style.tintOpacity)
                for backdrop in [NSColor.red, .blue] {
                    let colors = stops.map { composite($0.withAlphaComponent(alpha), on: backdrop) }
                    for channel in [\NSColor.redComponent, \NSColor.greenComponent, \NSColor.blueComponent] {
                        let sourceDifference = stops[2][keyPath: channel] - stops[0][keyPath: channel]
                        let resultDifference = colors[2][keyPath: channel] - colors[0][keyPath: channel]
                        #expect(abs(resultDifference - sourceDifference * alpha) < 0.0001)
                    }
                }
                let red = composite(stops[1].withAlphaComponent(alpha), on: .red)
                let blue = composite(stops[1].withAlphaComponent(alpha), on: .blue)
                if fallback {
                    #expect(red == blue)
                } else {
                    // Tests tint composition only; screen-composited product captures measure the material.
                    #expect(abs(red.redComponent - blue.redComponent) > 0.09)
                }
            }
        }
    }

    @Test("Opaque accessibility fallback paints the same aligned gradient in shell and floating panel")
    func fallbackPixels() throws {
        let size = CGSize(width: 400, height: 300)
        let shell = OrbitThemeFillView(materialRole: .windowShell)
        shell.frame = CGRect(origin: .zero, size: size)
        let floating = OrbitThemeFillView(materialRole: .floatingSidebar)
        floating.frame = CGRect(x: 0, y: 0, width: 180, height: 280)
        floating.windowFillSize = size
        floating.offsetInWindowFill = CGPoint(x: 5, y: 5)
        for isDark in [false, true] {
            for fill in [shell, floating] {
                fill.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
                fill.applyMaterialStyle(.resolve(role: fill.materialRole, isDark: isDark, isActive: true,
                                                reduceTransparency: true, increaseContrast: false))
                fill.layoutSubtreeIfNeeded()
            }
            let full = try pixels(shell), panel = try pixels(floating)
            for point in [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 100), CGPoint(x: 170, y: 270)] {
                // RGBA rows start at the bottom. The panel occupies y=15...295 in the shell.
                let a = full(Int(point.x) + 5, Int(point.y) + 15)
                let b = panel(Int(point.x), Int(point.y))
                #expect(zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
                #expect(a[3] == 255 && b[3] == 255)
            }
        }
    }

    private func pixels(_ view: NSView) throws -> (Int, Int) -> [UInt8] {
        let width = Int(view.bounds.width), height = Int(view.bounds.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        try #require(view.layer).render(in: context)
        let data = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                            count: width * height * 4))
        return { x, y in Array(data[((y * width + x) * 4)..<((y * width + x) * 4 + 4)]) }
    }

    private func composite(_ foreground: NSColor, on background: NSColor) -> NSColor {
        let foreground = foreground.usingColorSpace(.sRGB)!
        let alpha = foreground.alphaComponent
        return NSColor(srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha), alpha: 1)
    }

    private func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        let a = luminance(composite(foreground, on: background)), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }
}
}
