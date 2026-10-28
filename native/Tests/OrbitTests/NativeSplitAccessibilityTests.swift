import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeSplitAccessibilityTests {
    private typealias Window = BrowserWindowController<PeekSyntheticEngine>

    private func makeSplitWindow() async throws -> (BrowserEnvironment<PeekSyntheticEngine>, Window) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let window = try await environment.makeWindow()
        window.submitAddress("https://split.test/left")
        await window.session.waitForPendingCommands()
        window.session.addSplitPane(url: URL(string: "https://split.test/right")!)
        await settle(window)
        return (environment, window)
    }

    private func settle(_ window: Window) async {
        await window.session.waitForPendingCommands()
        await Task.yield()
        await window.session.waitForPendingCommands()
        window.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func key(_ code: UInt16, _ type: NSEvent.EventType = .keyDown, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }

    /// A standalone split view with synthetic hosts; no engine, no window.
    private func makeView(_ count: Int = 2, orientation: BrowserSplitOrientation = .horizontal)
        -> (BrowserSplitView, BrowserSplitGroup, [NSView]) {
        let ids = (0..<count).map { _ in TabID() }
        let group = BrowserSplitGroup(tabIDs: ids, orientation: orientation)
        let hosts = ids.map { _ in NSView() }
        let view = BrowserSplitView(frame: CGRect(x: 0, y: 0, width: 1010, height: 600))
        view.present(group, panes: zip(ids, hosts).map { .init(id: $0, view: $1, address: "https://split.test/") },
                     active: ids[0], accent: .defaultPurple)
        view.layoutSubtreeIfNeeded()
        return (view, group, hosts)
    }

    @Test("Pane cycling commands are available in the palette without a keyboard shortcut")
    func cycleCatalog() {
        for id in [BrowserCommandID.focusNextSplitPane, .focusPreviousSplitPane] {
            let definition = OrbitCommandCatalog.actionDefinitions.first { $0.id == id }
            #expect(definition?.shortcuts.isEmpty == true)
            #expect(definition?.owner == "SPLIT")
            #expect(definition?.sources.allSatisfy { $0.hasPrefix("Browser command:") } == true)
            #expect(!OrbitCommandCatalog.declarations.contains { $0.command == id })
        }
    }

    @Test("Next/previous pane commands wrap in layout order and move first responder to the pane")
    func cycleCommands() async throws {
        let (_, window) = try await makeSplitWindow()
        defer { window.session.close(); window.window?.close() }
        let router = BrowserWindowRouter<Window>(create: { _ in window }, present: { _,_ in }, dispose: { _ in })
        _ = router.newWindow(id: window.id)
        await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        let group = try #require(window.session.activeSplit)
        let ids = group.group.tabIDs
        #expect(group.activeTab?.id == ids[1])
        #expect(registry.isEnabled(.focusNextSplitPane))
        #expect(registry.dispatch(.focusNextSplitPane, origin: .menu))
        await settle(window)
        #expect(window.session.activeSplit?.activeTab?.id == ids[0])
        let leftHost = try #require(window.session.selectedSurface?.hostView)
        let responder = try #require(window.window?.firstResponder as? NSView)
        #expect(responder === leftHost || responder.isDescendant(of: leftHost))
        #expect(registry.dispatch(.focusPreviousSplitPane, origin: .menu))
        await settle(window)
        #expect(window.session.activeSplit?.activeTab?.id == ids[1])
        window.session.unsplit(group.group.id)
        await settle(window)
        #expect(!registry.isEnabled(.focusNextSplitPane))
        #expect(!registry.isEnabled(.focusPreviousSplitPane))
    }

    @Test("Pane VoiceOver label is the page title, never the address")
    func paneLabel() async throws {
        let (view, group, hosts) = makeView()
        view.present(group, panes: [
            .init(id: group.tabIDs[0], view: hosts[0], address: "https://secret.test/path?q=1", title: "Left Page"),
            .init(id: group.tabIDs[1], view: hosts[1], address: "https://secret.test/other", title: nil)
        ], active: group.tabIDs[0], accent: .defaultPurple)
        #expect(view.panes[group.tabIDs[0]]?.accessibilityLabel() == "Left Page")
        #expect(view.panes[group.tabIDs[1]]?.accessibilityLabel() == "Untitled")
        #expect(view.panes.values.allSatisfy { $0.accessibilityLabel()?.contains("secret.test") == false })

        let (_, window) = try await makeSplitWindow()
        defer { window.session.close(); window.window?.close() }
        for pane in window.split.view.panes.values {
            #expect(pane.accessibilityLabel()?.contains("split.test") == false)
        }
    }

    @Test("A member without surface keeps its geometry with a placeholder until its host arrives, without reload")
    func placeholder() {
        let (view, group, hosts) = makeView(3)
        let before = group.tabIDs.map { view.panes[$0]!.frame }
        view.present(group, panes: [
            .init(id: group.tabIDs[0], view: hosts[0], address: "a"),
            .init(id: group.tabIDs[1], view: nil, address: "b", title: "Moving"),
            .init(id: group.tabIDs[2], view: nil, address: "c", isOpenInAnotherWindow: true)
        ], active: group.tabIDs[0], accent: .defaultPurple)
        view.layoutSubtreeIfNeeded()
        #expect(view.panes.count == 3)
        #expect(group.tabIDs.map { view.panes[$0]!.frame } == before)
        let waiting = view.panes[group.tabIDs[1]]!, elsewhere = view.panes[group.tabIDs[2]]!
        #expect(waiting.isShowingPlaceholder && elsewhere.isShowingPlaceholder)
        #expect(waiting.accessibilityLabel() == "Moving")
        #expect(waiting.accessibilityHelp() == "Page not loaded yet")
        #expect(elsewhere.accessibilityHelp() == "Open in another window")
        #expect(hosts[1].superview == nil)
        // The live host replaces the placeholder in place; the same host object is adopted.
        view.present(group, panes: zip(group.tabIDs, hosts).map { .init(id: $0, view: $1, address: "x") },
                     active: group.tabIDs[0], accent: .defaultPurple)
        view.layoutSubtreeIfNeeded()
        #expect(!waiting.isShowingPlaceholder)
        #expect(hosts[1].isDescendant(of: waiting))
        #expect(waiting.accessibilityHelp() == nil)
        #expect(group.tabIDs.map { view.panes[$0]!.frame } == before)
    }

    @Test("Dividers are AXSplitters with orientation, label and a percentage value")
    func dividerAccessibility() {
        let (view, _, _) = makeView(3)
        #expect(view.dividers.count == 2)
        let first = view.dividers[0]
        #expect(first.accessibilityRole() == .splitter)
        #expect(first.accessibilityOrientation() == .vertical)
        #expect(first.accessibilityLabel() == "Resize panes 1 and 2")
        #expect((first.accessibilityValue() as? NSNumber)?.intValue == 33)
        #expect((view.dividers[1].accessibilityValue() as? NSNumber)?.intValue == 67)
        #expect(first.canBecomeKeyView)
        let (stacked, _, _) = makeView(2, orientation: .vertical)
        #expect(stacked.dividers[0].accessibilityOrientation() == .horizontal)
    }

    @Test("Arrow keys move the divider live and commit one resize on key release")
    func keyboardResize() {
        let (view, group, _) = makeView()
        var commits: [[Double]] = []
        view.onResize = { commits.append($0) }
        let divider = view.dividers[0]
        let width = view.panes[group.tabIDs[0]]!.frame.width
        divider.keyDown(with: key(124))
        divider.keyDown(with: key(124))
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.panes[group.tabIDs[0]]!.frame.width - (width + 20)) < 0.001)
        #expect(commits.isEmpty)
        divider.keyDown(with: key(123, shift: true))
        view.layoutSubtreeIfNeeded()
        #expect(abs(view.panes[group.tabIDs[0]]!.frame.width - (width - 10)) < 0.001)
        divider.keyUp(with: key(123, .keyUp, shift: true))
        #expect(commits.count == 1)
        #expect(abs(commits[0][0] * 1000 - (500 - 10)) < 0.001)
        #expect(abs(commits[0].reduce(0, +) - 1) < 0.000_001)
        // Up/down do nothing for side-by-side panes.
        divider.keyDown(with: key(125))
        divider.keyUp(with: key(125, .keyUp))
        #expect(commits.count == 1)
    }

    @Test("Home recentres the pair and VoiceOver increment commits immediately")
    func centerAndAccessibilityActions() {
        let ratios = [0.7, 0.3]
        let ids = [TabID(), TabID()]
        let group = BrowserSplitGroup(tabIDs: ids, ratios: ratios)
        let view = BrowserSplitView(frame: CGRect(x: 0, y: 0, width: 1010, height: 600))
        view.present(group, panes: ids.map { .init(id: $0, view: NSView(), address: "") }, active: ids[0], accent: .defaultPurple)
        var commits: [[Double]] = []
        view.onResize = { commits.append($0) }
        let divider = view.dividers[0]
        divider.keyDown(with: key(115))
        divider.keyUp(with: key(115, .keyUp))
        #expect(commits == [[0.5, 0.5]])
        #expect(divider.accessibilityPerformIncrement())
        #expect(commits.count == 2)
        #expect(abs(commits[1][0] - (0.7 + 10.0 / 1000)) < 0.000_001)
        #expect(divider.accessibilityPerformDecrement())
        #expect(commits.count == 3)
    }

    @Test("Editing a Split row's title is refused with feedback and leaves the organization unchanged")
    func splitRenameFeedback() async throws {
        let (_, window) = try await makeSplitWindow()
        defer { window.session.close(); window.window?.close() }
        let original = BrowserSplitFeedback.refuseRename
        defer { BrowserSplitFeedback.refuseRename = original }
        var refusals: [NSWindow?] = []
        BrowserSplitFeedback.refuseRename = { refusals.append($0) }
        let group = try #require(window.session.activeSplit)
        let before = window.session.organization
        window.renameSidebarNode(.split(group.group.id), to: "Research")
        await settle(window)
        #expect(refusals.count == 1)
        #expect(refusals.first.flatMap { $0 } === window.window)
        #expect(window.session.organization == before)
    }
}
}
