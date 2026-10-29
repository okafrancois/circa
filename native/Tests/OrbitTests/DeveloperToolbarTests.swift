import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@Suite("Developer toolbar", .serialized)
@MainActor
struct DeveloperToolbarTests {
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func button(_ id: String, in view: NSView) throws -> NSButton {
        try #require(descendants(view).first { $0.accessibilityIdentifier() == id } as? NSButton)
    }

    @Test("Measured header leaves the document flush below 35 points and removes the inset on hide")
    func cardGeometry() throws {
        let card = BrowserContentCardView()
        let toolbar = BrowserDeveloperToolbar()
        card.setHeader(toolbar)
        #expect(card.headerHeight == 35)
        card.setHeader(toolbar)
        #expect(card.headerHeight == 35)
        card.setHeader(nil)
        #expect(card.headerHeight == 0)
        #expect(toolbar.superview == nil)
    }

    @Test("Real action groups keep their order, route independently, and omit unsupported portrait capture")
    func actions() throws {
        let toolbar = BrowserDeveloperToolbar()
        let ids = descendants(toolbar).compactMap { ($0 as? NSButton)?.accessibilityIdentifier() }
        #expect(ids == ["developer-security", "developer-copy", "developer-capture", "developer-console", "developer-network",
                        "developer-inspect", "developer-extensions", "developer-split"])
        var panels: [BrowserDeveloperPanel] = []
        var captures = 0, extensions = 0, splits = 0, settings = 0
        toolbar.onSiteControls = { settings += 1 }
        toolbar.onPanel = { panels.append($0) }
        toolbar.onCapture = { captures += 1 }
        toolbar.onExtensions = { extensions += 1 }
        toolbar.onSplit = { splits += 1 }
        for id in ids where id != "developer-copy" { try button(id, in: toolbar).performClick(nil) }
        #expect(panels == [.console, .network, .elements])
        #expect(captures == 1 && extensions == 1 && splits == 1 && settings == 1)
        toolbar.update(url: URL(string: "https://www.chess.com/play"), canCapture: false)
        #expect(try button("developer-capture", in: toolbar).isHidden)
        #expect(toolbar.address.stringValue == "https://www.chess.com/play")
        #expect(toolbar.address.font?.pointSize == 9.5)
    }

    @Test("Extension updates preserve cached paint and anchors, reorder pins, and clear badges and removed profiles")
    func extensionUpdates() throws {
        let toolbar = BrowserDeveloperToolbar()
        let icon = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let png = try #require(icon.tiffRepresentation).base64EncodedString()
        let first = BrowserExtensionSummary(id: "first", name: "First", version: "1", isEnabled: true,
                                            hasAction: true, isPinned: true, iconPNGBase64: png, actionBadgeText: "22")
        let second = BrowserExtensionSummary(id: "second", name: "Second", version: "1", isEnabled: true, hasAction: true)
        toolbar.updateExtensions([first, second])
        let anchor = try button("developer-extension-first", in: toolbar)
        let image = try #require(anchor.image)
        let badge = try #require(anchor.subviews.first as? BrowserExtensionBadgeView)
        #expect(badge.text == "22" && !badge.isHidden)
        #expect(badge.intrinsicContentSize.height == 7)
        #expect(badge.hitTest(.zero) == nil)
        var clicked: String?
        toolbar.onExtension = { id, button in clicked = id; #expect(button === anchor) }
        anchor.performClick(nil)
        #expect(clicked == "first")
        var changed = first
        changed.iconPNGBase64 = nil
        changed.actionBadgeText = ""
        toolbar.updateExtensions([second, changed])
        #expect(try button("developer-extension-first", in: toolbar) === anchor)
        #expect(anchor.image === image)
        #expect(badge.isHidden)
        let stack = try #require(anchor.superview as? NSStackView)
        let order = stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.accessibilityIdentifier() }
        #expect(order.firstIndex(of: "developer-extension-second")! < order.firstIndex(of: "developer-extension-first")!)
        toolbar.updateExtensions([])
        #expect(anchor.superview == nil)
    }

    @Test("Legacy engine snapshots decode without fabricated badge state; optional global badge round trips")
    func badgeContract() throws {
        let data = Data(#"[{"id":"sample","name":"Sample","version":"1","isEnabled":true,"hasAction":true}]"#.utf8)
        var item = try #require(JSONDecoder().decode([BrowserExtensionSummary].self, from: data).first)
        #expect(item.actionBadgeText == nil)
        item.actionBadgeText = "22"
        #expect(try JSONDecoder().decode(BrowserExtensionSummary.self, from: JSONEncoder().encode(item)).actionBadgeText == "22")
    }

    @Test("Site tint overrides Space appearance and keeps URL, lock and every action readable")
    func siteTintContrast() throws {
        let toolbar = BrowserDeveloperToolbar()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            toolbar.appearance = NSAppearance(named: appearance)
            for (value, expected) in [(UInt8(0), NSColor.white), (UInt8(255), NSColor.black),
                                      (UInt8(117), NSColor.white), (UInt8(118), NSColor.black)] {
                toolbar.updateTint(.init(red: value, green: value, blue: value))
                toolbar.apply(theme: .default)
                #expect(toolbar.foreground == expected)
                #expect(toolbar.address.textColor == expected)
                for id in ["developer-security", "developer-copy", "developer-console", "developer-network",
                           "developer-inspect", "developer-extensions", "developer-split"] {
                    #expect(try button(id, in: toolbar).contentTintColor == expected)
                }
                let rgb = try #require(toolbar.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
                #expect(abs(rgb.redComponent - CGFloat(value) / 255) < 0.001)
            }
        }
        toolbar.updateTint(nil)
        #expect(toolbar.pageTint == nil)
        #expect(toolbar.layer?.backgroundColor == nil)
        let fill = try #require(toolbar.subviews.first as? OrbitThemeFillView)
        #expect(!fill.isHidden)
        #expect(toolbar.subviews.count == 4) // fill, lock, address, actions; no decorative overlay
    }

    @Test("Rendered edge sampling ignores a minority logo and rejects transparent pixels")
    func renderedEdgeTint() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 64, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        #expect(BrowserPageTint.sampledTopEdge(try #require(context.makeImage())) == nil)
        context.setFillColor(CGColor(srgbRed: 48.0 / 255, green: 46.0 / 255, blue: 43.0 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 1))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 1))
        #expect(BrowserPageTint.sampledTopEdge(try #require(context.makeImage())) == .init(red: 48, green: 46, blue: 43))
        // A full viewport's body cannot outvote its visible top edge.
        var bytes = [UInt8](repeating: 255, count: 64 * 8 * 4)
        for x in 0..<64 { bytes[x * 4] = 48; bytes[x * 4 + 1] = 46; bytes[x * 4 + 2] = 43 }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let viewport = try #require(CGImage(width: 64, height: 8, bitsPerComponent: 8, bitsPerPixel: 32,
                                            bytesPerRow: 256, space: space,
                                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        #expect(BrowserPageTint.sampledTopEdge(viewport) == .init(red: 48, green: 46, blue: 43))
        // Equal arithmetic brightness does not imply equal WCAG luminance.
        #expect(BrowserPageTint(red: 0, green: 0, blue: 255).prefersWhiteForeground)
        #expect(!BrowserPageTint(red: 0, green: 255, blue: 0).prefersWhiteForeground)
    }

    @Test("Engine colour changes repaint the selected toolbar without a title or URL change")
    func liveEngineTint() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.window?.close() }
        owner.submitAddress("https://tint.example.invalid/first")
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        var preferences = BrowserSitePreferences()
        preferences.developerMode = true
        try owner.siteControls.preferences.set(preferences, url: surface.currentURL, profileID: surface.profileID)
        owner.renderDeveloperToolbar()
        #expect(surface.observesPageTint)
        let dark = BrowserPageTint(red: 48, green: 46, blue: 43)
        surface.pageTint = dark
        surface.onChange?()
        #expect(owner.developerToolbar.pageTint == dark)
        surface.navigate(to: URL(string: "https://tint.example.invalid/second")!)
        #expect(owner.developerToolbar.pageTint == dark)
        surface.pageTint = .init(red: 244, green: 240, blue: 232)
        surface.onChange?()
        #expect(owner.developerToolbar.pageTint == surface.pageTint)
        #expect(owner.developerToolbar.foreground == .black)
        surface.pageTint = nil
        surface.onChange?()
        #expect(owner.developerToolbar.pageTint == nil)
        preferences.developerMode = false
        try owner.siteControls.preferences.set(preferences, url: surface.currentURL, profileID: surface.profileID)
        owner.renderDeveloperToolbar()
        #expect(!surface.observesPageTint)
        owner.session.close()
        try await environment.finalize()
    }
}
