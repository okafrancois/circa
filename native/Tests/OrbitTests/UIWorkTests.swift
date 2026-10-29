import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

@Suite(.serialized)
@MainActor
struct UIWorkTests {
    @Test("Unchanged glyph state stays clean; replacement configuration and appearance repaint")
    func idempotentGlyphState() throws {
        let button = OrbitGlyphButton(glyph: OrbitGlyph.symbol("plus", pointSize: 12), label: "Synthetic button")
        let tint = button.tint, disabled = button.disabledTint
        OrbitUIWorkCounters.enabled = true
        defer { OrbitUIWorkCounters.enabled = false; OrbitUIWorkCounters.reset() }
        OrbitUIWorkCounters.reset()
        button.tint = tint
        button.disabledTint = disabled
        button.isEnabled = button.isEnabled
        button.isHighlighted = button.isHighlighted
        button.glyph = OrbitGlyph.symbol("plus", pointSize: 12)
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] == 0)
        button.glyph = OrbitGlyph.symbol("plus", pointSize: 14)
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] > 0)
        OrbitUIWorkCounters.reset()
        button.isEnabled.toggle()
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] > 0)
        OrbitUIWorkCounters.reset()
        button.viewDidChangeEffectiveAppearance()
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] > 0)
        let image = try #require(button.glyph)
        OrbitUIWorkCounters.reset()
        image.size.width += 1
        button.glyph = image
        #expect(OrbitUIWorkCounters.values["glyphDirty", default: 0] > 0)
    }

    @Test("A title-only tab publication keeps its configured audio symbol and favicon")
    func tabPublication() {
        let id = TabID()
        let row = SidebarTabRow(item: .init(id: id, title: "First", selected: false))
        let audio = row.audioButton.glyph, favicon = row.favicon.image
        row.update(.init(id: id, title: "Second", selected: false), depth: 0)
        #expect(row.titleLabel.stringValue == "Second")
        #expect(row.audioButton.glyph === audio)
        #expect(row.favicon.image === favicon)
        var item = row.item
        item.activity.isAudioMuted = true
        row.update(item, depth: 0)
        #expect(row.audioButton.glyph !== audio)
    }
    @Test("Split rows skip unchanged presentations and clear transient state before reuse")
    func splitReuse() {
        let node = BrowserOrganizationNode.split(SplitGroupID())
        let item = SidebarTabItem(id: TabID(), title: "Split", selected: true,
            splitPanes: [.init(title: "Left", favicon: nil), .init(title: "Right", favicon: nil)])
        let row = SidebarSplitRow(item: item, node: node, depth: 0)
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 36)
        row.layoutSubtreeIfNeeded()
        OrbitUIWorkCounters.enabled = true
        defer { OrbitUIWorkCounters.enabled = false; OrbitUIWorkCounters.reset() }
        OrbitUIWorkCounters.reset()
        for _ in 0..<600 { row.updateSplit(item, node: node, depth: 0) }
        #expect(OrbitUIWorkCounters.values["splitUpdate", default: 0] == 0)
        row.mouseEntered(with: NSEvent())
        row.isPressed = true
        row.beginRename(text: item.title, font: OrbitTokens.Typography.sidebarTabTitle)
        row.resetForReuse()
        #expect(!row.isHovering && !row.isPressed && !row.isRenaming)
        #expect(row.paneCells.allSatisfy { $0.isHidden && $0.label.stringValue.isEmpty && $0.icon.image == nil })
        row.updateSplit(item, node: .split(SplitGroupID()), depth: 1)
        #expect(row.depth == 1 && row.paneCells.count == 2)
        #expect(row.paneCells.map { $0.label.stringValue } == ["Left", "Right"])
        #expect(row.paneCells.allSatisfy { !$0.isHidden })
    }

}
