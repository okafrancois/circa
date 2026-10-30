import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeShortcutCustomizationTests {
    private final class Window {}
    private func event(_ key: String, flags: NSEvent.ModifierFlags = .command, code: UInt16 = 0,
                       time: TimeInterval = 1) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: time, windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    @Test("Removing or remapping Copy URL frees its default character shortcut")
    func copyURLCanBeRemoved() throws {
        let preferences = BrowserShortcutPreferences()
        let definitions = OrbitCommandCatalog.definitions
        let copy = try #require(definitions.first { $0.id == .copyURL })
        let chord = try #require(preferences.bindings(for: copy).first)
        try preferences.setShortcut(nil, for: .copyURL, definitions: definitions)
        #expect(preferences.bindings(for: copy).isEmpty)
        try preferences.setShortcut(chord, for: .sidebarCopyLinks, definitions: definitions)
        try preferences.setShortcut(.init(key: "c", modifiers: [.command, .control, .option]), for: .copyURL, definitions: definitions)
        #expect(preferences.bindings(for: copy).count == 1)
    }

    @Test("Character-based recording survives persistence, updates routing, removes and resets")
    func persistenceAndImmediateRouting() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("shortcuts.json")
        let preferences = BrowserShortcutPreferences(destination: destination)
        let router = BrowserWindowRouter<Window>(create: { _ in Window() }, present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { _ in .init() })
        var calls = 0
        try registry.registerApplication(.showHideSidebar) { calls += 1 }
        registry.useShortcutPreferences(preferences)
        let chord = try #require(BrowserShortcut.recordedInput(event("é", flags: [.command, .option], code: 19)))
        #expect(chord.key == "é")
        try preferences.setShortcut(chord, for: .showHideSidebar, definitions: registry.defaultDefinitions)
        #expect(registry.resolve(try event("é", flags: [.command, .option], code: 19)) == .showHideSidebar)
        #expect(registry.resolve(BrowserShortcut(key: "s", modifiers: .command)) == nil)
        #expect(registry.dispatch(.showHideSidebar, origin: .keyboard))
        #expect(calls == 1)
        let restored = BrowserShortcutPreferences(destination: destination)
        #expect(restored.document == preferences.document)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        try restored.setShortcut(nil, for: .showHideSidebar, definitions: registry.defaultDefinitions)
        registry.useShortcutPreferences(restored)
        #expect(registry.definition(.showHideSidebar)?.shortcuts.isEmpty == true)
        try restored.reset(.showHideSidebar)
        #expect(registry.resolve(BrowserShortcut(key: "s", modifiers: .command)) == .showHideSidebar)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathExtension("backup").path))
    }

    @Test("Retired Quit command identifiers preserve shortcuts and priority without overwriting current choices")
    func quitCommandIdentifierMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("shortcuts.json")
        let previous = "quitPreviousApplication"
        let shortcut = BrowserShortcut(key: "q", modifiers: [.command, .option])
        var document = BrowserShortcutPreferences.Document()
        document.overrides[previous] = [.init(shortcut)]
        document.priorities[previous] = .both
        let original = try JSONEncoder().encode(document)
        try original.write(to: destination)
        let preferences = BrowserShortcutPreferences(destination: destination)
        let definition = try #require(OrbitCommandCatalog.definitions.first { $0.id == .quitOrbit })
        #expect(preferences.bindings(for: definition) == [shortcut])
        #expect(preferences.priority(for: .quitOrbit) == .both)
        #expect(preferences.isCustomized(.quitOrbit))
        #expect(try Data(contentsOf: destination) == original)
        #expect(preferences.document.overrides[previous] == nil)
        document.overrides[BrowserCommandID.quitOrbit.rawValue] = []
        document.priorities[BrowserCommandID.quitOrbit.rawValue] = .browser
        document.normalizeQuitCommandID()
        #expect(document.overrides[BrowserCommandID.quitOrbit.rawValue] == [])
        #expect(document.priorities[BrowserCommandID.quitOrbit.rawValue] == .browser)
    }

    @Test("Conflicts and invalid chords preserve the previous binding; commands without defaults are editable")
    func conflictAndReset() throws {
        let preferences = BrowserShortcutPreferences()
        let definitions = OrbitCommandCatalog.definitions
        #expect(throws: BrowserShortcutPreferenceError.self) {
            try preferences.setShortcut(.init(key: "t", modifiers: .command), for: .duplicate, definitions: definitions)
        }
        #expect(!preferences.isCustomized(.duplicate))
        #expect(throws: BrowserShortcutPreferenceError.self) {
            try preferences.setShortcut(.init(key: "a", modifiers: []), for: .duplicate, definitions: definitions)
        }
        try preferences.setShortcut(.init(key: "é", modifiers: [.command, .control]), for: .duplicate, definitions: definitions)
        #expect(preferences.isCustomized(.duplicate))
        try preferences.setOrdering(includeFavorites: false, nineSelectsLast: false)
        try preferences.setPriority(.both, for: .duplicate)
        try preferences.resetAll()
        #expect(preferences.document == .init())
    }

    @Test("AZERTY character recording detects the default numbered-tab equivalent as a conflict")
    func layoutAdaptedConflicts() throws {
        _ = NSApplication.shared
        let physical = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 19, keyDown: true))
        physical.flags = .maskCommand
        let native = try #require(NSEvent(cgEvent: physical))
        let recorded = try #require(BrowserShortcut.recordedInput(native))
        let preferences = BrowserShortcutPreferences()
        #expect(throws: BrowserShortcutPreferenceError.self) {
            try preferences.setShortcut(recorded, for: .duplicate, definitions: OrbitCommandCatalog.definitions)
        }
        #expect(!preferences.isCustomized(.duplicate))
        try preferences.setShortcut(nil, for: .selectTab2, definitions: OrbitCommandCatalog.definitions)
        try preferences.setShortcut(recorded, for: .duplicate, definitions: OrbitCommandCatalog.definitions)
        #expect(throws: BrowserShortcutPreferenceError.self) { try preferences.reset(.selectTab2) }
        #expect(preferences.document.overrides[BrowserCommandID.selectTab2.rawValue]?.isEmpty == true)
    }

    @Test("A future shortcuts document is preserved rather than overwritten")
    func futureDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("shortcuts.json")
        let data = Data("{\"version\":2}".utf8)
        try data.write(to: path)
        let preferences = BrowserShortcutPreferences(destination: path)
        #expect(preferences.isUnavailable)
        #expect(throws: BrowserShortcutPreferenceError.self) { try preferences.resetAll() }
        #expect(try Data(contentsOf: path) == data)
    }

    @Test("Recorder consumes reserved app keys and captures AZERTY characters without US keycode translation")
    func recorderOwnsReservedKeys() throws {
        _ = NSApplication.shared
        let window = BrowserSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let recorder = BrowserShortcutRecorderView(title: "—", target: nil, action: nil)
        window.contentView = recorder
        var captured: BrowserShortcut?
        recorder.onRecord = { captured = $0 }
        #expect(recorder.accessibilityPerformPress())
        #expect(window.performKeyEquivalent(with: try event("q", code: 12)))
        #expect(captured == .init(key: "q", modifiers: .command))
        #expect(recorder.accessibilityPerformPress())
        #expect(window.performKeyEquivalent(with: try event("é", flags: [.command, .control], code: 19)))
        #expect(captured?.key == "é")
    }

    @Test("Use Both routes the second non-repeat chord to the browser within the same window")
    func websitePriority() throws {
        let router = BrowserWindowRouter<Window>(create: { _ in Window() }, present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { _ in .init() })
        let preferences = BrowserShortcutPreferences()
        registry.useShortcutPreferences(preferences)
        try preferences.setPriority(.both, for: .showHideSidebar)
        #expect(!registry.prefersBrowser(.showHideSidebar))
        #expect(!registry.isSecondWebsiteShortcut(.showHideSidebar, event: try #require(BrowserShortcutEvent(event("s", time: 1)))))
        #expect(registry.isSecondWebsiteShortcut(.showHideSidebar, event: try #require(BrowserShortcutEvent(event("s", time: 1.2)))))
        try preferences.setPriority(.browser, for: .showHideSidebar)
        #expect(registry.prefersBrowser(.showHideSidebar))
        try preferences.setPriority(.websites, for: .newTab)
        #expect(!registry.prefersBrowser(.newTab))
    }

    @Test("A recent-tab gesture materializes a restored inactive tab instead of silently dropping selection")
    func restoredRecentTabSelection() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let source = BrowserStore()
        let profile = await source.createProfile(name: "Restored Synthetic")
        let space = try await source.createSpace(name: "Restored", profileID: profile)
        let window = try await source.createWindow(activeSpaceID: space)
        for index in 0..<3 {
            _ = try await source.openTab(url: URL(string: "https://restored-\(index).example.test/")!,
                from: source.captureContext(in: window), activate: true)
        }
        let store = try BrowserStore(restoring: await source.sessionDocument())
        let controller = BrowserWindowController(id: window.rawValue, store: store, spaceID: space,
            engine: SiteSyntheticEngine(), restoringWindowID: window, opensInitialTab: false,
            onClose: {}, onActivate: {})
        defer { controller.session.close(); controller.window?.close() }
        await controller.session.waitForPendingCommands()
        let original = try #require(controller.session.snapshot?.selectedOccurrenceID)
        let cold = try #require(controller.session.snapshot?.tabs.first { $0.occurrenceID != original })
        #expect(controller.session.surface(for: cold.occurrenceID) == nil)
        controller.tabSwitcher.controlIsHeld = { false }
        controller.tabSwitcher.cycle(backward: true)
        for _ in 0..<30 { await Task.yield(); await controller.session.waitForPendingCommands() }
        #expect(controller.session.snapshot?.selectedOccurrenceID != original)
        #expect(controller.session.selectedSurface != nil)
    }

    @Test("Sidebar navigation includes Favorites, pinned folder tabs and Today; nine selects last; duplication stays in profile")
    func sidebarNavigationAndDuplication() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let store = BrowserStore()
        let profile = await store.createProfile(name: "Shortcuts Synthetic")
        let space = try await store.createSpace(name: "Synthetic", profileID: profile)
        let router = BrowserWindowRouter(create: { id in
            let controller = BrowserWindowController(id: id, store: store, spaceID: space, engine: engine,
                onClose: {}, onActivate: {})
            await controller.session.waitForPendingCommands()
            return controller
        }, present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { $0.performAcceptedCommand($1) })
        BrowserWindowCommands.install(in: registry)
        router.newWindow()
        await router.waitForPendingCommands()
        let controller = try #require(router.selectedWindow)
        let session = try #require(controller.session)
        for number in 1...11 {
            session.openTab(url: URL(string: "https://shortcut-\(number).example.test/")!)
            await session.waitForPendingCommands()
        }
        let ids = try #require(session.organization?.allTabs.map(\.id))
        session.addToFavorites([ids[0]])
        session.pinTabs([ids[1], ids[2]])
        await session.waitForPendingCommands()
        let folder = try #require(await session.createFolder(title: "Keyboard folder", at: .init(.pinned(space)),
            containing: [.tab(ids[1]), .tab(ids[2])]).value)
        session.setFolderCollapsed(folder, true)
        await session.waitForPendingCommands()
        let order = try #require(session.organization?.tabNavigationItems.map(\.id))
        for (index, command) in BrowserFavoritesCommands.numbered.enumerated() {
            #expect(registry.dispatch(command, origin: .keyboard))
            await session.waitForPendingCommands()
            #expect(session.organization?.selectedTab?.id == (index == 8 ? order.last : order[index]))
        }
        #expect(registry.dispatch(.nextTab, origin: .keyboard))
        await session.waitForPendingCommands()
        #expect(session.organization?.selectedTab?.id == order.first)
        #expect(registry.dispatch(.previousTab, origin: .keyboard))
        await session.waitForPendingCommands()
        #expect(session.organization?.selectedTab?.id == order.last)
        let url = session.selectedSurface?.currentURL
        let count = session.organization?.allTabs.count
        #expect(registry.dispatch(.duplicate, origin: .menu))
        await session.waitForPendingCommands()
        #expect(session.organization?.allTabs.count == count.map { $0 + 1 })
        #expect(session.selectedSurface?.currentURL == url)
        #expect(session.activeProfileID == profile)
        try registry.shortcutPreferences.setOrdering(includeFavorites: false, nineSelectsLast: false)
        #expect(registry.dispatch(.selectTab1, origin: .keyboard))
        await session.waitForPendingCommands()
        #expect(session.organization?.selectedTab?.id == order[1])
        let today = try #require(session.organization?.today.compactMap { $0.node.tabID })
        session.createSplit(Array(today.prefix(2)))
        await session.waitForPendingCommands()
        let split = try #require(session.organization?.today.compactMap { item -> BrowserOrganizationSplitItem? in
            if case .split(let split) = item { return split }; return nil
        }.first)
        #expect(session.organization?.tabNavigationItems.filter { split.group.tabIDs.contains($0.id) }.count == 1)
    }
}

}
