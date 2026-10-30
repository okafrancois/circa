import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

/// Production sidebar views only: no browser engine, personal session, visible window or app launch.
extension NativeWebKitTests {
@Suite("Sidebar controls consume theme contrast roles", .serialized)
@MainActor
struct NativeThemeSidebarContrastTests {
    private var distinctiveAccent: OrbitTokens.ThemeAccent {
        var accent = OrbitTokens.ThemeAccent.defaultSpace
        accent.sidebarText = NSColor(srgbRed: 0.91, green: 0.07, blue: 0.32, alpha: 1)
        accent.icon = NSColor(srgbRed: 0.03, green: 0.71, blue: 0.46, alpha: 1)
        return accent
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        view.subviews.flatMap { child -> [T] in
            let matching = (child as? T).map { [$0] } ?? []
            return matching + descendants(child, of: type)
        }
    }

    private func entry(otherWindow: Bool = false, favicon: NSImage? = nil) -> SidebarListEntry {
        let item = SidebarTabItem(id: TabID(), title: "Synthetic tab", selected: false, favicon: favicon,
                                  isPinned: true, isAwayFromPinnedURL: true,
                                  isOpenInAnotherWindow: otherWindow)
        return SidebarListEntry(node: .tab(item.id), section: .pinned, ancestors: [], content: .tab(item))
    }

    private func same(_ actual: NSColor?, _ expected: NSColor, appearance: NSAppearance) -> Bool {
        guard let actual else { return false }
        let a = actual.resolved(for: appearance), b = expected.resolved(for: appearance)
        return zip([a.redComponent, a.greenComponent, a.blueComponent, a.alphaComponent],
                   [b.redComponent, b.greenComponent, b.blueComponent, b.alphaComponent])
            .allSatisfy { abs($0 - $1) < 1e-6 }
    }

    @Test("Live controls, late installations and replacement pages use the supplied accent")
    func sidebarAccentPropagation() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
        sidebar.appearance = appearance
        let address = NSTextField(string: "synthetic.test")
        address.textColor = .systemOrange
        sidebar.addressContainer.installField(address)
        let zoom = NSButton(title: "125%", target: nil, action: nil)
        sidebar.addressContainer.installAccessory(zoom)
        let first = entry(otherWindow: true)
        sidebar.page.render(title: "Synthetic Space", content: .init(entries: [first]), animated: false)
        let accent = distinctiveAccent
        sidebar.applyAccent(accent)

        #expect(same(zoom.contentTintColor, accent.sidebarSecondaryText, appearance: appearance))
        #expect(address.textColor == .systemOrange, "The installed address editor retains its separate styling")
        let lateAccessory = NSButton(image: try #require(OrbitGlyph.otherWindow), target: nil, action: nil)
        sidebar.addressContainer.installAccessory(lateAccessory)
        #expect(same(lateAccessory.contentTintColor, OrbitTokens.Color.Text.secondary, appearance: appearance))
        let lateCustomGlyph = OrbitGlyphButton(glyph: OrbitGlyph.close, label: "Synthetic accessory")
        sidebar.addressContainer.installAccessory(lateCustomGlyph)
        #expect(same(lateCustomGlyph.tint, OrbitTokens.Color.Text.secondary, appearance: appearance))
        try expectControls(sidebar, accent: accent, appearance: appearance)

        // A Space change creates a new page through the real sidebar projection path.
        let profile = ProfileID(), firstSpace = SpaceID(), secondSpace = SpaceID()
        let spaces = [BrowserSpace(id: firstSpace, profileID: profile, name: "First"),
                      BrowserSpace(id: secondSpace, profileID: profile, name: "Second")]
        let catalog = BrowserCatalogSnapshot(profiles: [], spaces: spaces)
        sidebar.render(catalog: catalog, activeSpaceID: firstSpace, organization: nil)
        let previous = sidebar.page
        sidebar.render(catalog: catalog, activeSpaceID: secondSpace, organization: nil)
        #expect(sidebar.page !== previous)
        try expectControls(sidebar, accent: accent, appearance: appearance)
        #expect(sidebar.footer.spaceButtons.count == 2)
        for button in sidebar.footer.spaceButtons {
            #expect(same(button.tint, accent.icon, appearance: appearance))
        }

        var updated = accent
        updated.sidebarText = .systemBlue
        updated.icon = .systemPurple
        sidebar.applyAccent(updated)
        try expectControls(sidebar, accent: updated, appearance: appearance)
        #expect(same(zoom.contentTintColor, updated.sidebarSecondaryText, appearance: appearance))
        #expect(same(lateAccessory.contentTintColor, OrbitTokens.Color.Text.secondary, appearance: appearance))
        #expect(same(lateCustomGlyph.tint, OrbitTokens.Color.Text.secondary, appearance: appearance))
        for button in sidebar.footer.spaceButtons {
            #expect(same(button.tint, updated.icon, appearance: appearance))
        }

        let tooltip = try #require(descendants(sidebar, of: SidebarSpaceTooltip.self).first)
        for label in tooltip.subviews.compactMap({ $0 as? NSTextField }) {
            #expect(label.textColor == NSColor(white: 0.96, alpha: 1), "The Space capsule keeps its observed dark material palette")
        }
        #expect(sidebar.window == nil, "The synthetic view never belongs to a visible window")
    }

    private func expectControls(_ sidebar: BrowserSidebarView, accent: OrbitTokens.ThemeAccent,
                                appearance: NSAppearance) throws {
        let newTab = sidebar.page.list.newTabRow
        let labels = descendants(newTab, of: NSTextField.self)
        #expect(labels.count == 2)
        let label = try #require(labels.first { $0.stringValue == SidebarListStrings.newTab })
        let shortcut = try #require(labels.first { $0.stringValue == "⌘T" })
        #expect(same(label.textColor, accent.foreground, appearance: appearance))
        #expect(same(shortcut.textColor, accent.foreground, appearance: appearance))
        let glyph = try #require(descendants(newTab, of: OrbitGlyphButton.self).first)
        #expect(same(glyph.tint, accent.foreground, appearance: appearance))
        let clear = sidebar.page.list.clearButton.attributedLabel.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(same(clear, accent.sidebarSecondaryText, appearance: appearance))
        let title = try #require(descendants(sidebar.page.list, of: NSTextField.self).first {
            ["Synthetic Space", "First", "Second"].contains($0.stringValue)
        })
        #expect(same(title.textColor, accent.foreground, appearance: appearance))
        let footerAccent = OrbitSpaceThemes.accent(accent, over: [], iconHover: OrbitTokens.Color.State.standaloneButton)
        #expect(same(sidebar.footer.libraryButton.tint, footerAccent.icon, appearance: appearance))
        #expect(same(sidebar.footer.plusButton.tint, footerAccent.icon, appearance: appearance))
    }

    @Test("Other-window titles, placeholder favicons and row actions update with theme and hover")
    func rowAccentAndHover() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let accent = distinctiveAccent
        let original = entry(otherWindow: true)
        var item = try #require(original.tab)
        let row = SidebarTabRow(item: item)
        row.accent = accent
        #expect(same(row.titleLabel.textColor, accent.sidebarSecondaryText, appearance: appearance))
        #expect(same(row.closeButton.tint, accent.icon, appearance: appearance))
        let imageViews = descendants(row, of: NSImageView.self)
        #expect(imageViews.count == 2)
        for image in imageViews { #expect(same(image.contentTintColor, accent.icon, appearance: appearance)) }
        let slash = try #require(descendants(row, of: SidebarPinnedSlashView.self).first)
        #expect(same(slash.tint, accent.icon, appearance: appearance))
        let hover = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        row.mouseEntered(with: hover)
        #expect(same(row.titleLabel.textColor, accent.sidebarText, appearance: appearance))
        row.mouseExited(with: hover)
        #expect(same(row.titleLabel.textColor, accent.sidebarSecondaryText, appearance: appearance))

        // Loaded site artwork keeps its own colours when a row is updated or its theme changes.
        item.favicon = NSImage(size: NSSize(width: 16, height: 16))
        item.isOpenInAnotherWindow = false
        row.update(item, depth: 0)
        let favicon = try #require(imageViews.first { $0.image === item.favicon })
        #expect(favicon.contentTintColor == nil)
        var nextAccent = accent
        nextAccent.icon = .systemPurple
        row.accent = nextAccent
        #expect(favicon.contentTintColor == nil)
        item.favicon = nil
        row.update(item, depth: 0)
        #expect(same(favicon.contentTintColor, nextAccent.icon, appearance: appearance))
        #expect(same(row.titleLabel.textColor, nextAccent.sidebarText, appearance: appearance))
        let disabledTint = row.closeButton.disabledTint
        row.commandsEnabled = false
        #expect(!row.closeButton.isEnabled)
        #expect(row.closeButton.disabledTint == disabledTint, "Disabled controls retain their explicit disabled role")
        #expect(row.window == nil)
    }

    @Test("Rows recycled through the actual list retain the current secondary accent")
    func recycledRowAccent() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let list = SidebarListView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
        let first = entry()
        list.apply(.init(entries: [first]), animated: false)
        let original = try #require(list.row(for: first.node) as? SidebarTabRow)
        list.apply(.empty, animated: false)
        list.accent = distinctiveAccent
        let next = entry(otherWindow: true)
        list.apply(.init(entries: [next]), animated: false)
        let reused = try #require(list.row(for: next.node) as? SidebarTabRow)
        #expect(reused === original)
        #expect(same(reused.titleLabel.textColor, list.accent.sidebarSecondaryText, appearance: appearance))
        #expect(same(reused.closeButton.tint, list.accent.icon, appearance: appearance))
        for image in descendants(reused, of: NSImageView.self) {
            #expect(same(image.contentTintColor, list.accent.icon, appearance: appearance))
        }
        #expect(list.window == nil)
    }

    @Test("Greyscale primary labels and secondary icons share one polarity", arguments: [false, true])
    func greyscaleControlContrast(isDark: Bool) throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let model = try #require(BrowserSpaceThemePresets.theme(family: BrowserSpaceThemePresets.greyscale, index: 7))
        let theme = OrbitSpaceThemes.rendered(model), accent = OrbitSpaceThemes.accent(for: theme)
        let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
        sidebar.appearance = appearance
        let primaryEntry = entry(), secondaryEntry = entry(otherWindow: true)
        sidebar.page.render(title: "Synthetic Space", content: .init(entries: [primaryEntry, secondaryEntry]), animated: false)
        sidebar.applyAccent(accent)
        let primary = try #require(sidebar.page.list.row(for: primaryEntry.node) as? SidebarTabRow)
        let secondary = try #require(sidebar.page.list.row(for: secondaryEntry.node) as? SidebarTabRow)
        // Orbit's fixed-opacity Space/New Tab captions are checked against their measured roles
        // in expectControls; the adaptive contrast contract applies to tab titles and actions.
        let primaryColors = [primary.titleLabel.textColor]
        let secondaryColors = [secondary.titleLabel.textColor,
                               sidebar.page.list.clearButton.attributedLabel.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                               primary.closeButton.tint,
                               sidebar.footer.libraryButton.tint, sidebar.footer.plusButton.tint]
            + descendants(primary, of: NSImageView.self).map(\.contentTintColor)
        let stops = try OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance).map {
            try #require(NSColor(cgColor: $0)?.usingColorSpace(.sRGB))
        }
        for (colors, minimum) in [(primaryColors, CGFloat(4.5)), (secondaryColors, CGFloat(3))] {
            for color in colors {
                let foreground = try #require(color).resolved(for: appearance)
                for background in stops {
                    #expect(foreground == accent.foreground.resolved(for: appearance),
                            "Actual sidebar colour falls below \(minimum), dark=\(isDark)")
                }
            }
        }
        try expectControls(sidebar, accent: accent, appearance: appearance)
        #expect(sidebar.window == nil)
    }

    @Test("Drag preview paints the supplied primary text and secondary placeholder accent")
    func dragPreviewRoles() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let item = entry()
        let accent = distinctiveAccent
        let size = NSSize(width: 240, height: 32)
        func pixels(_ accent: OrbitTokens.ThemeAccent) throws -> Data {
            let image = SidebarDragImage.render(item, size: size, accent: accent, appearance: appearance)
            let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
            return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let original = try pixels(accent)
        var changed = accent
        changed.sidebarText = .black
        #expect(try pixels(changed) != original, "Changing primary alone must change painted drag text")
        changed = accent
        changed.icon = .black
        #expect(try pixels(changed) != original, "Changing secondary alone must change the placeholder")
    }

    @Test("Footer dots paint theme tint and preserve the explicit inactive opacity")
    func footerDotPainting() throws {
        let footer = SidebarFooterView(frame: .zero)
        let profile = ProfileID(), active = SpaceID(), inactive = SpaceID()
        footer.accent = distinctiveAccent
        footer.render(spaces: [BrowserSpace(id: active, profileID: profile, name: "Active"),
                               BrowserSpace(id: inactive, profileID: profile, name: "Inactive")], activeSpaceID: active)
        let appearance = try #require(NSAppearance(named: .aqua))
        for button in footer.spaceButtons {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28,
                                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 28, height: 28))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            appearance.performAsCurrentDrawingAppearance {
                button.customDrawing?(button, NSRect(x: 0, y: 0, width: 28, height: 28))
            }
            NSGraphicsContext.restoreGraphicsState()
            let center = try #require(bitmap.colorAt(x: 14, y: 14)?.usingColorSpace(.sRGB))
            let expected = footer.accent.icon.resolved(for: appearance)
            #expect(abs(center.redComponent - expected.redComponent) < 0.02)
            #expect(abs(center.greenComponent - expected.greenComponent) < 0.02)
            #expect(abs(center.blueComponent - expected.blueComponent) < 0.02)
            let opacity = button.isActive ? CGFloat(1) : OrbitTokens.Metrics.Sidebar.footerInactiveSpaceOpacity
            #expect(abs(center.alphaComponent - opacity) < 0.02, "Inactive dots remain explicit attenuated indicators")
        }
        footer.setCommandsEnabled(false)
        #expect(!footer.libraryButton.isEnabled && !footer.plusButton.isEnabled)
        #expect(footer.spaceButtons.allSatisfy { !$0.isEnabled })
    }

    @Test("Address, toolbar and footer retain one foreground over hover and edit fills", arguments: [false, true])
    func addressAndButtonOverlayContrast(isDark: Bool) async throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        let hover = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        var themes = [BrowserSpaceThemePresets.default]
        for family in BrowserSpaceThemePresets.families {
            for index in family.swatches.indices {
                themes.append(try #require(BrowserSpaceThemePresets.theme(family: family, index: index)))
            }
        }
        func composite(_ overlay: NSColor, _ base: NSColor) -> NSColor {
            let alpha = overlay.alphaComponent
            return NSColor(srgbRed: overlay.redComponent * alpha + base.redComponent * (1 - alpha),
                green: overlay.greenComponent * alpha + base.greenComponent * (1 - alpha),
                blue: overlay.blueComponent * alpha + base.blueComponent * (1 - alpha), alpha: 1)
        }
        for model in themes {
            await Task.yield()
            let theme = OrbitSpaceThemes.rendered(model), accent = OrbitSpaceThemes.accent(for: theme)
            let address = SidebarAddressField(frame: .zero)
            let field = NSTextField(string: "synthetic.test")
            field.placeholderString = "Synthetic placeholder"
            let accessory = NSButton(title: "125%", target: nil, action: nil)
            address.installField(field)
            address.installAccessory(accessory)
            address.accent = accent
            let toolbar = SidebarToolbarRow(frame: .zero)
            let button = OrbitGlyphButton(glyph: OrbitGlyph.reload, label: "Synthetic navigation")
            toolbar.install([button])
            toolbar.accent = accent
            let footer = SidebarFooterView(frame: .zero)
            footer.accent = accent
            let stops = try OrbitThemeGradient.normalizedStops(theme.stops, appearance: appearance).map {
                try #require(NSColor(cgColor: $0)?.usingColorSpace(.sRGB))
            }
            for state in 0..<3 {
                if state == 1 { address.mouseEntered(with: hover) }
                if state == 2 { address.isEditing = true }
                let overlay = (state == 2 ? OrbitTokens.Color.State.tabCurrent
                    : state == 1 ? OrbitTokens.Color.State.sidebarItemHovered : OrbitTokens.Color.State.sidebarItem)
                    .resolved(for: appearance)
                let primary = try #require(field.textColor).resolved(for: appearance)
                let secondary = try #require(accessory.contentTintColor).resolved(for: appearance)
                let placeholder = try #require(field.placeholderAttributedString?.attribute(.foregroundColor, at: 0,
                    effectiveRange: nil) as? NSColor).resolved(for: appearance)
                for stop in stops {
                    let background = composite(overlay, stop)
                    #expect(primary == accent.foreground.resolved(for: appearance), "address state \(state), dark=\(isDark)")
                    #expect(secondary == accent.foreground.resolved(for: appearance))
                    #expect(placeholder == accent.foreground.resolved(for: appearance))
                }
            }
            for color in [button.tint, footer.libraryButton.tint, footer.plusButton.tint] {
                for stop in stops {
                    let foreground = color.resolved(for: appearance)
                    #expect(foreground == accent.foreground.resolved(for: appearance))
                    let background = composite(OrbitTokens.Color.State.standaloneButton.resolved(for: appearance), stop)
                    #expect(foreground == accent.foreground.resolved(for: appearance))
                }
            }
        }
    }

    @Test("Inactive Space dots retain their dimming without making a separate polarity decision", arguments: [false, true])
    func inactiveSpaceDotContrast(isDark: Bool) async throws {
        let appearance = try #require(NSAppearance(named: isDark ? .darkAqua : .aqua))
        for family in BrowserSpaceThemePresets.families {
            for index in family.swatches.indices {
                let model = try #require(BrowserSpaceThemePresets.theme(family: family, index: index))
                let accent = OrbitSpaceThemes.accent(for: OrbitSpaceThemes.rendered(model))
                let opacity = OrbitSpaceThemes.inactiveSpaceIconOpacity(for: accent, appearance: appearance, minimum: 0.45)
                #expect(opacity == 0.45)
                #expect(accent.icon.resolved(for: appearance) == accent.foreground.resolved(for: appearance))
            }
        }
    }

    private func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            func linear(_ value: CGFloat) -> CGFloat {
                value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let a = luminance(foreground), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
}
