import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct TabErgonomicsTests {
    private func fixture() async throws -> BrowserWindowController<PeekSyntheticEngine> {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Synthetic tabs")
        let space = try await store.createSpace(name: "First", profileID: profile)
        _ = try await store.createSpace(name: "Second", profileID: profile)
        let owner = BrowserWindowController(id: UUID(), store: store, spaceID: space, engine: PeekSyntheticEngine(),
            onClose: {}, onActivate: {})
        await owner.session.waitForPendingCommands()
        owner.session.openTab(url: URL(string: "http://127.0.0.1/fixture")!)
        await owner.session.waitForPendingCommands()
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        return owner
    }

    private func click(_ owner: BrowserWindowController<PeekSyntheticEngine>, view: NSView,
                       flags: NSEvent.ModifierFlags = [], count: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: owner.window!.windowNumber,
            context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    }

    @Test("Command reload creates a second document and double reload stops the original load")
    func reloadGestures() async throws {
        let owner = try await fixture()
        defer { owner.session.close(); owner.window?.close() }
        let original = try #require(owner.session.selectedSurface)
        let before = owner.session.snapshot!.tabs.count
        #expect(BrowserTabErgonomics.handle(try click(owner, view: owner.reloadButton, flags: .command), in: owner))
        await owner.session.waitForPendingCommands()
        #expect(owner.session.snapshot?.tabs.count == before + 1)
        #expect(owner.session.selectedSurface !== original)
        #expect(owner.session.selectedSurface?.currentURL == original.currentURL)
        let surface = try #require(owner.session.selectedSurface)
        surface.simulatedLoading = true
        #expect(BrowserTabErgonomics.handle(try click(owner, view: owner.reloadButton, count: 2), in: owner))
        await owner.session.waitForPendingCommands()
        #expect(surface.stopCount == 1)
        #expect(!BrowserTabErgonomics.handle(try click(owner, view: owner.reloadButton, count: 2), in: owner))
    }

    @Test("Native duplication adopts one document with independent backward and forward history")
    func duplicateHistory() async throws {
        let owner = try await fixture()
        defer { owner.session.close(); owner.window?.close() }
        let original = try #require(owner.session.selectedSurface)
        original.supportsNativeDuplication = true
        original.navigate(to: URL(string: "http://127.0.0.1/second")!)
        original.navigate(to: URL(string: "http://127.0.0.1/third")!)
        original.goBack()
        let before = owner.session.snapshot!.tabs.count
        owner.duplicateSidebarTab()
        for _ in 0..<20 { await owner.session.waitForPendingCommands(); await Task.yield() }
        let clone = try #require(owner.session.selectedSurface)
        #expect(clone !== original)
        #expect(owner.session.snapshot?.tabs.count == before + 1)
        #expect(clone.navigationState.canGoBack && clone.navigationState.canGoForward)
        clone.goForward()
        #expect(clone.currentURL?.path == "/third")
        #expect(original.currentURL?.path == "/second")
        clone.goBack()
        clone.goBack()
        #expect(clone.currentURL?.path == "/fixture")
    }

    @Test("Escape stops loading but leaves address editing alone")
    func escape() async throws {
        let owner = try await fixture()
        defer { owner.session.close(); owner.window?.close() }
        let surface = try #require(owner.session.selectedSurface)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: owner.window!.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        surface.simulatedLoading = true
        owner.window?.makeFirstResponder(surface.documentView)
        #expect(BrowserTabErgonomics.handle(event, in: owner))
        await owner.session.waitForPendingCommands()
        #expect(surface.stopCount == 1)
        surface.simulatedLoading = true
        let editor = NSTextView()
        owner.window?.contentView?.addSubview(editor)
        owner.window?.makeFirstResponder(editor)
        #expect(!BrowserTabErgonomics.handle(event, in: owner))
    }

    @Test("Side mouse buttons cycle Spaces in both directions")
    func sideButtons() async throws {
        let owner = try await fixture()
        defer { owner.session.close(); owner.window?.close() }
        let first = owner.session.snapshot?.activeSpaceID
        for button in [4, 3] {
            let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                mouseCursorPosition: .zero, mouseButton: CGMouseButton(rawValue: UInt32(button))!))
            let event = try #require(NSEvent(cgEvent: cg))
            #expect(BrowserTabErgonomics.handle(event, in: owner))
            await owner.session.waitForPendingCommands()
            if button == 4 { #expect(owner.session.snapshot?.activeSpaceID != first) }
        }
        #expect(owner.session.snapshot?.activeSpaceID == first)
    }

    @Test("Option copies a sidebar tab into a folder without moving its original")
    func copyDrop() async throws {
        let owner = try await fixture()
        defer { owner.session.close(); owner.window?.close() }
        let original = try #require(owner.session.organization?.selectedTab)
        let before = owner.session.organization!.allTabs.count
        let destination = BrowserOrganizationDestination(.pinned(owner.session.snapshot!.activeSpaceID))
        let folder = try #require(await owner.session.createFolder(title: "Synthetic folder", at: destination).value)
        await owner.session.waitForPendingCommands()
        let payload = SidebarDragPayload(sourceWindow: owner.id, spaceID: owner.session.snapshot!.activeSpaceID,
            profileID: owner.session.activeProfileID!, nodes: [.tab(original.id)], rowCount: 1, grabOffsetX: 0)
        #expect(owner.sidebar.isCopyDrag(payload, modifiers: .option))
        #expect(!owner.sidebar.isCopyDrag(payload, modifiers: []))
        owner.sidebar.onCopyDrop?(payload, .init(.folder(folder)))
        await owner.session.waitForPendingCommands()
        #expect(owner.session.organization?.allTabs.count == before + 1)
        #expect(owner.session.organization?.tab(original.id)?.section == original.section)
        let created = try #require(owner.session.organization?.selectedTab)
        #expect(created.id != original.id)
        #expect(created.url == original.url)
        #expect(owner.session.organization?.location(of: .tab(created.id))?.1 == [folder])
    }

    @Test("External text uses the existing drop feedback and the configured search engine")
    func externalDrop() async throws {
        let owner = try await fixture()
        defer { owner.session.close(); owner.window?.close() }
        owner.addressResolver = AddressResolver(searchEngine: .duckDuckGo)
        let list = owner.sidebar.page.list
        let point = owner.sidebar.convert(NSPoint(x: 100, y: list.bounds.maxY - 10), from: list)
        #expect(!owner.sidebar.updateExternalDrop("javascript:alert(1)", at: point))
        #expect(owner.sidebar.updateExternalDrop("synthetic search", at: point))
        #expect(owner.sidebar.commitExternalDrop())
        #expect(!owner.sidebar.commitExternalDrop())
        await owner.session.waitForPendingCommands()
        #expect(owner.session.selectedSurface?.currentURL == SearchEngine.duckDuckGo.searchURL(for: "synthetic search"))
        owner.sidebar.onTextDrop?("http://127.0.0.1/link", .init(.pinned(owner.session.snapshot!.activeSpaceID)))
        await owner.session.waitForPendingCommands()
        #expect(owner.session.selectedSurface?.currentURL?.path == "/link")
    }

    @Test("Only a double click on empty list space invokes the existing new-tab entry point")
    func emptyList() async throws {
        let owner = try await fixture()
        defer { owner.session.close(); owner.window?.close() }
        var invocations = 0
        owner.sidebar.onNewTab = { invocations += 1 }
        let list = owner.sidebar.page.list
        let point = list.convert(NSPoint(x: 110, y: list.bounds.maxY - 10), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: owner.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        #expect(BrowserTabErgonomics.handle(event, in: owner))
        #expect(invocations == 1)
        let row = try #require(list.row(for: .tab(owner.session.organization!.selectedTab!.id)))
        #expect(!BrowserTabErgonomics.handle(try click(owner, view: row, count: 2), in: owner))
    }

    @Test("Reverse switcher aliases match semantic AZERTY punctuation and Shift Tab")
    func reverseAliases() {
        let definition = OrbitCommandCatalog.definitions.first { $0.id == .tabSwitcherBackward }!
        #expect(definition.shortcuts.contains(.init(key: "`", modifiers: .control)))
        #expect(definition.shortcuts.contains(.init(key: "\t", modifiers: [.control, .shift])))
        // The active layout supplies the glyph; there is no US physical-key binding.
        #expect(BrowserShortcut.input(characters: "`", keyCode: 10, modifiers: .control,
            isComposing: false, isRepeat: false, unmodifiedCharacters: "`") == .init(key: "`", modifiers: .control))
    }
}
}
