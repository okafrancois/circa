import Testing
import AppKit
import BrowserCore
@testable import Orbit

struct BrowserTranslationTests {
    @Test("A translated live document keeps its restoration state across window ownership changes", arguments: [true, false])
    @MainActor func translatedTabTransfer(closeSource: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: PeekSyntheticEngine())
        let source = try await environment.makeWindow()
        let destination = try await environment.makeWindow()
        defer { source.session.close(); source.window?.close(); destination.session.close(); destination.window?.close() }
        source.openTab(url: URL(string: "https://translation.test/")!)
        await source.session.waitForPendingCommands()
        let surface = try #require(source.session.selectedSurface)
        surface.supportsPageTranslation = true
        source.translation.render()
        let page = try #require(source.translation.page)
        page.detection?.cancel()
        page.state.detect(source: "de", preferred: ["en"], supported: true)
        let began = page.state.begin()
        #expect(began)
        page.state.complete()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        source.window?.contentView?.addSubview(host)
        page.host = host
        let move = try #require(source.moveSurface(surface, to: destination))
        #expect(await move.value != nil)
        await destination.session.waitForPendingCommands()
        if closeSource { source.window?.close() }
        destination.translation.render()
        #expect(host.superview === destination.window?.contentView)
        #expect(destination.translation.page === page)
        #expect(destination.translation.page?.state.phase == .translated)
        await destination.translation.page?.restore()
        #expect(surface.translationRestoreCount == 1)
        #expect(page.state.phase == .original)
        surface.navigate(to: URL(string: "https://translation.test/next")!)
        destination.translation.render()
        #expect(destination.translation.page !== page)
        #expect(page.host == nil)
    }

    @Test("Status hit testing chooses its action control before URL editing")
    @MainActor func statusHitTarget() throws {
        let root = SidebarAddressField(frame: NSRect(x: 0, y: 0, width: 300, height: 36))
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        let field = OrbitLocationField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 14)
        OrbitAddressFieldStyle.applySingleLine(to: field)
        root.installField(field)
        field.stringValue = "https://example.org/"
        field.onStatusPress = {}
        field.setStatus("Synthetic translation status", animated: false)
        root.layoutSubtreeIfNeeded()
        field.layoutSubtreeIfNeeded()
        let rect = field.statusAnchorRect
        for center in [NSPoint(x: rect.midX, y: rect.midY), NSPoint(x: rect.midX, y: rect.maxY - 0.5)] {
            let point = field.convert(center, to: root.superview)
            let hit = try #require(root.hitTest(point))
            #expect(hit is NSButton && hit.superview === field)
        }
        field.onStatusPress = nil
        let point = field.convert(NSPoint(x: rect.midX, y: rect.midY), to: root.superview)
        #expect(!(root.hitTest(point) is NSButton))
    }

    @Test func preferredLanguagesSuppressOffers() {
        var state = BrowserTranslationState()
        state.detect(source: "de-DE", preferred: ["en-US", "de-AT"], supported: true)
        #expect(state.phase == .unavailable)
        state.detect(source: "de", preferred: ["en-US"], supported: true)
        #expect(state.phase == .available)
        #expect(state.source == "de" && state.target == "en")
    }
    @Test func lifecycleAndRetry() {
        var state = BrowserTranslationState()
        let refused = state.begin()
        #expect(!refused)
        state.detect(source: "de", preferred: ["en"], supported: true)
        let started = state.begin()
        #expect(started)
        #expect(state.phase == .translating)
        let duplicate = state.begin()
        #expect(!duplicate)
        state.complete()
        #expect(state.phase == .translated)
        state.restore()
        #expect(state.phase == .original)
        let restarted = state.begin()
        #expect(restarted)
        state.fail()
        #expect(state.phase == .failed)
        let retried = state.begin()
        #expect(retried)
    }
    @Test func unavailableAndUnknownLanguages() {
        for source in [nil, "und", "mul", "zxx"] as [String?] {
            var state = BrowserTranslationState()
            state.detect(source: source, preferred: ["en"], supported: true)
            #expect(state.phase == .unavailable)
        }
        var state = BrowserTranslationState()
        state.detect(source: "de", preferred: ["en"], supported: false)
        #expect(state.phase == .unavailable)
        state.detect(source: "de", preferred: [], supported: true)
        #expect(state.phase == .unavailable)
        state.complete()
        #expect(state.phase == .unavailable)
    }
    @Test("Target selection rejects unsupported pairs and restores an actionable state")
    func targetChoice() {
        var state = BrowserTranslationState()
        let accepted1 = state.selectTarget("fr", supported: true)
        #expect(!accepted1)
        state.detect(source: "de", preferred: ["en"], supported: true)
        let accepted2 = state.selectTarget("fr", supported: false)
        #expect(!accepted2)
        let accepted3 = state.selectTarget("de-DE", supported: true)
        #expect(!accepted3)
        #expect(state.target == "en" && state.phase == .available)
        let accepted4 = state.begin()
        #expect(accepted4)
        state.complete()
        let accepted5 = state.selectTarget("fr", supported: true)
        #expect(accepted5)
        #expect(state.target == "fr" && state.phase == .available)
        let accepted6 = state.begin()
        #expect(accepted6)
        state.complete()
        state.restore()
        #expect(state.target == "fr" && state.phase == .original)
        let accepted7 = state.selectTarget("zh-Hant", supported: true)
        #expect(accepted7)
        #expect(Locale.Language(identifier: state.target).script?.identifier == "Hant")
    }

    @Test("A suppressed host retains explicit manual controls without offering translation")
    func suppressionState() {
        var state = BrowserTranslationState()
        state.suppressSite(true)
        state.detect(source: "de", preferred: ["en"], supported: true)
        #expect(!state.offersTranslation)
        #expect(state.source == "de")
        state.suppressSite(false)
        #expect(state.offersTranslation)
    }

    @Test("The menu invokes only the recorded actions with their document target")
    @MainActor func optionsActions() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var chosen = "", toggles = 0, settings = 0
        let menu = BrowserTranslationOptionsMenu(targets: ["en", "fr"], suppressed: true,
            choose: { chosen = $0 }, toggleSite: { toggles += 1 }, settings: { settings += 1 })
        #expect(menu.items.map(\.title) == [uiText("Choose Another Language"), uiText("Never Translate This Site"), "", uiText("Language Settings")])
        #expect(menu.items[1].state == .on)
        let languages = try #require(menu.items[0].submenu)
        languages.performActionForItem(at: 1)
        #expect(chosen == "fr")
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 3)
        #expect(toggles == 1 && settings == 1)
    }

    @Test("Regular windows share host preferences; an independent private environment never inherits them")
    @MainActor func privatePreferences() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let normal = BrowserEnvironment(engine: PeekSyntheticEngine())
        let first = try await normal.makeWindow(), second = try await normal.makeWindow()
        let ephemeral = BrowserEnvironment(engine: PeekSyntheticEngine())
        ephemeral.isPrivate = true
        let privateWindow = try await ephemeral.makeWindow()
        defer {
            for window in [first, second, privateWindow] { window.session.close(); window.window?.close() }
        }
        let url = URL(string: "https://translation.test/")!
        let profile = try await normal.initialContext.value.1
        var value = BrowserSitePreferences(); value.neverTranslate = true
        try first.translation.preferences.set(value, url: url, profileID: profile)
        #expect(second.translation.preferences.preferences(url: url, profileID: profile).neverTranslate)
        #expect(!privateWindow.translation.preferences.preferences(url: url, profileID: profile).neverTranslate)
        try privateWindow.translation.preferences.set(value, url: url, profileID: profile)
        #expect(privateWindow.translation.preferences.preferences(url: url, profileID: profile).neverTranslate)
        #expect(!BrowserEnvironment(engine: PeekSyntheticEngine()).sitePreferences.preferences(url: url, profileID: profile).neverTranslate)
    }

    @Test func languageDetectionUsesContent() {
        #expect(BrowserTranslationState.detectLanguage(text: "Ein Baum ist eine verholzte Pflanze mit einer Wurzel, einem Stamm und einer Krone. Die meisten Bäume haben viele grüne Blätter.", hint: "en") == "de")
        #expect(BrowserTranslationState.detectLanguage(text: "Hi", hint: "de") == nil)
    }
}
