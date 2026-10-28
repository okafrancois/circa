import AppKit
import BrowserCore
import BrowserShell
import Testing
import WebKit
@testable import Orbit
@testable import BrowserEngineConformance
@testable import WebKitEngine

@Suite("DBG-KEYS event-level keyboard routing", .serialized)
@MainActor
struct NativeDebugKeysTests {
    // MARK: Platform evidence

    /// The root cause of repro (a), pinned on the platform itself: a first-responder WKWebView
    /// without a content process claims the key equivalent and never re-dispatches it. If a
    /// future WebKit answers such keys, `WebKitDocumentView`'s guard becomes redundant.
    @Test("WebKit swallows key equivalents when its view has no content process")
    func webKitWithoutContentProcessDropsKeys() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let plain = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
        window.contentView = plain
        #expect(window.makeFirstResponder(plain))
        let code = try #require(KeyRoutingHarness.layoutKeyCode(for: "s"))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: code))
        var redispatched = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { candidate in
            guard candidate === event else { return candidate } // Swallow only this probe's event.
            redispatched += 1
            return nil // Never let the probe reach any application menu.
        }
        defer { NSEvent.removeMonitor(monitor!) }
        let previous = NSApp.currentEvent
        KeyRoutingHarness.setCurrentEvent(event)
        #expect(plain.url == nil)
        #expect(window.performKeyEquivalent(with: event), "WebKit claims the key")
        KeyRoutingHarness.setCurrentEvent(previous)
        try await Task.sleep(for: .seconds(1))
        #expect(redispatched == 0, "…and never answers it: the menu would never see ⌘S")
        #expect(!window.isVisible)
    }

    // MARK: Repro (a)

    /// VIS-2 M1: address field focused in a blank New Tab, ⌘S hides the sidebar (menu path) and
    /// hands focus to the document; every following ⌘S used to vanish inside WebKit.
    @Test("⌘S toggles the sidebar repeatedly from a blank New Tab after focus moved to its document")
    func repeatedSidebarToggleFromBlankTab() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let c = h.controller
        let document = try #require(h.webView as? WebKitDocumentView)
        #expect(document.url == nil && !document.hasContentProcess)
        #expect(h.window.makeFirstResponder(c.addressField))
        #expect(c.isEditingInSidebar)
        var expected = true
        for round in 0..<4 {
            let start = h.trace.count
            let delivery = try await h.press("s")
            expected.toggle()
            #expect(c.isSidebarVisible == expected, "round \(round)")
            #expect(delivery == .menu, "round \(round): a blank document declines; AppKit continues to the menu")
            #expect(h.traceSince(start).contains { $0.contains("command=showHideSidebar result=accepted") })
            // The hidden sidebar hands focus to the document, even when the hide is instant.
            #expect(h.window.firstResponder === document, "round \(round)")
        }
        await h.close()
    }

    /// Page-first semantics are unchanged for a live page: a page that claims ⌘S keeps it; a page
    /// that ignores it lets WebKit re-dispatch it to the browser, which toggles the sidebar.
    @Test("A live page that handles ⌘S keeps it; otherwise WebKit re-dispatches it to the sidebar toggle")
    func pageFirstSaveIsPreserved() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let c = h.controller
        try await h.loadPage(.save)
        #expect(c.session.selectedSurface?.focusDocument() == true)
        var start = h.trace.count
        #expect(try await h.press("s", settle: .seconds(1)) == .page)
        #expect(c.isSidebarVisible, "The page handled ⌘S: the browser must not act")
        #expect(!h.traceSince(start).contains { $0.contains("stage=menu") })
        #expect(try await h.pageKeys().contains("Meta+s"))

        try await h.loadPage(.none)
        #expect(c.session.selectedSurface?.focusDocument() == true)
        var visible = true
        for round in 0..<2 {
            start = h.trace.count
            #expect(try await h.press("s") == .page)
            let trace = h.traceSince(start)
            guard await h.requireRedispatch(since: start, "round \(round)") else {
                #expect(c.isSidebarVisible == visible, "Without an answer the browser must not act")
                continue
            }
            visible.toggle()
            #expect(c.isSidebarVisible == visible, "\(trace)")
            // Monitor (page-first) → WebKit claims → page → WebKit re-dispatch → monitor → menu → registry.
            #expect(trace.firstIndex { $0.contains("stage=window result=claimed") } ?? .max
                    < trace.firstIndex { $0.contains("command=showHideSidebar result=accepted") } ?? -1)
            #expect(trace.filter { $0.contains("stage=monitor") && $0.contains("result=page-first") }.count == 2)
        }
        #expect(try await h.pageKeys() == ["Meta+meta", "Meta+s", "Meta+meta", "Meta+s"])
        await h.close()
    }

    /// The same defect for a crashed page: after its content process terminates, the document
    /// declines shortcuts until a load relaunches it.
    @Test("A terminated content process no longer swallows browser shortcuts; a reload restores page-first")
    func terminatedContentProcess() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let c = h.controller
        try await h.loadPage(.save)
        let document = try #require(h.webView as? WebKitDocumentView)
        #expect(document.hasContentProcess)
        // A real crash: WebKit does not report a termination its client requested
        // (`_killWebContentProcess`). The content process is this test process's own XPC child.
        let pid = try #require(document.value(forKey: "_webProcessIdentifier") as? Int32)
        try #require(pid > 0 && pid != getpid())
        #expect(kill(pid, SIGKILL) == 0)
        for _ in 0..<300 where document.hasContentProcess { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!document.hasContentProcess)
        #expect(c.session.selectedSurface?.focusDocument() == true)
        #expect(try await h.press("s") == .menu)
        #expect(!c.isSidebarVisible)
        try await h.loadPage(.save)
        #expect(c.session.selectedSurface?.focusDocument() == true)
        #expect(try await h.press("s", settle: .seconds(1)) == .page)
        #expect(!c.isSidebarVisible, "The relaunched page claims ⌘S again")
        await h.close()
    }

    /// Hidden/occluded windows, Reduce Motion and drag-collapse hide the column instantly; the
    /// focus decision used to run after AppKit had already dropped the field editor.
    @Test("Hiding the sidebar moves keyboard focus from any sidebar responder to the content")
    func focusLeavesHiddenSidebar() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let c = h.controller
        try await h.loadPage(.none)
        let document = try #require(h.webView)
        for responder in [c.addressField as NSView, c.sidebar.page.list] {
            c.setSidebarVisible(true)
            #expect(h.window.makeFirstResponder(responder))
            #expect(c.isFocusInSidebar)
            c.setSidebarVisible(false, animated: false)
            #expect(h.window.firstResponder === document, "\(type(of: responder))")
        }
        // Drag-collapse and the Library: the Library's search field takes focus, not the page under it.
        c.setSidebarVisible(true)
        c.showLibrary(.archive)
        await c.session.waitForPendingCommands()
        #expect(h.window.makeFirstResponder(c.addressField))
        c.hideSidebar()
        await c.session.waitForPendingCommands()
        #expect(!c.isSidebarVisible)
        let editor = try #require(h.window.firstResponder as? NSText)
        #expect(editor.delegate as? NSView === c.archive.view.searchField)
        // Focus outside the sidebar stays where it is.
        c.setSidebarVisible(true)
        #expect(document.window?.makeFirstResponder(document) == true)
        c.setSidebarVisible(false, animated: false)
        #expect(h.window.firstResponder === document)
        await h.close()
    }

    // MARK: Repro (b)

    /// VIS-2: Library (Archived Tabs) with its search field focused, ⌘W. ⌘W is reserved by
    /// command ID and closes the Library itself (LIBRARY-R3) in every category, from a field
    /// editor, with the key the host layout produces "w" with.
    @Test("⌘W closes the Library from its focused search field in every category, without archiving a tab")
    func libraryCloseFromSearchField() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let c = h.controller
        try await h.loadPage(.allCommandKeys)
        let tabs = c.session.snapshot?.tabs.count
        for category in [BrowserLibraryCategory.archive, .history, .downloads] {
            c.showLibrary(category)
            await c.session.waitForPendingCommands()
            let editor = try #require(h.window.firstResponder as? NSText)
            #expect(editor.delegate as? NSView === c.libraryFocusView)
            let start = h.trace.count
            #expect(try await h.press("w") == .monitor)
            #expect(!c.library.isPresented, "\(category)")
            #expect(c.session.snapshot?.tabs.count == tabs)
            #expect(h.traceSince(start).contains { $0.contains("result=reserved") })
        }
        #expect(try await h.pageKeys().allSatisfy { !$0.hasSuffix("+w") }, "A reserved key never reaches the page")
        await h.close()
    }

    /// The probable VIS-2 injection artefact: a driver injecting the US virtual key of "w" (13)
    /// on a French AZERTY layout produces ⌘Z — Undo in the search field, no visible change.
    @Test("The US virtual key 13 follows the host layout: on AZERTY it is ⌘Z and leaves the Library open")
    func usVirtualKeyOnHostLayout() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let c = h.controller
        let produced = try #require(KeyRoutingHarness.layoutCharacters(code: 13, flags: []))
        c.showLibrary(.archive)
        await c.session.waitForPendingCommands()
        let start = h.trace.count
        let delivery = try await h.press(code: 13)
        if produced == "w" {
            #expect(delivery == .monitor && !c.library.isPresented, "QWERTY-family host")
        } else {
            // AZERTY (`com.apple.keylayout.French`): ⌘Z, page-first Undo in the field editor.
            #expect(produced == "z")
            #expect(delivery != .monitor)
            #expect(c.library.isPresented, "Not ⌘W: the Library correctly stays open")
            #expect(!h.traceSince(start).contains { $0.contains("archiveTab") })
        }
        await h.close()
    }

    // MARK: Content process tracking (DBG-KEYS-R2)

    /// `hasContentProcess` must agree with WebKit's real process for every public entry point
    /// measured to launch one (script evaluation, web archives) and those that do not. The pid is
    /// read through WebKit's test SPI, in this test only.
    @Test("The document tracks the content process for every public entry point that launches it")
    func contentProcessTrackingMatchesWebKit() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)

        struct ScriptResult: Sendable {
            let errorCode: Int?
            let boolean: Bool?

            init(_ value: Any?, _ error: (any Error)?) {
                errorCode = error.map { ($0 as NSError).code }
                boolean = value as? Bool
            }

            init(_ result: Result<Any, any Error>) {
                switch result {
                case .success(let value): self.init(value, nil)
                case .failure(let error): self.init(nil, error)
                }
            }
        }

        func observe(_ action: @MainActor () async throws -> Any?) async -> ScriptResult {
            do { return ScriptResult(try await action(), nil) }
            catch { return ScriptResult(nil, error) }
        }

        func check(_ name: String, launches: Bool, expectsError: Bool? = nil, boolean: Bool? = nil,
                   action: @MainActor (WKWebView) async -> ScriptResult) async throws {
            let surface = WebKitSurface(profileID: ProfileID(), dataStore: .nonPersistent())
            defer { surface.dispose() }
            let document = try #require(surface.webView as? WebKitDocumentView)
            #expect(!document.hasContentProcess)
            // Deliberately pass WKWebView, so the real public Swift overlays are exercised.
            // A future overlay bypass of an overridden __ selector must fail loudly here.
            let result = await action(document)
            try await Task.sleep(for: .milliseconds(100))
            let pid = try #require(document.value(forKey: "_webProcessIdentifier") as? Int32)
            #expect((pid > 0) == launches, "\(name): WebKit's own process-launch behavior changed")
            #expect(document.hasContentProcess == (pid > 0),
                    "OVERLAY/TRACKING REGRESSION: \(name) bypassed a __ override or recorded a rejected launch")
            if let expectsError {
                #expect((result.errorCode != nil) == expectsError, "\(name): unexpected script outcome")
            }
            if let boolean { #expect(result.boolean == boolean, "\(name): supported arguments changed") }
        }

        typealias ScriptAction = @MainActor (WKWebView, String, [String: Any], WKContentWorld) async -> ScriptResult
        let evaluations: [(String, ScriptAction)] = [
            ("evaluateJavaScript async", { view, script, _, _ in
                await observe { try await view.evaluateJavaScript(script) } }),
            ("evaluateJavaScript callback", { view, script, _, _ in
                await withCheckedContinuation { done in
                    view.evaluateJavaScript(script) { value, error in done.resume(returning: ScriptResult(value, error)) }
                } }),
            ("evaluateJavaScript world async overlay", { view, script, _, world in
                await observe { try await view.evaluateJavaScript(script, in: nil, contentWorld: world) } }),
            ("evaluateJavaScript world Result overlay", { view, script, _, world in
                await withCheckedContinuation { done in
                    view.evaluateJavaScript(script, in: nil, in: world) { done.resume(returning: ScriptResult($0)) }
                } }),
            ("evaluateJavaScript refined callback", { view, script, _, world in
                await withCheckedContinuation { done in
                    view.__evaluateJavaScript(script, inFrame: nil, in: world) { value, error in
                        done.resume(returning: ScriptResult(value, error))
                    }
                } })
        ]
        for (name, action) in evaluations {
            for (label, script, fails) in [("value", "true", false), ("empty script", "", false),
                                           ("runtime error", "throw new Error('synthetic')", true),
                                           ("syntax error", "const =", true)] {
                try await check("\(name) / \(label)", launches: true, expectsError: fails,
                                boolean: label == "value" ? true : nil) {
                    await action($0, script, [:], .defaultClient)
                }
            }
        }

        let asyncCalls: [(String, ScriptAction)] = [
            ("callAsyncJavaScript async overlay", { view, script, arguments, world in
                await observe { try await view.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: world) } }),
            ("callAsyncJavaScript Result overlay", { view, script, arguments, world in
                await withCheckedContinuation { done in
                    view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: world) {
                        done.resume(returning: ScriptResult($0))
                    }
                } }),
            ("callAsyncJavaScript refined callback", { view, script, arguments, world in
                await withCheckedContinuation { done in
                    view.__callAsyncJavaScript(script, arguments: arguments, inFrame: nil, in: world) { value, error in
                        done.resume(returning: ScriptResult(value, error))
                    }
                } })
        ]
        let supported: [String: Any] = [
            "number": NSNumber(value: 7), "string": NSString(string: "synthetic"),
            "date": NSDate(timeIntervalSince1970: 0), "nothing": NSNull(),
            "nested": NSArray(array: [NSDictionary(dictionary: ["value": NSNumber(value: 9)])]),
            "numericKeys": NSDictionary(object: "synthetic", forKey: NSNumber(value: 7)),
            "native": ["array": [true, 3, "swift"], "date": Date(timeIntervalSince1970: 0)] as [String: Any]
        ]
        let supportedScript = """
            return number === 7 && string === 'synthetic' && date.getTime() === 0 && nothing === null
                && nested[0].value === 9 && numericKeys[7] === 'synthetic'
                && native.array[0] === true && native.array[1] === 3
                && native.array[2] === 'swift' && native.date.getTime() === 0;
            """
        // Swift collections create temporary Foundation wrappers during validation. Many
        // sibling containers must remain distinguishable, including a rejected leaf visited
        // after the other siblings (the traversal uses a LIFO work list).
        let siblingContainers: [[String: [Any]]] = (0..<512).map { ["values": [$0]] }
        var invalidSiblings = siblingContainers
        invalidSiblings[0] = ["values": [NSObject()]]
        for (name, action) in asyncCalls {
            try await check("\(name) / many Swift sibling containers", launches: true,
                            expectsError: false, boolean: true) {
                await action($0, "return siblings.length === 512 && siblings[511].values[0] === 511",
                             ["siblings": siblingContainers], .page)
            }
            try await check("\(name) / supported Foundation and Swift arguments", launches: true,
                            expectsError: false, boolean: true) {
                await action($0, supportedScript, supported, .page)
            }
            for (label, arguments) in [
                ("invalid NSObject", ["value": NSObject()] as [String: Any]),
                ("invalid nested array", ["value": [1, [NSObject()]]] as [String: Any]),
                ("invalid nested dictionary", ["value": ["nested": ["bad": NSObject()]]] as [String: Any]),
                ("invalid leaf after many Swift sibling containers", ["siblings": invalidSiblings] as [String: Any]),
                ("invalid dictionary key", ["value": NSDictionary(object: "synthetic", forKey: NSData())] as [String: Any])
            ] {
                try await check("\(name) / \(label)", launches: false, expectsError: true) {
                    await action($0, "return true", arguments, .page)
                }
            }
            for (label, script, fails) in [("empty script", "", false),
                                           ("runtime error", "throw new Error('synthetic')", true),
                                           ("syntax error", "const =", true)] {
                try await check("\(name) / \(label)", launches: true, expectsError: fails) {
                    await action($0, script, [:], .page)
                }
            }
        }

        // Public factories provide valid, nonoptional worlds. An empty name is a supported
        // boundary, not an invalid world. Do not manufacture a nil/uninitialized ObjC object.
        let emptyNamedWorld = WKContentWorld.world(name: "")
        #expect(emptyNamedWorld.name == "")
        for (name, action) in Array(evaluations.dropFirst(2)) + asyncCalls {
            let script = name.hasPrefix("callAsync") ? "return true" : "true"
            try await check("\(name) / empty named content world", launches: true, expectsError: false, boolean: true) {
                await action($0, script, [:], emptyNamedWorld)
            }
        }

        let archives: [(String, @MainActor (WKWebView) async -> ScriptResult)] = [
            ("createWebArchiveData refined async import", { view in
                await observe { try await view.__createWebArchiveData() } }),
            ("createWebArchiveData Result overlay", { view in
                await withCheckedContinuation { done in
                    view.createWebArchiveData { result in
                        switch result {
                        case .success(let data): done.resume(returning: ScriptResult(data, nil))
                        case .failure(let error): done.resume(returning: ScriptResult(nil, error))
                        }
                    }
                } }),
            ("createWebArchiveData refined callback", { view in
                await withCheckedContinuation { done in
                    view.__createWebArchiveData { data, error in done.resume(returning: ScriptResult(data, error)) }
                } })
        ]
        for (name, action) in archives {
            try await check(name, launches: true, expectsError: false, action: action)
        }

        // Optional completion handlers must not determine whether tracking records a launch.
        let noCompletion: [(String, Bool, @MainActor (WKWebView) -> Void)] = [
            ("evaluateJavaScript no callback", true, { $0.evaluateJavaScript("true", completionHandler: nil) }),
            ("evaluateJavaScript Result overlay no callback", true, {
                $0.evaluateJavaScript("true", in: nil, in: .defaultClient, completionHandler: nil) }),
            ("evaluateJavaScript refined no callback", true, {
                $0.__evaluateJavaScript("true", inFrame: nil, in: .defaultClient, completionHandler: nil) }),
            ("callAsyncJavaScript Result overlay no callback", true, {
                $0.callAsyncJavaScript("return true", in: nil, in: .page, completionHandler: nil) }),
            ("callAsyncJavaScript refined nil arguments no callback", true, {
                $0.__callAsyncJavaScript("return true", arguments: nil, inFrame: nil, in: .page, completionHandler: nil) }),
            ("callAsyncJavaScript Result overlay rejected without callback", false, {
                $0.callAsyncJavaScript("return true", arguments: ["bad": NSObject()], in: nil, in: .page,
                                      completionHandler: nil) }),
            ("callAsyncJavaScript refined rejected without callback", false, {
                $0.__callAsyncJavaScript("return true", arguments: ["bad": NSObject()], inFrame: nil, in: .page,
                                        completionHandler: nil) })
        ]
        for (name, launches, action) in noCompletion {
            try await check(name, launches: launches) {
                action($0)
                return ScriptResult(nil, nil)
            }
        }

        let nonLaunching: [(String, @MainActor (WKWebView) async -> Void)] = [
            ("untouched", { _ in }),
            ("find", { _ = try? await $0.find("x") }),
            ("takeSnapshot", { _ = try? await $0.takeSnapshot(configuration: nil) }),
            ("pdf", { _ = try? await $0.pdf() }),
            ("pageZoom", { $0.pageZoom = 1.5 })
        ]
        for (name, action) in nonLaunching {
            try await check(name, launches: false) {
                await action($0)
                return ScriptResult(nil, nil)
            }
        }
    }

    /// The review case: a script makes a never-loaded document handle ⌘S. The page, not the
    /// browser, must then receive it first and keep it.
    @Test("A script that installs a ⌘S handler in a never-loaded document receives ⌘S first")
    func scriptedBlankDocumentKeepsPageFirst() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let c = h.controller
        let document = try #require(h.webView as? WebKitDocumentView)
        #expect(document.url == nil && !document.hasContentProcess)
        try await h.installKeyLogger(.save, in: document)
        #expect(document.hasContentProcess)
        #expect(c.session.selectedSurface?.focusDocument() == true)
        let start = h.trace.count
        #expect(try await h.press("s", settle: .seconds(1)) == .page)
        #expect(c.isSidebarVisible, "The scripted page claimed ⌘S")
        #expect(!h.traceSince(start).contains { $0.contains("showHideSidebar") })
        #expect(try await h.pageKeys(document).contains("Meta+s"))
        await h.close()
    }

    // MARK: Hardware events (DBG-KEYS-R2, VIS-3 VIS3-02)

    /// AppKit reports a disabled menu match differently for window-server events: the native
    /// lookup returned nothing for every real key, so reserved keys fell to the page and Escape
    /// never closed a Peek. Every catalog binding the host layout can type must resolve the same
    /// for a hardware event as for a synthesized one.
    @Test("Hardware and synthesized key events resolve the same catalog bindings")
    func hardwareLookupMatchesSynthetic() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let registry = h.app.commands.registry
        var compared = 0
        for (key, flags, id) in [("w", NSEvent.ModifierFlags.command, BrowserCommandID.archiveTab), ("l", .command, .openCommandBar),
                                 ("t", .command, .newTab), ("s", .command, .showHideSidebar), ("f", .command, .find),
                                 ("t", [.command, .shift], .restoreLastClosedTab), ("\u{1b}", [], .dismissPeek),
                                 ("\u{F703}", [.command, .option], .nextSpace), ("q", .command, .quitOrbit)] {
            let code = try #require(KeyRoutingHarness.layoutKeyCode(for: key))
            let hardware = try #require(BrowserShortcutEvent(try h.keyEvent(.keyDown, code: code, flags: flags)))
            let synthetic = try #require(BrowserShortcutEvent(try h.keyEvent(.keyDown, code: code, flags: flags, synthetic: true)))
            let scope: BrowserCommandScope = id == .dismissPeek ? .peek : .browser
            #expect(registry.resolveBinding(hardware, scope: scope) == id, "\(id.rawValue) hardware")
            #expect(registry.resolveBinding(synthetic, scope: scope) == id, "\(id.rawValue) synthesized")
            #expect(Set(registry.matchingDefinitions(hardware).map(\.id)) == Set(registry.matchingDefinitions(synthetic).map(\.id)))
            compared += 1
        }
        #expect(compared == 9)
        await h.close()
    }

    /// VIS3-02: address field → Escape (the field owns it, the Peek stays) → focus the Peek's page
    /// (no editable field) → Escape closes the Peek, through the monitor, before WebKit sees it.
    @Test("Escape from a focused Peek page closes the Peek; the address field keeps its own Escape")
    func escapeClosesPeekFromItsPage() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let c = h.controller
        try await h.loadPage(.none)
        let server = try ConformanceFixtureServer()
        try await server.start()
        defer { server.stop() }
        let surface = try #require(c.openPeek(server.url("/posted")))
        try await h.waitForLoad(surface.webView)
        try await h.installKeyLogger(.none, in: surface.webView)
        #expect(h.window.makeFirstResponder(c.addressField))
        var start = h.trace.count
        #expect(try await h.press("\u{1b}", []) == .keyDown)
        #expect(c.isPeekPresented, "The address field editor owns Escape")
        #expect(!h.traceSince(start).contains { $0.contains("dismissPeek") })
        // A click in the Peek document makes its web view first responder.
        #expect(surface.focusDocument())
        #expect(c.isPeekPageFocused)
        start = h.trace.count
        #expect(try await h.press("\u{1b}", []) == .monitor)
        #expect(!c.isPeekPresented, "\(h.traceSince(start))")
        #expect(h.traceSince(start).contains { $0.contains("command=dismissPeek result=accepted") })
        #expect(h.traceSince(start).contains { $0.contains("code=53") && $0.contains("result=reserved") })
        #expect(try await h.pageKeys(surface.webView).isEmpty, "The Peek page never sees the Escape that closes it")
        // Reserved keys from a focused live page never reach it either (VIS-3 showed ⌘W page-first).
        _ = c.session.selectedSurface?.focusDocument()
        start = h.trace.count
        #expect(try await h.press("l") == .monitor)
        #expect(h.traceSince(start).contains { $0.contains("result=reserved") })
        await h.close()
    }

    @Test("A lost canary cannot excuse another event after monitors recover; strict never tolerates")
    func canaryToleranceIsEventScoped() {
        var evidence = KeyRoutingHarness.EventDispatchEvidence()
        evidence.begin(start: 10)
        evidence.record(reachable: false)
        #expect(evidence.missedCanaries == 1)
        #expect(evidence.canTolerate(since: 10, strict: false))
        #expect(!evidence.canTolerate(since: 10, strict: true))
        #expect(!evidence.canTolerate(since: 11, strict: false))
        evidence.begin(start: 20)
        evidence.record(reachable: true)
        #expect(evidence.missedCanaries == 0)
        #expect(!evidence.canTolerate(since: 20, strict: false), "Recovered monitors require an independent successful answer")
        evidence.record(reachable: false)
        evidence.record(reachable: false)
        #expect(evidence.missedCanaries == 2)
        #expect(evidence.canTolerate(since: 20, strict: false))
        #expect(!evidence.canTolerate(since: 10, strict: false))
    }

    // MARK: Matrix

    private struct Shortcut {
        let key: String
        let flags: NSEvent.ModifierFlags
        let command: BrowserCommandID
        let pageKey: String
        var reserved: Bool { BrowserShortcutPriority.reserved.contains(command) }
    }

    private static let shortcuts: [Shortcut] = [
        .init(key: "w", flags: .command, command: .archiveTab, pageKey: "Meta+w"),
        .init(key: "t", flags: .command, command: .newTab, pageKey: "Meta+t"),
        .init(key: "l", flags: .command, command: .openCommandBar, pageKey: "Meta+l"),
        .init(key: "\u{F703}", flags: [.command, .option], command: .nextSpace, pageKey: "Meta+arrowright"),
        .init(key: "s", flags: .command, command: .showHideSidebar, pageKey: "Meta+s"),
        .init(key: "f", flags: .command, command: .find, pageKey: "Meta+f"),
        .init(key: "d", flags: .command, command: .pinUnpinTab, pageKey: "Meta+d"),
        .init(key: "\u{F702}", flags: .command, command: .goBack, pageKey: "Meta+arrowleft")
    ]

    private enum Focus: String {
        case livePage, claimingPage, blankDocument, address, tabList, window, library, palette, peek, claimingPeek
    }

    /// Reserved shortcuts × page-first shortcuts × focus states × overlays (Library, palette, Peek,
    /// hidden sidebar). Handlers are replaced by recorders so state stays fixed; routing (monitor,
    /// WebKit, menu, scopes, prerequisites, enablement) is the production one. Invariants:
    /// a reserved key is consumed by the monitor and never reaches a page; a page-first key reaches
    /// a live focused page first; nothing vanishes — every chord ends in the monitor, a live page,
    /// or the menu stage, and a browser decision always names the expected command.
    @Test("No shortcut vanishes across reserved/page-first × focus × overlay states")
    func routingMatrix() async throws {
        let h = try await KeyRoutingHarness.make()
        defer { Task { await h.close() } }
        let c = h.controller
        let registry = h.app.commands.registry
        var recorded: [BrowserCommandID] = []
        for id in Self.shortcuts.map(\.command) where registry.isImplemented(id) {
            // Pin/Unpin has a feature-owned validator; replacing its action must preserve it.
            try registry.register(id, replace: true,
                                  validate: id == .pinUnpinTab ? { $0.canTogglePinFromSidebar } : nil) {
                _, _ in recorded.append(id)
            }
        }
        c.palette.registry = registry
        let server = try ConformanceFixtureServer()
        try await server.start()
        defer { server.stop() }
        let blank = try #require(h.webView)
        // A second, live tab; the first one stays a never-loaded blank document.
        c.session.openTab()
        await c.session.waitForPendingCommands()
        let live = try #require(h.webView)
        #expect(live !== blank)
        try await h.loadPage(.none, in: live)

        func select(_ webView: WKWebView) async {
            guard let surface = c.session.ownedSurfaces.first(where: { $0.webView === webView }),
                  let occurrence = c.session.occurrenceID(for: surface) else { return }
            c.session.selectOccurrence(occurrence)
            await c.session.waitForPendingCommands()
        }

        func prepare(_ focus: Focus, sidebarHidden: Bool) async throws -> WKWebView? {
            c.palette.dismiss(returnFocus: false)
            c.dismissPeek(animated: false)
            c.hideLibrary(focus: false)
            c.setSidebarVisible(!sidebarHidden, animated: false)
            await select(focus == .blankDocument ? blank : live)
            switch focus {
            case .livePage, .blankDocument:
                _ = c.session.selectedSurface?.focusDocument()
                return focus == .livePage ? live : nil
            case .claimingPage:
                try await h.loadPage(.allCommandKeys, in: live)
                _ = c.session.selectedSurface?.focusDocument()
                return live
            case .address: h.window.makeFirstResponder(c.addressField)
            case .tabList: h.window.makeFirstResponder(c.sidebar.page.list)
            case .window: h.window.makeFirstResponder(nil)
            case .library:
                c.showLibrary(.archive)
                await c.session.waitForPendingCommands()
            case .palette:
                c.palette.present(.currentTab)
                await c.session.waitForPendingCommands()
                #expect(c.palette.isPresented)
            case .peek, .claimingPeek:
                // `/page` claims every key itself (preventDefault); `/posted` handles none.
                let surface = try #require(c.openPeek(server.url(focus == .peek ? "/posted" : "/page?id=peek")))
                try await h.waitForLoad(surface.webView)
                try await h.installKeyLogger(.none, in: surface.webView)
                #expect(surface.focusDocument())
                return surface.webView
            }
            return nil
        }

        let states: [(Focus, Bool)] = [
            (.livePage, false), (.claimingPage, false), (.blankDocument, false), (.address, false),
            (.tabList, false), (.window, false), (.library, false), (.palette, false), (.peek, false), (.claimingPeek, false),
            (.livePage, true), (.claimingPage, true), (.blankDocument, true), (.window, true), (.library, true)
        ]
        var cells = 0
        for (focus, hidden) in states {
            let page = try await prepare(focus, sidebarHidden: hidden)
            if focus == .livePage { try await h.loadPage(.none, in: live); _ = c.session.selectedSurface?.focusDocument() }
            for shortcut in Self.shortcuts {
                let label = "\(focus.rawValue)\(hidden ? "+hidden" : "") \(shortcut.command.rawValue)"
                var before: [String] = []
                if let page { before = try await h.pageKeys(page) }
                let recordedBefore = recorded.count
                let wasEnabled = registry.isEnabled(shortcut.command)
                let start = h.trace.count
                let claiming = focus == .claimingPage || focus == .claimingPeek
                let delivery = try await h.press(shortcut.key, shortcut.flags,
                                                 settle: claiming ? .seconds(1) : .seconds(5))
                let trace = h.traceSince(start)
                var pageSaw = false
                if let page {
                    let after = try await h.pageKeys(page)
                    pageSaw = after.count > before.count && after.last == shortcut.pageKey
                }
                let menu = trace.last { $0.contains("stage=menu") && $0.contains("type=10") }
                cells += 1
                if shortcut.reserved {
                    #expect(delivery == .monitor, "\(label)")
                    #expect(!pageSaw, "\(label): a reserved key reached the page")
                    #expect(trace.contains { $0.contains("command=\(shortcut.command.rawValue) result=") }, "\(label)")
                    continue
                }
                #expect(delivery != .monitor, "\(label): page-first keys are not taken by the monitor")
                if page != nil {
                    #expect(delivery == .page && pageSaw, "\(label): the focused live page sees the key first")
                    if focus == .claimingPage || focus == .claimingPeek {
                        #expect(menu == nil && recorded.count == recordedBefore, "\(label): the page kept it")
                    }
                } else {
                    #expect(delivery != .page, "\(label): no live page may claim the key")
                }
                // Nothing vanishes: a live page that did not claim the key re-dispatches it.
                var toleratedMissingRedispatch = false
                if focus != .claimingPage && focus != .claimingPeek {
                    let pageKept = delivery == .page && menu == nil
                    if pageKept, page != nil, shortcut.command != .goBack {
                        toleratedMissingRedispatch = !(await h.requireRedispatch(since: start, label))
                    } else {
                        // WebKit's own editing bindings (⌘← in a document) may legitimately handle a key.
                        #expect(menu != nil || (pageKept && shortcut.command == .goBack), "\(label): the key vanished\n\(trace)")
                    }
                }
                if wasEnabled && !claiming && !toleratedMissingRedispatch {
                    #expect(menu?.contains("result=browser") == true, "\(label): enabled command must reach the browser menu\n\(trace)")
                    #expect(recorded.count == recordedBefore + 1 && recorded.last == shortcut.command,
                            "\(label): enabled command must execute exactly once")
                    #expect(trace.contains { $0.contains("stage=dispatch command=\(shortcut.command.rawValue) result=accepted") },
                            "\(label): expected accepted dispatch\n\(trace)")
                }
                if let dispatched = trace.last(where: { $0.contains("stage=dispatch") && $0.contains("result=accepted") }) {
                    #expect(dispatched.contains("command=\(shortcut.command.rawValue) "), "\(label): \(dispatched)")
                }
            }
        }
        #expect(cells == states.count * Self.shortcuts.count)
        #expect(recorded.contains(.showHideSidebar) && recorded.contains(.archiveTab))
        await h.close()
    }
}
