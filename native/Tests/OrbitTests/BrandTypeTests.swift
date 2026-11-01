import AppKit
import BrowserCore
import BrowserShell
import Foundation
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct BrandTypeTests {
    @Test("System menu shortcuts retain the prior native width and row baseline")
    func menuShortcutGeometry() throws {
        let row = CreationMenuRow(title: "New Space", symbol: "plus", shortcut: "⌘⇧N", enabled: true,
                                  identifier: "type-shortcut", accent: .defaultSpace)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        row.layoutSubtreeIfNeeded()
        let shortcut = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "⌘⇧N" })
        let text = shortcut.attributedStringValue
        #expect(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == NSFont.systemFont(ofSize: 13))
        #expect(text.attribute(.font, at: 2, effectiveRange: nil) as? NSFont == NSFont.systemFont(ofSize: 13))
        #expect(shortcut.frame.width == shortcut.intrinsicContentSize.width)
        #expect(shortcut.frame.origin.y == 11)
        #expect(shortcut.frame.height == 18)
        #expect(row.bounds.contains(shortcut.frame))
    }

    @Test("Command Bar shortcut runs retain the previous medium system weight")
    func commandShortcutFont() throws {
        let view = BrowserPaletteView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        view.isHidden = false
        view.render([.init(id: "new", title: "New Tab", detail: "Open a new tab", section: .commands,
                           action: .command(.newTab), shortcut: "⌘T")], selected: 0)
        func labels(_ view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? labels($0) }
        }
        let hint = try #require(labels(view).first { $0.stringValue == "⌘T" })
        #expect(hint.attributedStringValue.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
            == NSFont.systemFont(ofSize: 13, weight: .medium))
    }

    @Test("The editor exposes all 36 colors and keeps draft controls while paging")
    func presets() throws {
        var original = BrowserSpaceThemePresets.default
        original.mode = .dark
        original.noise = 0.27
        original.frost = true
        let view = OrbitThemeEditorView(state: .init(theme: original))
        var colors: Set<BrowserThemeColor> = []
        for (page, family) in BrowserSpaceThemePresets.families.enumerated() {
            #expect(view.state.familyIndex == page)
            #expect(!view.previousButton.isHidden && !view.nextButton.isHidden)
            #expect(view.previousButton.isEnabled == (page > 0))
            #expect(view.nextButton.isEnabled == (page < 3))
            let visible = view.swatches.filter { !$0.isHidden }
            #expect(visible.count == 9)
            for (index, swatch) in visible.enumerated() {
                swatch.performClick(nil)
                #expect(view.state.theme.presetID == BrowserSpaceThemePresets.presetID(family: family, index: index))
                #expect(view.state.theme.colors == [family.swatches[index]])
                #expect(view.state.theme.mode == .dark && view.state.theme.noise == 0.27)
                #expect(view.state.theme.frost)
                #expect(swatch.isSelected)
                colors.insert(family.swatches[index])
            }
            let draft = view.state.theme
            view.nextButton.performClick(nil)
            #expect(view.state.theme == draft, "Paging alone never changes the theme")
        }
        #expect(colors.count == 36)
        for _ in 0..<3 { view.previousButton.performClick(nil) }
        #expect(view.state.familyIndex == 0)
    }

    @Test("Opening the editor preserves arbitrary existing theme bytes and never reports a change")
    func existingThemePreserved() throws {
        let gradient = BrowserSpaceTheme.Gradient(stops: [.init(hex: 0x125454), .init(hex: 0x123012)],
                                                 angleDegrees: 37, locations: [0, 1])
        let theme = BrowserSpaceTheme(presetID: "imported.custom", mode: .dark, colors: [],
                                      intensity: 0.43, noise: 0.18, light: gradient, dark: gradient)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(theme)
        let view = OrbitThemeEditorView(state: .init(theme: theme))
        var changes = 0
        view.onChange = { _ in changes += 1 }
        view.spaceName = "Work"
        view.render()
        view.appearance = NSAppearance(named: .darkAqua)
        view.render()
        #expect(try encoder.encode(view.state.theme) == bytes)
        #expect(changes == 0)
        #expect(view.swatches.allSatisfy { !$0.isSelected })
    }

    @Test("Shared UI tokens restore system fonts without moving editor controls")
    func roles() {
        #expect(OrbitTokens.Typography.sidebarTabTitle == NSFont.systemFont(ofSize: 14))
        #expect(OrbitTokens.Typography.sidebarTabTitle.pointSize == 14)
        #expect(OrbitTokens.Typography.menuShortcut == NSFont.systemFont(ofSize: 13))
        #expect(OrbitTokens.Typography.emptyStateTitle == NSFont.systemFont(ofSize: 13, weight: .semibold))
        let editor = OrbitThemeEditorView(state: .init(theme: BrandPalette.spaceGradients[0].theme()))
        #expect(editor.field.frame == OrbitThemeEditorMetrics.field)
        #expect(editor.themeName.font == NSFont.systemFont(ofSize: 18, weight: .semibold))
        #expect(editor.surfaceScope.font == NSFont.systemFont(ofSize: 11, weight: .semibold))
        #expect(editor.themeName.frame.maxY < 522)
    }

    @Test("Audited custom control fills have no fixed blue, purple, orange or coral selection")
    func controlAudit() throws {
        #expect(OrbitTokens.Color.Accent.focusRing == NSColor.controlAccentColor)
        #expect(OrbitTokens.Color.Accent.primaryButton == NSColor.controlAccentColor)
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Orbit")
        for file in ["Boosts/BrowserBoostCodeView.swift", "Boosts/BrowserBoostEditorView.swift",
                     "Boosts/BrowserBoostZapView.swift", "SiteControls/NotificationSettingsPromptView.swift",
                     "Palette/BrowserPaletteView.swift", "Sidebar/SidebarCreationMenu.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for fixed in [".systemBlue", ".systemPurple", ".systemOrange", "BrandPalette.coral"] {
                #expect(!source.contains(fixed), "Fixed control color in \(file)")
            }
        }
    }
}


extension BrandTypeTests {
    @Test("Dialog and empty titles use readable display sizes and remain inside their layouts")
    func titleGeometry() throws {
        let empty = BrowserLibraryEmptyView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        empty.configure(symbol: "tray", title: "No Downloads")
        empty.layoutSubtreeIfNeeded()
        #expect(empty.message.font == NSFont.systemFont(ofSize: 14))
        #expect(empty.message.font?.pointSize == 14)
        #expect(empty.bounds.contains(empty.message.alignmentRect(forFrame: empty.message.frame)))
        #expect(empty.message.frame.height >= empty.message.intrinsicContentSize.height)
        empty.frame.size.height = 164
        empty.configure(symbol: "tray", title: "No Downloads", query: "Synthetic query")
        empty.layoutSubtreeIfNeeded()
        #expect(empty.bounds.contains(empty.message.alignmentRect(forFrame: empty.message.frame)))
        #expect(empty.message.frame.height >= empty.message.intrinsicContentSize.height)
        #expect(OrbitTokens.Typography.emptyStateDetail == NSFont.systemFont(ofSize: 13))
        let alert = OrbitFrostAlert()
        alert.messageText = "Remove this Space?"
        alert.informativeText = "Tabs in this Space will be archived."
        alert.addButton(withTitle: "Cancel")
        let window = alert.preparedWindow()
        defer { window.close() }
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let title = try #require(content.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == alert.messageText })
        let detail = try #require(content.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == alert.informativeText })
        #expect(title.font == NSFont.systemFont(ofSize: 13, weight: .semibold))
        #expect(detail.font == NSFont.systemFont(ofSize: 13))
        #expect(content.bounds.contains(title.frame))
        #expect(title.frame.height >= title.intrinsicContentSize.height)
    }
}
