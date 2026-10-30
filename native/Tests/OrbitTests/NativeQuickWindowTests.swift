import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class QuickWindowHostProbe: NSView {
    var moves: [(window: NSWindow?, size: NSSize)] = []
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        moves.append((window, superview?.bounds.size ?? .zero))
    }
}

@MainActor
private final class LimitedQuickWindowEngine: BrowserEngine {
    let reference = PeekSyntheticEngine()
    let kind = BrowserEngineKind.synthetic
    let capabilities: BrowserEngineCapabilities = []
    var extensions: (any BrowserExtensionHost)? { nil }
    func profile(for id: ProfileID) -> BrowserEngineProfile { reference.profile(for: id) }
    func makeSurface(profileID: ProfileID, delegate: any BrowserEngineSurfaceDelegate<PeekSyntheticSurface>) -> PeekSyntheticSurface {
        reference.makeSurface(profileID: profileID, delegate: delegate)
    }
    func shutdown() async { await reference.shutdown() }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativeQuickWindowTests {
    private typealias Environment = BrowserEnvironment<PeekSyntheticEngine>
    private typealias Window = BrowserWindowController<PeekSyntheticEngine>

    private func setup() async throws -> (Environment, Window) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = Environment(engine: PeekSyntheticEngine())
        return (environment, try await environment.makeWindow())
    }

    @Test("An empty Little Circa owns an unloaded surface and leaves the v3 session unchanged")
    func emptyWindow() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let before = await environment.store.sessionDocument()
        let little = try await environment.makeQuickWindow(spaceID: main.session.snapshot?.activeSpaceID)
        let surface = try #require(little.surface)
        #expect(surface.requestedURLs.isEmpty)
        #expect(surface.profileID == main.session.activeProfileID)
        #expect(surface.placement == .init(container: .quickWindow, windowID: little.id))
        #expect(surface.hostView.window === little.window)
        #expect(little.container.owns(surface))
        #expect(little.window?.isVisible == false && !NSApp.isActive)
        #expect(await environment.store.sessionDocument() == before)
        #expect(BrowserSessionDocument.currentVersion == 4)
        little.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(little.addressField.accessibilityLabel() == "Address")
        #expect(little.openButton.accessibilityLabel() == "Open in Personal")
        #expect(little.window?.contentView?.subviews.first?.frame.height == 47)
        little.window?.performClose(nil)
        #expect(little.isClosed && surface.isDisposed)
        #expect(environment.quickWindows.isEmpty)
    }

    @Test("Empty windows focus the address while external documents focus their page")
    func initialFocus() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let empty = try await environment.makeQuickWindow()
        empty.focusInitialContent()
        let input = try #require(empty.compactInput)
        #expect(input.window.firstResponder === input.input.currentEditor())
        #expect(input.input.currentEditor() is NSTextView)
        input.hide()
        let loaded = try await environment.makeQuickWindow(url: URL(string: "https://little.test/focus")!)
        let surface = try #require(loaded.surface)
        loaded.focusInitialContent()
        #expect(loaded.window?.firstResponder === surface.documentView)
        #expect(empty.window?.isVisible == false && loaded.window?.isVisible == false && !NSApp.isActive)
    }

    @Test("Promotion keeps the same document and history and closes only the Little Circa owner")
    func livePromotion() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let first = URL(string: "https://little.test/first")!, second = URL(string: "https://little.test/second")!
        let little = try await environment.makeQuickWindow(spaceID: main.session.snapshot?.activeSpaceID, url: first)
        let surface = try #require(little.surface)
        surface.navigate(to: second)
        surface.documentState = "unsaved synthetic form"
        let generation = surface.documentGeneration
        main.window?.contentView?.layoutSubtreeIfNeeded()
        little.window?.contentView?.layoutSubtreeIfNeeded()
        let probe = QuickWindowHostProbe(frame: surface.hostView.bounds)
        surface.hostView.addSubview(probe)
        probe.moves.removeAll()
        let task = try #require(little.promote(to: main))
        #expect(!little.container.owns(surface))
        #expect(surface.delegate === main)
        let occurrence = try #require(await task.value)
        await main.session.waitForPendingCommands()
        #expect(main.session.selectedSurface === surface)
        #expect(main.session.occurrenceID(for: surface) == occurrence)
        #expect(surface.documentState == "unsaved synthetic form")
        #expect(surface.requestedURLs == [first, second])
        #expect(surface.documentGeneration == generation)
        #expect(surface.navigationState.canGoBack)
        #expect(little.isClosed && !surface.isDisposed)
        #expect(environment.quickWindows.isEmpty)
        #expect(surface.hostView.window === main.window)
        #expect(surface.placement.container == .tab)
        #expect(little.window?.animationBehavior == NSWindow.AnimationBehavior.none)
        #expect(!probe.moves.isEmpty)
        #expect(probe.moves.allSatisfy { $0.window === main.window && $0.size.width > 0 && $0.size.height > 0 })
        #expect(surface.hostView.frame == surface.hostView.superview?.bounds)
    }

    @Test("Foreign-profile and retiring receivers refuse before the document moves")
    func refusal() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let little = try await environment.makeQuickWindow(url: URL(string: "https://little.test/source")!)
        let surface = try #require(little.surface)
        let profile = await environment.store.createProfile(name: "Synthetic second profile")
        let space = try await environment.store.createSpace(name: "Synthetic second Space", profileID: profile)
        let foreign = try await environment.makeWindow(spaceID: space)
        defer { foreign.window?.close() }
        #expect(little.promote(to: foreign) == nil)
        main.freezeCommandsForTermination()
        #expect(little.promote(to: main) == nil)
        main.cancelTerminationPreparation()
        #expect(little.container.owns(surface) && surface.delegate === little)
        #expect(surface.requestedURLs.count == 1)
        #expect(!little.isClosed)
    }

    @Test("A recording failure restores the live document, delegate, placement and host")
    func rollback() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let little = try await environment.makeQuickWindow(url: URL(string: "https://little.test/rollback")!)
        let surface = try #require(little.surface)
        surface.documentState = "retained"
        let adoption = try #require(little.promote(to: main))
        little.window?.performClose(nil)
        #expect(!little.isClosed, "normal close is vetoed until adoption settles")
        main.session.close()
        #expect(await adoption.value == nil)
        #expect(!little.isClosed && little.promotion == nil)
        #expect(little.container.owns(surface) && surface.delegate === little)
        #expect(surface.placement == .init(container: .quickWindow, windowID: little.id))
        #expect(surface.hostView.window === little.window)
        #expect(surface.documentState == "retained" && surface.requestedURLs.count == 1)
    }

    @Test("A forced source close during a failed transfer rescues the original document")
    func rescueWhenBothClose() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); environment.rescue.close(); main.window?.close() }
        let little = try await environment.makeQuickWindow(url: URL(string: "https://little.test/rescue")!)
        let surface = try #require(little.surface)
        let adoption = try #require(little.promote(to: main))
        little.retire()
        main.session.close()
        #expect(await adoption.value == nil)
        #expect(environment.rescue.owns(surface))
        #expect(!surface.isDisposed && surface.requestedURLs.count == 1)
    }

    @Test("Promotion out of Little Circa leaves an existing split intact and selects a standalone tab")
    func splitInteraction() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); main.window?.close() }
        main.session.addSplitPane(url: URL(string: "https://little.test/split")!)
        await main.session.waitForPendingCommands()
        let group = try #require(main.session.activeSplit)
        let members = main.session.ownedSurfaces
        let little = try await environment.makeQuickWindow(url: URL(string: "https://little.test/promoted")!)
        let surface = try #require(little.surface)
        let promotion = try #require(little.promote(to: main))
        #expect(await promotion.value != nil)
        await main.session.waitForPendingCommands()
        #expect(main.session.activeSplit == nil)
        #expect(main.session.selectedSurface === surface)
        #expect(members.allSatisfy { !$0.isDisposed })
        #expect(await environment.store.sessionDocument().organization.splits.contains { $0.id == group.group.id })
    }

    @Test("A successful promotion dismisses the previous selected tab's Peek through normal selection rules")
    func peekInteraction() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let opener = try #require(main.session.selectedSurface)
        let peek = try #require(opener.openNewTarget(URL(string: "https://little.test/peek")!, modifiers: [.shift]))
        #expect(main.isPeekPresented)
        let little = try await environment.makeQuickWindow(url: URL(string: "https://little.test/standalone")!)
        let task = try #require(little.promote(to: main))
        #expect(await task.value != nil)
        await main.session.waitForPendingCommands()
        #expect(!main.isPeekPresented && peek.isDisposed)
    }

    @Test("Little Circa scope shadows browser shortcuts without targeting an unrelated background window")
    func commandScope() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let little = try await environment.makeQuickWindow()
        let router = BrowserWindowRouter<Window>(create: { _ in main }, present: { _, _ in }, dispose: { _ in })
        var active = true
        let registry = try BrowserCommandRegistry<Window>(router: router, state: { _ in .init() }, currentWindowID: { nil })
        var promoted = 0, choices = 0
        BrowserQuickWindowCommands.install(in: registry, active: { active && !little.isClosed ? little : nil },
            promote: { _ in promoted += 1 }, chooseSpace: { _ in choices += 1 })
        #expect(registry.activeScope == .quickWindow)
        #expect(registry.resolve(.init(key: "o", modifiers: .command)) == .promoteQuickWindow)
        #expect(registry.dispatch(.promoteQuickWindow, origin: .keyboard))
        #expect(registry.dispatch(.chooseQuickWindowSpace, origin: .menu))
        #expect(promoted == 1 && choices == 1)
        #expect(registry.resolve(.init(key: "w", modifiers: .command)) == .closeQuickWindow)
        #expect(registry.resolve(.init(key: "\u{1b}", modifiers: [])) == nil, "Escape remains with the page/editor")
        active = false
        #expect(!registry.dispatch(.promoteQuickWindow, origin: .keyboard))
        #expect(!registry.dispatch(.closeQuickWindow, origin: .keyboard))
        active = true
        #expect(registry.dispatch(.closeQuickWindow, origin: .keyboard))
        #expect(little.isClosed && !main.session.isClosed)
    }

    @Test("Only engines lacking live transfer may load a copy; the source remains recoverable")
    func capabilityFallback() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: LimitedQuickWindowEngine())
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let url = URL(string: "https://little.test/copy")!
        let little = try await environment.makeQuickWindow(url: url)
        let original = try #require(little.surface)
        original.documentState = "unsaved"
        #expect(little.openButton.title == "Open a Copy in Circa")
        #expect(little.promote(to: main) == nil)
        await main.session.waitForPendingCommands()
        let copy = try #require(main.session.selectedSurface)
        #expect(copy !== original && copy.currentURL == url)
        #expect(little.container.owns(original) && original.documentState == "unsaved")
        #expect(!little.isClosed && !original.isDisposed)
    }

    @Test("The last activated Space supplies Little Circa's profile even after its main window closes")
    func remembersLastSpace() async throws {
        let (environment, main) = try await setup()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let profile = await environment.store.createProfile(name: "Synthetic last profile")
        let space = try await environment.store.createSpace(name: "Synthetic last Space", profileID: profile)
        let last = try await environment.makeWindow(spaceID: space)
        last.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: last.window))
        #expect(environment.lastUsedSpaceID == space)
        last.window?.close()
        let little = try await environment.makeQuickWindow()
        #expect(little.sourceSpaceID == space && little.profileID == profile)
        #expect(little.window?.isVisible == false && !NSApp.isActive)
    }

    @Test("The hosted-window identity is announced once and a live Little Circa blocks profile removal")
    func windowIdentityAndProfileRemoval() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SyntheticEngine()
        let environment = BrowserEnvironment(engine: engine)
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let profile = await environment.store.createProfile(name: "Synthetic removable profile")
        let space = try await environment.store.createSpace(name: "Synthetic removable Space", profileID: profile)
        let little = try await environment.makeQuickWindow(spaceID: space)
        #expect(engine.shellWindows[little.id] == little.window.map(ObjectIdentifier.init))
        await #expect(throws: BrowserSettingsError.profileHasSpaces) { try await environment.removeProfileFromSettings(profile) }
        // Model-only deletion intentionally leaves this detached document alive to exercise
        // the independent engine-surface guard after the assigned-Space guard has passed.
        try await environment.store.removeSettingsSpace(space)
        await #expect(throws: BrowserSettingsError.profileInUse) { try await environment.removeProfileFromSettings(profile) }
        #expect(little.profileID == profile)
        little.window?.performClose(nil)
        #expect(engine.shellWindows[little.id] == nil)
        #expect(engine.closedShellWindows.filter { $0 == little.id }.count == 1)
    }
}
}
