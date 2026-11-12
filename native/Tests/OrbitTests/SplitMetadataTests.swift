import AppKit
import Testing
@testable import BrowserCore
@testable import Orbit

extension NativeWebKitTests {
@Suite @MainActor struct SplitMetadataTests {
    @Test("Header metadata preserves pane hosts, divider identity and geometry")
    func headers() throws {
        let ids = [TabID(), TabID()]
        let group = BrowserSplitGroup(tabIDs: ids)
        let hosts = [NSView(), NSView()]
        let view = BrowserSplitView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let original = ids.indices.map { BrowserSplitView.Pane(id: ids[$0], view: hosts[$0], address: "https://synthetic.test/", title: "Initial") }
        view.present(group, panes: original, active: ids[0], accent: .defaultSpace)
        view.layoutSubtreeIfNeeded()
        let divider = try #require(view.dividers.first)
        let panes = ids.compactMap { view.panes[$0] }
        let frames = panes.map(\.frame)
        for n in 0..<100 {
            view.applyMetadata([.init(id: ids[0], view: hosts[0], address: "https://synthetic.test/", title: "Title \(n)", canGoBack: true)], group: group)
        }
        #expect(view.dividers.first === divider)
        #expect(ids.compactMap { view.panes[$0] }.map(\.frame) == frames)
        #expect(view.panes[ids[0]] === panes[0])
        #expect(view.panes[ids[0]]?.accessibilityLabel() == "Title 99")
        #expect(view.panes[ids[0]]?.back.isEnabled == true)
        #expect(hosts.allSatisfy { $0.superview != nil })
    }
}
}
