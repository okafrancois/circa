import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class R3MarkedEditor: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

@MainActor
private final class R3NativeTextTarget: NSObject {
    var calls = 0
    @objc func copy(_ sender: Any?) { calls += 1 }
    @objc func undo(_ sender: Any?) { calls += 1 }
    @objc func selectAll(_ sender: Any?) { calls += 1 }
}

@MainActor
private final class R3MinimizedWindow: NSWindow {
    var minimized = true
    var restoreCount = 0
    override var isMiniaturized: Bool { minimized }
    override func deminiaturize(_ sender: Any?) { minimized = false; restoreCount += 1 }
}

@MainActor
private final class R3TestWindow {
    var nativeWindow: NSWindow?
    var calls: [BrowserCommandID] = []
    var state: BrowserCommandState {
        var state = BrowserCommandState()
        state.hasWindow = true
        return state
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeCommandR3Tests {
    private func event(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 1, windowNumber: 0, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
    }

    private func productionFixture() async throws -> (BrowserWindowController<PeekSyntheticEngine>,
        BrowserCommandRegistry<BrowserWindowController<PeekSyntheticEngine>>, BrowserWindowRouter<BrowserWindowController<PeekSyntheticEngine>>) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let controller = try await environment.makeWindow()
        controller.submitAddress("https://cmd-r3.test/home")
        await controller.session.waitForPendingCommands()
        let router = BrowserWindowRouter<BrowserWindowController<PeekSyntheticEngine>>(create: { _ in controller },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        router.newWindow(id: controller.id)
        await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { window in
            var state = window?.commandState ?? .init()
            window?.applyPeekCommandState(to: &state)
            return state
        }, deliver: { window, action in window.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry)
        BrowserPeekCommands.install(in: registry)
        return (controller, registry, router)
    }

    @Test("Production Peek composition gives native text editors Escape before the overlay, including address and Find")
    func escapeTextPriority() async throws {
        let (controller, registry, router) = try await productionFixture()
        defer { router.shutdown() }
        _ = try #require(controller.openPeek(URL(string: "https://cmd-r3.test/peek")!))
        let page = try #require(controller.presentedPeekSurface)
        let window = try #require(controller.window)
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true },
                                               firstResponder: { window.firstResponder })
        let escape = try event("\u{1b}", code: 53)
        #expect(registry.activeScope == .peek)
        controller.focusAddress()
        await controller.session.waitForPendingCommands()
        #expect(controller.isTextFieldEditing)
        #expect(!keyboard.handle(escape))
        #expect(controller.isPeekPresented)
        #expect(!registry.isEnabled(.dismissPeek))
        controller.showFind()
        await controller.session.waitForPendingCommands()
        #expect(controller.isTextFieldEditing)
        #expect(!keyboard.handle(escape))
        #expect(controller.isPeekPresented)
        // Inline rename, palette and page-dialog native field editors use the same policy.
        let field = NSTextField(frame: .init(x: 0, y: 0, width: 100, height: 24))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(controller.isTextFieldEditing)
        #expect(!keyboard.handle(escape))
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 24))
        window.contentView?.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        #expect(!keyboard.handle(escape))
        #expect(controller.isPeekPresented)
        #expect(window.makeFirstResponder(page.documentView))
        #expect(!controller.isTextFieldEditing)
        #expect(keyboard.handle(escape))
        #expect(!controller.isPeekPresented)
        #expect(window.isVisible == false)
    }

    @Test("Merged raw switcher input owns its modal gesture while Peek editors and IME keep their priority")
    func mergedSwitcherRawInput() async throws {
        let (controller, registry, router) = try await productionFixture()
        defer { router.shutdown() }
        for suffix in ["second", "third"] {
            controller.session.openTab(url: URL(string: "https://cmd-r3.test/\(suffix)")!)
        }
        await controller.session.waitForPendingCommands()
        controller.tabSwitcher.controlIsHeld = { true }
        controller.focusAddress()
        await controller.session.waitForPendingCommands()
        let window = try #require(controller.window)
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true },
                                               firstResponder: { window.firstResponder })
        let tab = try event("\t", code: 48, flags: .control)
        let original = controller.session.snapshot?.selectedOccurrenceID
        #expect(keyboard.handle(tab))
        #expect(registry.activeScope == .switcher)
        #expect(controller.isTextFieldEditing, "the address editor remains underneath the modal switcher")
        #expect(keyboard.handle(try event("\t", code: 48, flags: [.control, .shift])))
        #expect(controller.tabSwitcher.model.highlightedID == original)
        let beforeTyping = registry.eventInputs.normalizationCount
        #expect(keyboard.handle(try event("k", code: 40)), "raw mode keys precede the plain-typing fast path")
        #expect(registry.eventInputs.normalizationCount == beforeTyping)
        #expect(keyboard.handle(tab))
        let count = try #require(controller.session.snapshot?.tabs.count)
        #expect(keyboard.handle(try event("w", code: 13, flags: .control)))
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.tabs.count == count - 1)
        let escape = try event("\u{1b}", code: 53)
        #expect(keyboard.handle(escape), "Escape cancels the active gesture above its underlying editor")
        #expect(!controller.tabSwitcher.model.isActive)
        _ = try #require(controller.openPeek(URL(string: "https://cmd-r3.test/raw-peek")!))
        controller.focusAddress()
        await controller.session.waitForPendingCommands()
        #expect(!keyboard.handle(escape), "without a modal gesture the Peek editor owns Escape")
        #expect(controller.isPeekPresented)
        controller.dismissPeek(animated: false)
        let page = try #require(controller.session.selectedSurface)
        #expect(window.makeFirstResponder(page.documentView))
        #expect(keyboard.handle(tab))
        let marked = R3MarkedEditor(frame: .init(x: 0, y: 0, width: 120, height: 24))
        window.contentView?.addSubview(marked)
        #expect(window.makeFirstResponder(marked))
        #expect(!keyboard.handle(try event("w", code: 13, flags: .control)))
        #expect(controller.tabSwitcher.model.isActive)
        let release = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59))
        #expect(keyboard.handle(release, isComposing: true), "modifier release closes a gesture even during IME")
        #expect(!controller.tabSwitcher.model.isActive)
        for _ in 0..<30 { await Task.yield(); await controller.session.waitForPendingCommands() }
        let committedPage = try #require(controller.session.selectedSurface)
        #expect(window.makeFirstResponder(committedPage.documentView))
        #expect(keyboard.handle(tab))
        let outside = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: -10, y: -10),
            modifierFlags: .control, timestamp: 1, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(keyboard.handle(outside, isComposing: true))
        #expect(!controller.tabSwitcher.model.isActive)
        #expect(!window.isVisible)
    }

    @Test("A disabled reserved reopen never reaches the page while the production Peek scope can reopen its own document")
    func reservedEmptyArchiveAndPeekReopen() async throws {
        let (controller, registry, router) = try await productionFixture()
        defer { router.shutdown() }
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true },
            firstResponder: { controller.window?.firstResponder })
        let reopen = try event("T", code: 17, flags: [.command, .shift])
        #expect(await controller.session.archivedTabs().value.isEmpty)
        #expect(!registry.isEnabled(.restoreLastClosedTab))
        let count = controller.session.snapshot?.tabs.count
        #expect(keyboard.handle(reopen))
        #expect(!registry.dispatch(.restoreLastClosedTab, origin: .keyboard))
        #expect(controller.session.snapshot?.tabs.count == count)
        _ = try #require(controller.openPeek(URL(string: "https://cmd-r3.test/only-peek")!))
        controller.dismissPeek(animated: false)
        #expect(await controller.session.archivedTabs().value.isEmpty)
        #expect(registry.isEnabled(.restoreLastClosedTab))
        #expect(keyboard.handle(try event("T", code: 17, flags: [.command, .shift])))
        await controller.session.waitForPendingCommands()
        #expect(controller.isPeekPresented)
    }

    @Test("IME composition defers the menu route to AppKit so standard editing items remain reachable")
    func compositionKeepsNativeMenuPath() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = BrowserWindowRouter<R3TestWindow>(create: { _ in .init() }, present: { _, _ in }, dispose: { _ in })
        defer { router.shutdown() }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = R3MarkedEditor(frame: .init(x: 0, y: 0, width: 200, height: 100))
        window.contentView = editor
        #expect(window.makeFirstResponder(editor))
        let menus = BrowserCommandMenus(registry: registry, keyWindow: { window })
        let bar = try #require(menus.makeMenuBar() as? BrowserKeyEquivalentMenu)
        let edit = try #require(bar.items.first { $0.title == "Edit" }?.submenu)
        let target = R3NativeTextTarget()
        for (id, key, code) in [(BrowserCommandID.copy, "c", UInt16(8)), (.undo, "z", 6), (.selectAll, "a", 0)] {
            let item = try #require(edit.items.first { $0.identifier?.rawValue == id.rawValue })
            #expect(item.target == nil)
            // A synthetic explicit target lets this hidden test observe super's dispatch,
            // without changing the real NSApplication key window or touching the pasteboard.
            item.target = target
            let input = try event(key, code: code, flags: .command)
            #expect(bar.routeKeyEquivalent?(input) == nil)
            #expect(bar.performKeyEquivalent(with: input))
        }
        #expect(target.calls == 3)
        #expect(!window.isVisible)
    }

    @Test("New Tab and Command Bar restore the last active minimized browser without creating another window")
    func minimizedWindows() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = BrowserWindowRouter<R3TestWindow>(create: { _ in .init() }, present: { _, _ in }, dispose: { _ in })
        defer { router.shutdown() }
        let first = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let second = try #require(router.newWindow())
        await router.waitForPendingCommands()
        let windows = (0..<2).map { _ in R3MinimizedWindow(contentRect: .zero, styleMask: [.titled, .miniaturizable], backing: .buffered, defer: true) }
        for window in windows { window.isReleasedWhenClosed = false }
        defer { windows.forEach { $0.close() } }
        router.windows[first]?.nativeWindow = windows[0]
        router.windows[second]?.nativeWindow = windows[1]
        router.activate(first)
        func route() -> BrowserCommandWindowRoute {
            BrowserCommandWindowRouting.route(router: router, keyWindow: nil, nativeWindow: { $0.nativeWindow })
        }
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() },
            currentWindowID: { route().windowID }, permitsMissingWindow: { route().allowsMissingWindowHandling })
        var created = 0
        for id in [BrowserCommandID.newTab, .openCommandBar] {
            try registry.register(id) { $0.calls.append(id); _ = $1 }
            try registry.registerWhenWindowMissing(id, withOrigin: { origin in
                BrowserCommandWindowRouting.performWhenWindowMissing(router: router, keyWindow: nil,
                    nativeWindow: { $0.nativeWindow },
                    action: { _ = registry.performRestoredWindowCommand(id, in: $0, origin: origin) },
                    create: { created += 1 })
            })
        }
        var replacementCalls = 0
        try registry.register(.newTab, replace: true) { window, origin in
            replacementCalls += 1
            #expect(origin == .keyboard)
            window.calls.append(.newTab)
        }
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        #expect(route().restorableWindowID == first)
        #expect(keyboard.handle(try event("t", code: 17, flags: .command)))
        #expect(windows[0].restoreCount == 1 && windows[1].restoreCount == 0)
        windows[0].minimized = true
        #expect(keyboard.handle(try event("l", code: 37, flags: .command)))
        #expect(windows[0].restoreCount == 2)
        #expect(router.windows[first]?.calls == [.newTab, .openCommandBar])
        #expect(router.windows[second]?.calls.isEmpty == true)
        #expect(created == 0 && replacementCalls == 1)
        #expect(windows.allSatisfy { !$0.isVisible })
    }

    @Test("Restoring minimized windows uses the merged palette handlers for New Tab and Command Bar")
    func minimizedPaletteCommands() async throws {
        let (controller, _, router) = try await productionFixture()
        defer { router.shutdown() }
        let native = R3MinimizedWindow(contentRect: .zero, styleMask: [.titled, .miniaturizable], backing: .buffered, defer: true)
        native.isReleasedWhenClosed = false
        defer { native.close() }
        var keyWindow: NSWindow?
        func route() -> BrowserCommandWindowRoute {
            BrowserCommandWindowRouting.route(router: router, keyWindow: keyWindow, nativeWindow: { _ in native })
        }
        let registry = try BrowserCommandRegistry(router: router, state: { window in
            var state = window?.commandState ?? .init()
            window?.applyPeekCommandState(to: &state)
            return state
        }, currentWindowID: { route().windowID }, permitsMissingWindow: { route().allowsMissingWindowHandling },
           deliver: { window, action in window.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry)
        for id in [BrowserCommandID.newTab, .openCommandBar] {
            try registry.registerWhenWindowMissing(id, withOrigin: { [weak registry] origin in
                BrowserCommandWindowRouting.performWhenWindowMissing(router: router, keyWindow: keyWindow,
                    nativeWindow: { _ in native }, action: { window in
                        keyWindow = native
                        _ = registry?.performRestoredWindowCommand(id, in: window, origin: origin)
                    }, create: { Issue.record("A minimized browser must be restored instead of creating a window") })
            })
        }
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true },
            firstResponder: { controller.window?.firstResponder })
        let tabCount = controller.session.snapshot?.tabs.count
        for (id, key, code) in [(BrowserCommandID.newTab, "t", UInt16(17)), (.openCommandBar, "l", 37)] {
            native.minimized = true
            keyWindow = nil
            #expect(keyboard.handle(try event(key, code: code, flags: .command)))
            await router.waitForPendingCommands()
            await controller.palette.waitForResults()
            #expect(controller.palette.isPresented)
            #expect(controller.palette.registry === registry)
            #expect(controller.palette.mode == (id == .newTab ? .newTab : .currentTab))
            #expect(registry.activeScope == .palette)
            #expect(controller.session.snapshot?.tabs.count == tabCount)
            controller.palette.dismiss(returnFocus: false)
        }
        #expect(native.restoreCount == 2)
        #expect(controller.window?.isVisible == false)
    }

    @Test("Disabled browser bindings leave auxiliary windows' Close and New Folder shortcuts untouched")
    func auxiliaryWindowReservation() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = BrowserWindowRouter<R3TestWindow>(create: { _ in .init() }, present: { _, _ in }, dispose: { _ in })
        defer { router.shutdown() }
        router.newWindow()
        await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() }, currentWindowID: { nil })
        for id in [BrowserCommandID.archiveTab, .closeWindow, .tabSwitcherForward, .selectSpace1] {
            try registry.register(id) { $0.calls.append(id); _ = $1 }
        }
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        for input in try [event("w", code: 13, flags: .command), event("W", code: 13, flags: [.command, .shift]),
                          event("N", code: 45, flags: [.command, .shift]), event("\t", code: 48, flags: .control),
                          event("1", code: 18, flags: .control)] {
            #expect(!keyboard.handle(input))
        }
        #expect(router.selectedWindow?.calls.isEmpty == true)
    }

    @Test("Routing micro-benchmark bypasses ordinary typing and shares one normalization between monitor and menu")
    func routingMicroBenchmark() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let router = BrowserWindowRouter<R3TestWindow>(create: { _ in .init() }, present: { _, _ in }, dispose: { _ in })
        defer { router.shutdown() }
        router.newWindow()
        await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.state ?? .init() })
        try registry.register(.showHideSidebar) { $0.calls.append(.showHideSidebar); _ = $1 }
        let keyboard = BrowserCommandKeyboard(registry: registry, acceptsKeyboard: { true })
        let menus = BrowserCommandMenus(registry: registry)
        let bar = try #require(menus.makeMenuBar() as? BrowserKeyEquivalentMenu)
        let ordinary = try event("a", code: 0)
        var unexpected = 0
        let start = ContinuousClock.now
        for _ in 0..<20_000 {
            if keyboard.handle(ordinary) { unexpected += 1 }
            if bar.routeKeyEquivalent?(ordinary) != nil { unexpected += 1 }
        }
        let typingTime = start.duration(to: .now)
        #expect(unexpected == 0)
        #expect(registry.eventInputs.normalizationCount == 0)
        var accepted = 0
        let chords = ContinuousClock.now
        for _ in 0..<250 {
            let input = try event("s", code: 1, flags: .command)
            if keyboard.handle(input) { unexpected += 1 }
            if bar.routeKeyEquivalent?(input) == true { accepted += 1 }
        }
        let chordTime = chords.duration(to: .now)
        #expect(unexpected == 0 && accepted == 250)
        #expect(registry.eventInputs.normalizationCount == 250)
        #expect(router.selectedWindow?.calls.count == 250)
        func micros(_ value: Duration, iterations: Double) -> Double {
            (Double(value.components.seconds) * 1_000_000 + Double(value.components.attoseconds) / 1_000_000_000_000) / iterations
        }
        print("cmd-r3 benchmark typing_pair_us=\(micros(typingTime, iterations: 20_000)) shortcut_pair_us=\(micros(chordTime, iterations: 250))")
    }
}
}

extension NativeWebKitTests.NativeCommandR3Tests {
    @Test("Close Window bypasses a session waiting for presentation")
    func closeWindowBypassesStalledSession() async throws {
        let (controller, registry, router) = try await productionFixture()
        defer { router.shutdown() }
        let window = try #require(controller.window)
        // The supplied presentation never completes until explicitly released below.
        let space = try #require(controller.session.snapshot?.activeSpaceID)
        let catalog = try #require(controller.session.catalog)
        var release: CheckedContinuation<Void, Never>?
        controller.session.activateSpaceFromSwipe(space, catalog: catalog,
            waitForPresentation: { await withCheckedContinuation { release = $0 } },
            isCurrent: { true }, completion: { _ in })
        while release == nil { await Task.yield() }
        #expect(controller.session.hasPendingCommands)
        #expect(registry.dispatch(.closeWindow, origin: .menu))
        // willClose is delivered even for a never-shown native window.
        #expect(controller.session.isClosed)
        #expect(!window.isVisible)
        release?.resume()
        await controller.session.waitForPendingCommands()
    }
}
