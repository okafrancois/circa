import AppKit
import BrowserShell
import Testing
import WebKit
@testable import Orbit

/// DBG-KEYS event-level harness. It drives the production composition (`OrbitApplication`,
/// its registry, menu bar and keyboard monitor body, a real `BrowserWindowController` hosting a
/// real WKWebView) with real `NSEvent` sequences, without presenting or activating anything.
/// A prohibited application never has an AppKit key window, so `NSApp.sendEvent` cannot route
/// a key equivalent to a hidden window. The harness therefore performs NSApplication's order
/// itself — local monitor (`BrowserCommandKeyboard.handle`, the monitor's body), key window
/// `performKeyEquivalent:` (reaching WebKit), menu bar, then `keyDown:` to the first responder —
/// and injects the window as the command key window.
/// WebKit's re-dispatch of an unhandled key is real: WebKit calls `NSApp.sendEvent` with the
/// same NSEvent object. A harness-owned local monitor catches exactly that object (any other
/// event passes untouched) and replays the production order for a re-sent key: monitor, key
/// window (WebKit declines the event it is re-sending), menu bar. The dedicated test process
/// isolates NSApplication's dispatch state from application lifecycle fixtures; the monitor
/// passes every event outside this harness's in-flight presses through unchanged.
@MainActor
final class KeyRoutingHarness {
    enum Delivery: String { case monitor, page, menu, keyDown }

    let app: OrbitApplication
    let controller: OrbitWindowController
    let menuBar: NSMenu
    private(set) var trace: [String] = []
    private var inFlight: [NSEvent] = []
    /// Claimed by WebKit during an earlier press: a late answer is absorbed, never replayed.
    private var retired: [NSEvent] = []
    private var redispatchMonitor: Any?
    private var isClosed = false
    private var dispatchEvidence = EventDispatchEvidence()

    var window: NSWindow { controller.window! }
    var webView: WKWebView? { controller.session.selectedSurface?.webView }

    private init(app: OrbitApplication, controller: OrbitWindowController) {
        self.app = app
        self.controller = controller
        menuBar = app.commands.menus.makeMenuBar()
    }

    static func make() async throws -> KeyRoutingHarness {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var key: NSWindow?
        let app = OrbitApplication(environment: PreviewEnvironment(), commandKeyWindow: { key },
                                  windowPresenter: { _, _ in })
        app.windows.newWindow()
        await app.windows.waitForPendingCommands()
        let controller = try #require(app.windows.selectedWindow)
        await controller.session.waitForPendingCommands()
        key = controller.window
        let harness = KeyRoutingHarness(app: app, controller: controller)
        app.commands.registry.keyTrace.sink = { [weak harness] line in harness?.trace.append(line) }
        harness.redispatchMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak harness] event in
            let consumed = MainActor.assumeIsolated {
                guard let harness else { return false }
                let current = harness.inFlight.contains { $0 === event }
                guard current || harness.retired.contains(where: { $0 === event }) else { return false }
                if current {
                    harness.trace.append("orbit-key stage=webkit result=redispatched")
                    harness.redeliver(event)
                }
                // WebKit set this event as the application's current event before re-sending it
                // and never clears it; other suites in this process read `NSApp.currentEvent`.
                DispatchQueue.main.async {
                    if NSApp.currentEvent === event { Self.setCurrentEvent(nil) }
                }
                return true
            }
            return consumed ? nil : event
        }
        #expect(controller.window?.isVisible == false)
        return harness
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        if let redispatchMonitor { NSEvent.removeMonitor(redispatchMonitor) }
        redispatchMonitor = nil
        inFlight.removeAll()
        retired.removeAll()
        if NSApp.currentEvent?.window === controller.window || NSApp.currentEvent?.windowNumber == controller.window?.windowNumber {
            Self.setCurrentEvent(nil)
        }
        controller.window?.close()
        await app.windows.waitForPendingCommands()
        app.windows.shutdown()
        #expect(!NSApp.isActive)
    }

    enum PageKeyPolicy: String { case none, save, allCommandKeys }

    /// A synthetic page records its keydown events (`Meta+s`); it claims ⌘S, or every ⌘ key,
    /// with `preventDefault()` as a web application would. No network, no persistent data.
    static func pageHTML(_ policy: PageKeyPolicy, token: String = "") -> String {
        let script = """
        window.keys = [];
        window.pageToken = '\(token)';
        document.addEventListener('keydown', event => {
          const key = event.key.toLowerCase();
          window.keys.push((event.metaKey ? 'Meta+' : '') + key);
          if (event.metaKey && ('\(policy.rawValue)' === 'allCommandKeys' || ('\(policy.rawValue)' === 'save' && key === 's')))
            event.preventDefault();
        });
        """
        return "<!doctype html><html><body><p>keys</p><script>\(script)</script></body></html>"
    }

    func loadPage(_ policy: PageKeyPolicy, in webView: WKWebView? = nil) async throws {
        let webView = try #require(webView ?? self.webView)
        Self.keepScheduled(webView)
        // The previous document also has `window.keys`: wait for this load's own token.
        let token = UUID().uuidString
        webView.loadHTMLString(Self.pageHTML(policy, token: token), baseURL: nil)
        try await waitForPage(webView, token: token)
    }

    /// Adds the same key logger to an already loaded page (a loopback fixture in a Peek).
    /// Hidden windows are never visible: in a long, loaded test process WebKit throttles or
    /// suspends their content processes, and a key's answer can stall for seconds. Production
    /// windows are visible and key; this public preference only removes the test-only stall.
    static func keepScheduled(_ webView: WKWebView) {
        webView.configuration.preferences.inactiveSchedulingPolicy = .none
    }

    func installKeyLogger(_ policy: PageKeyPolicy, in webView: WKWebView) async throws {
        Self.keepScheduled(webView)
        let token = UUID().uuidString
        let html = Self.pageHTML(policy, token: token)
        let start = try #require(html.range(of: "<script>")).upperBound
        let end = try #require(html.range(of: "</script>")).lowerBound
        _ = try await webView.evaluateJavaScript(String(html[start..<end]) + "; true")
        try await waitForPage(webView, token: token)
    }

    func waitForLoad(_ webView: WKWebView) async throws {
        for _ in 0..<250 {
            if webView.url != nil, !webView.isLoading { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The page did not load")
    }

    func waitForPage(_ webView: WKWebView, token: String) async throws {
        for _ in 0..<500 {
            if !webView.isLoading, (try? await webView.evaluateJavaScript("window.pageToken")) as? String == token { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The synthetic page did not load")
    }

    func pageKeys(_ webView: WKWebView? = nil) async throws -> [String] {
        try #require(try await (webView ?? self.webView)?.evaluateJavaScript("window.keys") as? [String])
    }

    func clearTrace() { trace.removeAll() }

    // MARK: Events

    private static let functionKeyCodes: [String: UInt16] = ["\u{F702}": 123, "\u{F703}": 124, "\u{F701}": 125, "\u{F700}": 126,
                                                            "\u{1b}": 53, "\t": 48]

    /// The virtual key producing `character` on the host's current keyboard layout (AZERTY puts
    /// "w" on key 6, QWERTY on 13). Events built from it are physically coherent: AppKit's own
    /// menu matching and the shortcut normalizer see what a real keyboard would produce.
    static func layoutKeyCode(for character: String) -> UInt16? {
        if let code = functionKeyCodes[character] { return code }
        return (UInt16(0)...UInt16(127)).first { layoutCharacters(code: $0, flags: []) == character }
    }

    /// What the host layout produces for a virtual key (CGEvent translation, as for real input).
    static func layoutCharacters(code: UInt16, flags: CGEventFlags) -> String? {
        guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return nil }
        cgEvent.flags = flags
        guard let event = NSEvent(cgEvent: cgEvent), event.type == .keyDown else { return nil }
        return event.charactersIgnoringModifiers
    }

    /// A window-server (CGEvent-backed) key event for an explicit virtual key, as a physical
    /// keyboard or a computer-use driver produces it: characters come from the host layout.
    /// AppKit treats these differently from synthesized NSEvents in menu key-equivalent matching
    /// (DBG-KEYS-R2); `synthetic: true` keeps the older NSEvent form for comparison tests.
    func keyEvent(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags,
                  synthetic: Bool = false) throws -> NSEvent {
        var cgFlags: CGEventFlags = []
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        let arrow = (123...126).contains(code)
        if arrow { cgFlags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown))
        cgEvent.flags = cgFlags
        cgEvent.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        let hardware = try #require(NSEvent(cgEvent: cgEvent))
        guard synthetic else { return hardware }
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: hardware.modifierFlags,
            timestamp: hardware.timestamp, windowNumber: window.windowNumber, context: nil,
            characters: hardware.characters ?? "", charactersIgnoringModifiers: hardware.charactersIgnoringModifiers ?? "",
            isARepeat: false, keyCode: code))
    }

    private func keyEvent(_ type: NSEvent.EventType, _ key: String, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try keyEvent(type, code: try #require(Self.layoutKeyCode(for: key), "No key produces \(key) on this layout"), flags: flags)
    }

    private func modifierEvents(_ flags: NSEvent.ModifierFlags, down: Bool) -> [NSEvent] {
        let order: [(NSEvent.ModifierFlags, UInt16)] = [(.command, 55), (.shift, 56), (.option, 58), (.control, 59)]
        var held: NSEvent.ModifierFlags = down ? [] : flags
        var events: [NSEvent] = []
        for (flag, code) in (down ? order : order.reversed()) where flags.contains(flag) {
            if down { held.insert(flag) } else { held.remove(flag) }
            if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: held,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
                events.append(event)
            }
        }
        return events
    }

    private func isKeyEquivalentCandidate(_ event: NSEvent) -> Bool {
        event.type == .keyDown && (!event.modifierFlags.intersection([.command, .control]).isEmpty
            || event.charactersIgnoringModifiers?.unicodeScalars.first.map({ (0xF700...0xF8FF).contains($0.value) }) == true)
    }

    static func setCurrentEvent(_ event: NSEvent?) {
        NSApp.perform(Selector(("_setCurrentEvent:")), with: event)
    }

    /// NSApplication's order for one event. Returns the stage that took it.
    @discardableResult
    func deliver(_ event: NSEvent) -> Delivery {
        // WebKit and AppKit validation read the application's current event, as in sendEvent;
        // restore it afterwards, as the end of sendEvent does for the shared test process.
        let previous = NSApp.currentEvent
        Self.setCurrentEvent(event)
        defer { Self.setCurrentEvent(previous) }
        if app.commands.keyboard.handle(event) { return .monitor }
        if isKeyEquivalentCandidate(event) {
            if window.performKeyEquivalent(with: event) {
                trace.append("orbit-key stage=window result=claimed")
                if !inFlight.contains(where: { $0 === event }) { inFlight.append(event) }
                return .page
            }
            if menuBar.performKeyEquivalent(with: event) { return .menu }
        }
        window.sendEvent(event)
        return .keyDown
    }

    /// WebKit's `NSApp.sendEvent` of a key its page did not handle, inside that call.
    private func redeliver(_ event: NSEvent) {
        inFlight.removeAll { $0 === event }
        if app.commands.keyboard.handle(event) { return }
        guard isKeyEquivalentCandidate(event) else { return }
        if window.performKeyEquivalent(with: event) {
            trace.append("orbit-key stage=window result=claimed-again")
            return
        }
        _ = menuBar.performKeyEquivalent(with: event)
    }

    /// One physical chord: modifiers down, key down, key up, modifiers up. When WebKit claimed
    /// the key, wait until its asynchronous answer has been re-dispatched (or not) by WebKit.
    /// `settle` bounds the wait for WebKit's answer when the page claimed the key: generous by
    /// default (the content process is slow under a loaded parallel test run), short only where
    /// the page is expected to keep the key and no re-dispatch can end the wait early.
    @discardableResult
    func press(_ key: String, _ flags: NSEvent.ModifierFlags = .command,
               settle: Duration = .seconds(5)) async throws -> Delivery {
        try await press(code: try #require(Self.layoutKeyCode(for: key), "No key produces \(key) on this layout"), flags,
                        settle: settle)
    }

    @discardableResult
    func press(code: UInt16, _ flags: NSEvent.ModifierFlags = .command,
               settle: Duration = .seconds(5)) async throws -> Delivery {
        for event in modifierEvents(flags, down: true) { deliver(event) }
        let start = trace.count
        dispatchEvidence.begin(start: start)
        dispatchEvidence.record(reachable: Self.eventMonitorsReachable(window: window))
        let delivery = deliver(try keyEvent(.keyDown, code: code, flags: flags))
        deliver(try keyEvent(.keyUp, code: code, flags: flags))
        for event in modifierEvents(flags, down: false) { deliver(event) }
        if delivery == .page {
            // A page round trip: the web process answers on a later turn. The bounded window
            // also covers a page that handled the key and therefore never re-dispatches.
            let deadline = ContinuousClock.now + settle
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                dispatchEvidence.record(reachable: Self.eventMonitorsReachable(window: window))
                if trace[start...].contains(where: { $0.contains("stage=menu") }) { break }
            }
        }
        retired.append(contentsOf: inFlight)
        inFlight.removeAll()
        await controller.session.waitForPendingCommands()
        await app.windows.waitForPendingCommands()
        return delivery
    }

    func traceSince(_ index: Int) -> [String] { Array(trace[index...]) }

    static func eventMonitorsReachable(window: NSWindow) -> Bool {
        let canary = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 42.4242,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F716}", charactersIgnoringModifiers: "\u{F716}",
            isARepeat: false, keyCode: 80)!
        var seen = false
        let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e === canary { seen = true; return nil }
            return e
        }
        let previous = NSApp.currentEvent
        NSApp.sendEvent(canary)
        setCurrentEvent(previous)
        NSEvent.removeMonitor(m!)
        return seen
    }

    /// Whether WebKit re-dispatched a key its page saw and did not claim.
    func webKitRedispatched(since index: Int) -> Bool {
        trace[index...].contains { $0.contains("stage=webkit result=redispatched") }
    }

    /// Only canaries sampled during this press can justify its missing WebKit answer.
    struct EventDispatchEvidence {
        private var currentStart: Int?
        private(set) var missedCanaries = 0

        mutating func begin(start: Int) {
            currentStart = start
            missedCanaries = 0
        }

        mutating func record(reachable: Bool) {
            if !reachable { missedCanaries += 1 }
        }

        func canTolerate(since start: Int, strict: Bool) -> Bool {
            !strict && currentStart == start && missedCanaries > 0
        }
    }

    /// Process-wide count of tolerated cells, printed with every occurrence.
    private(set) static var degradedDispatchCount = 0

    @discardableResult
    func requireRedispatch(since start: Int, _ label: String) async -> Bool {
        if webKitRedispatched(since: start) { return true }
        let strict = ProcessInfo.processInfo.environment["ORBIT_DBG_KEYS_STRICT"] == "1"
        guard dispatchEvidence.canTolerate(since: start, strict: strict) else {
            Issue.record("\(label): WebKit did not re-dispatch an unhandled key; no missed canary in this event window (strict=\(strict))\n\(traceSince(start))")
            return false
        }
        Self.degradedDispatchCount += 1
        print("DBG-KEYS degraded event dispatch: tolerated cell \(label) (count=\(Self.degradedDispatchCount), eventMisses=\(dispatchEvidence.missedCanaries))")
        withKnownIssue("NSApp.sendEvent bypassed local event monitors during this press", isIntermittent: true) {
            Issue.record("\(label): re-dispatch unobservable")
        }
        return false
    }
}
