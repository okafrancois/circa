import AppKit
import BrowserCore
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class CommandTestWindow {
    let id: UUID
    var calls: [BrowserCommandID] = []
    var state: BrowserCommandState
    init(id: UUID) {
        self.id = id
        state = BrowserCommandState()
        state.hasWindow = true
        state.context = .init(revision: 0, surface: nil, documentGeneration: 0, inputToken: UUID())
    }
}

@MainActor
private func commandRouter() -> BrowserWindowRouter<CommandTestWindow> {
    BrowserWindowRouter(create: { id in await Task.yield(); return CommandTestWindow(id: id) },
                        present: { _, _ in }, dispose: { _ in })
}

@MainActor
private func commandRegistry(_ router: BrowserWindowRouter<CommandTestWindow>) throws -> BrowserCommandRegistry<CommandTestWindow> {
    try BrowserCommandRegistry(router: router, state: { $0?.state ?? BrowserCommandState() })
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeCommandTests {
    @Test("Catalog retains every serialized declaration, source and unknown modifier mask")
    func catalogCoverage() throws {
        #expect(OrbitCommandCatalog.declarations.count == 179)
        #expect(OrbitCommandCatalog.structuralIDs.count == 14)
        #expect(OrbitCommandCatalog.actionDefinitions.count == 252) // Includes local page sharing.
        #expect(OrbitCommandCatalog.declarations.allSatisfy { $0.localizesKey })
        #expect(OrbitCommandCatalog.declarations.filter { !$0.key.isEmpty }.count == 85)
        #expect(OrbitCommandCatalog.declarations.filter { !$0.key.isEmpty && $0.modifierMask == nil }.map(\.source) == ["menu.declaration.25", "menu.declaration.117"])
        #expect(Set(OrbitCommandCatalog.declarations.map(\.source)).count == 179)
        #expect(OrbitCommandCatalog.supplemental.count == 26)
        #expect(Set(OrbitCommandCatalog.definitions.map(\.id)) == Set(BrowserCommandID.allCases))
        #expect(OrbitCommandCatalog.definitions.allSatisfy { !$0.sources.isEmpty && !$0.owner.isEmpty })
        let router = commandRouter()
        let registry = try commandRegistry(router)
        #expect(registry.shortcutConflicts == [[.newFolder, .newIncognitoWindow]])
    }

    @Test("Duplicate definitions and accidental duplicate handler registration fail explicitly")
    func duplicates() throws {
        let router = commandRouter()
        let definition = try #require(OrbitCommandCatalog.definitions.first)
        #expect(throws: BrowserCommandRegistryError.self) {
            try BrowserCommandRegistry(definitions: [definition, definition], router: router, state: { _ in .init() })
        }
        let registry = try commandRegistry(router)
        try registry.register(.newTab) { _, _ in }
        #expect(throws: BrowserCommandRegistryError.self) { try registry.register(.newTab) { _, _ in } }
        try registry.register(.newTab, replace: true) { _, _ in }
    }

    @Test("Shift and Option preserve distinct commands and upper-case key equivalents")
    func modifierVariants() {
        let row: (String) -> BrowserShortcut? = { source in OrbitCommandCatalog.declarations.first { $0.source == source }?.shortcut }
        #expect(row("menu.declaration.79") == BrowserShortcut(key: "c", modifiers: [.command, .shift]))
        #expect(row("menu.declaration.36") == BrowserShortcut(key: "c", modifiers: [.command, .shift, .option]))
        #expect(row("menu.declaration.129") != row("menu.declaration.79"))
        #expect(row("menu.declaration.62") != row("menu.declaration.93"))
        #expect(row("menu.declaration.21") != row("menu.declaration.40"))
        #expect(row("menu.declaration.18") == BrowserShortcut(key: "\t", modifiers: [.control, .shift]))
    }

    @Test("Keyboard normalization preserves IME, dead keys, repeats and keyboard-layout boundaries")
    func keyboardNormalization() {
        func input(_ text: String?, _ code: UInt16 = 0, _ flags: NSEvent.ModifierFlags = [.command],
                   composing: Bool = false, repeated: Bool = false) -> BrowserShortcut? {
            BrowserShortcut.input(characters: text, keyCode: code, modifiers: flags, isComposing: composing, isRepeat: repeated)
        }
        #expect(input("c", composing: true) == nil)
        #expect(input("c", repeated: true) == BrowserShortcut(key: "c", modifiers: [.command]))
        #expect(input("") == nil)
        #expect(input(nil) == nil)
        #expect(input("é", 19) == BrowserShortcut(key: "2", modifiers: [.command]))
        #expect(input("2", 19, [.command, .shift]) == BrowserShortcut(key: "2", modifiers: [.command, .shift]))
        #expect(input("é", 19, [.command, .option]) == BrowserShortcut(key: "2", modifiers: [.command, .option]))
        #expect(input("@", 19, [.command, .shift]) == BrowserShortcut(key: "2", modifiers: [.command, .shift]))
        #expect(input("+", 24, [.command, .shift]) == BrowserShortcut(key: "+", modifiers: [.command, .shift]))
        #expect(input("q", 0) == BrowserShortcut(key: "q", modifiers: [.command]))
        #expect(input("C", 8, [.command, .capsLock]) == BrowserShortcut(key: "c", modifiers: [.command]))
    }

    @Test("Unimplemented commands remain disabled even across pending window and session publication")
    func placeholdersStayDisabled() async throws {
        let router = commandRouter()
        let registry = try commandRegistry(router)
        router.newWindow()
        #expect(!registry.isEnabled(.newQuickWindowWindow))
        #expect(!registry.dispatch(.newQuickWindowWindow, origin: .keyboard))
        await router.waitForPendingCommands()
        router.selectedWindow?.state.hasPendingCommands = true
        #expect(!registry.isEnabled(.developerTools))
        #expect(!registry.dispatch(.newIncognitoWindow, origin: .menu))
        router.shutdown()
    }

    @Test("Enablement reflects surface, history, loading, reopen, modal and shutdown state")
    func enablement() async throws {
        let router = commandRouter()
        let registry = try commandRegistry(router)
        for id in [BrowserCommandID.archiveTab, .goBack, .goForward, .stopLoading, .restoreLastClosedTab, .showHideSidebar, .copyURL, .refreshThePage] {
            try registry.register(id, validate: id == .archiveTab ? { $0.state.hasSurface } : nil) { _, _ in }
        }
        router.newWindow()
        await router.waitForPendingCommands()
        let window = try #require(router.selectedWindow)
        #expect(registry.isEnabled(.showHideSidebar))
        #expect(!registry.isEnabled(.archiveTab))
        #expect(!registry.isEnabled(.goBack))
        #expect(!registry.isEnabled(.goForward))
        #expect(!registry.isEnabled(.stopLoading))
        #expect(!registry.isEnabled(.restoreLastClosedTab))
        window.state.hasSurface = true
        #expect(!registry.isEnabled(.copyURL))
        #expect(!registry.isEnabled(.refreshThePage))
        window.state.hasURL = true
        #expect(registry.isEnabled(.copyURL))
        #expect(registry.isEnabled(.refreshThePage))
        window.state.canGoBack = true
        window.state.canGoForward = true
        window.state.isLoading = true
        window.state.canReopen = true
        #expect([BrowserCommandID.archiveTab, .goBack, .goForward, .stopLoading, .restoreLastClosedTab].allSatisfy { registry.isEnabled($0) })
        window.state.isModal = true
        #expect(!registry.isEnabled(.archiveTab))
        window.state.isModal = false
        window.state.isAvailable = false
        #expect(!registry.dispatch(.showHideSidebar, origin: .menu))
        router.shutdown()
    }

    @Test("A command queued behind window creation never follows a subsequent focus change")
    func pendingWindowRouting() async throws {
        let router = commandRouter()
        let registry = try commandRegistry(router)
        try registry.register(.newTab) { $0.calls.append(.newTab); _ = $1 }
        let first = try #require(router.newWindow())
        #expect(registry.dispatch(.newTab, origin: .keyboard))
        let second = try #require(router.newWindow())
        #expect(registry.dispatch(.newTab, origin: .menu))
        await router.waitForPendingCommands()
        #expect(router.windows[first]?.calls == [.newTab])
        #expect(router.windows[second]?.calls == [.newTab])
        router.shutdown()
    }

    @Test("Captured context routes to its original window and rejects revision changes including A to B to A")
    func capturedContextRouting() async throws {
        let router = commandRouter()
        let registry = try commandRegistry(router)
        try registry.register(.showHideSidebar) { $0.calls.append(.showHideSidebar); _ = $1 }
        let first = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let target = try #require(registry.captureTarget())
        router.newWindow()
        await router.waitForPendingCommands()
        #expect(registry.dispatch(.showHideSidebar, origin: .contextMenu, target: target))
        #expect(router.windows[first]?.calls == [.showHideSidebar])
        #expect(router.selectedWindow?.calls.isEmpty == true)
        let original = try #require(router.windows[first]?.state.context)
        router.windows[first]?.state.context = .init(revision: original.revision + 2, surface: original.surface,
            documentGeneration: original.documentGeneration, inputToken: original.inputToken)
        #expect(!registry.dispatch(.showHideSidebar, origin: .palette, target: target))
        router.remove(first)
        #expect(!registry.dispatch(.showHideSidebar, origin: .contextMenu, target: target))
        router.shutdown()
    }

    @Test("Captured targets refuse a replaced document, explicit input and busy session")
    func capturedTargetRevocation() async throws {
        let router = commandRouter()
        let registry = try commandRegistry(router)
        try registry.register(.showHideSidebar) { _, _ in }
        router.newWindow()
        await router.waitForPendingCommands()
        let window = try #require(router.selectedWindow)
        let target = try #require(registry.captureTarget())
        let original = target.context
        window.state.context = .init(revision: original.revision, surface: original.surface,
            documentGeneration: original.documentGeneration + 1, inputToken: original.inputToken)
        #expect(!registry.isEnabled(.showHideSidebar, target: target))
        window.state.context = .init(revision: original.revision, surface: original.surface,
            documentGeneration: original.documentGeneration, inputToken: UUID())
        #expect(!registry.isEnabled(.showHideSidebar, target: target))
        window.state.context = original
        window.state.hasPendingCommands = true
        #expect(registry.captureTarget() == nil)
        #expect(!registry.isEnabled(.showHideSidebar, target: target))
        router.shutdown()
    }

    @Test("Scope and ambiguous bindings never dispatch a neighboring command")
    func scopedBindings() async throws {
        let router = commandRouter()
        let registry = try commandRegistry(router)
        for id in [BrowserCommandID.newFolder, .newIncognitoWindow, .promoteQuickWindow] {
            try registry.register(id) { _, _ in }
        }
        router.newWindow()
        await router.waitForPendingCommands()
        #expect(registry.resolve(.init(key: "n", modifiers: [.command, .shift])) == .newIncognitoWindow)
        #expect(registry.resolve(.init(key: "o", modifiers: [.command])) == nil)
        router.selectedWindow?.state.scope = .quickWindow
        #expect(registry.resolve(.init(key: "o", modifiers: [.command]), scope: .quickWindow) == .promoteQuickWindow)
        router.shutdown()
    }

    @Test("Pending responder permission is opt-in, keeps validation and captured guards, and resets on replacement")
    func pendingResponderPermissionIsBounded() async throws {
        let router = commandRouter()
        let registry = try commandRegistry(router)
        try registry.register(.undo, allowsPendingResponder: { $0.state.hasSurface },
                              validate: { $0.state.hasURL }) { window, _ in window.calls.append(.undo) }
        try registry.register(.copy, validate: { _ in true }) { window, _ in window.calls.append(.copy) }
        router.newWindow()
        await router.waitForPendingCommands()
        let window = try #require(router.selectedWindow)
        let captured = try #require(registry.captureTarget())
        window.state.hasPendingCommands = true
        #expect(!registry.dispatch(.undo, origin: .keyboard))
        window.state.hasSurface = true
        #expect(!registry.dispatch(.undo, origin: .keyboard)) // A permission does not bypass validation.
        window.state.hasURL = true
        #expect(registry.dispatch(.undo, origin: .keyboard))
        #expect(!registry.dispatch(.undo, origin: .contextMenu, target: captured))
        #expect(!registry.dispatch(.copy, origin: .keyboard))
        window.state.isModal = true
        #expect(!registry.dispatch(.undo, origin: .keyboard))
        window.state.isModal = false
        try registry.register(.undo, replace: true, validate: { _ in true }) { window, _ in window.calls.append(.undo) }
        #expect(!registry.dispatch(.undo, origin: .keyboard))
        #expect(window.calls == [.undo])
        router.shutdown()
    }

    @Test("Application commands cannot silently reinterpret a captured document target")
    func applicationTargetAndCreationPolicy() async throws {
        let router = commandRouter()
        let registry = try commandRegistry(router)
        var calls = 0
        try registry.registerApplication(.newWindow) { calls += 1 }
        try registry.register(.newTab) { _, _ in calls += 1 }
        try registry.registerWhenWindowMissing(.newTab) { calls += 10 }
        #expect(registry.dispatch(.newTab, origin: .keyboard))
        #expect(calls == 10)
        router.newWindow()
        await router.waitForPendingCommands()
        let target = try #require(registry.captureTarget())
        #expect(!registry.dispatch(.newWindow, origin: .contextMenu, target: target))
        #expect(registry.dispatch(.newWindow, origin: .palette))
        #expect(calls == 11)
        router.shutdown()
    }

    @Test("Context menu actions use their captured target and omit unavailable commands")
    func contextMenuDispatch() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = commandRouter()
        let registry = try commandRegistry(router)
        var origins: [BrowserCommandOrigin] = []
        try registry.register(.showHideSidebar) { _, origin in origins.append(origin) }
        router.newWindow()
        await router.waitForPendingCommands()
        let target = try #require(registry.captureTarget())
        let menus = BrowserCommandMenus(registry: registry, target: target)
        let menu = menus.makeContextMenu(commands: [.showHideSidebar, .addSplitView])
        let first = try #require(menu.items.first)
        #expect(menus.validateMenuItem(first))
        #expect(menu.items.count == 1)
        menu.performActionForItem(at: 0)
        #expect(origins == [.contextMenu])
        router.selectedWindow?.state.context = .init(revision: 1, surface: nil, documentGeneration: 0, inputToken: UUID())
        menu.performActionForItem(at: 0)
        #expect(origins.count == 1)
        router.shutdown()
    }

    @Test("The production command system wires shell actions and leaves owning lots unimplemented")
    func productionBindings() {
        let app = OrbitApplication()
        let system = app.makeCommandSystem()
        // 40 shell bindings (incl. THEME's Cmd+S and Edit Theme) + PEEK's 2 + ARCHIVE-UI's 4 + FAVORITES' 13 + SWITCHER's 3
        // + SB-LIST's 14 (Clear Unpinned Tabs belongs to ARCHIVE-UI) + LIBRARY's History binding
        // + SETTINGS' Preferences, About Orbit and default-browser bindings, IMPORT's 2 bindings, SPLIT's 9 and LITTLE's 6
        // + CH-ESSENTIALS' 37 page context menu commands and Print, Developer Tools, Inspect Elements, View Source.
        // + site-session/bookmark import and export (4), and private-window routing (1).
        // + local Share and page-context Share (2), sidebar tab navigation (4), Select Space 1–9 (9).
        let implemented = system.registry.definitions.filter { system.registry.isImplemented($0.id) }.map(\.id.rawValue)
        // Boost creation and the Library destination add two executable bindings.
        #expect(implemented.count == 187, "\(implemented.count): \(implemented.sorted())")
        #expect(system.registry.isImplemented(.checkForUpdates))
        #expect(system.registry.isImplemented(.toggleDeveloperMode))
        #expect(system.registry.isImplemented(.newIncognitoWindow))
        #expect(system.registry.isImplemented(.editTheme))
        #expect(system.registry.isImplemented(.print) && system.registry.isImplemented(.developerTools))
        #expect(system.registry.isImplemented(.inspectElements) && system.registry.isImplemented(.viewSource))
        #expect(system.registry.isImplemented(.preferences))
        #expect(system.registry.isImplemented(.aboutOrbit))
        #expect(system.registry.isImplemented(.setAsDefaultBrowser))
        #expect(system.registry.isImplemented(.dismissPeek))
        #expect(system.registry.isImplemented(.copyURL))
        #expect(system.registry.isImplemented(.showSiteControls))
        #expect(system.registry.isImplemented(.showHideSidebar))
        #expect(system.registry.isImplemented(.forceRefreshThePage))
        #expect(system.registry.isImplemented(.javascriptConsole))
        #expect(system.registry.isImplemented(.pasteAsNewTab))
        #expect(system.registry.isImplemented(.addSplitView))
        #expect(system.registry.isImplemented(.newQuickWindowWindow))
        #expect(!system.registry.isImplemented(.newChatGPTMessage))
        // Unsupported declarations retain no handler until their behavior is specified.
        for id: BrowserCommandID in [.blankWindow, .showHideToolbar, .joinMeeting, .cycleExtensions,
                                     .peekEmail, .copyURLAsQuote, .removeSuggestion, .exit] {
            #expect(!system.registry.isImplemented(id))
        }
    }

    @Test("MENUS-WORK audits every visible action and keeps unsupported commands out of every presentation")
    func menusWorkAudit() throws {
        let system = OrbitApplication().makeCommandSystem()
        let registry = system.registry
        let bar = system.menus.makeMenuBar()
        func audit(_ menu: NSMenu) {
            for item in menu.items where !item.isHidden && !item.isSeparatorItem {
                if let submenu = item.submenu { audit(submenu) }
                else if let raw = item.identifier?.rawValue, let id = BrowserCommandID(rawValue: raw), item.action != nil {
                    #expect(registry.isImplemented(id) || BrowserStandardActions.selector(for: id) != nil)
                    #expect(!OrbitCommandCatalog.hiddenCommands.contains(id))
                }
            }
        }
        audit(bar)
        let omitted = OrbitCommandCatalog.actionDefinitions.filter {
            !registry.isImplemented($0.id) && BrowserStandardActions.selector(for: $0.id) == nil
        }
        let unbound = registry.definitions.filter {
            !$0.shortcuts.isEmpty && !registry.isImplemented($0.id) && BrowserStandardActions.selector(for: $0.id) == nil
        }.map { $0.id.rawValue }.sorted()
        print("SHORTCUTS unimplemented: " + unbound.joined(separator: ", "))
        print("MENUS-WORK omitted: " + omitted.map { $0.id.rawValue }.sorted().joined(separator: ", "))
        for id in [BrowserCommandID.findAndReplace, .useSelectionToFind, .jumpToSelection, .copyURLAsQuote, .captureInPortraitMode] {
            #expect(!registry.isImplemented(id))
        }
        for id in OrbitCommandCatalog.hiddenCommands {
            #expect(!OrbitCommandCatalog.isCommandBarAction(try #require(registry.definition(id))))
            #expect(system.menus.makeContextMenu(commands: [id]).items.isEmpty)
        }
        for definition in registry.definitions where definition.scope != .browser {
            #expect(!OrbitCommandCatalog.isCommandBarAction(definition))
        }
        let file = try #require(bar.items.first { $0.title == "File" }?.submenu)
        #expect(file.items.filter { !$0.isSeparatorItem && !$0.isHidden }.compactMap(\.identifier?.rawValue) == [
            "newTab", "newWindow", "newIncognitoWindow", "newQuickWindowWindow", "restoreLastClosedTab", "openCommandBar", "newProfile",
            "closeWindow", "archiveTab", "share", "capture", "captureFullPage", "savePageAs", "print", "importFromArc"
        ])
        let edit = try #require(bar.items.first { $0.title == "Edit" }?.submenu)
        #expect(edit.items.contains { $0.identifier?.rawValue == "copyURLAsMarkdown" && $0.keyEquivalent == "C" && $0.keyEquivalentModifierMask == [.command, .option] })
        let view = try #require(bar.items.first { $0.title == "View" }?.submenu)
        #expect(view.items.contains { $0.identifier?.rawValue == "revealCurrentTab" && $0.keyEquivalent == " " && $0.keyEquivalentModifierMask == [.control] })
    }

    @Test("Markdown copies preserve a valid title and URL with Markdown metacharacters")
    func markdownLinkEscaping() {
        #expect(BrowserMarkdownLink.format(title: "A [title]\nline", url: URL(string: "https://example.test/a(b)")!)
            == "[A \\[title\\] line](https://example.test/a%28b%29)")
    }

    @Test("Product menus omit unavailable commands and empty groups; File keeps Orbit transfer commands")
    func productMenuAvailability() {
        let system = OrbitApplication().makeCommandSystem()
        let bar = system.menus.makeMenuBar()
        func check(_ menu: NSMenu) {
            let visible = menu.items.filter { !$0.isHidden }
            #expect(visible.first?.isSeparatorItem != true && visible.last?.isSeparatorItem != true)
            for (index, item) in visible.enumerated() {
                if item.isSeparatorItem, index > 0 { #expect(!visible[index - 1].isSeparatorItem) }
                if let submenu = item.submenu { check(submenu) }
                if let raw = item.identifier?.rawValue, let id = BrowserCommandID(rawValue: raw), item.action != nil, id != .services {
                    #expect(system.registry.isImplemented(id) || BrowserStandardActions.selector(for: id) != nil)
                }
            }
        }
        check(bar)
        let file = bar.items.first { $0.title == "File" }?.submenu
        #expect(file?.items.contains { $0.identifier?.rawValue == "newProfile" } == true)
        #expect(file?.items.contains { $0.identifier?.rawValue == "newEasel" } == false)
        // A single Orbit import command; separate transfer actions are hidden everywhere.
        #expect(file?.items.contains { $0.identifier?.rawValue == "importFromArc" } == true)
        for id in ["importArcConnections", "restoreArcConnections", "importBookmarks", "exportBookmarks"] {
            #expect(file?.items.contains { $0.identifier?.rawValue == id } == false)
        }
        #expect(bar.items.first { $0.title == "View" }?.submenu?.items.contains { $0.title == "Appearance" } == false)
    }

    @Test("Menu bar reproduces Orbit's declared order, separators, submenus and native actions")
    func menuStructureSnapshot() throws {
        let registry = try commandRegistry(commandRouter())
        for definition in registry.definitions { try registry.registerApplication(definition.id) {} }
        let menus = BrowserCommandMenus(registry: registry)
        let bar = menus.makeMenuBar()
        func keys(_ item: NSMenuItem) -> String {
            guard !item.keyEquivalent.isEmpty else { return "" }
            let names: [String: String] = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
                                           "\u{F70F}": "F12", "\t": "⇥", "\u{19}": "⇤", "\u{1B}": "⎋", " ": "Space"]
            let flags = item.keyEquivalentModifierMask
            let shifted = item.keyEquivalent.count == 1 && item.keyEquivalent.first?.isUppercase == true
            return " " + (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
                + (flags.contains(.shift) || shifted ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
                + (names[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
        }
        func snapshot(_ menu: NSMenu, depth: Int = 0) -> [String] {
            menu.items.flatMap { item -> [String] in
                let pad = String(repeating: "  ", count: depth)
                guard !item.isSeparatorItem else { return [pad + "---"] }
                var line = pad + item.title + (item.identifier.map { " [\($0.rawValue)]" } ?? "") + keys(item)
                if item.isHidden { line += " (hidden)" }
                if item.isAlternate { line += " (alternate)" }
                if item.allowsKeyEquivalentWhenHidden { line += " (key when hidden)" }
                if item.state == .on { line += " (on)" }
                if item.action != nil, item.target == nil { line += " <\(NSStringFromSelector(item.action!))>" }
                if item.target is NSFontManager { line += " <NSFontManager.\(NSStringFromSelector(item.action!)) tag \(item.tag)>" }
                let submenu = item.submenu.map { [pad + "  {\($0.title)}"] + snapshot($0, depth: depth + 1) } ?? []
                return [line] + submenu
            }
        }
        func allItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
        }
        let expected = """
        Orbit
          {Orbit}
          About Orbit [aboutOrbit]
          ---
          Preferences… [preferences] ⌘,
          Share Orbit [shareOrbit]
          Set as Default Browser [setAsDefaultBrowser]
          ---
          Import from Another Browser… [importFromAnotherBrowser]
          Check for Updates… [checkForUpdates]
          ---
          Services [services]
            {Services}
          Privacy Policy [privacyPolicy]
          ---
          Hide Orbit [hideOrbit] ⌘H
          Hide Other Windows [hideOtherWindows] ⌥⌘H
          Show All [showAll]
          ---
          Sign Out [signOut]
          ---
          Quit Orbit [quitOrbit] ⌘Q
        File
          {File}
          New Tab… [newTab] ⌘T
          New Window [newWindow] ⌘N
          Blank Window [blankWindow] ⌃⌘N
          New Incognito Window [newIncognitoWindow] ⇧⌘N
          New Little Orbit Window [newQuickWindowWindow] ⌥⌘N
          Restore Last Closed Tab [restoreLastClosedTab] ⇧⌘T
          ---
          Open Command Bar [openCommandBar] ⌘L
          ---
          New Boost [newBoost] (hidden)
          Edit Boost [editBoost] (hidden)
          New Legacy Boost (Advanced) [newLegacyBoostAdvanced] (hidden)
          Boost Gallery [boostGallery] (hidden)
          New Profile [newProfile]
          New Note [newNote] ⌃⇧N
          New Note (in Split) [newNoteInSplit] ⌃⌥N (hidden) (key when hidden)
          New Easel [newEasel] ⌃⇧E
          ---
          Close Window [closeWindow] ⇧⌘W
          Archive Tab [archiveTab] ⌘W (key when hidden)
          ---
          Share… [share]
          Send to Dia [sendToDia]
          Capture… [capture] ⇧⌘2
          Capture Full Page [captureFullPage]
          Capture in Portrait Mode [captureInPortraitMode] (key when hidden)
          Save Page As [savePageAs] ⇧⌘S
          Print [print] ⌘P
          ---
          Import from Arc… [importFromArc]
        Edit
          {Edit}
          Undo [undo] ⌘Z <undo:>
          Redo [redo] ⇧⌘Z <redo:>
          ---
          Cut [cut] ⌘X <cut:>
          Copy [copy] ⌘C <copy:>
          Copy URL [copyURL] ⇧⌘C
          Copy URL as Markdown [copyURLAsMarkdown] ⌥⇧⌘C
          Copy URL as Quote [copyURLAsQuote] ⌃⇧⌘C
          Paste [paste] ⌘V <paste:>
          Paste and Match Style [pasteAndMatchStyle] ⇧⌘V <pasteAsPlainText:>
          Delete [delete] <delete:>
          Select All [selectAll] ⌘A <selectAll:>
          ---
          Find
            {Find}
            Find… [find] ⌘F
            Find and Replace [findAndReplace] ⌥⌘F <performFindPanelAction:>
            Find Next [findNext] ⌘G
            Find Previous [findPrevious] ⇧⌘G
            Use Selection to Find [useSelectionToFind] <performFindPanelAction:>
            Jump to Selection [jumpToSelection] ⌘J <centerSelectionInVisibleArea:>
          Spelling and Grammar
            {Spelling}
            Show Spelling and Grammar [showSpellingAndGrammar] ⌘: <showGuessPanel:>
            Check Document Now [checkDocumentNow] ⌘; <checkSpelling:>
            ---
            Check Spelling While Typing [checkSpellingWhileTyping] <toggleContinuousSpellChecking:>
            Check Grammar With Spelling [checkGrammarWithSpelling] <toggleGrammarChecking:>
            Correct Spelling Automatically [correctSpellingAutomatically] <toggleAutomaticSpellingCorrection:>
          Substitutions
            {Substitutions}
            Show Substitutions [showSubstitutions] <orderFrontSubstitutionsPanel:>
            ---
            Smart Copy/Paste [smartCopyPaste] <toggleSmartInsertDelete:>
            Smart Quotes [smartQuotes] <toggleAutomaticQuoteSubstitution:>
            Smart Dashes [smartDashes] <toggleAutomaticDashSubstitution:>
            Smart Links [smartLinks] <toggleAutomaticLinkDetection:>
            Data Detectors [dataDetectors] <toggleAutomaticDataDetection:>
            Text Replacement [textReplacement] <toggleAutomaticTextReplacement:>
          Transformations
            {Transformations}
            Make Upper Case [makeUpperCase] <uppercaseWord:>
            Make Lower Case [makeLowerCase] <lowercaseWord:>
            Capitalize [capitalize] <capitalizeWord:>
          Speech
            {Speech}
            Start Speaking [startSpeaking] <startSpeaking:>
            Stop Speaking [stopSpeaking] <stopSpeaking:>
          Format
            {Format}
            Font
              {Font}
              Bold [bold] ⌘B <NSFontManager.addFontTrait: tag 2>
              Italic [italic] ⌘I <NSFontManager.addFontTrait: tag 1>
              Underline [underline] ⌘U <underline:>
        View
          {View}
          Appearance
            {}
            Websites, Easels, and Notes will use: [websitesEaselsAndNotesWillUse]
            Automatic [automatic] (on)
            Light [light]
            Dark [dark]
          ---
          Show/Hide Sidebar [showHideSidebar] ⌘S
          Show/Hide Toolbar [showHideToolbar] ⇧⌘D (hidden)
          Expand Pinned Section [expandPinnedSection] (hidden)
          Collapse Pinned Section [collapsePinnedSection] (hidden)
          Reveal Current Tab [revealCurrentTab] ⌃Space (hidden) (key when hidden)
          ---
          Stop Loading [stopLoading] ⌘.
          Refresh the Page [refreshThePage] ⌘R
          Force Refresh the Page [forceRefreshThePage] ⇧⌘R (alternate)
          Clear Cookies and Refresh [clearCookiesAndRefresh]
          Clear Cache and Refresh [clearCacheAndRefresh]
          ---
          Add Split View [addSplitView] ⌃⇧=
          Close this Split Pane [closeThisSplitPane] ⌃⇧-
          Separate Page from Split View [separatePageFromSplitView]
          Expand Current Split [expandCurrentSplit]
          ---
          Zoom to Actual Size [zoomToActualSize] ⌘0
          Zoom In [zoomIn] ⌘+
          Zoom In [zoomIn] ⌘= (hidden) (key when hidden)
          Zoom Out [zoomOut] ⌘- (key when hidden)
          Zoom Out [zoomOut] ⇧⌘- (hidden) (key when hidden)
          ---
          Cast [cast]
          ---
          Developer
            {Developer}
            View Source [viewSource] ⌥⌘U
            Developer Tools [developerTools] ⌥⌘I
            Developer Tools [developerTools] F12 (hidden) (key when hidden)
            Inspect Elements [inspectElements] ⌥⌘C
            JavaScript Console [javascriptConsole] ⌥⌘J
            Network Inspector [networkInspector]
            Allow JavaScript from Apple Events [allowJavaScriptFromAppleEvents]
            Toggle Developer Mode [toggleDeveloperMode] ⌃D
          ---
          Enter/Exit Full Screen [enterExitFullScreen] ⌃⌘F
          Exit [exit] ⎋ (key when hidden)
        Spaces
          {Spaces}
          New Space… [newSpace]
          Edit Theme… [editTheme]
          Rename Space [renameSpace]
          Change Profile [changeProfile]
          ---
          Next Space [nextSpace] ⌥⌘→
          Previous Space [previousSpace] ⌥⌘←
          ---
          Manage Spaces… [manageSpaces]
        Tabs
          {Tabs}
          New Tab… [newTab] ⌘T
          New ChatGPT Message… [newChatGPTMessage] ⌥⌘G (hidden) (key when hidden)
          Join Meeting [joinMeeting] ⌃⌘J (hidden) (key when hidden)
          Peek Email… [peekEmail] ⇧⌘E (hidden) (key when hidden)
          Pin/Unpin Tab [pinUnpinTab] ⌘D
          Open Little Orbit or Peek in… [openQuickWindowOrPeekIn] ⌘O (key when hidden)
          New Folder… [newFolder]
          Duplicate [duplicate] (key when hidden)
          Rename Current Item [renameCurrentItem] (hidden) (key when hidden)
          Collapse All Folders [collapseAllFolders] (hidden) (key when hidden)
          Expand All Folders [expandAllFolders] (hidden) (key when hidden)
          ---
          Next Tab [nextTab] ⌥⌘↓
          Previous Tab [previousTab] ⌥⌘↑
          Tab Switcher (forward) [tabSwitcherForward] ⌃⇥ (hidden) (key when hidden)
          Tab Switcher (backward) [tabSwitcherBackward] ⌃⇧⇤ (hidden) (key when hidden)
          Cycle Tab Forward [cycleTabForward] ⌃⌘→ (hidden) (key when hidden)
          Cycle Tab Backward [cycleTabBackward] ⌃⌘← (hidden) (key when hidden)
          Reveal Tab in Sidebar [revealTabInSidebar]
          ---
          Clear Unpinned Tabs [clearUnpinnedTabs] ⇧⌘K
          Reset all tabs in this Space [resetAllTabsInThisSpace]
          Reset Tab to Original URL [resetTabToOriginalURL] (hidden) (key when hidden)
        Archive
          {Archive}
          Go Back [goBack] ⌘[
          Go Back [goBack] ⌘← (hidden) (key when hidden)
          Go Forward [goForward] ⌘]
          Go Forward [goForward] ⌘→ (hidden) (key when hidden)
          ---
          View History [viewHistory] ⌘Y
          View Archive [viewArchive]
          Clear Archive [clearArchive]
        Extensions
          {Extensions}
          Add Extension… [addExtension]
          Manage Extensions… [manageExtensions]
        Window
          {Window}
          Minimize Window [minimizeWindow] ⌘M
          Zoom [zoom]
          ---
          View Library [viewLibrary] ⇧⌘L
          View Downloads [viewDownloads] ⇧⌘J
          View Easels & Notes [viewEaselsNotes]
          View Media [viewMedia]
          View Boosts [viewBoosts] (hidden)
          ---
          Bring All to Front [bringAllToFront]
        Help
          {Help}
          Getting Started [gettingStarted]
          Essential Keyboard Shortcuts [essentialKeyboardShortcuts]
          Release Notes [releaseNotes]
          Contact the Team [contactTheTeam]
          Visit Help Center [visitHelpCenter]
          Restore Data [restoreData]
          Export Orbit Notes [exportOrbitNotes]
          ---
          Troubleshooting
            {Troubleshooting}
            Record Trace [recordTrace]
            Cancel Trace [cancelTrace] (hidden)
            Open Task Manager [openTaskManager]
            ---
            Reveal Orbit Data [revealOrbitData]
            Copy Orbit Info [copyOrbitInfo]
        """
        let actual = snapshot(bar).joined(separator: "\n")
        #expect(actual == expected)
        #expect(bar.items.map(\.title) == ["Orbit", "File", "Edit", "View", "Spaces", "Tabs", "Archive", "Extensions", "Window", "Help"])
        let items = allItems(bar)
        #expect(items.allSatisfy { $0.allowsAutomaticKeyEquivalentLocalization && $0.allowsAutomaticKeyEquivalentMirroring })
        #expect(!items.contains { ["Item 1", "Item 2", "Item 3"].contains($0.title) })
        // No two items share a key equivalent unless they are the same command (New Tab in File and Tabs).
        var owners: [String: Set<String>] = [:]
        for item in items where !item.keyEquivalent.isEmpty {
            owners[keys(item), default: []].insert(item.identifier?.rawValue ?? "")
        }
        #expect(owners.filter { $0.value.count > 1 }.isEmpty)
    }
}
}
