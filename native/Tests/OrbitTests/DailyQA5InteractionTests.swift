import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized) @MainActor
struct DailyQA5InteractionTests {
    @Test("Collapsing pins during a painted theme blend preserves ink, selection and the update card")
    func collapseDuringThemeBlend() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer {
            owner.tabSuspension.close(); owner.resources.close(); owner.session.close()
            owner.window?.close(); environment.autoArchive.scheduler.stop()
        }
        owner.openTab(url: URL(string: "https://synthetic.invalid/pinned")!)
        await owner.session.waitForPendingCommands()
        let tab = try #require(owner.session.organization?.selectedTab)
        owner.session.pinTabs([tab.id])
        await owner.session.waitForPendingCommands()
        let sidebar = owner.sidebar
        sidebar.updateReady = true
        sidebar.setFrameSize(.init(width: 200, height: 640))
        let source = OrbitSpaceThemes.rendered(.radial(colors: [.init(hex: 0x794D91)], noise: 0, mode: .dark))
        let destination = OrbitSpaceThemes.rendered(.radial(colors: [.init(hex: 0xB8F478)], noise: 0, mode: .light))
        owner.windowShell.onThemePaint = { sidebar.applyAccent(OrbitSpaceThemes.accent(for: $0)) }
        defer { owner.windowShell.onThemePaint = nil }
        owner.windowShell.apply(theme: source, animated: false)
        for (progress, collapsed) in [(0.25, true), (0.5, false), (0.75, true), (1.0, false)] {
            owner.windowShell.applySpaceSwipeBlend(.init(source: source, destination: destination, progress: progress))
            owner.session.setPinnedSectionCollapsed(collapsed)
            await owner.session.waitForPendingCommands()
            sidebar.layoutSubtreeIfNeeded()
            #expect(owner.session.organization?.selectedTab?.id == tab.id)
            #expect(sidebar.page.disclosure.isCollapsed == collapsed)
            #expect(sidebar.page.disclosure.tint == sidebar.page.accent.foreground)
            #expect(sidebar.updateCard.accent == sidebar.page.accent)
            #expect(!sidebar.updateCard.isHidden)
            #expect(sidebar.updateCard.frame.maxY <= sidebar.footer.frame.minY)
            #expect(sidebar.updateCard.frame.maxX <= sidebar.bounds.maxX)
            #expect(sidebar.page.list.tabRows.allSatisfy { row in
                let ink = row.item.isPinned && row.item.selected
                    ? OrbitTokens.Color.State.pinnedSelectedText : sidebar.page.accent.foreground
                return row.titleLabel.textColor == ink
            })
        }
        let first = try #require(owner.session.snapshot?.activeSpaceID)
        let profile = try #require(owner.session.activeProfileID)
        let second = try await environment.store.createSpace(name: "Synthetic second", profileID: profile)
        owner.session.activateSpace(second)
        await owner.session.waitForPendingCommands()
        #expect(sidebar.updateReady)
        owner.session.activateSpace(first)
        await owner.session.waitForPendingCommands()
        #expect(sidebar.updateReady && owner.session.organization?.selectedTab?.id == tab.id)
        #expect(owner.window?.isVisible == false)
    }
}
}
