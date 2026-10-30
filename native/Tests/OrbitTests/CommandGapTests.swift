import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import Testing
@testable import Orbit

@MainActor
private final class GapResponder: NSView, NSUserInterfaceValidations {
    var accepted: Selector?
    var invoked: Selector?
    var validatedTag: Int?
    var invokedTag: Int?
    var enabled = true
    override var acceptsFirstResponder: Bool { true }
    override func responds(to selector: Selector!) -> Bool {
        selector == accepted || super.responds(to: selector)
    }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        validatedTag = item.tag
        return enabled
    }
    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        guard action == accepted else { return super.tryToPerform(action, with: object) }
        invoked = action
        invokedTag = (object as? NSMenuItem)?.tag
        return true
    }
}

extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct CommandGapTests {
    nonisolated static let addedResponders: [BrowserCommandID] = [
        .delete, .jumpToSelection, .findAndReplace, .useSelectionToFind,
        .showSpellingAndGrammar, .checkDocumentNow, .checkSpellingWhileTyping,
        .checkGrammarWithSpelling, .correctSpellingAutomatically, .showSubstitutions,
        .smartCopyPaste, .smartQuotes, .smartDashes, .smartLinks, .dataDetectors, .textReplacement,
        .makeUpperCase, .makeLowerCase, .capitalize, .startSpeaking, .stopSpeaking, .underline, .bold, .italic
    ]

    private func fixture() async throws -> (BrowserWindowController<PeekSyntheticEngine>,
        BrowserCommandRegistry<BrowserWindowController<PeekSyntheticEngine>>, BrowserWindowRouter<BrowserWindowController<PeekSyntheticEngine>>) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let engine = PeekSyntheticEngine()
        engine.capabilities.insert(.devTools)
        let environment = BrowserEnvironment(engine: engine)
        let controller = try await environment.makeWindow()
        controller.submitAddress("https://commands.test/")
        await controller.session.waitForPendingCommands()
        let router = BrowserWindowRouter<BrowserWindowController<PeekSyntheticEngine>>(create: { _ in controller },
            present: { _, _ in }, dispose: { $0.session.close(); $0.window?.close() })
        router.newWindow(id: controller.id)
        await router.waitForPendingCommands()
        let registry = try BrowserCommandRegistry(router: router, state: { $0?.commandState ?? .init() },
            deliver: { owner, action in owner.performAcceptedCommand(action) })
        BrowserWindowCommands.install(in: registry, commandKeyWindow: { controller.window })
        return (controller, registry, router)
    }

    @Test("Every added native action validates its selector and sender tag in the owning window", arguments: addedResponders)
    func nativeActions(_ id: BrowserCommandID) async throws {
        let (owner, registry, router) = try await fixture()
        defer { router.shutdown() }
        let window = try #require(owner.window)
        let responder = GapResponder(frame: .init(x: 0, y: 0, width: 100, height: 40))
        responder.accepted = BrowserStandardActions.validationSelector(for: id)
        window.contentView?.addSubview(responder)
        #expect(window.makeFirstResponder(responder))
        #expect(registry.isImplemented(id))
        #expect(registry.definition(id)?.requirement == .responder)
        #expect(registry.isEnabled(id))
        #expect(responder.validatedTag == BrowserStandardActions.tag(for: id))
        responder.enabled = false
        #expect(!registry.dispatch(id, origin: .palette))
        responder.enabled = true
        let sender = try #require(BrowserStandardActions.sender(for: id))
        #expect(sender.action == BrowserStandardActions.selector(for: id))
        #expect(sender.tag == BrowserStandardActions.tag(for: id))
        if id != .bold && id != .italic {
            #expect(registry.dispatch(id, origin: .palette))
            await router.waitForPendingCommands()
            #expect(responder.invoked == sender.action)
            #expect(responder.invokedTag == sender.tag)
        } else {
            #expect(BrowserStandardActions.target(for: id) === NSFontManager.shared)
            #expect(sender.tag == (id == .bold ? 2 : 1))
        }
        #expect(owner.commandResponder(for: sender.action!, keyWindow: nil) == nil)
        #expect(window.isVisible == false)
    }

    @Test("Native transformation and deletion commands change a real selected text range")
    func nativeTextEffects() async throws {
        let (owner, registry, router) = try await fixture()
        defer { router.shutdown() }
        let editor = NSTextView(frame: .init(x: 0, y: 0, width: 120, height: 40))
        owner.window?.contentView?.addSubview(editor)
        owner.window?.makeFirstResponder(editor)
        for (id, expected): (BrowserCommandID, String) in [(.makeUpperCase, "HELLO WORLD"), (.makeLowerCase, "hello world"), (.capitalize, "Hello World"), (.delete, "")] {
            editor.string = "hello WORLD"
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            #expect(registry.dispatch(id, origin: .menu))
            await router.waitForPendingCommands()
            #expect(editor.string == expected)
        }
    }

    @Test("Network Inspector opens the network panel on the captured document")
    func networkPanel() async throws {
        let (owner, registry, router) = try await fixture()
        defer { router.shutdown() }
        let surface = try #require(owner.session.selectedSurface)
        #expect(registry.dispatch(.networkInspector, origin: .palette))
        await router.waitForPendingCommands()
        await owner.session.waitForPendingCommands()
        #expect(surface.developerPanels == [.network])
        owner.engine.capabilities.remove(.devTools)
        #expect(!registry.isEnabled(.networkInspector))
    }

    @Test("Exit dismisses the current Library or Peek and never closes a tab or native editor")
    func exitContexts() async throws {
        let (owner, registry, router) = try await fixture()
        defer { router.shutdown() }
        let tabs = owner.session.snapshot?.tabs.count
        #expect(!registry.isEnabled(.exit))
        owner.showLibrary()
        await owner.session.waitForPendingCommands()
        #expect(registry.dispatch(.exit, origin: .menu))
        await router.waitForPendingCommands()
        #expect(!owner.library.isPresented)
        _ = try #require(owner.openPeek(URL(string: "https://commands.test/peek")!))
        owner.window?.makeFirstResponder(owner.presentedPeekSurface?.documentView)
        #expect(registry.dispatch(.exit, origin: .keyboard))
        await router.waitForPendingCommands()
        #expect(!owner.isPeekPresented)
        #expect(owner.session.snapshot?.tabs.count == tabs)
        let surface = try #require(owner.session.selectedSurface)
        var fullscreenToggles = 0
        owner.toggleNativeFullScreen = { _ in fullscreenToggles += 1 }
        owner.surface(surface, didChangeElementFullscreen: true)
        #expect(owner.elementFullscreenSurfaceKey != nil)
        #expect(registry.dispatch(.exit, origin: .keyboard))
        await router.waitForPendingCommands()
        #expect(owner.elementFullscreenSurfaceKey == nil)
        #expect(fullscreenToggles == 1)
        _ = try #require(owner.openPeek(URL(string: "https://commands.test/editor")!))
        let editor = NSTextView()
        owner.window?.contentView?.addSubview(editor)
        owner.window?.makeFirstResponder(editor)
        #expect(!registry.isEnabled(.exit))
        #expect(owner.isPeekPresented)
        owner.palette.registry = registry
        owner.palette.present(.newTab)
        #expect(registry.isEnabled(.exit))
        #expect(registry.dispatch(.exit, origin: .palette))
        await router.waitForPendingCommands()
        #expect(!owner.isPeekPresented)
    }

    @Test("Media opens the existing Library destination")
    func mediaLibrary() async throws {
        let (owner, registry, router) = try await fixture()
        defer { router.shutdown() }
        #expect(registry.dispatch(.viewMedia, origin: .palette))
        await router.waitForPendingCommands()
        await owner.session.waitForPendingCommands()
        #expect(owner.library.isPresented)
        #expect(owner.library.category == .media)
    }

    @Test("Reveal Data uses only the configured root and is disabled without persistence")
    func revealData() throws {
        let router = BrowserWindowRouter<NSObject>(create: { _ in NSObject() }, present: { _, _ in }, dispose: { _ in })
        let registry = try BrowserCommandRegistry(router: router, state: { _ in .init() })
        var root: URL? = URL(fileURLWithPath: "/tmp/command-gaps/synthetic")
        var revealed: URL?
        var copied: String?
        BrowserDataCommands.install(in: registry, dataRoot: { root }, copy: { copied = $0 }, reveal: { revealed = $0 })
        #expect(registry.dispatch(.revealOrbitData, origin: .menu))
        #expect(revealed == root)
        #expect(registry.dispatch(.copyOrbitInfo, origin: .palette))
        let info = try #require(copied).data(using: .utf8)!
        let fields = try #require(JSONSerialization.jsonObject(with: info) as? [String: String])
        #expect(Set(fields.keys) == ["application", "version", "build", "system"])
        #expect(fields["application"] == ProductIdentity.displayName)
        root = nil
        #expect(!registry.dispatch(.revealOrbitData, origin: .palette))
    }

    @Test("New handlers retain every declared shortcut and the existing collision policy")
    func shortcutOwnership() async throws {
        let (_, registry, router) = try await fixture()
        defer { router.shutdown() }
        #expect(registry.shortcutConflicts == [[.newFolder, .newIncognitoWindow]])
        for id in Self.addedResponders + [.networkInspector, .exit, .revealOrbitData, .copyOrbitInfo, .viewMedia] {
            #expect(registry.definition(id)?.shortcuts == OrbitCommandCatalog.definitions.first { $0.id == id }?.shortcuts)
        }
        #expect(registry.resolve(.init(key: "\u{1b}", modifiers: []), scope: .peek) == nil)
    }
}
}
