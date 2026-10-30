import AppKit
import BrowserCore
import QuartzCore
import Testing
@testable import Orbit

@Suite("Painted Space transition contrast", .serialized)
@MainActor
struct ThemeTransitionContrastTests {
    private func luminance(_ color: NSColor, appearance: NSAppearance) -> CGFloat {
        let c = color.resolved(for: appearance)
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private func composite(_ overlay: NSColor, on fill: NSColor, appearance: NSAppearance) -> NSColor {
        let a = overlay.resolved(for: appearance), b = fill.resolved(for: appearance), p = a.alphaComponent
        return NSColor(srgbRed: a.redComponent * p + b.redComponent * (1 - p),
                       green: a.greenComponent * p + b.greenComponent * (1 - p),
                       blue: a.blueComponent * p + b.blueComponent * (1 - p), alpha: 1)
    }

    private func model(_ hex: UInt32, mode: BrowserSpaceTheme.Mode, legacy: Bool) throws -> BrowserSpaceTheme {
        var model = BrowserSpaceTheme.radial(colors: [.init(hex: hex)], noise: 0, mode: mode)
        if legacy {
            model.paletteVersion = nil
            model.light = .init(stops: [.init(hex: mode == .dark ? 0xEEECEF : hex)])
            model.dark = .init(stops: [.init(hex: mode == .dark ? 0x2C212D : 0x193638)])
        }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        if legacy { json["material"] = "liquidGlass" }
        return try JSONDecoder().decode(BrowserSpaceTheme.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test("Cached and live row ink stays above 3:1 on every mixed-mode transition frame",
          arguments: [false, true], [false, true])
    func contrast(darkSystem: Bool, legacy: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic contrast")
        let first = try await store.createSpace(name: "First", profileID: profile)
        let second = try await store.createSpace(name: "Second", profileID: profile)
        let windowID = try await store.createWindow(activeSpaceID: first)
        for id in [first, second] {
            try await store.activateSpace(id, in: windowID)
            _ = try await store.openTab(url: URL(string: "https://synthetic.invalid/row")!,
                                       from: store.captureContext(in: windowID), activate: true)
            _ = try await store.createFolder(title: "Synthetic project", at: .init(.pinned(id)),
                                              from: store.captureContext(in: windowID))
        }
        let document = await store.sessionDocument(), catalog = await store.catalogSnapshot()
        let original = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: darkSystem ? .darkAqua : .aqua)
        defer { NSApplication.shared.appearance = original }
        // One pair keeps light ink at both endpoints; the other crosses the shared polarity threshold.
        for lightHex: UInt32 in [0x346160, 0xB8F478] {
            let themes = try [model(0x794D91, mode: .dark, legacy: legacy),
                              model(lightHex, mode: .light, legacy: legacy)].map(OrbitSpaceThemes.rendered)
            for reverse in [false, true] {
                let sourceID = reverse ? second : first, targetID = reverse ? first : second
                let source = themes[reverse ? 1 : 0], target = themes[reverse ? 0 : 1]
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
                                      styleMask: [.titled], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                let root = OrbitWindowRootView(frame: NSRect(x: 0, y: 0, width: 600, height: 640))
                window.contentView = root
                let shell = OrbitWindowShell()
                shell.prepare(window: window, root: root)
                shell.apply(theme: source, animated: false)
                let sidebar = BrowserSidebarView(frame: NSRect(x: 0, y: 0, width: 240, height: 640))
                root.addSubview(sidebar)
                sidebar.render(catalog: catalog, activeSpaceID: sourceID, organization: nil)
                sidebar.applyAccent(OrbitSpaceThemes.accent(for: source))
                sidebar.layoutSubtreeIfNeeded()
                sidebar.prepareSpaceSwipeNeighbors(document: document, active: sourceID,
                    resolveTheme: { $0 == first ? themes[0] : themes[1] })
                let preview = try #require(sidebar.preparedSpaceSwipePage(for: targetID))
                let cachedInk = preview.accent.foreground.resolved(for: preview.effectiveAppearance)
                let cachedOverlays = preview.list.tabRows.compactMap { $0.background.fillColor?.resolved(for: preview.effectiveAppearance) }
                #expect(preview.scrollView.superview == nil, "The fixture must exercise a prepainted page")
                let gradient = try #require(shell.themeFill.layer?.sublayers?
                    .flatMap { $0.sublayers ?? [] }.compactMap { $0 as? CAGradientLayer }.first)
                shell.onThemePaint = { sidebar.applyAccent(OrbitSpaceThemes.accent(for: $0)) }
                defer { shell.onThemePaint = nil }
                let content = SpaceSwipePreview.content(document: document, spaceID: targetID, windowID: windowID)
                let space = try #require(document.spaces.first { $0.id == targetID })
                var previousPolarity: Bool?, flips = 0
                for frame in 0...72 {
                    let progress = CGFloat(frame) / 72
                    shell.applySpaceSwipeBlend(.init(source: source, destination: target, progress: progress))
                    sidebar.showSpaceSwipe(offset: (reverse ? 1 : -1) * max(0.000001, progress * sidebar.swipeWidth),
                        space: space, content: content, destinationAccent: OrbitSpaceThemes.accent(for: target))
                    let colors = try #require(gradient.colors as? [CGColor])
                    let fill = try #require(colors.first.flatMap(NSColor.init(cgColor:)))
                    let appearance = sidebar.effectiveAppearance
                    let expected = OrbitThemeForeground.color(on: fill)
                    let polarity = OrbitThemeForeground.isLight(on: expected)
                    let flipped = previousPolarity.map { $0 != polarity } ?? false
                    if flipped { flips += 1 }
                    previousPolarity = polarity
                    let ink: [NSColor]
                    if preview.scrollView.superview == nil {
                        ink = [cachedInk]
                    } else {
                        #expect(preview.scrollView.isDescendant(of: preview))
                        #expect(!preview.list.tabRows.isEmpty && !preview.list.folderRows.isEmpty)
                        ink = [try #require(preview.titleLabel.textColor),
                               try #require(preview.list.newTabRow.label.textColor), try #require(preview.list.newTabRow.subviews.compactMap { $0 as? OrbitGlyphButton }.first).tint]
                            + preview.list.tabRows.flatMap { [$0.titleLabel.textColor!, $0.closeButton.tint] }
                            + preview.list.folderRows.flatMap { [$0.titleLabel.textColor!, $0.glyph.accent.foreground] }
                    }
                    let overlays = preview.scrollView.superview == nil ? cachedOverlays
                        : preview.list.tabRows.compactMap { $0.background.fillColor?.resolved(for: appearance) }
                    for overlay in overlays {
                        let surface = composite(overlay, on: fill, appearance: appearance)
                        let foreground = preview.scrollView.superview == nil ? cachedInk : expected
                        let a = luminance(surface, appearance: appearance), b = luminance(foreground, appearance: appearance)
                        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 3 || flipped,
                                "selected surface at frame \(frame), legacy \(legacy), reverse \(reverse)")
                    }
                    for foreground in ink {
                        let a = luminance(fill, appearance: appearance), b = luminance(foreground, appearance: appearance)
                        let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                        #expect(ratio >= 3 || flipped, "frame \(frame), ratio \(ratio), legacy \(legacy), reverse \(reverse)")
                        #expect(foreground.resolved(for: appearance) == expected)
                    }
                }
                #expect(flips <= 1)
                sidebar.finishSpaceSwipe(committed: nil)
            }
        }
    }
}
