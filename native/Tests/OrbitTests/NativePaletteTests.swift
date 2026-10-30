import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Foundation
import Testing
@testable import Orbit

@MainActor
private final class PaletteSyntheticEngine: BrowserEngine {
    let base = SiteSyntheticEngine()
    let kind = BrowserEngineKind.synthetic
    var capabilities: BrowserEngineCapabilities { base.capabilities.union(.persistentProfiles) }
    var extensions: (any BrowserExtensionHost)? { nil }
    func profile(for id: ProfileID) -> BrowserEngineProfile { .init(profileID: id, persistence: .persistent) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<SiteSyntheticSurface>) -> SiteSyntheticSurface {
        base.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async { await base.shutdown() }
}

@MainActor
private final class PaletteHarness {
    let store = BrowserStore()
    let engine = PaletteSyntheticEngine()
    let recorder: BrowserHistoryRecorder
    let profileID: ProfileID
    let spaceID: SpaceID
    let root: URL
    let router: BrowserWindowRouter<BrowserWindowController<PaletteSyntheticEngine>>
    let registry: BrowserCommandRegistry<BrowserWindowController<PaletteSyntheticEngine>>
    var window: BrowserWindowController<PaletteSyntheticEngine> { router.selectedWindow! }

    init(openStore: BrowserHistoryStoreOpener? = nil) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("orbit-palette-synthetic-\(UUID())")
        recorder = BrowserHistoryRecorder(directory: root, resolveProfile: { .init(profileID: $0, persistence: .persistent) },
                                          openStore: openStore ?? { try BrowserHistoryStore(profileID: $0, policy: .persistent, directory: $1) })
        profileID = await store.createProfile(name: "Palette synthetic")
        spaceID = try await store.createSpace(name: "Palette", profileID: profileID)
        let store = store, engine = engine, space = spaceID, history = recorder
        router = BrowserWindowRouter(create: { id in
            let controller = BrowserWindowController(id: id, store: store, spaceID: space, engine: engine, history: history, onClose: {}, onActivate: {})
            controller.session.onError = { _ in }
            await controller.session.waitForPendingCommands()
            return controller
        }, present: { _, _ in }, dispose: { $0.palette.dismiss(returnFocus: false); $0.window?.close() })
        registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() })
        BrowserWindowCommands.install(in: registry)
        _ = router.newWindow()
        await router.waitForPendingCommands()
    }
    func show(_ mode: BrowserPaletteMode = .newTab) async {
        _ = registry.dispatch(mode == .newTab ? .newTab : .openCommandBar, origin: .keyboard)
        await router.waitForPendingCommands()
        await window.palette.waitForResults()
    }
    func settle() async {
        for controller in router.windows.values { await controller.palette.waitForAcceptance() }
        await router.waitForPendingCommands()
        for controller in router.windows.values { await controller.session.waitForPendingCommands() }
        await recorder.flush()
    }
    func close() async throws {
        router.shutdown()
        try await recorder.close()
        try? FileManager.default.removeItem(at: root)
    }
}

extension NativeWebKitTests {
@Suite("Native command palette", .serialized)
@MainActor
struct NativePaletteTests {
    @Test("The first palette render uses known sidebar pixels only from the captured profile")
    func knownIconOnFirstRender() async throws {
        let h = try await PaletteHarness()
        let home = URL(string: "https://cached.synthetic.test/")!
        h.window.session.openTab(url: home)
        await h.settle()
        let pixels = try #require(BrowserFaviconImage(sourceURL: home, png: NativeFaviconReceiptTests.png()))
        let image = try #require(await pixels.nativeImage())
        h.window.sidebarIcons.memoryCache.put(image, profile: ProfileID(), home: home)
        h.window.palette.registry = h.registry
        h.window.palette.present(.newTab)
        h.window.palette.query("cached")
        let first = try #require(h.window.palette.results.first { $0.url == home })
        #expect(h.window.palette.view.favicons[first.id] == nil)
        h.window.sidebarIcons.memoryCache.put(image, profile: h.profileID, home: home)
        h.window.palette.query("cached")
        #expect(h.window.palette.view.favicons[first.id] === image)
        let search = try #require(h.window.palette.results.first { $0.section == .search })
        let searchURL = try #require(search.url)
        h.window.sidebarIcons.memoryCache.put(image, profile: h.profileID, home: searchURL)
        h.window.palette.query("cached")
        #expect(h.window.palette.view.favicons[search.id] == nil)
        try await h.close()
    }
    @Test("Split creation opens an empty address draft and navigates the new pane only",
          arguments: [BrowserCommandOrigin.menu, .keyboard, .palette])
    func splitAddressDraft(_ origin: BrowserCommandOrigin) async throws {
        let h = try await PaletteHarness()
        h.window.submitAddress("https://split.test/source")
        await h.settle()
        let source = try #require(h.window.session.selectedSurface)
        if origin == .palette {
            await h.show()
            h.window.palette.query("Add Split View")
            await h.window.palette.waitForResults()
            let index = try #require(h.window.palette.results.firstIndex { $0.action == .command(.addSplitView) })
            h.window.palette.move(index - h.window.palette.selection.index)
            h.window.palette.accept()
        } else {
            #expect(h.registry.dispatch(.addSplitView, origin: origin))
        }
        await h.settle()
        await h.window.palette.waitForResults()
        let target = try #require(h.window.session.selectedSurface)
        #expect(target !== source)
        #expect(h.window.session.activeSplit?.tabs.count == 2)
        #expect(h.window.palette.isPresented)
        #expect(h.window.palette.mode == .currentTab)
        #expect(h.window.palette.view.input.stringValue.isEmpty)
        #expect(!h.window.palette.results.contains { if case .command = $0.action { true } else { false } })
        #expect(!h.window.palette.results.contains { $0.url?.absoluteString == "about:blank" })
        h.window.palette.query("https://split.test/target")
        await h.window.palette.waitForResults()
        h.window.palette.accept()
        await h.settle()
        #expect(target.navigationState.url?.absoluteString == "https://split.test/target")
        #expect(source.navigationState.url?.absoluteString == "https://split.test/source")
        #expect(h.window.session.activeSplit?.tabs.count == 2)
        try await h.close()
    }

    @Test("Command-T opens instantly without creating a tab; Escape cancels; repeated shortcut toggles")
    func presentation() async throws {
        let h = try await PaletteHarness()
        let count = h.window.session.snapshot?.tabs.count
        await h.show()
        #expect(h.window.palette.isPresented)
        #expect(h.registry.activeScope == .palette)
        #expect(h.window.session.snapshot?.tabs.count == count)
        #expect(h.window.window?.isVisible == false)
        #expect(h.window.palette.view.input.stringValue == "")
        h.window.palette.dismiss()
        #expect(!h.window.palette.isPresented)
        await h.show(); await h.show()
        #expect(!h.window.palette.isPresented)
        try await h.close()
    }

    @Test("Command-L edits the current URL; Return replaces; Command-Return creates a tab")
    func addressModes() async throws {
        let h = try await PaletteHarness()
        h.window.session.openTab(url: URL(string: "https://original.test/")!)
        await h.settle()
        let occurrence = h.window.session.snapshot?.selectedOccurrenceID
        await h.show(.currentTab)
        #expect(h.window.palette.view.input.stringValue == "https://original.test/")
        h.window.palette.query("https://replacement.test/")
        h.window.palette.accept()
        await h.settle()
        #expect(h.window.session.snapshot?.selectedOccurrenceID == occurrence)
        #expect(h.window.session.selectedSurface?.currentURL?.host == "replacement.test")
        await h.show(.currentTab)
        h.window.palette.query("https://new-tab.test/")
        h.window.palette.accept(modifiers: [.command])
        await h.settle()
        #expect(h.window.session.snapshot?.selectedOccurrenceID != occurrence)
        #expect(h.window.session.selectedSurface?.currentURL?.host == "new-tab.test")
        #expect(try await h.recorder.suggestions(for: h.profileID, query: "replacement").first?.typedCount == 1)
        #expect(try await h.recorder.suggestions(for: h.profileID, query: "new-tab").first?.typedCount == 1)
        try await h.close()
    }

    @Test("Command-Return on an existing tab opens its URL as a new tab in the source window")
    func commandReturnExistingTab() async throws {
        let h = try await PaletteHarness()
        h.window.session.openTab(url: URL(string: "https://existing.test/")!)
        await h.settle()
        let existing = h.window.session.selectedSurface
        h.window.session.openTab(url: URL(string: "https://second.test/")!)
        await h.settle()
        let count = h.window.session.snapshot?.tabs.count ?? 0
        await h.show()
        h.window.palette.query("existing")
        #expect(h.window.palette.results.first?.section == .tabs)
        h.window.palette.accept(modifiers: .command)
        await h.settle()
        #expect(h.window.session.snapshot?.tabs.count == count + 1)
        #expect(h.window.session.selectedSurface?.currentURL?.host == "existing.test")
        #expect(h.window.session.selectedSurface !== existing)
        try await h.close()
    }

    @Test("Switching uses the existing live surface and commands execute through the captured registry")
    func switchAndCommand() async throws {
        let h = try await PaletteHarness()
        h.window.session.openTab(url: URL(string: "https://existing.test/")!)
        await h.settle()
        let existing = h.window.session.selectedSurface
        h.window.session.openTab(url: URL(string: "https://second.test/")!)
        await h.settle()
        await h.show()
        h.window.palette.query("existing")
        await h.window.palette.waitForResults()
        #expect(h.window.palette.results.first?.section == .tabs)
        h.window.palette.accept()
        await h.settle()
        #expect(h.window.session.selectedSurface === existing)
        await h.show()
        h.window.palette.query("Sidebar")
        await h.window.palette.waitForResults()
        let commandIndex = try #require(h.window.palette.results.firstIndex { $0.section == .commands })
        h.window.palette.move(commandIndex - h.window.palette.selection.index)
        let wasVisible = h.window.isSidebarShown
        h.window.palette.accept()
        await h.settle()
        #expect(h.window.isSidebarShown != wasVisible)
        try await h.close()
    }

    @Test("New-tab drafts survive selection changes; option-return stays inactive")
    func staleAndModifiers() async throws {
        let h = try await PaletteHarness()
        await h.show()
        h.window.palette.query("https://target.test/")
        h.window.palette.accept(modifiers: [.option])
        #expect(h.window.palette.isPresented)
        h.window.session.openTab(url: URL(string: "https://unrelated.test/")!)
        await h.settle()
        #expect(h.window.palette.isPresented)
        #expect(h.window.palette.view.input.stringValue == "https://target.test/")
        let unrelated = h.window.session.selectedSurface
        let tabCount = h.window.session.snapshot?.tabs.count ?? 0
        h.window.palette.accept()
        await h.settle()
        #expect(h.window.session.selectedSurface?.currentURL?.host == "target.test")
        #expect(h.window.session.snapshot?.tabs.count == tabCount + 1)
        #expect(unrelated?.currentURL?.host == "unrelated.test")
        try await h.close()
    }

    @Test("Arrow and Tab cycling wrap; marked text keeps IME commands; rows expose accessibility labels")
    func inputAndAccessibility() {
        var selection = BrowserPaletteSelection()
        selection.move(-1, count: 3); #expect(selection.index == 2)
        selection.move(1, count: 3); #expect(selection.index == 0)
        selection.move(1, count: 0); #expect(selection.index == 0)
        let view = BrowserPaletteView(frame: NSRect(x: 0, y: 0, width: 1024, height: 640))
        var moves: [Int] = []
        var accepts = 0
        var dismisses = 0
        view.onMove = { moves.append($0) }; view.onAccept = { _ in accepts += 1 }; view.onDismiss = { dismisses += 1 }
        let text = NSTextView()
        #expect(view.control(view.input, textView: text, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(view.control(view.input, textView: text, doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        #expect(moves == [1, -1])
        text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.control(view.input, textView: text, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!view.control(view.input, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(accepts == 0 && dismisses == 0)
        text.unmarkText()
        #expect(view.control(view.input, textView: text, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(dismisses == 1)
        #expect(view.input.accessibilityLabel() == "Search or Enter URL")
        let rect = BrowserPaletteView.panelFrame(in: NSSize(width: 1024, height: 640))
        #expect(rect == NSRect(x: 129.5, y: 151.5, width: 765, height: 328))
        let small = BrowserPaletteView.panelFrame(in: NSSize(width: 600, height: 400))
        #expect(small.maxX <= 600 && small.maxY <= 400)
    }
    @Test("Profile-scoped sources switch across Spaces and windows, and restore archived identities")
    func sourceScopes() async throws {
        let h = try await PaletteHarness()
        let first = h.window
        first.session.openTab(url: URL(string: "https://across-space.test/")!)
        await h.settle()
        let existing = first.session.selectedSurface
        let otherSpace = try await h.store.createSpace(name: "Other Space", profileID: h.profileID)
        first.session.refreshCatalog()
        await h.settle()
        first.session.activateSpace(otherSpace)
        await h.settle()
        await h.show()
        first.palette.query("across-space")
        await first.palette.waitForResults()
        first.palette.accept()
        await h.settle()
        #expect(first.session.snapshot?.activeSpaceID == h.spaceID)
        #expect(first.session.selectedSurface === existing)
        _ = h.router.newWindow()
        await h.settle()
        let second = h.window
        await h.show()
        second.palette.query("across-space")
        await second.palette.waitForResults()
        #expect(second.palette.results.first?.scopePriority == 2)
        second.palette.accept()
        await h.settle()
        #expect(first.session.selectedSurface === existing)
        #expect(second.session.selectedSurface !== existing)
        #expect(first.window?.isVisible == false)
        first.session.closeSelectedTab()
        await h.settle()
        let archived = try #require(await first.session.archivedTabs().value.first?.id)
        await h.show()
        second.palette.query("across-space")
        await second.palette.waitForResults()
        let index = try #require(second.palette.results.firstIndex { $0.section == .archive })
        second.palette.move(index - second.palette.selection.index)
        second.palette.accept()
        await h.settle()
        #expect(second.session.organization?.selectedTab?.id == archived)
        try await h.close()
    }

    @Test("Async history selects the best match until the user moves; search pages are not typed")
    func defaultSelectionAndSearchIntent() async throws {
        let h = try await PaletteHarness()
        _ = try await h.recorder.importDocument(.init(profileID: h.profileID, visits: (0..<60).map {
            .init(url: URL(string: "https://different\($0).test/")!, title: "Reference letter e \($0)", typedCount: 1)
        }))
        await h.show()
        h.window.palette.query("e")
        await h.window.palette.waitForResults()
        #expect(h.window.palette.results.first?.section == .history)
        #expect(h.window.palette.selection.index == 0)
        #expect(h.window.palette.results.last?.id == "search")
        let search = try #require(h.window.palette.results.firstIndex { $0.id == "search" })
        h.window.palette.move(search)
        h.window.palette.query("e", preserveSelection: true, userInitiated: false)
        await h.window.palette.waitForResults()
        #expect(h.window.palette.results[h.window.palette.selection.index].id == "search")
        h.window.palette.accept()
        await h.settle()
        #expect(h.window.session.selectedSurface?.currentURL?.host == "www.google.com")
        let recordedSearch = try await h.recorder.suggestions(for: h.profileID, query: "google")
        #expect(!recordedSearch.isEmpty)
        #expect(recordedSearch.allSatisfy { $0.typedCount == 0 })
        try await h.close()
    }

    @Test("Redirects do not close address editing; pending commands defer opening and acceptance")
    func pendingAndRedirects() async throws {
        let h = try await PaletteHarness()
        h.window.session.openTab(url: URL(string: "https://initial.test/")!)
        await h.settle()
        await h.show(.currentTab)
        let original = try #require(h.window.session.selectedSurface)
        h.window.palette.query("https://edited.test/")
        original.navigate(to: URL(string: "https://redirected.test/")!)
        await h.settle()
        #expect(h.window.palette.isPresented)
        #expect(h.window.palette.view.input.stringValue == "https://edited.test/")
        h.window.palette.accept()
        await h.settle()
        #expect(h.window.session.selectedSurface === original)
        #expect(original.currentURL?.host == "edited.test")
        h.window.session.closeSelectedTab()
        _ = h.registry.dispatch(.newTab, origin: .keyboard)
        await h.router.waitForPendingCommands()
        #expect(h.window.palette.isPresented)
        h.window.palette.query("https://after-close.test/")
        h.window.palette.accept()
        await h.settle()
        #expect(h.window.session.selectedSurface?.currentURL?.host == "after-close.test")
        try await h.close()
    }

    @Test("Command-L closes when its selected tab is replaced and reopens with the new URL")
    func replacedAddressTarget() async throws {
        let h = try await PaletteHarness()
        await h.show(.currentTab)
        h.window.palette.query("https://retained-draft.test/")
        h.window.session.openTab(url: URL(string: "https://replacement-tab.test/")!)
        h.window.palette.accept()
        await h.settle()
        #expect(!h.window.palette.isPresented)
        #expect(h.window.session.selectedSurface?.currentURL?.host == "replacement-tab.test")
        await h.show(.currentTab)
        #expect(h.window.palette.view.input.stringValue == "https://replacement-tab.test/")
        h.window.palette.query("https://replacement-edited.test/")
        h.window.palette.accept()
        await h.settle()
        #expect(h.window.session.selectedSurface?.currentURL?.host == "replacement-edited.test")
        #expect(!h.window.palette.isPresented)
        try await h.close()
    }

    @Test("Command-L selection-changing acceptance finishes before dismissing and never cancels itself")
    func addressSelectionAcceptance() async throws {
        let h = try await PaletteHarness()
        let controller = h.window
        controller.session.openTab(url: URL(string: "https://first.accept-palette.test/")!)
        await h.settle()
        let first = try #require(controller.session.selectedSurface)
        controller.session.openTab(url: URL(string: "https://archive.accept-palette.test/")!)
        await h.settle()
        controller.session.closeSelectedTab()
        controller.session.openTab(url: URL(string: "https://current.accept-palette.test/")!)
        await h.settle()
        var visibleDuringAcceptance: [Bool] = []
        let render = controller.session.onChange
        controller.session.onChange = {
            render?()
            if controller.palette.isAccepting { visibleDuringAcceptance.append(controller.palette.isPresented) }
        }
        await h.show(.currentTab)
        controller.palette.query("https://first.accept-palette.test/")
        await controller.palette.waitForResults()
        let switchRow = try #require(controller.palette.results.firstIndex { if case .tab = $0.action { return true }; return false })
        controller.palette.view.onSelect?(switchRow)
        await h.settle()
        #expect(controller.session.selectedSurface === first)
        #expect(!controller.palette.isPresented)
        await h.show(.currentTab)
        controller.palette.query("https://archive.accept-palette.test/")
        await controller.palette.waitForResults()
        let archiveRow = try #require(controller.palette.results.firstIndex { if case .archive = $0.action { return true }; return false })
        controller.palette.view.onSelect?(archiveRow)
        await h.settle()
        #expect(controller.session.selectedSurface?.currentURL?.host == "archive.accept-palette.test")
        #expect(!controller.palette.isPresented)
        let before = controller.session.snapshot?.tabs.count ?? 0
        await h.show(.currentTab)
        controller.palette.query("https://new.accept-palette.test/")
        controller.palette.accept(modifiers: .command)
        await h.settle()
        #expect(controller.session.snapshot?.tabs.count == before + 1)
        #expect(controller.session.selectedSurface?.currentURL?.host == "new.accept-palette.test")
        #expect(!controller.palette.isPresented)
        #expect(!visibleDuringAcceptance.isEmpty && visibleDuringAcceptance.allSatisfy { $0 })
        try await h.close()
    }

    @Test("Command-L closes when its current Space changes within the profile")
    func addressSpaceChange() async throws {
        let h = try await PaletteHarness()
        h.window.session.openTab(url: URL(string: "https://space-source.test/")!)
        await h.settle()
        await h.show(.currentTab)
        let space = try await h.store.createSpace(name: "Other synthetic Space", profileID: h.profileID)
        h.window.session.activateSpace(space)
        await h.settle()
        #expect(!h.window.palette.isPresented)
        #expect(h.window.session.paletteContext?.spaceID == space)
        try await h.close()
    }

    @Test("Command-L closes after a peer window archives its selected tab")
    func addressPeerArchive() async throws {
        let h = try await PaletteHarness()
        let source = h.window
        source.session.openTab(url: URL(string: "https://kept.peer-palette.test/")!)
        source.session.openTab(url: URL(string: "https://closed.peer-palette.test/")!)
        await h.settle()
        let archived = try #require(source.session.organization?.selectedTab?.id)
        await h.show(.currentTab)
        source.palette.query("https://stale.peer-palette.test/")
        _ = h.router.newWindow()
        await h.router.waitForPendingCommands()
        h.window.session.archiveTabs([archived])
        await h.settle()
        source.session.synchronizeOrganization()
        await h.settle()
        #expect(!source.palette.isPresented)
        #expect(source.session.selectedSurface?.currentURL?.host == "kept.peer-palette.test")
        #expect(source.session.snapshot?.tabs.contains { $0.url.host == "stale.peer-palette.test" } == false)
        try await h.close()
    }

    @Test("A queued Library request cannot replace a newer palette presentation or its draft")
    func queuedLibraryBeforePalette() async throws {
        let h = try await PaletteHarness()
        h.window.palette.registry = h.registry
        let gate = PaletteExecutionGate()
        let blocker = Task.detached { await h.store.holdPaletteExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        h.window.showLibrary(.history)
        h.window.palette.present(.newTab)
        h.window.palette.query("newer palette intent")
        #expect(h.window.palette.isPresented)
        gate.release()
        await blocker.value
        await h.settle()
        await h.window.palette.waitForResults()
        #expect(h.window.palette.isPresented)
        #expect(!h.window.library.isPresented)
        #expect(h.window.palette.view.input.stringValue == "newer palette intent")
        try await h.close()
    }

    @Test("Presenting and accepting the palette hide the Library, including another destination window")
    func libraryVisibility() async throws {
        let h = try await PaletteHarness()
        h.window.showLibrary(.history)
        await h.window.session.waitForPendingCommands()
        #expect(h.window.library.isPresented)
        await h.show()
        #expect(!h.window.library.isPresented)
        h.window.showLibrary(.history)
        await h.window.session.waitForPendingCommands()
        #expect(h.window.library.isPresented && !h.window.palette.isPresented)
        await h.show()
        #expect(!h.window.library.isPresented)
        h.window.palette.query("https://library-accept.test/")
        h.window.palette.accept()
        await h.settle()
        #expect(!h.window.library.isPresented)
        #expect(h.window.session.selectedSurface?.currentURL?.host == "library-accept.test")
        let source = h.window
        _ = h.router.newWindow()
        await h.router.waitForPendingCommands()
        let destination = h.window
        destination.session.openTab(url: URL(string: "https://library-destination.test/")!)
        await h.settle()
        source.palette.present(.newTab)
        await source.palette.waitForResults()
        source.palette.query("https://library-destination.test/")
        await source.palette.waitForResults()
        let row = try #require(source.palette.results.firstIndex { result in
            if case .tab(_, let window, _) = result.action { return window == destination.id }
            return false
        })
        destination.showLibrary(.history)
        await destination.session.waitForPendingCommands()
        source.palette.view.onSelect?(row)
        await h.settle()
        #expect(!source.library.isPresented && !destination.library.isPresented)
        #expect(destination.session.selectedSurface?.currentURL?.host == "library-destination.test")
        try await h.close()
    }

    @Test("Command-L waits for queued selection and recomputes the displayed URL before Return")
    func queuedAddressSelection() async throws {
        let h = try await PaletteHarness()
        h.window.session.openTab(url: URL(string: "https://old-tab.test/")!)
        await h.settle()
        let gate = PaletteExecutionGate()
        let blocker = Task.detached { await h.store.holdPaletteExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        h.window.session.openTab(url: URL(string: "https://queued-tab.test/")!)
        _ = h.registry.dispatch(.openCommandBar, origin: .keyboard)
        await h.router.waitForPendingCommands()
        #expect(h.window.session.hasPendingCommands)
        #expect(h.window.palette.isPresented)
        h.window.palette.accept()
        gate.release()
        await blocker.value
        await h.settle()
        #expect(h.window.session.selectedSurface?.currentURL?.host == "queued-tab.test")
        try await h.close()
    }

    @Test("Editing revokes an uncommitted Return and retains the newer draft")
    func editWhileAcceptQueued() async throws {
        let h = try await PaletteHarness()
        await h.show()
        let gate = PaletteExecutionGate()
        let blocker = Task.detached { await h.store.holdPaletteExecutor(gate) }
        await gate.waitUntilEntered()
        defer { gate.release() }
        h.window.session.openTab(url: URL(string: "https://prior-queued.test/")!)
        h.window.palette.query("https://obsolete-draft.test/")
        h.window.palette.accept()
        await Task.yield()
        h.window.palette.query("https://newer-draft.test/")
        gate.release()
        await blocker.value
        await h.settle()
        #expect(h.window.palette.isPresented)
        #expect(h.window.palette.view.input.stringValue == "https://newer-draft.test/")
        #expect(h.window.session.selectedSurface?.currentURL?.host == "prior-queued.test")
        h.window.palette.accept()
        await h.settle()
        #expect(h.window.session.selectedSurface?.currentURL?.host == "newer-draft.test")
        try await h.close()
    }

    @Test("A cold history opener cannot delay acceptance of an explicit destination")
    func acceptBeforeHistoryReady() async throws {
        let gate = PaletteExecutionGate()
        let h = try await PaletteHarness(openStore: { id, root in
            gate.hold()
            return try BrowserHistoryStore(profileID: id, policy: .persistent, directory: root)
        })
        defer { gate.release() }
        _ = h.registry.dispatch(.newTab, origin: .keyboard)
        await h.router.waitForPendingCommands()
        await gate.waitUntilEntered()
        h.window.palette.query("https://immediate.test/")
        h.window.palette.accept()
        await h.window.palette.waitForAcceptance()
        #expect(h.window.session.selectedSurface?.currentURL?.host == "immediate.test")
        #expect(!h.window.palette.isPresented)
        gate.release()
        await h.settle()
        try await h.close()
    }

    @Test("Escape restores the current document and T-to-L retains the original responder")
    func focusIdentity() async throws {
        let h = try await PaletteHarness()
        let controller = h.window
        let oldWindow = try #require(controller.window)
        let hidden = PaletteFocusWindow(contentRect: oldWindow.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        hidden.contentView = oldWindow.contentView
        hidden.delegate = controller
        controller.window = hidden
        let first = try #require(controller.session.selectedSurface)
        #expect(first.focusDocument())
        await h.show()
        _ = h.registry.dispatch(.openCommandBar, origin: .keyboard)
        await h.router.waitForPendingCommands()
        await controller.palette.waitForResults()
        controller.palette.dismiss()
        #expect(hidden.firstResponder === first.documentView)
        await h.show()
        controller.session.openTab(url: URL(string: "https://new-focus.test/")!)
        await h.settle()
        let second = try #require(controller.session.selectedSurface)
        controller.palette.dismiss()
        #expect(hidden.firstResponder === second.documentView)
        await h.show()
        controller.palette.query("Zoom In")
        await controller.palette.waitForResults()
        let zoom = try #require(controller.palette.results.firstIndex { $0.action == .command(.zoomIn) })
        controller.palette.move(zoom - controller.palette.selection.index)
        controller.palette.accept()
        await h.settle()
        #expect(second.pageZoom > 1)
        #expect(hidden.firstResponder === second.documentView)
        controller.showLibrary(.history)
        await controller.session.waitForPendingCommands()
        #expect(controller.library.isPresented)
        await h.show()
        #expect(!controller.library.isPresented)
        controller.palette.dismiss()
        #expect(hidden.firstResponder === second.documentView)
        #expect(!hidden.isVisible)
        #expect(!NSApp.isActive)
        try await h.close()
    }

    @Test("Tab enters site search, URL-like drafts stay scoped and empty Backspace or Escape exits")
    func scopedSiteSearch() async throws {
        let h = try await PaletteHarness()
        await h.show()
        let palette = try #require(h.window.palette)
        let editor = NSTextView()
        palette.query("youtube")
        #expect(palette.view.siteSearchHint?.name == "YouTube")
        #expect(palette.view.control(palette.view.input, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(palette.siteSearch?.name == "YouTube")
        #expect(palette.draft.isEmpty && palette.results.isEmpty)
        palette.query("example.com/a?b=c&d=+é")
        await palette.waitForResults()
        #expect(palette.results.count == 1)
        #expect(palette.results.first?.url?.host == "www.youtube.com")
        #expect(URLComponents(url: try #require(palette.results.first?.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "example.com/a?b=c&d=+é")
        #expect(palette.view.control(palette.view.input, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(palette.isPresented && palette.siteSearch == nil && palette.draft.isEmpty)
        palette.query("Wikipedia")
        #expect(palette.enterSiteSearch())
        #expect(palette.view.control(palette.view.input, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        #expect(palette.siteSearch == nil && palette.isPresented)
        palette.query("github.com")
        #expect(palette.enterSiteSearch())
        palette.query("orbit browser")
        palette.accept()
        await h.settle()
        #expect(!palette.isPresented)
        let url = try #require(h.window.session.selectedSurface?.currentURL)
        #expect(url.host == "github.com" && url.path == "/search")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "orbit browser")
        try await h.close()
    }

    @Test("A persisted user entry uses the built-in Tab handoff and cannot be entered after disabling or deletion")
    func userSiteSearchHandoff() async throws {
        let h = try await PaletteHarness()
        let settings = try BrowserSettingsStore()
        let custom = BrowserSiteSearch(name: "Synthetic Search", shortcut: "lab", template: "https://search.example.test/?q=%s")
        try await settings.saveSiteSearch(custom)
        h.window.palette.siteSearches = await settings.snapshot().siteSearches
        await h.show()
        let palette = try #require(h.window.palette)
        palette.query("lab")
        #expect(palette.view.siteSearchHint == custom)
        #expect(palette.view.control(palette.view.input, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(palette.siteSearch == custom && palette.draft.isEmpty)
        palette.query("café 猫 & #")
        palette.accept()
        await h.settle()
        #expect(h.window.session.selectedSurface?.currentURL == custom.url(for: "café 猫 & #"))
        try await settings.setSiteSearchEnabled(custom.id, false)
        palette.siteSearches = await settings.snapshot().siteSearches
        await h.show()
        palette.query("lab")
        #expect(palette.view.siteSearchHint == nil && !palette.enterSiteSearch())
        try await settings.removeSiteSearch(custom.id)
        palette.siteSearches = await settings.snapshot().siteSearches
        palette.query("lab")
        #expect(!palette.enterSiteSearch())
        try await h.close()
    }

    @Test("First results stay synchronous while 100k history is searched off the main actor")
    func latency100k() async throws {
        let h = try await PaletteHarness()
        let visits = (0..<100_000).map { index in
            BrowserHistoryVisit(url: URL(string: "https://synthetic\(index).test/caf%C3%A9")!,
                                title: "Synthetic résumé document \(index)",
                                visitedAt: Date(timeIntervalSince1970: Double(1_000_000 + index)), typedCount: index % 5)
        }
        #expect(try await h.recorder.importDocument(.init(profileID: h.profileID, visits: visits)) == 100_000)
        await h.show()
        let clock = ContinuousClock()
        var samples: [Double] = []
        var asyncSamples: [Double] = []
        let queries = ["s", "sy", "syn", "synthetic", "café résumé"]
        for index in 0..<60 {
            let query = queries[index % queries.count]
            h.window.palette.query(query)
            if index >= 10 { samples.append(h.window.palette.lastRenderMilliseconds) }
            #expect(!h.window.palette.results.isEmpty)
            await h.window.palette.waitForResults()
            if index >= 10 { asyncSamples.append(h.window.palette.lastAsyncRenderMilliseconds) }
        }
        samples.sort(); asyncSamples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        let asyncP95 = asyncSamples[Int(Double(asyncSamples.count - 1) * 0.95)]
        let typing = ["s", "sy", "syn", "synt", "synth", "synthe", "synthet", "syntheti", "synthetic", "synthetic résumé"]
        var lastKey = clock.now
        let typingStart = clock.now
        for (index, query) in typing.enumerated() {
            let scheduled = typingStart.advanced(by: .milliseconds(index * 40))
            if clock.now < scheduled { try await clock.sleep(until: scheduled) }
            lastKey = clock.now
            h.window.palette.query(query)
        }
        await h.window.palette.waitForResults()
        let final = lastKey.duration(to: clock.now)
        let finalMS = Double(final.components.seconds) * 1000 + Double(final.components.attoseconds) / 1e15
        #expect(h.window.palette.completedQuery == typing.last)
        #expect(h.window.palette.view.input.stringValue == typing.last)
        #expect(h.window.palette.results.contains { $0.id == "search" })
        #expect(h.window.palette.results.allSatisfy { BrowserSuggestionText.matches(typing.last!, title: $0.title, url: $0.url) })
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        print("PALETTE_R2_BENCH configuration=\(configuration) history_pages=100000 warmup=10 iterations=50 first_p50_ms=\(samples[25]) first_p95_ms=\(p95) first_max_ms=\(samples.last!) async_render_p95_ms=\(asyncP95) typing_interval_ms=40 last_key_to_final_ms=\(finalMS) stale_results=false")
        // The product budget is evaluated in release; debug remains a correctness benchmark.
        #if !DEBUG
        #expect(p95 < 8)
        #endif
        try await h.close()
    }

}
}

private final class PaletteExecutionGate: @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    private let semaphore = DispatchSemaphore(value: 0)
    func hold() {
        entered.continuation.yield(())
        entered.continuation.finish()
        #expect(semaphore.wait(timeout: .now() + 10) == .success)
    }
    func release() { semaphore.signal() }
    func waitUntilEntered() async { for await _ in entered.stream { return } }
}
private extension BrowserStore {
    func holdPaletteExecutor(_ gate: PaletteExecutionGate) { gate.hold() }
}

/// Inject only key-window identity; the test never orders or activates the hidden window.
@MainActor
private final class PaletteFocusWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

extension NativeWebKitTests.NativePaletteTests {
    @Test("Suggestion deletion uses the declared shortcut and removes every visit for only the selected URL")
    func deleteHistorySuggestion() async throws {
        let h = try await PaletteHarness()
        let url = URL(string: "https://suggestion.test/remove")!, keep = URL(string: "https://suggestion.test/keep")!
        let visits = [BrowserHistoryVisit(url: url, title: "Suggestion removal"), BrowserHistoryVisit(url: url, title: "Suggestion removal"),
                      BrowserHistoryVisit(url: keep, title: "Suggestion kept")]
        #expect(try await h.recorder.importDocument(.init(profileID: h.profileID, visits: visits)) == 3)
        await h.recorder.prepareSuggestions(for: h.profileID)
        await h.show()
        h.window.palette.query("suggestion")
        await h.window.palette.waitForResults()
        let row = try #require(h.window.palette.results.firstIndex { $0.section == .history && $0.url == url })
        h.window.palette.move(row - h.window.palette.selection.index)
        let shortcut = try #require(h.registry.definition(.removeSuggestion)?.shortcuts.first)
        #expect(shortcut.key == "\u{7f}")
        #expect(shortcut.modifiers.rawValue == NSEvent.ModifierFlags([.command, .option]).rawValue)
        #expect(h.registry.dispatch(.removeSuggestion, origin: .keyboard))
        await h.window.palette.waitForDeletion()
        await h.window.palette.waitForResults()
        #expect(!h.window.palette.results.contains { $0.url == url })
        #expect(try await h.recorder.visits(for: h.profileID).map(\.url) == [keep])
        await h.recorder.prepareSuggestions(for: h.profileID)
        #expect(!h.recorder.cachedSuggestions(for: h.profileID, query: "suggestion").contains { $0.url == url })
        let batches = try await h.recorder.syncBatches(for: h.profileID)
        #expect(Set(batches.flatMap(\.events).compactMap { $0.deletion?.visitID }) == Set(visits.prefix(2).map(\.id)))
        try await h.close()
    }

    @Test("Remote suggestions arrive independently of local rows and deletion hides them for the palette session")
    func remoteSuggestionIntegration() async throws {
        let h = try await PaletteHarness()
        h.window.palette.searchSuggestions = PaletteSuggestionURLProtocol.service()
        await h.show()
        h.window.palette.query("orbit")
        #expect(h.window.palette.results.contains { $0.id == "search" })
        #expect(!h.window.palette.results.contains { $0.remoteSuggestion != nil })
        let selected = h.window.palette.results[h.window.palette.selection.index].id
        await h.window.palette.waitForResults()
        #expect(h.window.palette.results[h.window.palette.selection.index].id == selected)
        let row = try #require(h.window.palette.results.firstIndex { $0.remoteSuggestion == "orbit news" })
        h.window.palette.move(row - h.window.palette.selection.index)
        #expect(h.registry.dispatch(.removeSuggestion, origin: .keyboard))
        #expect(!h.window.palette.results.contains { $0.remoteSuggestion == "orbit news" })
        h.window.palette.dismiss(returnFocus: false)
        await h.show()
        h.window.palette.query("orbit")
        await h.window.palette.waitForResults()
        #expect(!h.window.palette.results.contains { $0.remoteSuggestion == "orbit news" })
        h.window.palette.showsSearchSuggestions = false
        #expect(!h.window.palette.results.contains { $0.remoteSuggestion != nil })
        try await h.close()
    }
}
