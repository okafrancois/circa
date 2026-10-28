import AppKit
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class KeyboardWindow {
    var state = BrowserCommandState()
    var received: [BrowserCommandID] = []
    var nativeWindow: NSWindow?
    init() {
        state.hasWindow = true
        state.hasSurface = true
        state.hasURL = true
        state.canGoBack = true
        state.canGoForward = true
        state.context = .init(revision: 0, surface: nil, documentGeneration: 0, inputToken: UUID())
    }
}

/// A synthetic document host conforms to NSTextInputClient just like WKWebView, without
/// starting a browser process or displaying a window. Handled keys stop at the page boundary.
@MainActor
private final class KeyboardPage: NSTextView {
    var pageHandles = true
    var offered: [UInt16] = []
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        offered.append(event.keyCode)
        return pageHandles
    }
}

@MainActor
private final class AuxiliaryKeyboardWindow: NSWindow {
    var closedByCommand = 0
    var minimizedByCommand = 0
    override func performClose(_ sender: Any?) { closedByCommand += 1 }
    override func performMiniaturize(_ sender: Any?) { minimizedByCommand += 1 }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool { true }
}

@MainActor
private final class SystemKeyboardMenuTarget: NSObject {
    var calls = 0
    @objc func performSystemCommand(_ sender: Any?) { calls += 1 }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeKeyboardRoutingTests {
    private func event(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = [.command], repeated: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 1, windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: repeated, keyCode: code))
    }

    /// Construct a physically coherent punctuation event on the current host layout. A
    /// synthetic US keycode with AZERTY glyphs would test an impossible input combination.
    private func punctuationEvent(_ glyph: String, base: String, flags: NSEvent.ModifierFlags,
                                  repeated: Bool = false) throws -> NSEvent {
        for code in UInt16(0)...UInt16(127) {
            let probe = try event(glyph, code: code, flags: flags, repeated: repeated)
            if probe.characters(byApplyingModifiers: []) == base,
               probe.characters(byApplyingModifiers: flags.intersection(.shift)) == glyph { return probe }
        }
        throw CocoaError(.featureUnsupported)
    }

    private func router() -> BrowserWindowRouter<KeyboardWindow> {
        BrowserWindowRouter(create: { _ in KeyboardWindow() }, present: { _, _ in }, dispose: { _ in })
    }

    @Test("The monitor leaves editing, find, save, pin, sidebar and history keys to the focused page")
    func pageFirstMonitorAndNativeMenuFallback() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        for id in [BrowserCommandID.find, .showHideSidebar, .savePageAs, .pinUnpinTab, .goBack, .goForward, .undo, .selectAll] {
            try registry.register(id) { $0.received.append(id); _ = $1 }
        }
        router.newWindow()
        await router.waitForPendingCommands()
        let window = try #require(router.selectedWindow)
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        let menus = BrowserCommandMenus(registry: registry)
        let bar = menus.makeMenuBar()
        let host = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        let page = KeyboardPage(frame: .init(x: 0, y: 0, width: 400, height: 200))
        host.contentView = page
        #expect(host.makeFirstResponder(page))
        #expect(host.firstResponder is NSTextInputClient)
        for input in try [event("z", code: 6), event("a", code: 0), event("f", code: 3),
                      event("s", code: 1), event("d", code: 2),
                      event("\u{F702}", code: 123), event("\u{F703}", code: 124)] {
            #expect(!keyboard.handle(input))
            // This is the native ordering: focused host first, then menu only if unhandled.
            if !page.performKeyEquivalent(with: input) { _ = bar.performKeyEquivalent(with: input) }
        }
        #expect(page.offered.count == 7)
        #expect(window.received.isEmpty)
        page.pageHandles = false
        for input in try [event("f", code: 3), event("s", code: 1), event("\u{F702}", code: 123), event("\u{F703}", code: 124)] {
            #expect(!keyboard.handle(input))
            #expect(!page.performKeyEquivalent(with: input))
            #expect(bar.performKeyEquivalent(with: input))
        }
        #expect(window.received == [.find, .showHideSidebar, .goBack, .goForward])
        #expect(!host.isVisible)
    }

    @Test("Global reserved shortcuts work with no key window and do not target a background document")
    func noKeyWindow() async throws {
        let router = router()
        defer { router.shutdown() }
        var key: UUID?
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() }, currentWindowID: { key })
        var calls: [BrowserCommandID] = []
        for id in [BrowserCommandID.newWindow, .quitOrbit, .hideOrbit] {
            try registry.registerApplication(id) { calls.append(id) }
        }
        try registry.register(.newTab) { $0.received.append(.newTab); _ = $1 }
        try registry.registerWhenWindowMissing(.newTab) { calls.append(.newTab) }
        try registry.register(.archiveTab) { $0.received.append(.archiveTab); _ = $1 }
        router.newWindow()
        await router.waitForPendingCommands()
        key = nil // Includes an auxiliary key window, whose ID is absent from the browser router.
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        for input in try [event("n", code: 45), event("t", code: 17), event("q", code: 12), event("h", code: 4)] {
            #expect(keyboard.handle(input))
        }
        #expect(calls == [.newWindow, .newTab, .quitOrbit, .hideOrbit])
        #expect(!keyboard.handle(try event("w", code: 13))) // Auxiliary windows retain Close.
        #expect(router.selectedWindow?.received.isEmpty == true)
        let menus = BrowserCommandMenus(registry: registry)
        let menu = menus.makeContextMenu(commands: [.newWindow])
        #expect(menu.performKeyEquivalent(with: try event("n", code: 45)))
        #expect(calls.last == .newWindow)
    }

    @Test("Scope providers route Peek, Little Orbit, switcher and palette keys before browser bindings")
    func featureScopes() async throws {
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        for id in [BrowserCommandID.dismissPeek, .promoteQuickWindow, .closeSwitcherTab, .removeSuggestion, .openQuickWindowOrPeekIn] {
            try registry.register(id) { $0.received.append(id); _ = $1 }
        }
        router.newWindow()
        await router.waitForPendingCommands()
        var scope: BrowserCommandScope? = .peek
        registry.registerScopeProvider("feature-overlay", priority: 100) { _ in scope }
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        #expect(keyboard.handle(try event("\u{1b}", code: 53, flags: [])))
        scope = .quickWindow
        #expect(keyboard.handle(try event("o", code: 31)))
        scope = .switcher
        #expect(keyboard.handle(try event("w", code: 13, flags: [.control])))
        scope = .palette
        #expect(keyboard.handle(try event("\u{7f}", code: 51, flags: [.command, .option])))
        #expect(router.selectedWindow?.received == [.dismissPeek, .promoteQuickWindow, .closeSwitcherTab, .removeSuggestion])
        scope = .quickWindow
        registry.registerPrerequisite(.promoteQuickWindow) { _, _ in false }
        #expect(keyboard.handle(try event("o", code: 31))) // Disabled contextual bindings remain reserved.
        #expect(registry.resolve(.init(key: "o", modifiers: .command)) == nil)
        registry.unregisterScopeProvider("feature-overlay")
        #expect(registry.activeScope == .browser)
    }

    @Test("Modal permissions are registered per feature and editing never goes through the browser monitor")
    func modalRouting() async throws {
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        try registry.register(.newTab) { _, _ in }
        try registry.register(.dismissPeek, allowsDuringModal: true) { $0.received.append(.dismissPeek); _ = $1 }
        router.newWindow()
        await router.waitForPendingCommands()
        router.selectedWindow?.state.isModal = true
        registry.registerScopeProvider("sheet", priority: 1) { _ in .peek }
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        #expect(keyboard.handle(try event("t", code: 17))) // The modal disables the action, not its reservation.
        for input in try [event("v", code: 9), event("c", code: 8), event("x", code: 7), event("a", code: 0), event("z", code: 6)] {
            #expect(!keyboard.handle(input))
        }
        #expect(keyboard.handle(try event("\u{1b}", code: 53, flags: [])))
        #expect(router.selectedWindow?.received == [.dismissPeek])
    }

    @Test("Palette captures survive text edits but reject document, revision and retirement changes")
    func paletteCapture() async throws {
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        try registry.register(.showHideSidebar) { $0.received.append(.showHideSidebar); _ = $1 }
        let id = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let window = try #require(router.selectedWindow)
        let palette = try #require(registry.capturePaletteTarget())
        let regular = try #require(registry.captureTarget())
        let context = palette.context
        window.state.context = .init(revision: context.revision, surface: context.surface,
                                     documentGeneration: context.documentGeneration, inputToken: UUID())
        #expect(registry.dispatch(.showHideSidebar, origin: .palette, target: palette))
        #expect(!registry.dispatch(.showHideSidebar, origin: .contextMenu, target: regular))
        window.state.context = .init(revision: context.revision, surface: context.surface,
                                     documentGeneration: context.documentGeneration + 1, inputToken: UUID())
        #expect(!registry.dispatch(.showHideSidebar, origin: .palette, target: palette))
        window.state.context = .init(revision: context.revision + 1, surface: context.surface,
                                     documentGeneration: context.documentGeneration, inputToken: UUID())
        #expect(!registry.dispatch(.showHideSidebar, origin: .palette, target: palette))
        router.remove(id)
        #expect(!registry.dispatch(.showHideSidebar, origin: .palette, target: palette))
    }

    @Test("Repeat, shifted punctuation, Caps Lock, keypad and AZERTY-like base keys use one normalization")
    func layoutAndRepeat() throws {
        func input(_ text: String, _ base: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags, repeated: Bool = false) -> BrowserShortcut? {
            BrowserShortcut.input(characters: text, keyCode: code, modifiers: flags,
                                  isComposing: false, isRepeat: repeated, unmodifiedCharacters: base)
        }
        #expect(input("+", "=", 24, [.control, .shift]) == .init(key: "=", modifiers: [.control, .shift]))
        #expect(input("_", "-", 27, [.command, .shift]) == .init(key: "-", modifiers: [.command, .shift]))
        #expect(input("Z", "z", 6, [.command, .capsLock], repeated: true) == .init(key: "z", modifiers: [.command]))
        #expect(input("é", "é", 19, [.command]) == .init(key: "2", modifiers: [.command]))
        #expect(input("à", "à", 29, [.command]) == .init(key: "0", modifiers: [.command]))
        #expect(input("0", "0", 82, [.command, .numericPad]) == .init(key: "0", modifiers: [.command]))
        #expect(input("2", "2", 84, [.command, .numericPad]) == .init(key: "2", modifiers: [.command]))
        #expect(input("q", "q", 0, [.command]) == .init(key: "q", modifiers: [.command]))
        #expect(input("a", "a", 12, [.command]) == .init(key: "a", modifiers: [.command]))
        #expect(input("\u{F703}", "\u{F703}", 124, [.command, .option], repeated: true) == .init(key: "\u{F703}", modifiers: [.command, .option]))
    }

    @Test("Holding a reserved space shortcut dispatches each repeated keyDown")
    func reservedRepeat() async throws {
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        try registry.register(.nextSpace) { $0.received.append(.nextSpace); _ = $1 }
        router.newWindow()
        await router.waitForPendingCommands()
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        #expect(keyboard.handle(try event("\u{F703}", code: 124, flags: [.command, .option])))
        #expect(keyboard.handle(try event("\u{F703}", code: 124, flags: [.command, .option], repeated: true)))
        #expect(router.selectedWindow?.received == [.nextSpace, .nextSpace])
    }

    @Test("Post-page menu routing covers supplemental commands and repeats without visible placeholder items")
    func supplementalMenuAndRepeat() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        for id in [BrowserCommandID.selectTab2, .cycleExtensions, .findNext, .zoomIn, .zoomOut, .zoomToActualSize, .addSplitView] {
            try registry.register(id) { $0.received.append(id); _ = $1 }
        }
        router.newWindow()
        await router.waitForPendingCommands()
        let menus = BrowserCommandMenus(registry: registry)
        let bar = menus.makeMenuBar()
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        for input in try [event("é", code: 19), event("e", code: 14), event("g", code: 5, repeated: true), event("à", code: 29), event("0", code: 82),
                          punctuationEvent("=", base: "=", flags: [.command], repeated: true),
                          punctuationEvent("_", base: "-", flags: [.command, .shift], repeated: true),
                          punctuationEvent("+", base: "=", flags: [.control, .shift])] {
            #expect(!keyboard.handle(input))
            #expect(bar.performKeyEquivalent(with: input))
        }
        #expect(router.selectedWindow?.received == [.selectTab2, .cycleExtensions, .findNext, .zoomToActualSize, .zoomToActualSize, .zoomIn, .zoomOut, .addSplitView])
    }

    @Test("Standard editing and text menus preserve AppKit targets even when browser commands are modal-disabled")
    func standardMenuTargets() async throws {
        _ = NSApplication.shared
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        router.newWindow()
        await router.waitForPendingCommands()
        router.selectedWindow?.state.isModal = true
        let menus = BrowserCommandMenus(registry: registry)
        let commands: [BrowserCommandID] = [.undo, .redo, .cut, .copy, .paste, .selectAll, .pasteAndMatchStyle,
            .showSpellingAndGrammar, .checkDocumentNow, .checkSpellingWhileTyping, .checkGrammarWithSpelling,
            .correctSpellingAutomatically, .showSubstitutions, .smartCopyPaste, .smartQuotes, .smartDashes,
            .smartLinks, .dataDetectors, .textReplacement, .makeUpperCase, .makeLowerCase, .capitalize,
            .startSpeaking, .stopSpeaking, .underline]
        let menu = menus.makeContextMenu(commands: commands)
        #expect(menu.items.count == commands.count)
        for (item, id) in zip(menu.items, commands) {
            #expect(item.target == nil)
            #expect(item.action == BrowserStandardActions.selector(for: id))
            #expect(item.isEnabled) // Browser modal validation never owns these items.
        }
        let field = NSTextView()
        field.string = "synthetic text"
        field.setSelectedRange(.init(location: 0, length: 0))
        #expect(field.tryToPerform(#selector(NSText.selectAll(_:)), with: nil))
        #expect(field.selectedRange().length == field.string.count)
        let nativeFont = menus.makeContextMenu(commands: [.bold, .italic])
        #expect(nativeFont.items.allSatisfy { $0.target is NSFontManager })
        #expect(nativeFont.items.map(\.tag) == [2, 1])
    }

    @Test("Shifted letter and arrow events never fall through to unshifted commands")
    func exactShiftVariants() async throws {
        _ = NSApplication.shared
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        for id in [BrowserCommandID.newTab, .restoreLastClosedTab, .archiveTab, .closeWindow, .findNext,
                   .findPrevious, .openCommandBar, .showHideSidebar, .pinUnpinTab, .refreshThePage, .goBack] {
            try registry.register(id) { $0.received.append(id); _ = $1 }
        }
        router.newWindow()
        await router.waitForPendingCommands()
        router.selectedWindow?.state.canReopen = true
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        let menus = BrowserCommandMenus(registry: registry)
        let bar = menus.makeMenuBar()
        let restore = try event("T", code: 17, flags: [.command, .shift])
        #expect(registry.resolve(restore) == .restoreLastClosedTab)
        #expect(keyboard.handle(restore))
        let close = try event("W", code: 13, flags: [.command, .shift])
        #expect(registry.resolve(close) == .closeWindow)
        #expect(keyboard.handle(close))
        let previous = try event("G", code: 5, flags: [.command, .shift])
        #expect(registry.resolve(previous) == .findPrevious)
        #expect(!keyboard.handle(previous))
        #expect(bar.performKeyEquivalent(with: previous))
        for input in try [event("L", code: 37, flags: [.command, .shift]), event("S", code: 1, flags: [.command, .shift]),
                          event("R", code: 15, flags: [.command, .shift]), event("D", code: 2, flags: [.command, .shift]),
                          event("\u{F702}", code: 123, flags: [.command, .shift])] {
            #expect(registry.resolve(input) == nil)
            #expect(!keyboard.handle(input))
            #expect(!bar.performKeyEquivalent(with: input))
        }
        router.selectedWindow?.state.canReopen = false
        #expect(registry.resolve(restore) == nil)
        #expect(keyboard.handle(restore)) // Empty reopen history does not expose the shortcut to the page.
        #expect(router.selectedWindow?.received == [.restoreLastClosedTab, .closeWindow, .findPrevious])
    }

    @Test("Native text fields own arrow selection, Escape and bare function keys before keyDown")
    func nativeFieldKeyEquivalents() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        for id in [BrowserCommandID.goBack, .goForward, .exit, .developerTools] {
            try registry.register(id) { $0.received.append(id); _ = $1 }
        }
        router.newWindow()
        await router.waitForPendingCommands()
        let host = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        host.contentView = NSTextView(frame: .init(x: 0, y: 0, width: 400, height: 200))
        #expect(host.makeFirstResponder(host.contentView))
        // Dependency injection represents the key-window lookup without making it visible/key.
        let menus = BrowserCommandMenus(registry: registry, keyWindow: { host })
        let bar = menus.makeMenuBar()
        for input in try [event("\u{F702}", code: 123), event("\u{F703}", code: 124),
                          event("\u{F702}", code: 123, flags: [.command, .shift]),
                          event("\u{1b}", code: 53, flags: []), event("\u{F70F}", code: 111, flags: [])] {
            #expect(!bar.performKeyEquivalent(with: input))
        }
        #expect(router.selectedWindow?.received.isEmpty == true)
        #expect(!host.isVisible)
    }

    @Test("A non-browser key window receives Close and Minimize instead of a background tab")
    func auxiliaryWindowMenuActions() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() }, currentWindowID: { nil })
        for id in [BrowserCommandID.archiveTab, .closeWindow, .minimizeWindow] {
            try registry.register(id) { $0.received.append(id); _ = $1 }
        }
        router.newWindow()
        await router.waitForPendingCommands()
        let auxiliary = AuxiliaryKeyboardWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        auxiliary.isReleasedWhenClosed = false
        defer { auxiliary.close() }
        let menus = BrowserCommandMenus(registry: registry, keyWindow: { auxiliary })
        let bar = menus.makeMenuBar()
        #expect(bar.performKeyEquivalent(with: try event("w", code: 13)))
        #expect(bar.performKeyEquivalent(with: try event("m", code: 46)))
        #expect(auxiliary.closedByCommand == 1)
        #expect(auxiliary.minimizedByCommand == 1)
        #expect(router.selectedWindow?.received.isEmpty == true)
        #expect(!auxiliary.isVisible)
    }

    @Test("Production routing queues commands for a requested window and rejects auxiliary background fallback")
    func productionWindowRouting() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = router()
        defer { router.shutdown() }
        let browser = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
                               styleMask: [.titled], backing: .buffered, defer: true)
        let auxiliary = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
                                 styleMask: [.titled], backing: .buffered, defer: true)
        browser.isReleasedWhenClosed = false
        auxiliary.isReleasedWhenClosed = false
        defer { browser.close(); auxiliary.close() }
        var key: NSWindow? = browser
        func route() -> BrowserCommandWindowRoute {
            BrowserCommandWindowRouting.route(router: router, keyWindow: key, nativeWindow: { $0.nativeWindow })
        }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() },
            currentWindowID: { route().windowID }, permitsMissingWindow: { route().allowsMissingWindowCreation })
        for id in [BrowserCommandID.newTab, .openCommandBar, .archiveTab] {
            try registry.register(id) { $0.received.append(id); _ = $1 }
        }
        var missingCalls = 0
        try registry.registerWhenWindowMissing(.newTab) { missingCalls += 1 }
        try registry.registerWhenWindowMissing(.openCommandBar) { missingCalls += 1 }
        try registry.registerApplication(.newWindow) { router.newWindow() }
        let first = try #require(router.newWindow())
        await router.waitForPendingCommands()
        router.windows[first]?.nativeWindow = browser
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        #expect(keyboard.handle(try event("n", code: 45)))
        let second = try #require(router.selectedWindowID)
        #expect(second != first)
        #expect(route().windowID == second) // The old browser is still key during creation.
        for input in try [event("t", code: 17), event("l", code: 37), event("w", code: 13)] {
            #expect(keyboard.handle(input))
        }
        await router.waitForPendingCommands()
        #expect(router.windows[first]?.received.isEmpty == true)
        #expect(router.windows[second]?.received == [.newTab, .openCommandBar, .archiveTab])
        key = auxiliary
        for input in try [event("t", code: 17), event("l", code: 37)] {
            #expect(!keyboard.handle(input))
        }
        #expect(!registry.isEnabled(.openCommandBar))
        #expect(missingCalls == 0)
        key = nil
        #expect(!keyboard.handle(try event("l", code: 37))) // A ready background window is not a browser command target.
        router.remove(first)
        router.remove(second)
        #expect(keyboard.handle(try event("t", code: 17)))
        #expect(keyboard.handle(try event("l", code: 37)))
        #expect(missingCalls == 2)
        #expect(!browser.isVisible && !auxiliary.isVisible)
    }

    @Test("Unknown system function keys retain the AppKit menu path while extra Shift on browser keys is rejected")
    func systemFunctionKeyMenuFallback() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = router()
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        try registry.register(.developerTools) { $0.received.append(.developerTools); _ = $1 }
        router.newWindow()
        await router.waitForPendingCommands()
        let menus = BrowserCommandMenus(registry: registry)
        let bar = menus.makeMenuBar()
        let receiver = SystemKeyboardMenuTarget()
        for (key, flags) in [("\u{F700}", NSEvent.ModifierFlags.control), ("\u{F710}", NSEvent.ModifierFlags())] {
            let item = NSMenuItem(title: "Synthetic system action", action: #selector(SystemKeyboardMenuTarget.performSystemCommand(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.target = receiver
            bar.addItem(item)
        }
        // Fn-Control-Up models a system Move & Resize command inserted after composition.
        #expect(bar.performKeyEquivalent(with: try event("\u{F700}", code: 126, flags: [.control, .function])))
        #expect(bar.performKeyEquivalent(with: try event("\u{F710}", code: 105, flags: [])))
        #expect(receiver.calls == 2)
        #expect(!bar.performKeyEquivalent(with: try event("\u{F70F}", code: 111, flags: [.shift])))
        #expect(router.selectedWindow?.received.isEmpty == true)
    }

    @Test("Omitted NIB masks retain raw absence and decode F12 and Escape as zero modifiers")
    func omittedMasks() throws {
        let f12 = try #require(OrbitCommandCatalog.declarations.first { $0.source == "M-285" })
        #expect(f12.modifierMask == nil)
        #expect(f12.shortcut == .init(key: "\u{F70F}", modifiers: []))
        let escape = try #require(OrbitCommandCatalog.declarations.first { $0.source == "M-1324" })
        #expect(escape.modifierMask == nil)
        #expect(escape.shortcut == .init(key: "\u{1b}", modifiers: []))
    }
}
}
