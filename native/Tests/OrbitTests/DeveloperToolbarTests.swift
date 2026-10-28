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
        #expect(toolbar.address.font?.pointSize == 10)
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
        #expect(badge.intrinsicContentSize.height == 8)
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
}
