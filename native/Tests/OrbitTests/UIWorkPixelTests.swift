import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

/// Deterministic painter fixtures. Product-window motion is checked separately by the synthetic probe.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_PIXEL_DIR"] != nil))
@MainActor
struct UIWorkPixelTests {
    private func render(_ view: NSView, name: String, scale: CGFloat, layers: Bool = false) throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ORBIT_UI_PIXEL_DIR"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        if layers, let layer = view.layer {
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            context.cgContext.scaleBy(x: scale, y: scale)
            layer.render(in: context.cgContext)
        } else {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test func painterMatrix() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let themes: [OrbitTokens.SpaceTheme] = [ .default,
            .init(stops: [NSColor(srgbRed: 32.0/255, green: 63.0/255, blue: 152.0/255, alpha: 1)], mode: .automatic, texture: .none, textureIntensity: 0),
            .init(stops: [NSColor(srgbRed: 184.0/255, green: 244.0/255, blue: 120.0/255, alpha: 1)], mode: .automatic, texture: .none, textureIntensity: 0)]
        for scale: CGFloat in [1, 2] {
            for (appearanceIndex, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
                for (themeIndex, theme) in themes.enumerated() {
                    let accent = OrbitSpaceThemes.accent(for: theme)
                    for state in 0..<4 {
                        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 112))
                        root.appearance = NSAppearance(named: appearance)
                        let glyphs = [OrbitGlyph.back, OrbitGlyph.forward, OrbitGlyph.reload, OrbitGlyph.close,
                                      OrbitGlyph.newTab, OrbitGlyph.sidebarToggle, OrbitGlyph.faviconPlaceholder, OrbitGlyph.siteControlCenter]
                        for (index, glyph) in glyphs.enumerated() {
                            let button = OrbitGlyphButton(glyph: glyph, label: "Synthetic glyph")
                            button.frame = NSRect(x: 36 * index, y: 0, width: 32, height: 32)
                            button.tint = accent.icon
                            button.isEnabled = state != 1
                            button.isHighlighted = state == 3
                            if state == 2 { button.mouseEntered(with: NSEvent()) }
                            root.addSubview(button)
                        }
                        let clear = SidebarClearButton()
                        clear.accent = accent
                        clear.alphaValue = 1
                        clear.frame = NSRect(x: 300, y: 0, width: clear.preferredWidth, height: 28)
                        clear.isEnabled = state != 1
                        clear.isHighlighted = state == 3
                        if state == 2 { clear.mouseEntered(with: NSEvent()) }
                        root.addSubview(clear)
                        let row = SidebarSplitRow(item: .init(id: TabID(), title: "Synthetic split", selected: state != 1,
                            splitPanes: [.init(title: "Left pane", favicon: nil), .init(title: "Right pane", favicon: nil)]),
                            node: .split(SplitGroupID()), depth: 0)
                        row.frame = NSRect(x: 0, y: 44, width: 410, height: 36)
                        row.accent = accent
                        if state >= 2 { row.mouseEntered(with: NSEvent()) }
                        row.isPressed = state == 3
                        root.addSubview(row)
                        let name = "s\(Int(scale))-a\(appearanceIndex)-t\(themeIndex)-v\(state)"
                        try render(root, name: name, scale: scale)
                    }
                }
                let field = OrbitThemeFieldView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
                field.appearance = NSAppearance(named: appearance)
                field.refresh()
                try render(field, name: "field-s\(Int(scale))-a\(appearanceIndex)", scale: scale, layers: true)
            }
        }
    }
}
