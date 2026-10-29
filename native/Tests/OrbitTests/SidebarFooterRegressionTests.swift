import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

/// Offscreen source tests: no window, app activation, personal root or menu tracking.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct SidebarFooterRegressionTests {
    private func spaces(_ count: Int) -> [BrowserSpace] {
        let profile = ProfileID()
        return (0..<count).map { BrowserSpace(id: SpaceID(), profileID: profile, name: "Synthetic Space \($0)") }
    }

    @Test("Long names wrap fully and repeated measurements do not reuse a truncated field width")
    func tooltipMeasurement() {
        let tooltip = SidebarSpaceTooltip()
        let short = tooltip.configure(name: "One", shortcut: nil)
        let name = String(repeating: "Synthetic long Space name 🇫🇷 👩🏽‍💻 ", count: 12)
        let long = tooltip.configure(name: name, shortcut: "⌃2")
        #expect(long.height > 22)
        #expect(long.width <= 600)
        let again = tooltip.configure(name: "One", shortcut: nil)
        #expect(again == short)
        let fields = tooltip.subviews.compactMap { $0 as? NSTextField }
        #expect(fields.first?.stringValue == "One")
    }

    @Test("Crowded footers keep every Space visible between Library and + without scrolling")
    func crowdedTargets() {
        for count in [1, 4, 6, 12, 40] {
            for width: CGFloat in [180, 220, 260, 400] {
                let footer = SidebarFooterView()
                let items = spaces(count)
                footer.render(spaces: items, activeSpaceID: items.last?.id)
                let geometry = OrbitSidebarGeometry.resolve(.init(width: width, height: 640, spaceCount: count))
                footer.frame = geometry.footerFrame
                footer.apply(geometry)
                #expect(footer.spaceButtons.count == count)
                #expect(footer.enclosingScrollView == nil && footer.spaceButtons.allSatisfy { $0.enclosingScrollView == nil })
                for button in footer.spaceButtons {
                    #expect(button.superview === footer)
                    #expect(button.frame.width > 0)
                    #expect(button.frame.minX >= footer.libraryButton.frame.maxX)
                    #expect(button.frame.maxX <= footer.plusButton.frame.minX)
                }
                for pair in zip(footer.spaceButtons, footer.spaceButtons.dropFirst()) {
                    #expect(pair.0.frame.maxX <= pair.1.frame.minX + 0.001)
                }
                #expect(footer.spaceButtons.allSatisfy { $0.presentation == footer.spaceLayout.presentation })
                #expect(footer.spaceButtons.allSatisfy { ($0.hoverFill.side ?? $0.frame.width) <= $0.frame.width + 0.001 })
            }
        }
    }

    @Test("Icons keep the measured 34 pt pitch while they fit and switch to dots once they do not")
    func dotBreakpoint() {
        // Default sidebar 228: Library hit square ends at 38, + starts at 190; 4 pt clearance → 144 pt.
        let fitting = FooterSpaceLayout.resolve(count: 4, libraryCenterX: 24, plusCenterX: 204)
        #expect(fitting.presentation == .icons && fitting.pitch == 34)
        let compressed = FooterSpaceLayout.resolve(count: 6, libraryCenterX: 24, plusCenterX: 204)
        #expect(compressed.presentation == .icons && compressed.pitch == 24)
        let crowded = FooterSpaceLayout.resolve(count: 7, libraryCenterX: 24, plusCenterX: 204)
        #expect(crowded.presentation == .dots && crowded.pitch == 18 && crowded.dotDiameter == 8)
        let dense = FooterSpaceLayout.resolve(count: 30, libraryCenterX: 24, plusCenterX: 204)
        #expect(dense.presentation == .dots && dense.pitch * 30 <= 144.001)
        #expect(dense.dotDiameter >= 3 && dense.dotDiameter <= dense.pitch)
        for layout in [fitting, compressed, crowded, dense] {
            let first = layout.centerXs.first ?? 0, last = layout.centerXs.last ?? 0
            #expect(abs(first + last - 228) < 0.001)
        }
    }

    @Test("Crowded presentation draws emoji Spaces as dots, active at full tint and inactive dimmed")
    func crowdedEmojiBecomesDot() {
        let space = spaces(1)[0]
        let active = SidebarSpaceButton(space: space, index: 0, isActive: true)
        let inactive = SidebarSpaceButton(space: space, index: 0, isActive: false)
        for button in [active, inactive] {
            button.settingsIcon = "🌈"
            button.tint = .black
            button.presentation = .dots
        }
        func opaqueStats(_ bitmap: NSBitmapImageRep) -> (count: Int, colored: Int, maxAlpha: CGFloat) {
            var count = 0, colored = 0, maxAlpha: CGFloat = 0
            for y in 0..<40 { for x in 0..<40 {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.05 else { continue }
                count += 1
                maxAlpha = max(maxAlpha, c.alphaComponent)
                if abs(c.redComponent - c.blueComponent) > 0.1 { colored += 1 }
            } }
            return (count, colored, maxAlpha)
        }
        let a = opaqueStats(raster(active)), i = opaqueStats(raster(inactive))
        // An 8 pt dot covers about 50 px; an emoji glyph covers far more and is coloured.
        #expect(a.count > 0 && a.count < 70 && a.colored == 0)
        #expect(i.count > 0 && i.count < 70 && i.colored == 0)
        #expect(a.maxAlpha > 0.95 && i.maxAlpha < 0.8)
        inactive.hoverAmount = 1
        let hovered = opaqueStats(raster(inactive))
        #expect(hovered.maxAlpha > i.maxAlpha && hovered.maxAlpha < a.maxAlpha)
        active.presentation = .icons
        #expect(opaqueStats(raster(active)).colored > 0)
    }

    @Test("Active state changes retain hovered controls and icon updates invalidate cached drawing")
    func activeStateChanges() {
        let items = spaces(2)
        let footer = SidebarFooterView()
        footer.render(spaces: items, activeSpaceID: items[0].id)
        let old = footer.spaceButtons[0]
        old.settingsIcon = "🌈"
        let previousPixels = raster(old).tiffRepresentation
        old.settingsIcon = "🇬🇧"
        #expect(old.settingsIcon == "🇬🇧" && old.isActive)
        #expect(raster(old).tiffRepresentation != previousPixels)
        footer.render(spaces: items, activeSpaceID: items[1].id)
        #expect(!footer.spaceButtons[0].isActive && footer.spaceButtons[1].isActive)
        #expect(footer.spaceButtons[0] === old)
    }

    @Test("Equivalent footer paint and control state writes do not invalidate Space icons")
    func equivalentPaintDoesNotInvalidate() {
        let items = spaces(3)
        let footer = SidebarFooterView()
        footer.render(spaces: items, activeSpaceID: items[0].id)
        let geometry = OrbitSidebarGeometry.resolve(.init(width: 240, height: 640, spaceCount: 3))
        footer.frame = geometry.footerFrame
        footer.apply(geometry)
        let accent = footer.accent
        OrbitUIWorkCounters.enabled = true
        defer { OrbitUIWorkCounters.enabled = false; OrbitUIWorkCounters.reset() }
        OrbitUIWorkCounters.reset()
        footer.accent = accent
        footer.apply(geometry)
        footer.setCommandsEnabled(true)
        for button in footer.spaceButtons {
            let active = button.isActive, hover = button.hoverAmount, emphasis = button.iconEmphasis
            button.isActive = active
            button.hoverAmount = hover
            button.iconEmphasis = emphasis
            #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] == 0)
        }
    }

    @Test("Opacity providers compare current values and retain changed appearance behavior")
    func opacityProviderChanges() {
        let button = SidebarSpaceButton(space: spaces(1)[0], index: 0, isActive: false)
        OrbitUIWorkCounters.enabled = true
        defer { OrbitUIWorkCounters.enabled = false; OrbitUIWorkCounters.reset() }
        button.appearance = NSAppearance(named: .aqua)
        button.inactiveOpacity = { _ in 0.5 }
        OrbitUIWorkCounters.reset()
        button.inactiveOpacity = { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.8 : 0.5
        }
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] == 0)
        #expect(button.inactiveOpacity(NSAppearance(named: .darkAqua)!) == 0.8)
        button.appearance = NSAppearance(named: .darkAqua)
        button.viewDidChangeEffectiveAppearance()
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] > 0)
        OrbitUIWorkCounters.reset()
        button.inactiveOpacity = { _ in 0.8 }
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] == 0)
        button.inactiveOpacity = { _ in 0.6 }
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] > 0)
    }

    @Test("Active and animated state changes still invalidate, including an already emphasized icon")
    func changedPaintInvalidates() {
        let button = SidebarSpaceButton(space: spaces(1)[0], index: 0, isActive: false)
        OrbitUIWorkCounters.enabled = true
        defer { OrbitUIWorkCounters.enabled = false; OrbitUIWorkCounters.reset() }
        button.mouseEntered(with: NSEvent())
        button.hoverAmount = 1
        button.iconEmphasis = 1
        OrbitUIWorkCounters.reset()
        button.isActive = true
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] > 0)
        OrbitUIWorkCounters.reset()
        button.hoverAmount = 0.75
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] > 0)
        OrbitUIWorkCounters.reset()
        button.iconEmphasis = 0.5
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] > 0)
    }

    private func raster(_ button: SidebarSpaceButton) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        button.customDrawing?(button, NSRect(x: 0, y: 0, width: 40, height: 40))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    @Test("Inactive multi-scalar emoji are grayscale while active emoji keep color and alpha")
    func emojiRendering() {
        let space = spaces(1)[0]
        for emoji in ["🇬🇧", "👩🏽‍💻", "🌈"] {
            let active = SidebarSpaceButton(space: space, index: 0, isActive: true)
            let inactive = SidebarSpaceButton(space: space, index: 0, isActive: false)
            active.settingsIcon = emoji
            inactive.settingsIcon = emoji
            let color = raster(active), gray = raster(inactive)
            var colored = 0, grayVisible = 0
            for y in 0..<40 {
                for x in 0..<40 {
                    guard let c = color.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let g = gray.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if c.alphaComponent > 0.5 && abs(c.redComponent - c.blueComponent) > 0.1 { colored += 1 }
                    if g.alphaComponent > 0.5 {
                        grayVisible += 1
                        #expect(abs(g.redComponent - g.greenComponent) < 0.025)
                        #expect(abs(g.greenComponent - g.blueComponent) < 0.025)
                    }
                    #expect(abs(c.alphaComponent - g.alphaComponent) < 0.06)
                }
            }
            #expect(colored > 0 && grayVisible > 0)
        }
    }
}
}
