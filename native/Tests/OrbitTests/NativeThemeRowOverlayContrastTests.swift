import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

/// Synthetic AppKit views only. No browser engine, visible window, application launch or stored data.
extension NativeWebKitTests {
@Suite("Sidebar foreground contrast on painted row overlays", .serialized)
@MainActor
struct NativeThemeRowOverlayContrastTests {
    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            ((child as? T).map { [$0] } ?? []) + descendants(child, of: type)
        }
    }

    private func themes() -> [(String, OrbitTokens.SpaceTheme)] {
        [("default", .default)] + BrowserSpaceThemePresets.families.flatMap { family in
            family.swatches.indices.compactMap { index in
                BrowserSpaceThemePresets.theme(family: family, index: index).map {
                    (BrowserSpaceThemePresets.presetID(family: family, index: index), OrbitSpaceThemes.rendered($0))
                }
            }
        }
    }

    private func hoverEvent() throws -> NSEvent {
        try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
    }

    private func composite(_ overlay: NSColor?, on base: NSColor, appearance: NSAppearance) -> NSColor {
        guard let overlay else { return base }
        let color = overlay.resolved(for: appearance), alpha = color.alphaComponent
        return NSColor(srgbRed: color.redComponent * alpha + base.redComponent * (1 - alpha),
                       green: color.greenComponent * alpha + base.greenComponent * (1 - alpha),
                       blue: color.blueComponent * alpha + base.blueComponent * (1 - alpha), alpha: 1)
    }

    private func backgrounds(_ theme: OrbitTokens.SpaceTheme, overlay: NSColor?, appearance: NSAppearance) throws -> [NSColor] {
        let stops = try OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance).map {
            try #require(NSColor(cgColor: $0)?.usingColorSpace(.sRGB))
        }
        return zip(stops, stops.dropFirst()).flatMap { a, b in
            (0...32).map { sample in
                let t = CGFloat(sample) / 32
                let base = NSColor(srgbRed: a.redComponent * (1 - t) + b.redComponent * t,
                                   green: a.greenComponent * (1 - t) + b.greenComponent * t,
                                   blue: a.blueComponent * (1 - t) + b.blueComponent * t, alpha: 1)
                return composite(overlay, on: base, appearance: appearance)
            }
        }
    }

    private func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        func luminance(_ c: NSColor) -> CGFloat {
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func check(theme: OrbitTokens.SpaceTheme, _ colors: [NSColor?], minimum: CGFloat, backgrounds: [NSColor],
                       appearance: NSAppearance, context: String, expectedInk: NSColor? = nil) throws {
        let expected = (expectedInk ?? OrbitSpaceThemes.accent(for: theme).foreground).resolved(for: appearance)
        for color in colors {
            #expect(try #require(color).resolved(for: appearance) == expected, "\(context): shared foreground")
            if expectedInk != nil {
                #expect(backgrounds.allSatisfy { contrast(expected, $0) >= minimum })
            }
        }
    }

    @Test("Explicit accents without a source theme retain their supplied primary and icon roles")
    func explicitAccentCompatibility() throws {
        var accent = OrbitTokens.ThemeAccent.defaultSpace
        accent.sidebarText = .systemPink
        accent.icon = .systemGreen
        #expect(accent.contrastTheme == nil)
        let item = SidebarTabItem(id: TabID(), title: "Synthetic tab", selected: true,
                                  isOpenInAnotherWindow: true)
        let row = SidebarTabRow(item: item)
        row.accent = accent
        #expect(row.titleLabel.textColor == accent.sidebarSecondaryText)
        #expect(row.closeButton.tint == accent.icon)
        #expect(row.effectiveAccent == accent)
        row.mouseEntered(with: try hoverEvent())
        #expect(row.titleLabel.textColor == accent.sidebarText)
        #expect(row.effectiveAccent == accent)
        row.isDropTarget = true
        #expect(row.effectiveAccent == accent)
        let newTab = SidebarNewTabRow(), clear = SidebarClearButton()
        newTab.accent = accent
        clear.accent = accent
        newTab.isHighlighted = true
        clear.isHighlighted = true
        #expect(descendants(newTab, of: NSTextField.self).first {
            $0.stringValue == SidebarListStrings.newTab
        }?.textColor == accent.foreground)
        #expect(clear.attributedLabel.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == accent.sidebarSecondaryText)
    }

    @Test("Actual selected, renaming, hover, pressed, context, multi and drop roles cover all picker swatches", arguments: [false, true])
    func rowOverlays(isDark: Bool) async throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let event = try hoverEvent()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        defer { window.close() }
        let variants = themes()
        #expect(variants.count == 37)
        for (name, theme) in variants {
            await Task.yield()
            for state in ["rest", "selected", "renaming", "hover", "pressed", "context", "multi", "drop"] {
                for secondary in [false, true] {
                    let item = SidebarTabItem(id: TabID(), title: "Synthetic tab", selected: state == "selected",
                                              isMultiSelected: state == "multi", isPinned: true, isAwayFromPinnedURL: true,
                                              isOpenInAnotherWindow: secondary)
                    let row = SidebarTabRow(item: item)
                    row.frame = NSRect(x: 0, y: 0, width: 240, height: 36)
                    row.appearance = appearance
                    row.accent = OrbitSpaceThemes.accent(for: theme)
                    row.isPressed = state == "pressed"
                    row.isContextTarget = state == "context"
                    row.isDropTarget = state == "drop"
                    if state == "hover" { row.mouseEntered(with: event) }
                    if state == "renaming" {
                        window.contentView = row
                        row.beginRename(text: "Synthetic rename", font: OrbitTokens.Typography.sidebarRenameField)
                        #expect(row.renameField != nil)
                    }
                    let painted = try backgrounds(theme, overlay: row.background.fillColor, appearance: appearance)
                    let context = "\(name) \(state) secondary=\(secondary) dark=\(isDark)"
                    try check(theme: theme, [row.titleLabel.textColor], minimum: secondary && state != "hover" ? 3 : 4.5,
                              backgrounds: painted, appearance: appearance, context: context,
                              expectedInk: state == "selected" && !isDark ? (secondary ? OrbitTokens.Color.State.pinnedSelectedIcon : OrbitTokens.Color.State.pinnedSelectedText) : nil)
                    if let field = row.renameField {
                        let editor = try #require(field.currentEditor() as? NSTextView)
                        #expect(editor.insertionPointColor == NSColor.controlAccentColor)
                        try check(theme: theme, [field.textColor, editor.textColor], minimum: 4.5,
                                  backgrounds: painted, appearance: appearance, context: context + " rename/editor")
                    }
                    let icons = [row.closeButton.tint]
                        + descendants(row, of: NSImageView.self).map(\.contentTintColor)
                        + descendants(row, of: SidebarPinnedSlashView.self).map { Optional($0.tint) }
                    try check(theme: theme, icons, minimum: 3, backgrounds: painted, appearance: appearance, context: context + " icons",
                              expectedInk: state == "selected" && !isDark ? OrbitTokens.Color.State.pinnedSelectedIcon : nil)
                    let buttonBackgrounds = painted.map {
                        composite(OrbitTokens.Color.State.rowCloseButtonHover, on: $0, appearance: appearance)
                    }
                    try check(theme: theme, [row.closeButton.tint], minimum: 3, backgrounds: buttonBackgrounds,
                              appearance: appearance, context: context + " nested button overlay",
                              expectedInk: state == "selected" && !isDark ? OrbitTokens.Color.State.pinnedSelectedIcon : nil)
                    row.cancelRename()
                    window.contentView = nil
                }
            }
        }
        #expect(!window.isVisible)
    }

    @Test("Folder outlines and titles follow each overlay, including the live rename editor", arguments: [false, true])
    func folderOverlays(isDark: Bool) async throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let event = try hoverEvent()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        defer { window.close() }
        for (name, theme) in themes() {
            await Task.yield()
            for state in ["rest", "renaming", "hover", "pressed", "context", "multi", "drop"] {
                let item = SidebarFolderItem(id: FolderID(), title: "Synthetic folder", isCollapsed: false,
                                             childCount: 1, isMultiSelected: state == "multi")
                let row = SidebarFolderRow(item: item)
                row.frame = NSRect(x: 0, y: 0, width: 240, height: 36)
                row.appearance = appearance
                row.accent = OrbitSpaceThemes.accent(for: theme)
                row.isPressed = state == "pressed"
                row.isContextTarget = state == "context"
                row.isDropTarget = state == "drop"
                if state == "hover" { row.mouseEntered(with: event) }
                if state == "renaming" {
                    window.contentView = row
                    row.beginRename(text: "Synthetic rename", font: OrbitTokens.Typography.sidebarFolderTitle)
                    let field = try #require(row.renameField)
                    let editor = try #require(field.currentEditor() as? NSTextView)
                        #expect(editor.insertionPointColor == NSColor.controlAccentColor)
                    let painted = try backgrounds(theme, overlay: row.background.fillColor, appearance: appearance)
                    try check(theme: theme, [field.textColor, editor.textColor], minimum: 4.5,
                              backgrounds: painted, appearance: appearance, context: "\(name) folder rename/editor dark=\(isDark)")
                }
                let painted = try backgrounds(theme, overlay: row.background.fillColor, appearance: appearance)
                try check(theme: theme, [row.titleLabel.textColor], minimum: 4.5, backgrounds: painted,
                          appearance: appearance, context: "\(name) folder \(state) dark=\(isDark)")
                try check(theme: theme, [row.glyph.accent.icon], minimum: 3, backgrounds: painted,
                          appearance: appearance, context: "\(name) folder outline \(state)")
                #expect(row.glyph.accent.iconFill.resolved(for: appearance)
                    == OrbitThemeGradient.representativeColor(theme, appearance: appearance))
                row.cancelRename()
                window.contentView = nil
            }
        }
        #expect(!window.isVisible)
    }

    @Test("Drag bitmap paints selected-row foregrounds over its unchanged translucent overlay", arguments: [false, true])
    func dragPreviewOverlay(isDark: Bool) async throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let size = NSSize(width: 240, height: 36)
        for (name, theme) in themes() {
            await Task.yield()
            let accent = OrbitSpaceThemes.accent(for: theme)
            let tab = SidebarTabItem(id: TabID(), title: "Synthetic tab", selected: true)
            let folder = SidebarFolderItem(id: FolderID(), title: "Synthetic folder", isCollapsed: false, childCount: 1)
            let entries = [SidebarListEntry(node: .tab(tab.id), section: .pinned, ancestors: [], content: .tab(tab)),
                           SidebarListEntry(node: .folder(folder.id), section: .pinned, ancestors: [], content: .folder(folder))]
            for entry in entries {
                // Drag previews always lift the row on tabCurrent, including unselected folders.
                let expected = OrbitSpaceThemes.accent(accent, over: [OrbitTokens.Color.State.tabCurrent])
                let image = SidebarDragImage.render(entry, size: size, accent: accent, appearance: appearance)
                let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
                let primary = expected.sidebarText.resolved(for: appearance)
                let icon = expected.icon.resolved(for: appearance)
                var primaryPixels = 0, iconPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.995 else { continue }
                        func matches(_ color: NSColor) -> Bool {
                            max(abs(pixel.redComponent - color.redComponent), abs(pixel.greenComponent - color.greenComponent),
                                abs(pixel.blueComponent - color.blueComponent)) < 0.025
                        }
                        if x > 80, matches(primary) { primaryPixels += 1 }
                        if x < 80, matches(icon) { iconPixels += 1 }
                    }
                }
                #expect(primaryPixels > 0, "\(name) dark=\(isDark): bitmap must actually paint the corrected primary")
                #expect(iconPixels > 0, "\(name) dark=\(isDark): bitmap must actually paint the corrected placeholder/outline")
                let painted = try backgrounds(theme, overlay: OrbitTokens.Color.State.tabCurrent, appearance: appearance)
                try check(theme: theme, [primary], minimum: 4.5, backgrounds: painted, appearance: appearance, context: "\(name) drag title")
                try check(theme: theme, [icon], minimum: 3, backgrounds: painted, appearance: appearance, context: "\(name) drag icon")
                let fillPixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 20, y: bitmap.pixelsHigh / 2))
                #expect(abs(fillPixel.alphaComponent - OrbitTokens.Color.State.tabCurrent.resolved(for: appearance).alphaComponent) < 0.01)
            }
        }
    }

    @Test("Actual New Tab and Clear foregrounds follow their hover and pressed overlays", arguments: [false, true])
    func auxiliaryOverlays(isDark: Bool) async throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let event = try hoverEvent()
        for (name, theme) in themes() {
            await Task.yield()
            for state in ["rest", "hover", "pressed"] {
                let newTab = SidebarNewTabRow(), clear = SidebarClearButton()
                newTab.appearance = appearance
                clear.appearance = appearance
                newTab.accent = OrbitSpaceThemes.accent(for: theme)
                clear.accent = newTab.accent
                if state == "hover" { newTab.mouseEntered(with: event); clear.mouseEntered(with: event) }
                newTab.isHighlighted = state == "pressed"
                clear.isHighlighted = state == "pressed"
                for label in descendants(newTab, of: NSTextField.self) {
                    #expect(label.textColor == newTab.accent.foreground)
                }
                for glyph in descendants(newTab, of: OrbitGlyphButton.self) {
                    #expect(glyph.tint == newTab.accent.foreground)
                }
                let clearBackground = try backgrounds(theme, overlay: state == "rest" ? nil : OrbitTokens.Color.State.standaloneButton,
                                                       appearance: appearance)
                try check(theme: theme, [clear.attributedLabel.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor],
                          minimum: 3, backgrounds: clearBackground, appearance: appearance, context: "\(name) Clear \(state) dark=\(isDark)")
            }
        }
    }
}
}
