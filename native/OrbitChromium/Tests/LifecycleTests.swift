import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumLifecycleStub
import Foundation

@MainActor
private final class LifecycleDelegate: BrowserEngineSurfaceDelegate {
    var failedNavigations = 0
    var closeRequests = 0
    var onClose: ((ChromiumSurface) -> Void)?
    var onDownload: ((any BrowserEngineDownload) -> Void)?
    func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) { failedNavigations += 1 }
    func surfaceDidRequestClose(_ surface: ChromiumSurface) {
        closeRequests += 1
        onClose?(surface)
    }
    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) {
        if let onDownload { onDownload(download) }
        else { download.cancel() }
    }
}

/// CH-ESSENTIALS (ABI 9): records page requests and answers them as configured.
@MainActor
private final class PageDelegate: BrowserEngineSurfaceDelegate {
    var dialogs: [BrowserJavaScriptDialog] = []
    var dialogResponse: BrowserJavaScriptDialogResponse = .cancel
    var resets = 0
    var challenges: [BrowserAuthenticationChallenge] = []
    var credential: BrowserCredential?
    var choosers: [BrowserFileChooserRequest] = []
    var files: [URL]?
    var menus: [BrowserContextMenuRequest] = []
    var fullscreen: [Bool] = []
    var terminations: [BrowserRendererTermination] = []
    var unresponsive: [Bool] = []
    var failedNavigations = 0
    func surfaceDidStartNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidCommitNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFinishNavigation(_ surface: ChromiumSurface) {}
    func surfaceDidFailNavigation(_ surface: ChromiumSurface) { failedNavigations += 1 }
    func surfaceDidRequestClose(_ surface: ChromiumSurface) {}
    func surface(_ surface: ChromiumSurface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) { decision.decide(.allow) }
    func surface(_ surface: ChromiumSurface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> ChromiumSurface) -> ChromiumSurface? { nil }
    func surface(_ surface: ChromiumSurface, didStartDownload download: any BrowserEngineDownload) { download.cancel() }
    func surface(_ surface: ChromiumSurface, runJavaScriptDialog dialog: BrowserJavaScriptDialog) async -> BrowserJavaScriptDialogResponse {
        dialogs.append(dialog)
        return dialogResponse
    }
    func surfaceDidResetJavaScriptDialogs(_ surface: ChromiumSurface) { resets += 1 }
    func surface(_ surface: ChromiumSurface, requestsCredentialsFor challenge: BrowserAuthenticationChallenge) async -> BrowserCredential? {
        challenges.append(challenge)
        return credential
    }
    func surface(_ surface: ChromiumSurface, runFileChooser request: BrowserFileChooserRequest) async -> [URL]? {
        choosers.append(request)
        return files
    }
    func surface(_ surface: ChromiumSurface, showContextMenu request: BrowserContextMenuRequest) { menus.append(request) }
    func surface(_ surface: ChromiumSurface, didChangeElementFullscreen isFullscreen: Bool) { fullscreen.append(isFullscreen) }
    func surface(_ surface: ChromiumSurface, rendererDidTerminate termination: BrowserRendererTermination) {
        terminations.append(termination)
    }
    func surface(_ surface: ChromiumSurface, rendererDidBecomeUnresponsive isUnresponsive: Bool) {
        unresponsive.append(isUnresponsive)
    }
}

@MainActor
private func emit(_ kind: ACREventKind, _ token: UInt64, request: UInt64 = 0, value: Int32 = 0, flags: Int32 = 0,
                  url: String? = nil, detail: String? = nil, title: String? = nil, payload: String? = nil) {
    ACRStubEmit(Int32(bitPattern: kind.rawValue), token, request, value, flags, url, detail, title, payload)
}

/// Waits (bounded) until the stub recorded an answer for `request`.
@MainActor
private func answer(for request: UInt64, after count: UInt32) async -> ACRStubResolution {
    for _ in 0..<400 {
        let last = ACRStubLastResolution()!.pointee
        if last.count > count && last.request_id == request { return last }
        try? await Task.sleep(for: .milliseconds(5))
    }
    preconditionFailure("no answer recorded for request \(request)")
}

@MainActor
private func text(_ resolution: ACRStubResolution, second: Bool = false) -> String {
    func decode<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }
    return second ? decode(resolution.second) : decode(resolution.text)
}

/// ABI 9 page requests through the C ABI to the delegate and back, without CEF.
@MainActor
private func pageSurfaceChecks(_ backend: ChromiumBrowserEngine) async {
    let delegate = PageDelegate()
    let page = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, page.token, value: 2)
    precondition(page.isBrowserCreated, "the synthetic CREATED makes the browser ready")
    var count = ACRStubLastResolution()!.pointee.count

    // alert: origin reduced to scheme, host and port; the delegate's answer reaches the bridge once.
    delegate.dialogResponse = .accept(text: nil)
    emit(ACR_EVENT_JS_DIALOG, page.token, request: 101, value: 0, url: "http://127.0.0.1:4100/path?q=1", detail: "hello")
    var resolution = await answer(for: 101, after: count)
    count = resolution.count
    precondition(delegate.dialogs.last == BrowserJavaScriptDialog(kind: .alert, message: "hello", origin: "http://127.0.0.1:4100"))
    precondition(resolution.value == 1 && resolution.has_text == 0, "an accepted alert is OK without text")

    // prompt: the default text reaches the delegate, the typed text reaches the page.
    delegate.dialogResponse = .accept(text: "typed")
    emit(ACR_EVENT_JS_DIALOG, page.token, request: 102, value: 2, url: "https://example.test/", detail: "name?", title: "default")
    resolution = await answer(for: 102, after: count)
    count = resolution.count
    precondition(delegate.dialogs.last?.kind == .prompt(defaultText: "default"))
    precondition(resolution.value == 1 && text(resolution) == "typed")

    // A suppressed confirm is false; a suppressed beforeunload proceeds (never traps the page).
    delegate.dialogResponse = .suppressed
    emit(ACR_EVENT_JS_DIALOG, page.token, request: 103, value: 1, detail: "sure?")
    resolution = await answer(for: 103, after: count)
    count = resolution.count
    precondition(resolution.value == 0, "a suppressed confirm answers false")
    emit(ACR_EVENT_JS_DIALOG, page.token, request: 104, value: 3, flags: 1)
    resolution = await answer(for: 104, after: count)
    count = resolution.count
    precondition(delegate.dialogs.last?.kind == .beforeUnload(isReload: true) && delegate.dialogs.last?.origin == nil)
    precondition(resolution.value == 1, "a suppressed beforeunload proceeds")
    emit(ACR_EVENT_JS_DIALOG_RESET, page.token)
    precondition(delegate.resets == 1, "a reset reaches the delegate")

    // HTTP authentication: the challenge without credentials in traces; the credential reaches CEF.
    delegate.credential = BrowserCredential(user: "synthetic-user", password: "synthetic-pass")
    emit(ACR_EVENT_AUTH, page.token, request: 105,
         payload: #"{"origin":"http://127.0.0.1:4100/","host":"127.0.0.1","port":4100,"realm":"Lab","scheme":"Basic","proxy":false}"#)
    resolution = await answer(for: 105, after: count)
    count = resolution.count
    precondition(delegate.challenges.last == BrowserAuthenticationChallenge(origin: "http://127.0.0.1:4100", host: "127.0.0.1",
                                                                           port: 4100, realm: "Lab", scheme: "basic", isProxy: false))
    precondition(resolution.value == 1 && text(resolution) == "synthetic-user" && text(resolution, second: true) == "synthetic-pass")
    delegate.credential = nil
    emit(ACR_EVENT_AUTH, page.token, request: 106,
         payload: #"{"origin":"","host":"proxy.test","port":3128,"realm":"","scheme":"","proxy":true}"#)
    resolution = await answer(for: 106, after: count)
    count = resolution.count
    precondition(resolution.value == 0, "no credential cancels")
    precondition(delegate.challenges.last?.isProxy == true && delegate.challenges.last?.realm == nil)

    // File chooser: accept filters and CEF's expanded extensions; chosen paths reach CEF.
    delegate.files = [URL(fileURLWithPath: "/private/tmp/a.txt"), URL(fileURLWithPath: "/private/tmp/b.png")]
    emit(ACR_EVENT_FILE_DIALOG, page.token, request: 107,
         payload: #"{"mode":1,"title":"","defaultPath":"","acceptTypes":["image/*",".TXT"],"acceptExtensions":[".png;.jpg",".txt"]}"#)
    resolution = await answer(for: 107, after: count)
    count = resolution.count
    precondition(delegate.choosers.last == BrowserFileChooserRequest(mode: .openMultiple, acceptTypes: ["image/*", ".txt"],
                                                                     acceptExtensions: ["png", "jpg", "txt"]))
    precondition(resolution.value == 2 && text(resolution) == "/private/tmp/a.txt" && text(resolution, second: true) == "/private/tmp/b.png")
    delegate.files = nil
    emit(ACR_EVENT_FILE_DIALOG, page.token, request: 108,
         payload: #"{"mode":2,"title":"Pick","defaultPath":"/private/tmp","acceptTypes":[],"acceptExtensions":[]}"#)
    resolution = await answer(for: 108, after: count)
    count = resolution.count
    precondition(delegate.choosers.last?.mode == .openFolder && resolution.value == 0, "a cancelled chooser")

    delegate.files = [URL(fileURLWithPath: "/private/tmp/orbit-synthetic-extension", isDirectory: true)]
    emit(ACR_EVENT_FILE_DIALOG, page.token, request: 208,
         payload: #"{"mode":4,"title":"Select directory","defaultPath":"/private/tmp","acceptTypes":[],"acceptExtensions":[]}"#)
    resolution = await answer(for: 208, after: count)
    count = resolution.count
    precondition(delegate.choosers.last?.mode == .openExistingFolder && resolution.value == 1,
                 "native directory purpose survives separately from web upload")
    precondition(text(resolution) == "/private/tmp/orbit-synthetic-extension")
    delegate.files = nil
    emit(ACR_EVENT_FILE_DIALOG, page.token, request: 209,
         payload: #"{"mode":4,"title":"","defaultPath":"","acceptTypes":[],"acceptExtensions":[]}"#)
    resolution = await answer(for: 209, after: count)
    count = resolution.count
    precondition(resolution.value == 0, "native directory cancellation sends no path")

    // Context menu: the request and its offered commands; a command executes the offered id once.
    let menuPayload = #"{"x":12,"y":34,"typeFlags":4,"linkURL":"https://example.test/a","sourceURL":"","pageURL":"https://example.test/","frameURL":"","hasImageContents":false,"titleText":"","mediaType":0,"mediaFlags":0,"selectionText":"","misspelledWord":"helo","suggestions":["hello","help"],"isEditable":true,"editFlags":31,"commands":{"IDC_CONTENT_CONTEXT_COPY":50150,"IDC_CONTENT_CONTEXT_INSPECTELEMENT":50162,"IDC_SPELLCHECK_SUGGESTION_0":41000,"IDC_SPELLCHECK_SUGGESTION_1":41001}}"#
    emit(ACR_EVENT_CONTEXT_MENU, page.token, request: 109, payload: menuPayload)
    guard let menu = delegate.menus.last else { preconditionFailure("the menu reaches the delegate") }
    precondition(menu.location == CGPoint(x: 12, y: 34) && menu.linkURL?.absoluteString == "https://example.test/a")
    precondition(menu.isEditable && menu.editFlags.contains([.canCopy, .canPaste]) && !menu.editFlags.contains(.canDelete))
    precondition(menu.availableCommands == [.copy, .inspect, .replaceMisspelling], "\(menu.availableCommands)")
    do {
        try page.performContextMenuCommand(.replaceMisspelling("help"), for: menu)
    } catch { preconditionFailure("an offered suggestion executes: \(error)") }
    resolution = await answer(for: 109, after: count)
    count = resolution.count
    precondition(resolution.value == 41001, "the second suggestion's Chrome command")
    var refused = false
    do { try page.performContextMenuCommand(.copy, for: menu) } catch { refused = true }
    precondition(refused, "a menu answers once")
    emit(ACR_EVENT_CONTEXT_MENU, page.token, request: 110, payload: menuPayload)
    let second = delegate.menus.last!
    refused = false
    do { try page.performContextMenuCommand(.cut, for: second) } catch { refused = true }
    precondition(refused, "a command not offered is refused")
    page.contextMenuDidClose(second)
    resolution = await answer(for: 110, after: count)
    count = resolution.count
    precondition(resolution.value == -1, "a menu closed without a page command cancels the native menu")

    // Element fullscreen, unresponsive and terminated renderers.
    emit(ACR_EVENT_FULLSCREEN, page.token, value: 1)
    precondition(delegate.fullscreen == [true] && page.isElementFullscreen)
    page.exitElementFullscreen()
    precondition(ACRStubLastResolution()!.pointee.kind == Int32(bitPattern: ACR_EVENT_FULLSCREEN.rawValue))
    count = ACRStubLastResolution()!.pointee.count
    emit(ACR_EVENT_FULLSCREEN, page.token, value: 0)
    precondition(delegate.fullscreen == [true, false] && !page.isElementFullscreen)
    emit(ACR_EVENT_UNRESPONSIVE, page.token, value: 1)
    precondition(delegate.unresponsive == [true] && page.isRendererUnresponsive)
    do { try page.perform(.terminateUnresponsiveRenderer) } catch { preconditionFailure("exit page reaches the bridge") }
    resolution = await answer(for: page.token, after: count)
    count = resolution.count
    precondition(resolution.value == 1 && !page.isRendererUnresponsive)
    emit(ACR_EVENT_RENDER_TERMINATED, page.token, value: 2)
    precondition(delegate.terminations == [.crashed] && page.rendererTermination == .crashed && delegate.failedNavigations == 1)
    emit(ACR_EVENT_DOCUMENT, page.token, url: "https://example.test/")
    precondition(page.rendererTermination == nil, "a new document clears the crashed state")

    // beforeunload-aware close: pending, then the user stays; pending, then the page closes.
    page.hostedWindowToken = 77
    ACRStubSetRequestCloseResult(1)
    let stay = Task { await page.confirmClose() }
    try? await Task.sleep(for: .milliseconds(20))
    emit(ACR_EVENT_JS_DIALOG, page.token, request: 111, value: 3)
    emit(ACR_EVENT_CLOSE_CANCELED, page.token)
    let stayed = await stay.value
    precondition(stayed == false, "Stay keeps the tab")
    let leave = Task { await page.confirmClose() }
    try? await Task.sleep(for: .milliseconds(20))
    emit(ACR_EVENT_CLOSED, page.token)
    let left = await leave.value
    precondition(left == true && !page.isDisposed, "the shell disposes after the page agreed")
    page.dispose()
    ACRStubSetRequestCloseResult(2)
    count = ACRStubLastResolution()!.pointee.count

    // A disposed surface's requests are answered at once: never left pending in CEF.
    let gone = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, gone.token, value: 2)
    gone.dispose()
    emit(ACR_EVENT_JS_DIALOG, gone.token, request: 112, value: 3)
    resolution = await answer(for: 112, after: count)
    count = resolution.count
    precondition(resolution.value == 1, "a disposed surface's beforeunload proceeds")
    emit(ACR_EVENT_CONTEXT_MENU, gone.token, request: 113, payload: menuPayload)
    resolution = await answer(for: 113, after: count)
    precondition(resolution.value == -1, "a disposed surface's menu is cancelled")
    emit(ACR_EVENT_CLOSED, gone.token)
    print("PASS: ABI 9 page surfaces (dialogs, auth, choosers, menus, fullscreen, renderer, close) through the stub bridge")
}

/// Reports the failing geometry assertion (optimized builds drop precondition messages).
private func requireGeometry(_ condition: Bool, _ message: @autoclosure () -> String) {
    guard !condition else { return }
    FileHandle.standardError.write(Data("FAILED \(message())\n".utf8))
    exit(1)
}

@MainActor
private func failedAddressChecks(_ backend: ChromiumBrowserEngine) {
    let delegate = LifecycleDelegate()
    let page = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, page.token, value: 2)
    emit(ACR_EVENT_ADDRESS, page.token, url: "https://previous.example.test/")
    emit(ACR_EVENT_DOCUMENT, page.token, url: "https://previous.example.test/")
    let generation = page.documentGeneration
    let stateURL = URL(string: "https://previous.example.test/?entry=1")!
    page.navigate(to: stateURL)
    emit(ACR_EVENT_ADDRESS, page.token, value: 1, url: stateURL.absoluteString)
    precondition(page.navigationState.committedURL == stateURL && page.currentURL == stateURL,
                 "same-document history updates committed and requested URL authority")
    precondition(page.documentGeneration == generation, "same-document history keeps document identity")
    emit(ACR_EVENT_LOAD_ERROR, page.token, value: -105, url: "http://unavailable.invalid/")
    precondition(page.navigationState.url?.absoluteString == "http://unavailable.invalid/",
                 "a DNS failure must not display the previous document's address")
    emit(ACR_EVENT_LOAD_ERROR, page.token, value: -3, url: "https://cancelled.example.test/")
    precondition(page.navigationState.url?.absoluteString == "http://unavailable.invalid/",
                 "an aborted request must not replace the displayed address")
    page.dispose()
    emit(ACR_EVENT_CLOSED, page.token)
    print("PASS: failed navigation addresses and cancelled request isolation")
}

@MainActor
private func nativeCloseChecks(_ backend: ChromiumBrowserEngine) async {
    let delegate = LifecycleDelegate()
    let session = BrowserWindowSession<ChromiumSurface>(makeSurface: { profile, _ in
        backend.makeSurface(profileID: profile, delegate: delegate)
    })
    delegate.onClose = { [weak session] surface in _ = session?.closeOwnedSurface(surface) }
    session.openTab(url: URL(string: "https://native-close.example.test/")!)
    await session.waitForPendingCommands()
    let page = session.selectedSurface!
    emit(ACR_EVENT_CREATED, page.token, value: 2)
    emit(ACR_EVENT_RENDER_TERMINATED, page.token, value: 2)
    precondition(delegate.closeRequests == 0 && session.selectedSurface === page && !page.isDisposed,
                 "a renderer crash keeps the model tab")
    emit(ACR_EVENT_CLOSED, page.token)
    await session.waitForPendingCommands()
    precondition(delegate.closeRequests == 1 && session.snapshot!.tabs.isEmpty && page.isDisposed,
                 "native destruction without CLOSE_REQUEST removes the Today occurrence")

    let requested = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, requested.token, value: 2)
    emit(ACR_EVENT_CLOSE_REQUEST, requested.token)
    emit(ACR_EVENT_CLOSED, requested.token)
    precondition(delegate.closeRequests == 2, "CLOSE_REQUEST followed by CLOSED notifies once")
    requested.dispose()

    let disposed = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, disposed.token, value: 2)
    disposed.dispose()
    emit(ACR_EVENT_CLOSED, disposed.token)
    precondition(delegate.closeRequests == 2, "shell disposal never creates a second close request")

    let confirmed = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, confirmed.token, value: 2)
    confirmed.hostedWindowToken = 77
    ACRStubSetRequestCloseResult(1)
    let confirmation = Task { await confirmed.confirmClose() }
    try? await Task.sleep(for: .milliseconds(20))
    emit(ACR_EVENT_CLOSED, confirmed.token)
    let accepted = await confirmation.value
    precondition(accepted && delegate.closeRequests == 2 && !confirmed.isDisposed,
                 "beforeunload approval resumes the shell close without a duplicate request")
    confirmed.dispose()
    ACRStubSetRequestCloseResult(2)

    delegate.onDownload = { download in _ = download.makeTransfer(chooseDestination: { _ in nil }) }
    for committed in [false, true] {
        let source = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
        emit(ACR_EVENT_CREATED, source.token, value: 2)
        if committed { emit(ACR_EVENT_DOCUMENT, source.token, url: "https://download.example.test/") }
        let previousRequests = delegate.closeRequests
        emit(ACR_EVENT_DOWNLOAD, source.token, request: committed ? 702 : 701)
        precondition(source.hasActiveDownloads && delegate.closeRequests == previousRequests + (committed ? 0 : 1),
                     "only an uncommitted auxiliary download source requests a shell close")
        source.dispose()
        emit(ACR_EVENT_CLOSED, source.token)
        precondition(delegate.closeRequests == previousRequests + (committed ? 0 : 1),
                     "retained download teardown does not request another model close")
    }
    delegate.onDownload = nil
    session.close()
    await session.waitForPendingCommands()
    print("PASS: native close updates Today, deduplicates requests, preserves crash, confirmation and download paths")
}

/// Exercises repeated native target determination after the source tab has retired.
@MainActor
private func downloadRetryChecks(_ backend: ChromiumBrowserEngine) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-download-retry-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let coordinator = BrowserDownloadCoordinator()
    let delegate = LifecycleDelegate()
    let source = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, source.token, value: 2)
    emit(ACR_EVENT_DOCUMENT, source.token, url: "about:blank")
    var offers = 0
    delegate.onDownload = { download in
        offers += 1
        let transfer = download.makeTransfer { _ in root.appendingPathComponent("synthetic.bin") }
        let registration = try! coordinator.register(owner: .init(profileID: source.profileID), transfer: transfer)
        transfer.attach(registration)
    }
    ACRStubDownload(source.token, 800, Int32(ACR_DOWNLOAD_IN_PROGRESS.rawValue), 0)
    for _ in 0..<100 {
        if ACRStubDownloadRequest() == 800 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let path = String(cString: ACRStubDownloadPath())
    precondition(!path.isEmpty)
    try Data(repeating: 1, count: 128).write(to: URL(fileURLWithPath: path))
    source.dispose()
    ACRStubDownload(source.token, 801, Int32(ACR_DOWNLOAD_IN_PROGRESS.rawValue), 64)
    precondition(ACRStubDownloadRequest() == 801 && String(cString: ACRStubDownloadPath()) == path)
    precondition(offers == 1 && source.hasActiveDownloads)
    ACRStubDownload(source.token, 0, Int32(ACR_DOWNLOAD_INTERRUPTED.rawValue), 64)
    precondition(coordinator.allSnapshots.first?.state == .interrupted)
    precondition(coordinator.allSnapshots.first?.canPerform(.resume) == true)
    try coordinator.perform(.resume, in: coordinator.allSnapshots[0].context)
    ACRStubDownload(source.token, 802, Int32(ACR_DOWNLOAD_IN_PROGRESS.rawValue), 64)
    precondition(ACRStubDownloadRequest() == 802 && String(cString: ACRStubDownloadPath()) == path)
    ACRStubDownload(source.token, 0, Int32(ACR_DOWNLOAD_COMPLETE.rawValue), 128)
    precondition(coordinator.allSnapshots.first?.state == .complete)
    let completed = try Data(contentsOf: root.appendingPathComponent("synthetic.bin"))
    precondition(completed.count == 128)
    precondition(!FileManager.default.fileExists(atPath: path))
    emit(ACR_EVENT_CLOSED, source.token)
    coordinator.shutdown()
    print("PASS: a detached download reuses its target across native retry and interruption/resume, then publishes completed bytes")
}

@main
@MainActor
struct LifecycleTests {
    static func main() async {
        var engine: ChromiumBrowserEngine?
        let runtime = ChromiumRuntime.shared
        let result = runtime.run(options: .init(rootCachePath: "/private/tmp/orbit-unused-lifecycle-stub",
            keychainServiceName: "unused-stub", keychainAccountName: "unused-stub", hiddenApplication: true)) {
            engine = ChromiumBrowserEngine(persistence: .ephemeral)
        }
        precondition(result == 0 && engine != nil, "the stub must report readiness without starting CEF")
        if CommandLine.arguments.contains("--performance-only") {
            await performanceChecks(engine!)
            return
        }
        if CommandLine.arguments.contains("--review-favicon-only") {
            await reviewFaviconReceiptChecks(engine!)
            return
        }
        if CommandLine.arguments.contains("--downloads-only") {
            try! await downloadRetryChecks(engine!)
            return
        }
        if CommandLine.arguments.contains("--native-close-only") {
            await nativeCloseChecks(engine!)
            return
        }
        if CommandLine.arguments.contains("--engine-tab-only") {
            await checkEngineTabAdoption()
            await checkEngineTabAdoptionRevocation()
            return
        }
        if CommandLine.arguments.contains("--host-geometry-only") {
            checkHostedContentGeometry()
            return
        }
        if CommandLine.arguments.contains("--favicon-only") {
            await faviconReceiptChecks(engine!)
            print("PASS: binary favicon receipt through C ABI -> Swift adapter, identity/generation/revision guards, corrupt/oversize/none/disposal")
            return
        }
        await checkProfileRemovalCapabilities()
        await checkExtensionAdapter()
        await checkVisibleCreationPublication()
        checkHostedContentGeometry()
        await checkEngineTabAdoption()
        await checkEngineTabAdoptionRevocation()
        let backend = engine!
        let delegate = LifecycleDelegate()
        let retainedSurface = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
        precondition(retainedSurface.isCreationPending && !retainedSurface.isReady)
        precondition(backend.liveNativeTokens == [retainedSurface.token])
        retainedSurface.dispose()
        precondition(retainedSurface.isDisposed && !retainedSurface.isTeardownComplete,
                     "disposal must await the native creation result")
        ACRStubAbortCreation(retainedSurface.token)
        precondition(!retainedSurface.isCreationPending && retainedSurface.isTeardownComplete,
                     "CREATE_ABORTED must complete teardown even when disposal happened earlier")
        precondition(runtime.surface(retainedSurface.token) == nil && backend.liveNativeTokens.isEmpty)

        // CHROMIUM-APP-R2: a refused profile request context never stops the process.
        ACRStubRefuseNextProfile()
        let refused = ProfileID()
        _ = backend.profile(for: refused)
        precondition(backend.refusedProfiles == [refused], "the refusal is recorded, not fatal")
        await backend.profileReady(refused)  // Returns at once instead of waiting forever.
        let failing = backend.makeSurface(profileID: refused, delegate: delegate)
        precondition(failing.creationFailed && !failing.isCreationPending && !failing.isReady)
        precondition(backend.liveNativeTokens.isEmpty, "a refused creation leaves no live native token")
        failing.navigate(to: URL(string: "https://refused.invalid/")!)
        for _ in 0..<200 where delegate.failedNavigations == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        precondition(delegate.failedNavigations == 1, "the navigation of a refused surface is reported as failed")
        let accepted = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
        precondition(accepted.isCreationPending && !accepted.creationFailed, "other profiles keep working")
        accepted.dispose()
        ACRStubAbortCreation(accepted.token)
        failing.dispose()

        await pageSurfaceChecks(backend)
        await nativeCloseChecks(backend)
        failedAddressChecks(backend)

        let outcome = await backend.shutdown(timeout: .milliseconds(100))
        precondition(outcome.isCompleted && backend.isShutDown)
        precondition(retainedSurface.isDisposed && retainedSurface.isTeardownComplete,
                     "the Swift surface remains retained through shutdown")
        print("PASS: profile-removal capability and guard -> pending disposal -> CREATE_ABORTED -> retained surface teardown -> refused profile recoverable -> engine shutdown (stub bridge, no CEF)")
    }

    /// The shell's host view is the only geometry authority over the engine's content view.
    /// Chromium may set that view's frame itself (WebContentsViewMac::Resize when a background tab is
    /// added, sized like the previously active tab); AppKit autoresizing then keeps the difference
    /// forever and the page lays out wider than its visible card (horizontal overflow) until a
    /// re-placement. Plain views in a never-ordered window: no CEF, no visible window.
    private static func checkHostedContentGeometry() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = ChromiumHostView(frame: NSRect(x: 300, y: 0, width: 900, height: 800))
        host.autoresizesSubviews = true
        window.contentView!.addSubview(host)
        // What CEF's hosted placement does (PlaceContentView): frame = parent bounds, autoresizing.
        let content = NSView(frame: host.bounds)
        content.autoresizingMask = [.width, .height]
        host.addSubview(content)
        func fits(_ label: String) {
            requireGeometry(content.frame == host.bounds,
                         "host-geometry: \(label): content \(content.frame) != host \(host.bounds)")
        }
        fits("initial placement")
        // Chromium resizes the attached content view to another tab's container (full window).
        content.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        host.setFrameSize(NSSize(width: 700, height: 760))
        fits("after the card narrows following an engine-initiated content resize")
        content.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        fits("immediately after an engine-initiated content resize")
        host.setFrameSize(NSSize(width: 1200, height: 800))  // Full-screen card, sidebar hidden.
        fits("after the card widens")
        host.setFrameSize(.zero)                            // Collapsed during a transition.
        host.setFrameSize(NSSize(width: 880, height: 700))
        fits("after a zero-size transition")
        // A replacement content view (cross-profile transfer, re-placement) is fitted on insertion.
        let replacement = NSView(frame: NSRect(x: 5, y: 5, width: 10, height: 10))
        content.removeFromSuperview()
        host.addSubview(replacement)
        requireGeometry(replacement.frame == host.bounds, "host-geometry: replacement fitted on insertion")
        content.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
        requireGeometry(content.frame.size == NSSize(width: 50, height: 50), "a detached view is not managed")
        replacement.removeFromSuperview()
        host.removeFromSuperview()
        window.close()
        requireGeometry(!window.isVisible, "host-geometry: the fixture window never appears")
        print("PASS: actual host view keeps engine content exactly at its bounds after engine resizes, card resizes, zero-size and replacement")
    }

    /// EXT-OUTCOME-R1: a Chrome-created tab offered through ABI 11 reaches the shell handler of the
    /// window that registered its token, with its profile, URL and activation, and becomes a pending
    /// surface whose host view and token go back to the bridge. Unknown windows/profiles, unready
    /// profiles, a declining or removed handler and shutdown give nothing back. No CEF, no window
    /// is ever ordered.
    private static func checkEngineTabAdoption() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        ACRStubSetPatchLevel(4); ACRStubHostedMode(1)
        defer { ACRStubHostedMode(0); ACRStubSetPatchLevel(0) }
        let backend = ChromiumBrowserEngine(persistence: .persistent, hostedWhenAvailable: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let windowID = WindowID()
        backend.shellWindowDidOpen(windowID, window: window)
        let windowToken = backend.shellWindows[windowID]?.token ?? 0
        let profileID = ProfileID()
        _ = backend.profile(for: profileID)
        let profileToken = backend.profileToken(for: profileID)
        ACRStubReadyProfile(profileToken)
        var requests: [BrowserEngineTabRequest] = []
        var answer = true
        var recorded: [ChromiumSurface] = []  // The shell's session retains what it records.
        backend.setEngineTabAdoption(for: windowID) { request, make in
            requests.append(request)
            guard answer else { return nil }
            let surface = make()
            recorded.append(surface)
            return surface
        }
        func offer(window: UInt64 = windowToken, profile: UInt64 = profileToken,
                   url: String = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/welcome.html",
                   foreground: Int32 = 1) -> (view: UnsafeMutableRawPointer?, token: UInt64) {
            var token: UInt64 = 0
            let view = ACRStubAdoptEngineTab(window, profile, url, foreground, &token)
            return (view, token)
        }
        let adopted = offer()
        let surface = backend.runtime.surface(adopted.token)
        requireGeometry(adopted.view != nil && adopted.token != 0 && surface != nil,
                        "engine-tab: the registered window adopts the tab")
        requireGeometry(adopted.view == surface.map { Unmanaged.passUnretained($0.hostView).toOpaque() },
                        "engine-tab: the bridge receives the adopted surface's own host view")
        requireGeometry(surface?.isCreationPending == true && backend.liveNativeTokens.contains(adopted.token),
                        "engine-tab: CEF owns the creation of the pending surface")
        requireGeometry(requests.last == BrowserEngineTabRequest(
            url: URL(string: "chrome-extension://abcdefghijklmnopabcdefghijklmnop/welcome.html"),
            profileID: profileID, isForeground: true), "engine-tab: request carries profile, URL and activation")
        let background = offer(url: "", foreground: 0)
        requireGeometry(background.token != 0 && requests.last?.url == nil && requests.last?.isForeground == false,
                        "engine-tab: an empty URL and a background tab are reported as such")
        let count = requests.count
        requireGeometry(offer(window: windowToken &+ 999).view == nil, "engine-tab: unknown window")
        requireGeometry(offer(profile: profileToken &+ 999).view == nil, "engine-tab: unknown profile")
        let unready = ProfileID()
        _ = backend.profile(for: unready)
        requireGeometry(offer(profile: backend.profileToken(for: unready)).view == nil, "engine-tab: unready profile")
        requireGeometry(requests.count == count, "engine-tab: refused offers never reach the shell")
        answer = false
        let live = backend.liveNativeTokens
        requireGeometry(offer().view == nil && backend.liveNativeTokens == live,
                        "engine-tab: a declining shell leaves no pending creation")
        backend.setEngineTabAdoption(for: windowID, nil)
        answer = true
        requireGeometry(offer().view == nil, "engine-tab: a removed handler adopts nothing")
        emit(ACR_EVENT_CREATED, adopted.token, value: 2)
        requireGeometry(surface?.isCreationPending == false, "engine-tab: the native browser arrives in the adopted surface")
        for token in [adopted.token, background.token] { emit(ACR_EVENT_CLOSED, token) }
        for surface in recorded { surface.dispose() }
        backend.shellWindowWillClose(windowID)
        requireGeometry(offer().view == nil, "engine-tab: a closed window adopts nothing")
        _ = await backend.shutdown(timeout: .milliseconds(100))
        requireGeometry(offer().view == nil, "engine-tab: a shut-down engine adopts nothing")
        window.close()
        print("PASS: actual adapter adopts Chrome-created tabs into the registering window's handler; refuses unknown/unready, declined, removed, closed and shut down")
    }

    /// EXT-OUTCOME-R2 (review B1): the shell callback may retire the authority checked before it.
    /// Each case revokes one authority inside the callback; the adapter must give the bridge no
    /// view, start no native creation and abort the surface the shell recorded exactly once.
    private static func checkEngineTabAdoptionRevocation() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        ACRStubSetPatchLevel(4); ACRStubHostedMode(1)
        defer { ACRStubHostedMode(0); ACRStubSetPatchLevel(0) }
        let backend = ChromiumBrowserEngine(persistence: .persistent, hostedWhenAvailable: true)
        let profileID = ProfileID()
        _ = backend.profile(for: profileID)
        let profileToken = backend.profileToken(for: profileID)
        ACRStubReadyProfile(profileToken)
        let foreign = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                               styleMask: [.borderless], backing: .buffered, defer: true)
        foreign.isReleasedWhenClosed = false
        enum Revocation: CaseIterable { case windowClosed, windowReplaced, handlerRemoved, handlerReplaced,
                                         surfaceDisposed, foreignHostWindow }
        for revocation in Revocation.allCases {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let replacement = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                       styleMask: [.borderless], backing: .buffered, defer: true)
            replacement.isReleasedWhenClosed = false
            let windowID = WindowID()
            backend.shellWindowDidOpen(windowID, window: window)
            let windowToken = backend.shellWindows[windowID]?.token ?? 0
            var recorded: [ChromiumSurface] = []
            var aborts = 0
            backend.setEngineTabAdoption(for: windowID) { _, make in
                let surface = make()
                recorded.append(surface)
                surface.onEngineEvent = { name, _ in if name == "create-aborted" { aborts += 1 } }
                switch revocation {
                case .windowClosed: backend.shellWindowWillClose(windowID)
                case .windowReplaced: backend.shellWindowDidOpen(windowID, window: replacement)
                case .handlerRemoved: backend.setEngineTabAdoption(for: windowID, nil)
                case .handlerReplaced: backend.setEngineTabAdoption(for: windowID) { _, make in make() }
                case .surfaceDisposed: surface.dispose()
                case .foreignHostWindow: foreign.contentView!.addSubview(surface.hostView)
                }
                return surface
            }
            let live = backend.liveNativeTokens
            var token: UInt64 = 0
            let view = ACRStubAdoptEngineTab(windowToken, profileToken, "https://example.invalid/", 1, &token)
            requireGeometry(view == nil && token == 0, "engine-tab revocation \(revocation): no view for the bridge")
            requireGeometry(backend.liveNativeTokens == live, "engine-tab revocation \(revocation): no native creation")
            requireGeometry(recorded.count == 1 && recorded[0].isDisposed,
                            "engine-tab revocation \(revocation): the recorded surface is retired")
            requireGeometry(aborts == (revocation == .surfaceDisposed ? 0 : 1),
                            "engine-tab revocation \(revocation): aborted exactly once (\(aborts))")
            recorded[0].hostView.removeFromSuperview()
            backend.setEngineTabAdoption(for: windowID, nil)
            backend.shellWindowWillClose(windowID)
            window.close(); replacement.close()
        }
        _ = await backend.shutdown(timeout: .milliseconds(100))
        foreign.close()
        print("PASS: actual adapter revalidates window, registration, handler, surface and host window after the shell callback; aborts once")
    }

    private static func checkVisibleCreationPublication() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        ACRStubSetPatchLevel(4); ACRStubHostedMode(1)
        defer { ACRStubHostedMode(0); ACRStubSetPatchLevel(0) }
        let backend = ChromiumBrowserEngine(persistence: .ephemeral, hostedWhenAvailable: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let registration = backend.makeWindow(for: window)!
        let delegate = LifecycleDelegate()
        let a = backend.makeTabSurface(profileID: ProfileID(), in: registration, delegate: delegate)!
        window.contentView!.addSubview(a.hostView)
        _ = a.focusDocument() // Focus queued before native creation used to conceal the missing publication.
        precondition(ACRStubPublishedSurface() == 0)
        emit(ACR_EVENT_CREATED, a.token, value: 2)
        precondition(ACRStubPublishedSurface() == a.token && ACRStubActivationCount() == 1,
                     "the first visible tab publishes selection before its cache becomes authoritative")
        backend.activateHostedTab(a)
        precondition(ACRStubActivationCount() == 1, "the cache is valid only after publication")
        let b = backend.makeTabSurface(profileID: ProfileID(), in: registration, delegate: delegate)!
        window.contentView!.addSubview(b.hostView)
        emit(ACR_EVENT_CREATED, b.token, value: 2)
        precondition(a.profileID != b.profileID && ACRStubPublishedSurface() == b.token && ACRStubActivationCount() == 2,
                     "a newly visible different-profile tab publishes without requiring a tab switch")
        backend.activateHostedTab(b)
        precondition(ACRStubActivationCount() == 2)
        a.dispose(); b.dispose()
        emit(ACR_EVENT_CLOSED, a.token); emit(ACR_EVENT_CLOSED, b.token)
        registration.close(); window.close()
        _ = await backend.shutdown(timeout: .milliseconds(100))
        precondition(!window.isVisible)
        print("PASS: actual adapter visible-created first-window and new-profile selection publication before activation cache")
    }

    private static func checkExtensionAdapter() async {
        defer { ACRStubSetPatchLevel(0); ACRStubExtensionsReenter(0) }
        ACRStubSetPatchLevel(3)
        let legacy = ChromiumBrowserEngine(persistence: .persistent, hostedWhenAvailable: true)
        precondition(legacy.extensions == nil && ACRExtensionsAvailable() == 0)
        let oldToken = legacy.profileToken(for: ProfileID())
        ACRStubReadyProfile(oldToken)
        precondition(ACRExtensionsSnapshot(oldToken, nil, 0) == -1)
        precondition(ACRObserveExtensions(oldToken, 1) == 0 && ACRObserveExtensions(oldToken, 0) == 0)
        precondition(ACRExtensionSetEnabled(oldToken, String(repeating: "a", count: 32), 1) == 0)
        precondition(ACRExtensionRemove(oldToken, String(repeating: "a", count: 32)) == 0)
        precondition(ACROpenExtensionManager(0) == 0 && ACRPerformExtensionAction(0, "", nil) == 0)
        _ = await legacy.shutdown(timeout: .milliseconds(100))
        ACRStubSetPatchLevel(4)
        let ephemeral = ChromiumBrowserEngine(persistence: .ephemeral, hostedWhenAvailable: true)
        precondition(ephemeral.extensions == nil)
        _ = await ephemeral.shutdown(timeout: .milliseconds(100))
        let backend = ChromiumBrowserEngine(persistence: .persistent, hostedWhenAvailable: true)
        let a = ProfileID(), b = ProfileID()
        let ta = backend.profileToken(for: a), tb = backend.profileToken(for: b)
        ACRStubReadyProfile(ta); ACRStubReadyProfile(tb)
        let host = backend.extensions as! ChromiumExtensionHost
        let fixture = #"[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Synthetic","version":"1","isEnabled":true,"hasAction":true}]"#
        ACRStubExtensionsSnapshot(fixture, -2, -2)
        do {
            let inventoryA = try host.installedExtensions(in: a)
            precondition(inventoryA.count == 1)
            precondition(ACRStubLastExtensionProfile() == ta)
            let inventoryB = try host.installedExtensions(in: b)
            precondition(inventoryB.count == 1)
            precondition(ACRStubLastExtensionProfile() == tb)
            try host.setEnabled(false, extensionID: String(repeating: "a", count: 32), in: b)
            precondition(ACRStubLastExtensionProfile() == tb)
        } catch { preconditionFailure("valid native inventory must decode: \(error)") }
        for (json, size, read): (String, Int32, Int32) in [
            ("invalid", -2, -2), (fixture, 4 * 1024 * 1024, -2),
            (fixture, -1, -2), (fixture, -2, 0), ("{}", -2, -2)] {
            ACRStubExtensionsSnapshot(json, size, read)
            var rejected = false
            do { _ = try host.installedExtensions(in: a) } catch { rejected = true }
            precondition(rejected, "malformed/oversized/inconsistent snapshots must fail closed")
        }
        ACRStubExtensionsSnapshot(fixture, -2, -2)
        var first = 0, second = 0, other = 0
        do {
            let one = try host.observeChanges(in: a) { first += 1 }
            let two = try host.observeChanges(in: a) { second += 1 }
            let three = try host.observeChanges(in: b) { other += 1 }
            ACRStubExtensionsChanged(ta)
            precondition(first == 1 && second == 1 && other == 0)
            one.cancel(); ACRStubExtensionsChanged(ta)
            precondition(first == 1 && second == 2 && other == 0)
            ACRStubExtensionsChanged(tb)
            precondition(other == 1)
            two.cancel(); three.cancel()
        } catch { preconditionFailure("independent native subscriptions must register") }
        // Native remove synchronously notifies; its handler unregisters reentrantly.
        var removed = 0
        host.onExtensionsChange = { profile in
            precondition(profile == a)
            removed += 1
            host.stopObserving(a)
        }
        ACRStubExtensionsReenter(4 | 2)
        do { try host.remove(extensionID: String(repeating: "a", count: 32), in: a) }
        catch { preconditionFailure("remove with reentrant unregister must return safely") }
        precondition(removed == 1)
        ACRStubExtensionsChanged(ta)
        precondition(removed == 1, "late native events cannot revive an unregistered profile")
        host.onExtensionsChange = nil
        do { try await backend.removeProfile(b) }
        catch { preconditionFailure("synthetic profile release must unregister: \(error)") }
        precondition(backend.runtime.extensionListeners[tb] == nil)
        ACRStubExtensionsChanged(tb)
        ACRStubExtensionsReenter(0)
        do { _ = try host.installedExtensions(in: a) } catch { preconditionFailure("resubscribe") }
        // Shutdown revokes all listeners before unregistration calls back.
        host.onExtensionsChange = { _ in preconditionFailure("shutdown/unregister callback escaped") }
        ACRStubExtensionsReenter(2)
        let unregisters = ACRStubExtensionUnregisterCount()
        _ = await backend.shutdown(timeout: .milliseconds(100))
        precondition(ACRStubExtensionUnregisterCount() >= unregisters + 1)
        precondition(ACRStubExtensionObserverCount() == 0 && backend.extensions == nil)
        ACRStubExtensionsChanged(ta); ACRStubExtensionsChanged(tb)
        do { try await backend.removeProfile(a) } catch { /* shutdown refuses safely */ }
        // Observer installation itself can be synchronously revoked by legacy listeners.
        ACRStubExtensionsReenter(0)
        let reentrant = ChromiumBrowserEngine(persistence: .persistent, hostedWhenAvailable: true)
        let id = ProfileID(), token = reentrant.profileToken(for: id)
        ACRStubReadyProfile(token)
        let reentrantHost = reentrant.extensions as! ChromiumExtensionHost
        reentrantHost.onExtensionsChange = { [weak reentrantHost] _ in reentrantHost?.stopObserving() }
        ACRStubExtensionsReenter(1 | 2)
        var rejected = false
        do { _ = try reentrantHost.installedExtensions(in: id) } catch { rejected = true }
        precondition(rejected && ACRStubExtensionObserverCount() == 0)
        ACRStubExtensionsReenter(0)
        _ = await reentrant.shutdown(timeout: .milliseconds(100))
        print("PASS: ABI 10 actual Swift adapter, v3 fail closed, profile routing, malformed snapshots, independent observers and reentrant remove/shutdown")
    }

    private static func checkProfileRemovalCapabilities() async {
        defer { ACRStubSetPatchLevel(0) }
        for version: UInt32 in [0, 1, 2, 3] {
            ACRStubSetPatchLevel(version)
            for persistence: BrowserWebsiteDataPersistence in [.persistent, .ephemeral] {
                let backend = ChromiumBrowserEngine(persistence: persistence, hostedWhenAvailable: true)
                precondition(backend.capabilities.contains(.profileRemoval) == (version >= 2),
                             "profile removal requires side API v2's profile_loaded safety check")
                precondition(backend.surfaceMode == (version >= 1 ? .hosted : .alloy))
                precondition(backend.capabilities.contains(.liveSurfaceTransfer) == (version >= 2))
                if version < 2 {
                    do {
                        try await backend.removeProfile(ProfileID())
                        preconditionFailure("stock and v1 must refuse removal before touching a profile")
                    } catch {
                        precondition(error as? BrowserEngineError == .unsupportedOperation)
                    }
                } else if persistence == .ephemeral {
                    // Exercise the advertised implementation without any filesystem or CEF data.
                    let profileID = ProfileID()
                    _ = backend.profile(for: profileID)
                    precondition(backend.profileCount == 1)
                    do {
                        try await backend.removeProfile(profileID)
                        try await backend.removeProfile(profileID)
                    } catch {
                        preconditionFailure("advertised ephemeral removal must succeed idempotently: \(error)")
                    }
                    precondition(backend.profileCount == 0)
                }
                let outcome = await backend.shutdown(timeout: .milliseconds(100))
                precondition(outcome.isCompleted)
            }
        }
    }
}

@MainActor
private func faviconReceiptChecks(_ engine: ChromiumBrowserEngine) async {
    let delegate = LifecycleDelegate()
    let surface = engine.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, surface.token, value: 2)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = bitmap.representation(using: .png, properties: [:])!
    let url = "https://fixture.example.test/owned.png"
    func receipt(profile: UInt64? = nil, browser: Int32? = nil, generation: UInt64 = 0,
                 revision: UInt64 = 1, address: String? = url, data: Data? = png) {
        let bytes = data ?? Data()
        bytes.withUnsafeBytes { raw in
            ACRStubEmitFavicon(surface.token, profile ?? surface.profileToken, browser ?? surface.browserID,
                generation, revision, address, data == nil ? nil : raw.baseAddress, bytes.count)
        }
    }
    receipt(profile: surface.profileToken + 100)
    precondition(surface.navigationState.faviconURL == nil)
    receipt(browser: surface.browserID + 100)
    precondition(surface.navigationState.faviconURL == nil)
    receipt(generation: 100)
    precondition(surface.navigationState.faviconURL == nil)
    receipt()
    precondition(surface.navigationState.faviconURL?.absoluteString == url)
    precondition(surface.navigationState.faviconImage?.png == png, "binary bytes must survive C callback lifetime")
    let decoded = await surface.navigationState.faviconImage?.nativeImage()
    precondition(decoded != nil)
    receipt(revision: 2, address: "https://fixture.example.test/new.png", data: nil)
    receipt(revision: 1)
    precondition(surface.navigationState.faviconImage == nil && surface.navigationState.faviconURL?.path == "/new.png")
    receipt(revision: 3, data: Data("not an image".utf8))
    precondition(surface.navigationState.faviconImage == nil)
    receipt(revision: 4, data: Data(repeating: 0, count: 131073))
    precondition(surface.navigationState.faviconImage == nil)
    receipt(revision: 5, address: nil, data: nil)
    precondition(surface.navigationState.faviconURL == nil)
    receipt(revision: 6)
    emit(ACR_EVENT_DOCUMENT, surface.token, url: "https://fixture.example.test/next")
    receipt(revision: 7)
    precondition(surface.navigationState.faviconURL == nil, "old document must not refill the new document")
    surface.dispose()
    receipt(generation: 1, revision: 8)
    precondition(surface.navigationState.faviconURL == nil)
    ACRStubAbortCreation(surface.token)
}

// Independent review assertions; author receipt checks above remain unchanged.
@MainActor
private func reviewFaviconReceiptChecks(_ engine: ChromiumBrowserEngine) async {
    let delegate = LifecycleDelegate()
    let surface = engine.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, surface.token, value: 2)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let bytes = bitmap.representation(using: .png, properties: [:])!
    func receipt(_ url: String, revision: UInt64, payload: Data? = nil) {
        let data = payload ?? Data()
        data.withUnsafeBytes { raw in
            ACRStubEmitFavicon(surface.token, surface.profileToken, surface.browserID, 0, revision,
                url, payload == nil ? nil : raw.baseAddress, data.count)
        }
    }
    let original = "https://fixture.example.test/current.png"
    receipt(original, revision: 1)
    receipt("https://fixture.example.test/stale.png", revision: 1, payload: bytes)
    let acceptedDifferentURL = surface.navigationState.faviconURL?.absoluteString != original
    FileHandle.standardOutput.write(Data("REVIEW equal-revision different-URL payload accepted: \(acceptedDifferentURL)\n".utf8))
    receipt("file:///synthetic/icon.png", revision: 2, payload: bytes)
    let acceptedFile = surface.navigationState.faviconImage != nil
    FileHandle.standardOutput.write(Data("REVIEW privileged source URL image accepted: \(acceptedFile)\n".utf8))
    surface.dispose()
    ACRStubAbortCreation(surface.token)
    precondition(!acceptedDifferentURL && !acceptedFile, "favicon boundary must reject stale URL and privileged source schemes independently")
}

@MainActor
private func performanceChecks(_ backend: ChromiumBrowserEngine) async {
    let delegate = LifecycleDelegate()
    let surface = backend.makeSurface(profileID: ProfileID(), delegate: delegate)
    emit(ACR_EVENT_CREATED, surface.token, value: 2)
    emit(ACR_EVENT_DOCUMENT, surface.token, url: "about:blank")
    surface.hostView.frame.size = CGSize(width: 1000, height: 600)
    ACRStubCaptureMode(1)
    ACRStubDevToolsMode(1)
    let firstNative = Task { try await surface.captureSnapshot(.init(width: 200)) }
    while ACRStubCaptureCount() == 0 { await Task.yield() }
    firstNative.cancel()
    do { _ = try await firstNative.value; preconditionFailure("cancelled readback succeeded") } catch is CancellationError {} catch { preconditionFailure("wrong cancellation") }
    let secondNative = Task { try await surface.captureSnapshot(.init(width: 200)) }
    try? await Task.sleep(for: .milliseconds(25))
    precondition(ACRStubCaptureCount() == 1 && ACRStubDevToolsID() == 0, "cancelled native work keeps admission until its callback")
    ACRStubCaptureFinish(1)
    while ACRStubCaptureCount() != 2 { await Task.yield() }
    ACRStubCaptureFinish(1)
    let image = try! await secondNative.value
    precondition(image.image.width == 200 && image.image.height == 120 && ACRStubDevToolsID() == 0)
    let changed = Task { try await surface.captureSnapshot(.init(width: 200)) }
    while ACRStubCaptureCount() != 3 { await Task.yield() }
    emit(ACR_EVENT_DOCUMENT, surface.token, url: "about:blank")
    ACRStubCaptureFinish(1)
    do { _ = try await changed.value; preconditionFailure("stale document succeeded") } catch { precondition(error as? BrowserEngineError == .documentChanged) }
    let resized = Task { try await surface.captureSnapshot(.init(width: 200)) }
    while ACRStubCaptureCount() != 4 { await Task.yield() }
    surface.hostView.frame.size.width = 900
    ACRStubCaptureFinish(1)
    do { _ = try await resized.value; preconditionFailure("stale geometry succeeded") } catch { precondition(error as? BrowserEngineError == .snapshotUnavailable) }
    let unavailable = Task { try await surface.captureSnapshot(.init(width: 200)) }
    while ACRStubCaptureCount() != 5 { await Task.yield() }
    ACRStubCaptureFinish(-1)
    while ACRStubDevToolsID() == 0 { await Task.yield() }
    unavailable.cancel(); _ = try? await unavailable.value
    emit(ACR_EVENT_DEVTOOLS_RESULT, surface.token, request: UInt64(ACRStubDevToolsID()), value: 0)
    ACRStubCaptureMode(0)
    ACRStubDevToolsMode(1)
    let cancelled = Task { try await surface.captureSnapshot(.init(width: 40)) }
    while ACRStubDevToolsID() == 0 { await Task.yield() }
    cancelled.cancel()
    do { _ = try await cancelled.value; preconditionFailure("cancelled capture succeeded") }
    catch { precondition(error is CancellationError) }
    let second = Task { await surface.devToolsCall("Page.captureScreenshot", timeout: .milliseconds(30)) }
    try? await Task.sleep(for: .milliseconds(15))
    precondition(ACRStubDevToolsID() == 1, "cancelled native capture still owns the slot")
    emit(ACR_EVENT_DEVTOOLS_RESULT, surface.token, request: 1, value: 1, payload: "{}")
    _ = await second.value
    precondition(ACRStubDevToolsID() == 2, "late response releases the slot; next request times out once")
    emit(ACR_EVENT_DEVTOOLS_RESULT, surface.token, request: 2, value: 1, payload: "{}")
    let neverIssued = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return await surface.devToolsCall("Page.captureScreenshot")
    }
    let neverIssuedResult = await neverIssued.value
    precondition(!neverIssuedResult.0 && ACRStubDevToolsID() == 2)
    surface.dispose()
    emit(ACR_EVENT_CLOSED, surface.token)
    ACRStubDevToolsMode(0)
    ACRStubSetPatchLevel(2)
    let persistent = ChromiumBrowserEngine(persistence: .persistent)
    for code: Int32 in [2, -1] {
        let id = ProfileID()
        ACRStubRetirementMode(code)
        let removal = Task { try await persistent.removeProfile(id) }
        try? await Task.sleep(for: .milliseconds(20))
        precondition(persistent.profileToken(for: id) == 0, "recreation is refused during worker cleanup")
        precondition(ChromiumBrowserEngine(persistence: .persistent).profileToken(for: id) == 0)
        await persistent.profileReady(id)
        do { try await persistent.removeProfile(id); preconditionFailure("overlapping removal accepted") }
        catch { precondition(error as? BrowserEngineError == .profileInUse) }
        do { try await removal.value; precondition(code == 2) }
        catch { precondition(code == -1 && error as? BrowserEngineError == .profileRemovalIncomplete) }
        precondition(persistent.profileToken(for: id) != 0, "recreation is possible after cleanup completion")
    }
    print("PASS: prompt cancellation, native capture serialization, late result/timeout races, profile cleanup ordering and failure")
}
