import AppKit
import BrowserCore
import BrowserEngine
import Testing
@testable import Orbit

@MainActor
private final class UpdateInputDocument: NSView {
    var keys = 0, commits = 0, pastes = 0
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys += 1 }
    @objc dynamic func insertText(_ text: Any, replacementRange: NSRange) { commits += 1 }
    @objc dynamic func paste(_ sender: Any?) { pastes += 1 }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct UnsavedInputUpdateTests {
    private func key(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0))
    }

    @Test("Web keys, IME commits and menu paste mark only the focused live document", arguments: ["key", "ime", "paste"], [false, true])
    func input(kind: String, little: Bool) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = SiteSyntheticEngine()
        let surface = engine.makeSurface(profileID: ProfileID())
        let window: NSWindow = little
            ? BrowserQuickWindowPanel(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
            : OrbitBrowserWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close(); surface.dispose() }
        window.contentView = surface.hostView
        let document = UpdateInputDocument()
        surface.hostView.addSubview(document)
        OrbitUnsavedInputGuard.register(surface)
        #expect(window.makeFirstResponder(document))
        #expect(!OrbitUnsavedInputGuard.preventsInstallation([surface]))
        switch kind {
        case "key": window.sendEvent(try key(window))
        case "ime": document.insertText("漢", replacementRange: NSRange(location: NSNotFound, length: 0))
        default: document.paste(nil)
        }
        #expect(OrbitUnsavedInputGuard.preventsInstallation([surface]))
        #expect(document.keys + document.commits + document.pastes == 1, "original responder receives the input exactly once")
        OrbitUnsavedInputGuard.clear(surface)
        let shell = UpdateInputDocument()
        window.contentView = NSView()
        window.contentView?.addSubview(shell)
        #expect(window.makeFirstResponder(shell))
        shell.insertText("漢", replacementRange: NSRange(location: 0, length: 0))
        shell.paste(nil)
        window.sendEvent(try key(window))
        #expect(!OrbitUnsavedInputGuard.preventsInstallation([surface]), "the same hooked class outside web content stays clean")
    }

    @Test("Shell Command Bar, rename and Settings fields do not dirty a background document", arguments: ["Command Bar", "Rename", "Settings"])
    func shellFields(name: String) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let surface = SiteSyntheticEngine().makeSurface(profileID: ProfileID())
        let window = OrbitBrowserWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close(); surface.dispose() }
        OrbitUnsavedInputGuard.register(surface)
        window.contentView?.addSubview(surface.hostView)
        let field: NSTextField
        switch name {
        case "Command Bar": field = BrowserPaletteView().input
        case "Settings": field = BrowserSettingsNameTextField()
        default: field = NSTextField(string: name) // Sidebar rename uses an ordinary NSTextField.
        }
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        window.sendEvent(try key(window))
        #expect(!OrbitUnsavedInputGuard.preventsInstallation([surface]))
    }

    @Test("Dirty background tabs in another window defer a fake installer until commit, close or discard",
          arguments: ["commit", "close", "discard"])
    func lifecycle(action: String) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        let other = try await environment.makeWindow()
        defer {
            for controller in [owner, other] {
                controller.tabSuspension.close(); controller.session.close(); controller.window?.close()
            }
            environment.autoArchive.scheduler.stop()
        }
        owner.openTab(url: URL(string: "https://input.test/draft")!)
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        let occurrence = try #require(owner.session.snapshot?.selectedOccurrenceID)
        let window = try #require(owner.window)
        #expect(surface.focusDocument())
        window.sendEvent(try key(window))
        owner.openTab(url: URL(string: "https://input.test/other")!)
        await owner.session.waitForPendingCommands()
        let surfaces = { owner.session.ownedSurfaces + other.session.ownedSurfaces }
        let domain = "orbit.test.unsaved." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let updater = OrbitUpdater(defaults: defaults)
        var installs = 0
        updater.idleSignals = { .init(idleSeconds: 600, mediaPlaying: false,
            unsavedInput: OrbitUnsavedInputGuard.preventsInstallation(surfaces())) }
        updater.mediaPreventsAutomaticInstallation = { false }
        updater.fetchLatestVersion = { "27" }
        updater.installPendingUpdate = { installs += 1 }
        updater.prepared(version: "27")
        await updater.attemptAutomaticInstallation()
        #expect(installs == 0)
        surface.delegate?.surfaceDidStartNavigation(surface)
        surface.delegate?.surfaceDidFailNavigation(surface)
        surface.delegate?.surface(surface, didNavigateWithinDocument: .init(url: surface.currentURL!, kind: .fragment))
        #expect(OrbitUnsavedInputGuard.preventsInstallation(surfaces()), "pending, failed and same-document navigation preserve the mark")
        switch action {
        case "commit": surface.reload()
        case "close":
            owner.session.closeOccurrence(occurrence)
            await owner.session.waitForPendingCommands()
            #expect(surface.isDisposed)
        default:
            surface.isSuspended = true
            surface.onChange?()
            // Clearing survives wake even if no updater tick occurred during discard.
            surface.isSuspended = false
        }
        #expect(!OrbitUnsavedInputGuard.preventsInstallation([surface]))
        await updater.attemptAutomaticInstallation()
        #expect(installs == 1 && updater.permitsAutomaticTermination)
        if action != "close" {
            owner.session.selectOccurrence(occurrence)
            await owner.session.waitForPendingCommands()
            #expect(surface.focusDocument())
            window.sendEvent(try key(window))
            #expect(!updater.permitsAutomaticTermination, "last-moment input also cancels termination")
        }
    }

    @Test("Unknown live surfaces block; a discarded or closed surface has no unsaved-input veto")
    func unknown() {
        let surface = SiteSyntheticEngine().makeSurface(profileID: ProfileID())
        #expect(OrbitUnsavedInputGuard.preventsInstallation([surface]))
        surface.isSuspended = true
        #expect(!OrbitUnsavedInputGuard.preventsInstallation([surface]))
        surface.dispose()
        #expect(!OrbitUnsavedInputGuard.preventsInstallation([surface]))
    }

    @Test("An exposed beforeunload confirmation blocks even after Stay until the next commit")
    func beforeUnload() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = BrowserEnvironment(engine: SiteSyntheticEngine())
        let owner = try await environment.makeWindow()
        defer { owner.tabSuspension.close(); owner.session.close(); owner.window?.close(); environment.autoArchive.scheduler.stop() }
        owner.openTab(url: URL(string: "https://input.test/unload")!)
        await owner.session.waitForPendingCommands()
        let surface = try #require(owner.session.selectedSurface)
        let center = BrowserPageDialogCenter.shared
        let dialog = Task { await owner.surface(surface, runJavaScriptDialog: .init(kind: .beforeUnload(isReload: false), message: "", origin: "https://input.test")) }
        for _ in 0..<100 where !center.hasBeforeUnloadConfirmation { await Task.yield() }
        #expect(center.hasBeforeUnloadConfirmation)
        #expect(OrbitUnsavedInputGuard.preventsInstallation([surface]))
        #expect(center.respond(for: ObjectIdentifier(surface), accept: false))
        #expect(await dialog.value == .cancel)
        #expect(!center.hasBeforeUnloadConfirmation)
        #expect(OrbitUnsavedInputGuard.preventsInstallation([surface]))
        surface.reload()
        #expect(!OrbitUnsavedInputGuard.preventsInstallation([surface]))
    }
}
}
