import AppKit
@testable import BrowserCore
import Testing
@testable import Orbit

/// Independent source review. This file also compiles against the exact pre-stack base.
/// All views/windows remain hidden; no popup presentation or native event dispatch is used.
extension NativeWebKitTests {
@Suite("UI R1 independent baseline-compatible contracts", .serialized)
@MainActor
struct UIUXR1IndependentBaselineTests {
    @Test("Forty Spaces remain in the footer without a scroll ancestor")
    func allVisibleFooter() {
        let footer = SidebarFooterView()
        let profile = ProfileID()
        let spaces = (0..<40).map { BrowserSpace(id: SpaceID(), profileID: profile, name: "Synthetic \($0)") }
        footer.render(spaces: spaces, activeSpaceID: spaces.last?.id)
        let geometry = OrbitSidebarGeometry.resolve(.init(width: 180, height: 640, spaceCount: spaces.count))
        footer.frame = geometry.footerFrame
        footer.apply(geometry)
        #expect(footer.spaceButtons.allSatisfy { $0.enclosingScrollView == nil })
        #expect(footer.spaceButtons.allSatisfy {
            $0.frame.width > 0 && $0.superview === footer
                && $0.frame.minX >= footer.libraryButton.frame.maxX
                && $0.frame.maxX <= footer.plusButton.frame.minX
        })
    }

    @Test("The actual custom menu preserves Rename, Icon, Theme ordering and captured authority")
    func actualCustomMenuContract() throws {
        let footer = SidebarFooterView()
        let profile = ProfileID()
        let first = BrowserSpace(id: SpaceID(), profileID: profile, name: "Synthetic first")
        let second = BrowserSpace(id: SpaceID(), profileID: profile, name: "Synthetic second")
        footer.render(spaces: [first, second], activeSpaceID: second.id)
        var renamed: [SpaceID] = []
        var selected: [SpaceID] = []
        footer.onRenameSpace = { renamed.append($0) }
        footer.onSelectSpace = { selected.append($0) }
        footer.showContextMenu(for: footer.spaceButtons[0], present: false)
        let menu = try #require(footer.contextMenu)
        #expect(Array(menu.actions.prefix(3).map(\.kind)) == [.rename, .icon, .theme])
        #expect(Array(menu.actions.prefix(3).map(\.title)) == ["Rename Space…", "Change Icon or Emoji…", "Edit Theme Color…"])
        #expect(selected.isEmpty)
        menu.activate(0)
        #expect(renamed == [first.id] && selected.isEmpty)
        footer.render(spaces: [first, second], activeSpaceID: first.id)
        menu.activate(0)
        #expect(renamed == [first.id])
    }

    @Test("Interactive color frames avoid material work but explicit appearance and activation changes still resolve it")
    func incrementalMaterialAndInvalidation() {
        let fill = OrbitThemeFillView(materialRole: .windowShell)
        var source = OrbitTokens.SpaceTheme.amberCoral
        var target = OrbitTokens.SpaceTheme.lavender
        target.surface = source.surface
        source.texture = .grain
        target.texture = .grain
        source.textureIntensity = 0.5
        target.textureIntensity = 0.5
        fill.apply(source)
        var refreshes = 0
        fill.onMaterialChange = { refreshes += 1 }
        for step in 1...4 {
            fill.applyInteractiveTheme(SpaceSwipeThemeBlend(source: source, destination: target, progress: CGFloat(step) / 5).theme)
        }
        #expect(refreshes == 0)
        fill.viewDidChangeEffectiveAppearance()
        #expect(refreshes == 1)
        fill.refreshMaterial()
        #expect(refreshes == 2)
    }
}
}
