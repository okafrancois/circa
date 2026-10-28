import AppKit
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
@testable import BrowserShell
import Foundation
import Testing
import UniformTypeIdentifiers
import WebKit
import WebKitEngine
@testable import Orbit

private typealias PageEnvironment = BrowserEnvironment<SyntheticEngine>
private typealias PageWindow = BrowserWindowController<SyntheticEngine>

private enum PageTestError: Error { case timedOut(String) }

@MainActor
private func waitForPage(_ phase: String, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw PageTestError.timedOut(phase) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Records WebKit page requests (CH-ESSENTIALS coverage) and answers them as configured.
@MainActor
private final class WebKitPageDelegate: BrowserEngineSurfaceDelegate {
    var dialogs: [BrowserJavaScriptDialog] = []
    var response: BrowserJavaScriptDialogResponse = .accept(text: nil)
    var committed = 0
    func surfaceDidStartNavigation(_ surface: WebKitSurface) {}
    func surfaceDidCommitNavigation(_ surface: WebKitSurface) { committed += 1 }
    func surfaceDidFinishNavigation(_ surface: WebKitSurface) {}
    func surfaceDidFailNavigation(_ surface: WebKitSurface) {}
    func surfaceDidRequestClose(_ surface: WebKitSurface) {}
    func surface(_ surface: WebKitSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func surface(_ surface: WebKitSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> WebKitSurface) -> WebKitSurface? { nil }
    func surface(_ surface: WebKitSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
    func surface(_ surface: WebKitSurface, runJavaScriptDialog dialog: BrowserJavaScriptDialog) async -> BrowserJavaScriptDialogResponse {
        dialogs.append(dialog)
        return response
    }
}

/// CH-ESSENTIALS: page-initiated surfaces of Orbit's windows over the reference synthetic engine.
/// No window is shown; dialogs are answered through `BrowserPageDialogCenter` as their buttons would.
extension NativeWebKitTests {
@Suite(.serialized)
@MainActor
struct NativePageInteractionTests {
    private func loadedWindow(_ engine: SyntheticEngine = SyntheticEngine(),
                              _ url: String = "https://page.test/") async throws -> (PageWindow, SyntheticSurface) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PageEnvironment(engine: engine)
        let controller = try await environment.makeWindow()
        controller.submitAddress(url)
        await controller.session.waitForPendingCommands()
        let surface = try #require(controller.session.selectedSurface)
        try await waitForPage("load \(url)") { surface.navigationState.committedURL?.absoluteString == url }
        return (controller, surface)
    }

    private func dialogView(in host: NSView) -> BrowserPageDialogView? {
        host.subviews.compactMap { $0 as? BrowserPageDialogView }.last
    }

    @Test("Little Orbit cancels obsolete page dialogs on navigation and disposal")
    func quickWindowPageDialogLifecycle() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PageEnvironment(engine: SyntheticEngine())
        defer { environment.retireQuickWindows() }
        let little = try await environment.makeQuickWindow(url: URL(string: "https://little.test/first")!)
        let surface = try #require(little.surface)
        try await waitForPage("Little Orbit load") { surface.navigationState.committedURL != nil }
        let center = BrowserPageDialogCenter.shared
        let key = ObjectIdentifier(surface)
        let challenge = BrowserAuthenticationChallenge(origin: "https://little.test", host: "little.test", port: 443,
                                                        realm: "Synthetic", scheme: "basic", isProxy: false)
        let credentials = Task { await little.surface(surface, requestsCredentialsFor: challenge) }
        try await waitForPage("Little Orbit authentication") { center.presentedDialog(for: key)?.kind == .authentication }
        surface.navigate(to: URL(string: "https://little.test/second")!)
        try await waitForPage("Little Orbit new document") { surface.navigationState.committedURL?.path == "/second" }
        #expect(await credentials.value == nil)
        #expect(center.pendingCount(for: key) == 0)
        little.surface(surface, rendererDidTerminate: .crashed)
        #expect(center.isCrashedPageShown(for: key))
        surface.navigate(to: URL(string: "https://little.test/third")!)
        try await waitForPage("Little Orbit reload") { surface.navigationState.committedURL?.path == "/third" }
        #expect(!center.isCrashedPageShown(for: key))
        little.surface(surface, rendererDidBecomeUnresponsive: true)
        try await waitForPage("Little Orbit unresponsive") { center.presentedDialog(for: key)?.kind == .unresponsive }
        surface.navigate(to: URL(string: "https://little.test/fourth")!)
        try await waitForPage("Little Orbit responsive new document") { surface.navigationState.committedURL?.path == "/fourth" }
        await Task.yield()
        #expect(surface.performedPageCommands.isEmpty, "automatic dismissal never requests renderer termination")
        little.surface(surface, rendererDidBecomeUnresponsive: true)
        little.surface(surface, rendererDidBecomeUnresponsive: false)
        await Task.yield()
        #expect(center.pendingCount(for: key) == 0, "recovery before presentation cancels the queued request")
        let dialog = Task { await little.surface(surface, runJavaScriptDialog:
            BrowserJavaScriptDialog(kind: .confirm, message: "Synthetic close", origin: "https://little.test")) }
        try await waitForPage("Little Orbit confirm") { center.presentedDialog(for: key)?.kind == .confirm }
        little.retire()
        #expect(await dialog.value == .cancel)
        #expect(center.pendingCount(for: key) == 0)
    }

    @Test("A Little Orbit crashed-page Reload follows its surface through promotion")
    func quickWindowCrashedReloadAfterPromotion() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = PageEnvironment(engine: SyntheticEngine())
        let main = try await environment.makeWindow()
        defer { environment.retireQuickWindows(); main.window?.close() }
        let little = try await environment.makeQuickWindow(url: URL(string: "https://little.test/reload")!)
        let surface = try #require(little.surface)
        try await waitForPage("Little Orbit reload document") { surface.navigationState.committedURL != nil }
        little.surface(surface, rendererDidTerminate: .crashed)
        let overlay = try #require(surface.hostView.subviews.compactMap { $0 as? BrowserPageCrashedView }.first)
        let generation = surface.documentGeneration
        let promotion = try #require(little.promote(to: main))
        #expect(await promotion.value != nil)
        #expect(main.session.holds(surface) && little.isClosed)
        overlay.performReload()
        try await waitForPage("promoted crashed-page reload") { surface.documentGeneration > generation }
        #expect(!BrowserPageDialogCenter.shared.isCrashedPageShown(for: ObjectIdentifier(surface)))
    }

    // MARK: Rules and wording

    @Test("JavaScript dialog rules: one at a time, prevention offered within a second, scoped to the document")
    func dialogRules() {
        var rules = BrowserJavaScriptDialogRules()
        let surface = ObjectIdentifier(NSView())
        let document = BrowserJavaScriptDialogRules.Document(surface: surface, generation: 1)
        let start = ContinuousClock.now
        #expect(rules.decide(for: document, isBeforeUnload: false, now: start) == .show(offersPrevention: false))
        #expect(rules.decide(for: document, isBeforeUnload: false, now: start) == .suppress, "one dialog at a time")
        rules.didClose(document, preventingFurther: false, now: start)
        #expect(rules.decide(for: document, isBeforeUnload: false, now: start + .milliseconds(400))
                == .show(offersPrevention: true), "a quick follow-up offers prevention")
        rules.didClose(document, preventingFurther: true, now: start + .milliseconds(500))
        #expect(rules.decide(for: document, isBeforeUnload: false, now: start + .seconds(5)) == .suppress)
        #expect(rules.decide(for: document, isBeforeUnload: true, now: start + .seconds(5)) == .suppress,
                "a prevented document's beforeunload is suppressed (and proceeds)")
        let next = BrowserJavaScriptDialogRules.Document(surface: surface, generation: 2)
        rules.reset(surface, keepingGeneration: 2)
        #expect(rules.decide(for: next, isBeforeUnload: false, now: start + .seconds(6)) == .show(offersPrevention: false),
                "a new document starts clean")
        rules.didClose(next, preventingFurther: false, now: start + .seconds(6))
        #expect(rules.decide(for: next, isBeforeUnload: true, now: start + .seconds(6)) == .show(offersPrevention: false),
                "beforeunload never offers prevention")
    }

    @Test("Dialog wording follows Chromium's strings")
    func dialogWording() {
        #expect(BrowserPageDialogText.javaScriptTitle(origin: "http://127.0.0.1:4100") == "127.0.0.1:4100 says")
        #expect(BrowserPageDialogText.javaScriptTitle(origin: "https://example.com:443") == "example.com says")
        #expect(BrowserPageDialogText.javaScriptTitle(origin: nil) == "This page says")
        let leave = BrowserPageDialogText.spec(for: BrowserJavaScriptDialog(kind: .beforeUnload(isReload: false), message: "", origin: nil),
                                               offersPrevention: false)
        #expect(leave.title == "Leave site?" && leave.message == "Changes you made may not be saved."
                && leave.primary == "Leave" && leave.secondary == "Cancel")
        let reload = BrowserPageDialogText.spec(for: BrowserJavaScriptDialog(kind: .beforeUnload(isReload: true), message: "", origin: nil),
                                                offersPrevention: false)
        #expect(reload.title == "Reload site?" && reload.primary == "Reload")
        let alert = BrowserPageDialogText.spec(for: BrowserJavaScriptDialog(kind: .alert, message: "Hi", origin: "https://a.test"),
                                               offersPrevention: true)
        #expect(alert.secondary == nil && alert.checkbox == "Prevent this page from creating additional dialogs")
        let auth = BrowserPageDialogText.spec(for: BrowserAuthenticationChallenge(origin: "http://intranet.test:8080",
            host: "intranet.test", port: 8080, realm: "Lab", scheme: "basic", isProxy: false))
        #expect(auth.title == "Sign in" && auth.message == "intranet.test:8080 requires a username and password.")
        #expect(auth.note == "Your connection to this site is not private" && auth.fields.count == 2 && auth.fields[1].isSecure)
        let proxy = BrowserPageDialogText.spec(for: BrowserAuthenticationChallenge(origin: "", host: "proxy.test", port: 3128,
            realm: nil, scheme: nil, isProxy: true))
        #expect(proxy.message == "The proxy proxy.test:3128 requires a username and password." && proxy.note == nil)
        let external = BrowserPageDialogText.externalProtocol(application: "Mail", origin: "https://mail.test")
        #expect(external.title == "Open Mail?" && external.message == "mail.test wants to open this application."
                && external.primary == "Open Mail")
        #expect(BrowserPageDialogText.folderUpload(folderName: "Photos", fileCount: 3).title == "Upload 3 files to this site?")
        #expect(BrowserPageDialogText.folderUpload(folderName: "Photos", fileCount: 1).title == "Upload 1 file to this site?")
        #expect(BrowserPageDialogText.unresponsive().escapeChoosesPrimary)
    }

    // MARK: JavaScript dialogs

    @Test("A JavaScript dialog is tab-modal over its own document, one at a time, answered once")
    func javaScriptDialogOverDocument() async throws {
        let (controller, surface) = try await loadedWindow()
        defer { controller.window?.close() }
        let center = BrowserPageDialogCenter.shared
        let key = ObjectIdentifier(surface)
        let prompt = BrowserJavaScriptDialog(kind: .prompt(defaultText: "default"), message: "Name?", origin: "https://page.test")
        let answer = Task { await controller.surface(surface, runJavaScriptDialog: prompt) }
        try await waitForPage("prompt shown") { center.presentedDialog(for: key) != nil }
        #expect(center.presentedDialog(for: key)?.kind == .prompt)
        #expect(center.presentedDialog(for: key)?.title == "page.test says")
        #expect(dialogView(in: surface.hostView) != nil, "the dialog is a subview of its document's host view")
        #expect(controller.window?.attachedSheet == nil, "not a window sheet: other tabs stay usable")
        let second = await controller.surface(surface, runJavaScriptDialog: BrowserJavaScriptDialog(kind: .alert, message: "x", origin: nil))
        #expect(second == .suppressed, "a dialog while one is shown is suppressed")
        #expect(center.respond(for: key, accept: true, fieldValues: ["typed"]))
        #expect(await answer.value == .accept(text: "typed"))
        #expect(dialogView(in: surface.hostView) == nil && center.presentedDialog(for: key) == nil)

        // A quick follow-up offers prevention; checked, the document's later dialogs are suppressed.
        let follow = Task { await controller.surface(surface, runJavaScriptDialog: BrowserJavaScriptDialog(kind: .confirm, message: "Again?", origin: nil)) }
        try await waitForPage("follow-up shown") { center.presentedDialog(for: key) != nil }
        #expect(center.presentedDialog(for: key)?.checkbox == "Prevent this page from creating additional dialogs")
        center.respond(for: key, accept: false, checkbox: true)
        #expect(await follow.value == .cancel)
        let prevented = await controller.surface(surface, runJavaScriptDialog: BrowserJavaScriptDialog(kind: .alert, message: "spam", origin: nil))
        #expect(prevented == .suppressed)

        // A new document starts clean; a reset removes a shown dialog.
        surface.navigate(to: URL(string: "https://page.test/next")!)
        try await waitForPage("next document") { surface.navigationState.committedURL?.path == "/next" }
        let fresh = Task { await controller.surface(surface, runJavaScriptDialog: BrowserJavaScriptDialog(kind: .alert, message: "new", origin: nil)) }
        try await waitForPage("fresh alert shown") { center.presentedDialog(for: key) != nil }
        controller.surfaceDidResetJavaScriptDialogs(surface)
        #expect(await fresh.value == .cancel && dialogView(in: surface.hostView) == nil)
    }

    @Test("Dialogs and sign-in of a surface the window does not show never appear")
    func foreignSurfaceIsSuppressed() async throws {
        let engine = SyntheticEngine()
        let (controller, _) = try await loadedWindow(engine)
        defer { controller.window?.close() }
        let stranger = engine.makeSurface(profileID: ProfileID(), delegate: controller)
        defer { stranger.dispose() }
        #expect(await controller.surface(stranger, runJavaScriptDialog: BrowserJavaScriptDialog(kind: .alert, message: "x", origin: nil))
                == .suppressed)
        let challenge = BrowserAuthenticationChallenge(origin: "https://a.test", host: "a.test", port: 443, realm: nil, scheme: "basic",
                                                       isProxy: false)
        #expect(await controller.surface(stranger, requestsCredentialsFor: challenge) == nil)
        #expect(BrowserPageDialogCenter.shared.presentedDialog(for: ObjectIdentifier(stranger)) == nil)
    }

    @Test("Sign-in returns the typed credential; Cancel returns none")
    func signIn() async throws {
        let (controller, surface) = try await loadedWindow()
        defer { controller.window?.close() }
        let center = BrowserPageDialogCenter.shared
        let key = ObjectIdentifier(surface)
        let challenge = BrowserAuthenticationChallenge(origin: "https://page.test", host: "page.test", port: 443, realm: "Lab",
                                                       scheme: "basic", isProxy: false)
        let typed = Task { await controller.surface(surface, requestsCredentialsFor: challenge) }
        try await waitForPage("sign-in shown") { center.presentedDialog(for: key)?.kind == .authentication }
        #expect(center.presentedDialog(for: key)?.note == nil, "HTTPS: no insecure-connection note")
        center.respond(for: key, accept: true, fieldValues: ["synthetic-user", "synthetic-pass"])
        #expect(await typed.value == BrowserCredential(user: "synthetic-user", password: "synthetic-pass"))
        let cancelled = Task { await controller.surface(surface, requestsCredentialsFor: challenge) }
        try await waitForPage("second sign-in shown") { center.presentedDialog(for: key) != nil }
        center.respond(for: key, accept: false)
        #expect(await cancelled.value == nil)
    }

    // MARK: External application links

    @Test("Application links ask before the system opens them; never automatically")
    func externalApplicationLinks() async throws {
        let (controller, surface) = try await loadedWindow()
        defer { controller.window?.close() }
        let gate = BrowserExternalProtocolGate.shared
        let center = BrowserPageDialogCenter.shared
        let key = ObjectIdentifier(surface)
        let previous = (gate.applicationName, gate.opener)
        defer { gate.applicationName = previous.0; gate.opener = previous.1 }
        var opened: [URL] = []
        gate.applicationName = { $0.scheme == "mailto" ? "Mail" : nil }
        gate.opener = { opened.append($0) }

        let mailto = URL(string: "mailto:someone@example.test")!
        let action = BrowserNavigationAction(url: mailto, isMainFrame: true, kind: .linkActivation, isUserGesture: true)
        #expect(controller.navigationActionPolicy(for: action, in: surface) == .cancel, "the page never navigates")
        try await waitForPage("confirmation shown") { center.presentedDialog(for: key)?.kind == .externalProtocol }
        #expect(center.presentedDialog(for: key)?.title == "Open Mail?")
        #expect(center.presentedDialog(for: key)?.message == "page.test wants to open this application.")
        #expect(opened.isEmpty, "nothing opens before the user agrees")
        #expect(controller.navigationActionPolicy(for: action, in: surface) == .cancel)
        #expect(center.pendingCount(for: key) == 1, "one confirmation at a time")
        center.respond(for: key, accept: true)
        try await waitForPage("opened") { opened == [mailto] }

        _ = controller.navigationActionPolicy(for: action, in: surface)
        try await waitForPage("second confirmation") { center.presentedDialog(for: key) != nil }
        center.respond(for: key, accept: false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(opened == [mailto], "Cancel opens nothing")

        let subframe = BrowserNavigationAction(url: mailto, isMainFrame: false, kind: .other, isUserGesture: false)
        #expect(controller.navigationActionPolicy(for: subframe, in: surface) == .cancel)
        let unknown = BrowserNavigationAction(url: URL(string: "nothing-handles-this:x")!, isMainFrame: true, kind: .linkActivation,
                                              isUserGesture: true)
        #expect(controller.navigationActionPolicy(for: unknown, in: surface) == .cancel)
        try await Task.sleep(for: .milliseconds(50))
        #expect(center.presentedDialog(for: key) == nil, "no dialog without a gesture in a subframe, nor without an application")
        #expect(gate.log.suffix(2).map(\.outcome) == ["dropped-subframe-without-gesture", "no-application"])
        #expect(!BrowserExternalProtocolGate.isExternal(URL(string: "javascript:alert(1)")!))
        #expect(!BrowserExternalProtocolGate.isExternal(URL(string: "file:///etc/hosts")!))
    }

    // MARK: Context menu

    @Test("Page context menu groups follow Chromium's order with Orbit's labels")
    func contextMenuModel() {
        let context = BrowserPageContextMenuModel.Context(canGoBack: true, canGoForward: false, canPrint: true, canInspect: true,
                                                          searchEngineName: "Google")
        let link = BrowserContextMenuRequest(location: .zero, linkURL: URL(string: "https://b.test/")!, documentGeneration: 1,
                                             availableCommands: [.saveLink, .inspect])
        #expect(BrowserPageContextMenuModel.groups(for: link, context: context).map { $0.map(\.command) } == [
            [.pageOpenLinkInNewTab, .pageOpenLinkInSplitView], [.pageSaveLinkAs, .pageCopyLinkAddress], [.pageInspect]])
        let mail = BrowserContextMenuRequest(location: .zero, linkURL: URL(string: "mailto:a@b.test")!, documentGeneration: 1)
        #expect(BrowserPageContextMenuModel.groups(for: mail, context: context).map { $0.map(\.command) } == [
            [.pageOpenLinkInNewTab], [.pageCopyEmailAddress]])
        let image = BrowserContextMenuRequest(location: .zero, mediaKind: .image, sourceURL: URL(string: "https://b.test/i.png")!,
                                              hasImageContents: true, documentGeneration: 1,
                                              availableCommands: [.saveImage, .copyImage])
        #expect(BrowserPageContextMenuModel.groups(for: image, context: context).map { $0.map(\.command) } == [
            [.pageOpenImageInNewTab, .pageSaveImageAs, .pageCopyImage, .pageCopyImageAddress]])
        let selection = BrowserContextMenuRequest(location: .zero, selectionText: "orbit", documentGeneration: 1,
                                                  availableCommands: [.copy, .lookUp, .inspect])
        let selected = BrowserPageContextMenuModel.groups(for: selection, context: context)
        #expect(selected.map { $0.map(\.command) } == [[.pageLookUp], [.pageCopy, .pageSearchSelection], [.pageInspect]])
        #expect(selected[0][0].title == "Look Up “orbit”" && selected[1][1].title == "Search Google for “orbit”")
        let editable = BrowserContextMenuRequest(location: .zero, isEditable: true, editFlags: [.canPaste, .canSelectAll],
                                                 misspelledWord: "helo", spellingSuggestions: ["hello", "help"], documentGeneration: 1,
                                                 availableCommands: [.replaceMisspelling, .addToDictionary, .undo, .cut, .copy,
                                                                     .paste, .selectAll])
        let edit = BrowserPageContextMenuModel.groups(for: editable, context: context)
        #expect(edit.map { $0.map(\.command) } == [
            [.pageSpellingSuggestion0, .pageSpellingSuggestion1], [.pageAddToDictionary], [.pageEmojiAndSymbols], [.pageUndo],
            [.pageCut, .pageCopy, .pagePaste, .pageSelectAll]])
        #expect(edit[0].map(\.title) == ["hello", "help"])
        #expect(edit[3][0].isEnabled == false && edit[4].map(\.isEnabled) == [false, false, true, true])
        #expect(BrowserPageContextCommands.engineCommand(for: .pageSpellingSuggestion1, request: editable) == .replaceMisspelling("help"))
        #expect(BrowserPageContextCommands.engineCommand(for: .pageAddToDictionary, request: editable) == .addToDictionary("helo"))
        let page = BrowserContextMenuRequest(location: .zero, pageURL: URL(string: "https://b.test/")!, documentGeneration: 1,
                                             availableCommands: [.inspect])
        let pageGroups = BrowserPageContextMenuModel.groups(for: page, context: context)
        #expect(pageGroups.map { $0.map(\.command) } == [[.pageBack, .pageForward, .pageReload], [.pageShare], [.pagePrint, .pageViewSource], [.pageInspect]])
        #expect(pageGroups[0].map(\.isEnabled) == [true, false, true])
        let video = BrowserContextMenuRequest(location: .zero, mediaKind: .video, sourceURL: URL(string: "https://b.test/v.mp4")!,
                                              mediaState: [.loop], documentGeneration: 1,
                                              availableCommands: [.mediaLoop, .mediaControls, .mediaPictureInPicture, .saveMedia])
        let media = BrowserPageContextMenuModel.groups(for: video, context: context)
        #expect(media.map { $0.map(\.command) } == [[.pageMediaLoop, .pageMediaShowControls, .pageMediaPictureInPicture],
                                                     [.pageOpenMediaInNewTab, .pageSaveMediaAs, .pageCopyMediaAddress]])
        #expect(media[0][0].isChecked && !media[0][1].isChecked && media[1][0].title == "Open Video in New Tab")
        // Context-menu commands live outside the menu bar and the palette.
        let ids = Set(BrowserPageContextCommands.definitions.map(\.id))
        #expect(ids.isSubset(of: Set(OrbitCommandCatalog.definitions.map(\.id))))
        #expect(BrowserPageContextCommands.definitions.allSatisfy { $0.menu == BrowserPageContextCommands.menu && $0.shortcuts.isEmpty })
    }

    @Test("Context menu commands act on the captured document only, through the engine or the shell")
    func contextMenuCommands() async throws {
        let engine = SyntheticEngine()
        engine.extraCapabilities = [.pageContextMenus, .devTools, .printing]
        let (controller, surface) = try await loadedWindow(engine)
        defer { controller.window?.close() }
        var observed: [[BrowserPageContextMenuModel.Item]] = []
        controller.pageInteraction.menuObserver = { _, groups in observed = groups }
        let link = URL(string: "https://linked.test/")!
        let request = BrowserContextMenuRequest(location: CGPoint(x: 10, y: 10), pageURL: surface.navigationState.committedURL,
                                                linkURL: link, documentGeneration: surface.documentGeneration,
                                                availableCommands: [.saveLink, .inspect])
        controller.surface(surface, showContextMenu: request)
        #expect(observed.first?.map(\.command) == [.pageOpenLinkInNewTab, .pageOpenLinkInSplitView])
        controller.performPageContextCommand(.pageSaveLinkAs)
        #expect(surface.performedContextMenuCommands == [.saveLink], "a page command goes to the engine")

        let selected = controller.session.snapshot?.selectedOccurrenceID
        controller.performPageContextCommand(.pageOpenLinkInNewTab)
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.tabs.contains { $0.url == link } == true)
        #expect(controller.session.snapshot?.selectedOccurrenceID == selected, "Open Link in New Tab stays in the background")

        // A newer document invalidates the captured menu.
        surface.navigate(to: URL(string: "https://page.test/other")!)
        try await waitForPage("other document") { surface.navigationState.committedURL?.path == "/other" }
        controller.performPageContextCommand(.pageInspect)
        #expect(surface.performedContextMenuCommands == [.saveLink], "nothing reaches a newer document")

        // Without the capability, no menu: the engine's native menu is released.
        engine.extraCapabilities = []
        let later = BrowserContextMenuRequest(location: .zero, documentGeneration: surface.documentGeneration)
        controller.surface(surface, showContextMenu: later)
        #expect(surface.closedContextMenus.last == later)
    }

    @Test("Extension menus preserve native nesting and revoke commands on document changes")
    func extensionContextMenus() async throws {
        let engine = SyntheticEngine()
        engine.extraCapabilities = [.pageContextMenus]
        let (controller, surface) = try await loadedWindow(engine)
        defer { controller.window?.close() }
        controller.pageInteraction.menuObserver = { _, _ in }
        let children = [BrowserExtensionMenuItem(commandID: 49001, title: "Checked", isChecked: true),
                        BrowserExtensionMenuItem(commandID: 49002, title: "Unavailable", isEnabled: false)]
        let entries = [BrowserExtensionMenuItem(commandID: 49000, title: "Extension", children: children)]
        let request = BrowserContextMenuRequest(location: .zero, documentGeneration: surface.documentGeneration,
                                                availableCommands: [.extensionAction], extensionItems: entries)
        controller.surface(surface, showContextMenu: request)
        controller.performExtensionContextCommand(49002, request: request, surface: surface)
        controller.performExtensionContextCommand(50100, request: request, surface: surface)
        #expect(surface.performedContextMenuCommands.isEmpty)
        controller.performExtensionContextCommand(49001, request: request, surface: surface)
        #expect(surface.performedContextMenuCommands == [.extensionAction(49001)])
        let menu = NSMenu()
        let presenter = BrowserExtensionContextMenu { _ in }
        presenter.append(entries, to: menu)
        let submenu = try #require(menu.items.first?.submenu)
        #expect(submenu.items.map(\.title) == ["Checked", "Unavailable"])
        #expect(submenu.items[0].state == .on)
        #expect(!submenu.items[1].isEnabled)
        #expect(!BrowserExtensionMenuItem(commandID: 49000, title: "Disabled parent", isEnabled: false,
                                          children: children).permits(49001))
        surface.navigate(to: URL(string: "https://page.test/replaced")!)
        try await waitForPage("replacement document") { surface.navigationState.committedURL?.path == "/replaced" }
        controller.performExtensionContextCommand(49001, request: request, surface: surface)
        #expect(surface.performedContextMenuCommands == [.extensionAction(49001)])
    }

    // MARK: Fullscreen, renderer

    @Test("Element fullscreen takes the window and gives it back; Escape leaves it first")
    func elementFullscreen() async throws {
        let (controller, surface) = try await loadedWindow()
        defer { controller.window?.close() }
        var toggles = 0
        controller.toggleNativeFullScreen = { _ in toggles += 1 }
        #expect(controller.isSidebarVisible)
        controller.surface(surface, didChangeElementFullscreen: true)
        #expect(!controller.isSidebarVisible && toggles == 1 && controller.elementFullscreenSurfaceKey == ObjectIdentifier(surface))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "\u{1b}",
                                                   charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        guard case .browser = controller.surface(surface, willSendKeyToPage: escape) else {
            Issue.record("Escape must stay with the browser while an element is fullscreen")
            return
        }
        #expect(surface.fullscreenExits == 1 && controller.isSidebarVisible && controller.elementFullscreenSurfaceKey == nil)
        // The page leaving by itself restores the layout too.
        controller.surface(surface, didChangeElementFullscreen: true)
        controller.surface(surface, didChangeElementFullscreen: false)
        #expect(controller.isSidebarVisible && controller.elementFullscreenSurfaceKey == nil)
    }

    @Test("A crashed page shows Aw, Snap! with Reload; a new document removes it")
    func crashedPage() async throws {
        let (controller, surface) = try await loadedWindow()
        defer { controller.window?.close() }
        let center = BrowserPageDialogCenter.shared
        let key = ObjectIdentifier(surface)
        controller.surface(surface, rendererDidTerminate: .crashed)
        #expect(center.isCrashedPageShown(for: key))
        #expect(surface.hostView.subviews.contains { $0 is BrowserPageCrashedView })
        let reloads = surface.reloads
        #expect(center.reloadCrashedPage(for: key))
        #expect(surface.reloads == reloads + 1 && !center.isCrashedPageShown(for: key))
        controller.surface(surface, rendererDidTerminate: .killed)
        surface.navigate(to: URL(string: "https://page.test/after")!)
        try await waitForPage("after crash") { surface.navigationState.committedURL?.path == "/after" }
        #expect(!center.isCrashedPageShown(for: key))
    }

    @Test("An unresponsive page offers Wait and Exit page")
    func unresponsivePage() async throws {
        let engine = SyntheticEngine()
        engine.extraCapabilities = [.devTools]
        let (controller, surface) = try await loadedWindow(engine)
        defer { controller.window?.close() }
        let center = BrowserPageDialogCenter.shared
        let key = ObjectIdentifier(surface)
        controller.surface(surface, rendererDidBecomeUnresponsive: true)
        try await waitForPage("unresponsive shown") { center.presentedDialog(for: key)?.kind == .unresponsive }
        center.respond(for: key, accept: false)
        try await waitForPage("exit page") { surface.performedPageCommands == [.terminateUnresponsiveRenderer] }
        controller.surface(surface, rendererDidBecomeUnresponsive: true)
        try await waitForPage("shown again") { center.presentedDialog(for: key) != nil }
        controller.surface(surface, rendererDidBecomeUnresponsive: false)
        #expect(center.presentedDialog(for: key) == nil, "a recovered renderer removes the question")
    }

    // MARK: Close, commands, files

    @Test("⌘W asks the page first when the engine runs beforeunload; Stay keeps the tab")
    func closeAsksThePage() async throws {
        let engine = SyntheticEngine()
        engine.extraCapabilities = [.beforeUnloadOnClose]
        let (controller, first) = try await loadedWindow(engine)
        defer { controller.window?.close() }
        controller.openTab(url: URL(string: "https://page.test/second")!)
        await controller.session.waitForPendingCommands()
        let second = try #require(controller.session.selectedSurface)
        #expect(second !== first)
        second.closeConfirmation = false
        controller.closeSelectedTab()
        try await waitForPage("asked") { second.closeConfirmationRequests == 1 }
        await controller.session.waitForPendingCommands()
        #expect(controller.owns(second), "Stay keeps the tab")
        second.closeConfirmation = true
        controller.closeSelectedTab()
        try await waitForPage("closed") { !controller.owns(second) }
        #expect(second.closeConfirmationRequests == 2)
    }

    @Test("Save Page As writes a self-contained archive and refuses document changes while choosing")
    func savePageCommand() async throws {
        let engine = SyntheticEngine()
        engine.extraCapabilities = [.pageSaving]
        let (controller, surface) = try await loadedWindow(engine)
        defer { controller.session.close(); controller.window?.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("page.mhtml")
        controller.pageSaver.chooseDestination = { _, _ in
            let onMainThread = { Thread.isMainThread }
            #expect(onMainThread())
            return file
        }
        controller.pageSaver.begin()
        try await waitForPage("page saved") { !controller.pageSaver.isBusy }
        #expect(try Data(contentsOf: file) == surface.pageArchive)
        try FileManager.default.removeItem(at: file)
        controller.pageSaver.chooseDestination = { _, _ in
            surface.navigate(to: URL(string: "https://changed.test/")!)
            try? await waitForPage("changed document") { surface.navigationState.committedURL?.host == "changed.test" }
            return file
        }
        controller.pageSaver.begin()
        try await waitForPage("stale save cancelled") { !controller.pageSaver.isBusy }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("Print, Developer Tools and View Source reach the page command surface")
    func pageCommands() async throws {
        let engine = SyntheticEngine()
        let (controller, surface) = try await loadedWindow(engine)
        defer { controller.window?.close() }
        #expect(controller.canPerformPageCommand(.print) && !controller.canViewPageSource, "the reference engine prints; developer tools remain opt-in")
        engine.extraCapabilities = [.printing, .devTools]
        #expect(controller.canPerformPageCommand(.print) && controller.canPerformPageCommand(.showDevTools))
        controller.performPageCommand(.print)
        controller.performPageCommand(.showDevTools)
        await controller.session.waitForPendingCommands()
        try await waitForPage("commands") { surface.performedPageCommands == [.print, .showDevTools] }
        #expect(controller.canViewPageSource)
        controller.viewPageSource()
        await controller.session.waitForPendingCommands()
        #expect(controller.session.snapshot?.tabs.contains { $0.url.absoluteString == "view-source:https://page.test/" } == true)
    }

    @Test("WebKit coverage: alert, confirm and prompt reach the same contract callback")
    func webKitDialogs() async throws {
        let engine = WebKitBrowserEngine()
        let delegate = WebKitPageDelegate()
        let surface = engine.makeSurface(profileID: ProfileID(), delegate: delegate)
        defer { surface.dispose() }
        surface.webView.loadHTMLString("<p>dialogs</p>", baseURL: URL(string: "https://webkit.test/"))
        try await waitForPage("WebKit document") { !surface.webView.isLoading && surface.webView.url != nil }
        delegate.response = .accept(text: nil)
        let confirmed = try await surface.webView.evaluateJavaScript("confirm('Sure?')") as? Bool
        #expect(confirmed == true)
        #expect(delegate.dialogs.last == BrowserJavaScriptDialog(kind: .confirm, message: "Sure?", origin: "https://webkit.test"))
        delegate.response = .accept(text: "typed")
        let typed = try await surface.webView.evaluateJavaScript("prompt('Name?', 'default')") as? String
        #expect(typed == "typed" && delegate.dialogs.last?.kind == .prompt(defaultText: "default"))
        delegate.response = .suppressed
        let refused = try await surface.webView.evaluateJavaScript("confirm('Again?')") as? Bool
        #expect(refused == false, "a suppressed confirm answers false")
        #expect(engine.capabilities.contains(.printing) && !engine.capabilities.contains(.pageContextMenus))
        #expect(surface.webView.configuration.preferences.isElementFullscreenEnabled)
    }

    @Test("File chooser accept filters become content types; unknown filters leave it unrestricted")
    func fileChooserTypes() {
        let images = BrowserFileChooserRequest(mode: .open, acceptTypes: ["image/*", ".pdf", "application/json"], acceptExtensions: ["png"])
        let types = BrowserFileChooserPresenter.contentTypes(for: images)
        #expect(types.contains(.image) && types.contains(.pdf) && types.contains(.json) && types.contains(.png))
        #expect(BrowserFileChooserPresenter.contentTypes(for: BrowserFileChooserRequest(mode: .open, acceptTypes: ["weird"])).isEmpty)
    }

    @Test("A chosen folder is confirmed in the page with its file count before the page gets it")
    func folderUploadIsConfirmed() async throws {
        let (controller, surface) = try await loadedWindow()
        defer { controller.window?.close() }
        let folder = URL(fileURLWithPath: "/private/tmp/OrbitFolderUpload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.txt", "b.txt"] { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        let presenter = BrowserFileChooserPresenter.shared
        presenter.responder = { _ in [folder] }
        defer { presenter.responder = nil }
        let center = BrowserPageDialogCenter.shared
        let key = ObjectIdentifier(surface)
        let chosen = Task { await controller.surface(surface, runFileChooser: BrowserFileChooserRequest(mode: .openFolder)) }
        try await waitForPage("confirmation") { center.presentedDialog(for: key)?.kind == .folderUpload }
        #expect(center.presentedDialog(for: key)?.title == "Upload 2 files to this site?")
        center.respond(for: key, accept: true)
        #expect(await chosen.value == [folder])
        let refused = Task { await controller.surface(surface, runFileChooser: BrowserFileChooserRequest(mode: .openFolder)) }
        try await waitForPage("second confirmation") { center.presentedDialog(for: key) != nil }
        center.respond(for: key, accept: false)
        #expect(await refused.value == nil, "Cancel sends nothing")
        presenter.responder = { _ in [URL(fileURLWithPath: "/private/tmp/one.txt")] }
        #expect(await controller.surface(surface, runFileChooser: BrowserFileChooserRequest(mode: .openMultiple))
                == [URL(fileURLWithPath: "/private/tmp/one.txt")])
    }
}
}
