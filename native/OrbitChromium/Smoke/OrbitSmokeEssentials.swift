import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell
import ChromiumEngine
import Foundation

extension OrbitSmokeDriver {
    static let essentialsUser = "orbit-synthetic-user"
    static let essentialsPassword = "orbit-synthetic-password"

    private func essentialsPage(_ name: String) -> URL {
        URL(string: "/essentials/\(name)", relativeTo: fixture)!.absoluteURL
    }

    private var tlsFixture: URL? {
        arguments.first { $0.hasPrefix("--orbit-smoke-tls-fixture=") }
            .flatMap { URL(string: String($0.dropFirst("--orbit-smoke-tls-fixture=".count))) }
            .flatMap { $0.host == "127.0.0.1" && $0.scheme == "https" ? $0 : nil }
    }

    func essentials(_ application: OrbitApplication, _ window: OrbitWindowController, home: ChromiumSurface,
                    _ engine: ChromiumBrowserEngine) async {
        let center = BrowserPageDialogCenter.shared
        var presented: [String] = []
        center.onPresent = { _, spec in presented.append(spec.kind.rawValue) }
        defer { center.onPresent = nil }
        func evaluate(_ script: String, _ surface: ChromiumSurface) async -> String? {
            try? await engine.conformanceProbe?.evaluateScript(script, in: surface)
        }
        func value(_ script: String, _ surface: ChromiumSurface, equals expected: String? = nil, _ seconds: Double = 10) async -> String? {
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
            while ContinuousClock.now < deadline, !finished {
                if let value = await evaluate(script, surface), expected == nil || value == expected { return value }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return await evaluate(script, surface)
        }
        func dialog(_ surface: ChromiumSurface, _ kind: BrowserPageDialogSpec.Kind, _ seconds: Double = 10) async -> BrowserPageDialogSpec? {
            await until(seconds) { center.presentedDialog(for: ObjectIdentifier(surface)).flatMap { $0.kind == kind ? $0 : nil } }
        }
        func overlayShown(on surface: ChromiumSurface) -> Bool {
            surface.hostView.subviews.contains { $0 is BrowserPageDialogView }
        }
        var essentialTabs: [ChromiumSurface] = []
        defer {
            for surface in essentialTabs where window.owns(surface) { _ = window.session.closeOwnedSurface(surface) }
            if let occurrence = window.session.occurrenceID(for: home) { window.session.selectOccurrence(occurrence) }
        }

        let dialogs = essentialsPage("dialogs")
        window.openTab(url: dialogs)
        guard let tab = await committed(window, dialogs) else {
            record("essentials.page", "failed", ["reason": "the essentials fixture did not commit"])
            return
        }
        essentialTabs.append(tab)
        let key = ObjectIdentifier(tab)
        let origin = "127.0.0.1:\(fixture.port ?? 0)"
        check("essentials.page", tab.tabIdentity?.isHosted == true, identity(tab))

        // 1. JavaScript dialogs: tab-modal over the document, answered once, the page gets the answer.
        _ = await evaluate("setTimeout(() => { alert('orbit-alert'); window.__alert = 'done'; }, 0); 1", tab)
        let alert = await dialog(tab, .alert)
        let alertOverlay = overlayShown(on: tab)
        center.respond(for: key, accept: true)
        let alertDone = await value("window.__alert", tab, equals: "done")
        check("essentials.js-alert", alert?.message == "orbit-alert" && alert?.title == "\(origin) says" && alertOverlay
              && alertDone == "done" && window.window?.attachedSheet == nil,
              ["title": alert?.title ?? "none", "overlayInDocument": alertOverlay, "pageContinued": alertDone ?? "none"])

        _ = await evaluate("setTimeout(() => { window.__confirm = String(confirm('orbit-confirm')); }, 0); 1", tab)
        let confirm = await dialog(tab, .confirm)
        center.respond(for: key, accept: false)
        let confirmed = await value("window.__confirm", tab, equals: "false")
        check("essentials.js-confirm", confirm?.message == "orbit-confirm" && confirm?.secondary != nil && confirmed == "false",
              ["pageResult": confirmed ?? "none"])

        _ = await evaluate("setTimeout(() => { window.__prompt = String(prompt('orbit-prompt', 'seed')); }, 0); 1", tab)
        let prompt = await dialog(tab, .prompt)
        center.respond(for: key, accept: true, fieldValues: ["orbit-typed"])
        let typed = await value("window.__prompt", tab, equals: "orbit-typed")
        check("essentials.js-prompt", prompt?.fields.first?.initialValue == "seed" && typed == "orbit-typed",
              ["pageResult": typed ?? "none"])

        // Chromium's "prevent additional dialogs": a quick follow-up offers it; checked, the next is suppressed.
        // Past Chromium's expected delay (1 s) after the prompt, the first dialog offers no prevention.
        try? await Task.sleep(for: .milliseconds(1300))
        let shownBefore = presented.count
        _ = await evaluate("setTimeout(() => { alert('one'); alert('two'); alert('three'); window.__spam = 'done'; }, 0); 1", tab)
        let first = await until(10) { center.presentedDialog(for: key).flatMap { $0.message == "one" ? $0 : nil } }
        center.respond(for: key, accept: true)
        let second = await until(10) { center.presentedDialog(for: key).flatMap { $0.message == "two" ? $0 : nil } }
        center.respond(for: key, accept: true, checkbox: true)
        let spamDone = await value("window.__spam", tab, equals: "done")
        let shown = presented.count - shownBefore
        check("essentials.js-prevent-additional", first?.checkbox == nil && second?.checkbox != nil && spamDone == "done"
              && shown == 2 && center.presentedDialog(for: key) == nil,
              ["secondOffersPrevention": second?.checkbox != nil, "dialogsShown": shown, "pageContinued": spamDone ?? "none"])

        guard !finished else { return }
        // 2. beforeunload: on navigation (Stay keeps the document) and on ⌘W (Stay keeps the tab, Leave closes it).
        let leaving = essentialsPage("beforeunload")
        window.openTab(url: leaving)
        if let page = await committed(window, leaving) {
            essentialTabs.append(page)
            let pageKey = ObjectIdentifier(page)
            _ = await evaluate("document.getElementById('field').value = 'unsaved'; 1", page)  // a user gesture
            window.submitAddress(essentialsPage("linked").absoluteString)
            let ask = await dialog(page, .beforeUnload)
            center.respond(for: pageKey, accept: false)
            try? await Task.sleep(for: .seconds(1))
            let stayed = page.navigationState.committedURL == leaving
            check("essentials.beforeunload-navigation", ask?.title == "Leave site?" && stayed,
                  ["asked": ask != nil, "stayed": stayed])

            _ = await evaluate("document.getElementById('field').value = 'unsaved again'; 1", page)
            window.closeSelectedTab()
            let askClose = await dialog(page, .beforeUnload)
            center.respond(for: pageKey, accept: false)
            try? await Task.sleep(for: .seconds(1))
            let kept = window.owns(page) && !page.isDisposed
            _ = await evaluate("document.getElementById('field').value = 'leave'; 1", page)
            window.closeSelectedTab()
            let askLeave = await dialog(page, .beforeUnload)
            center.respond(for: pageKey, accept: true)
            let closed = await until(10) { !window.owns(page) && page.isDisposed }
            check("essentials.beforeunload-close", askClose != nil && kept && askLeave != nil && closed,
                  ["askedOnClose": askClose != nil, "stayKeptTab": kept, "leaveClosedTab": closed])
        } else {
            record("essentials.beforeunload-navigation", "failed", ["reason": "fixture did not commit"])
        }

        guard !finished else { return }
        // 3. HTTP authentication (Basic): the sign-in dialog, credentials reach the server; Cancel shows the 401.
        let auth = essentialsPage("auth")
        window.openTab(url: auth)
        let authTab = await until(10) { window.session.selectedSurface.flatMap { $0 !== tab && $0.currentURL == auth ? $0 : nil } }
        if let authTab {
            essentialTabs.append(authTab)
            let authKey = ObjectIdentifier(authTab)
            let signIn = await dialog(authTab, .authentication)
            center.respond(for: authKey, accept: true, fieldValues: [Self.essentialsUser, Self.essentialsPassword])
            let signedIn = await until(15) { authTab.navigationState.title == "essentials-auth-ok" }
            check("essentials.http-auth", signIn?.message == "\(origin) requires a username and password."
                  && signIn?.note != nil && signedIn,
                  ["message": signIn?.message ?? "none", "insecureNote": signIn?.note != nil, "signedIn": signedIn])
            authTab.navigate(to: essentialsPage("auth-cancel"))
            let second = await dialog(authTab, .authentication)
            center.respond(for: authKey, accept: false)
            let refused = await until(15) { authTab.navigationState.title == "essentials-auth-required" }
            check("essentials.http-auth-cancel", second != nil && refused, ["serverResponseShown": refused])
        } else {
            record("essentials.http-auth", "failed", ["reason": "no auth tab"])
        }

        guard !finished else { return }
        if let occurrence = window.session.occurrenceID(for: tab) { window.session.selectOccurrence(occurrence) }
        _ = await until(5) { window.session.selectedSurface === tab }

        // 4. File chooser: the page's accept filters reach Orbit; the chosen files reach the page.
        var fileResolutions: [String] = []
        let previousFileEvents = tab.onEngineEvent
        tab.onEngineEvent = { name, fields in
            previousFileEvents?(name, fields)
            if name == "file-chooser-resolved" { fileResolutions.append(fields["count"] ?? "missing") }
        }
        defer { tab.onEngineEvent = previousFileEvents }
        let uploads = runRoot.appendingPathComponent("reports", isDirectory: true)
        let fileA = uploads.appendingPathComponent("upload-a.txt"), fileB = uploads.appendingPathComponent("upload-b.txt")
        try? Data("synthetic a".utf8).write(to: fileA)
        try? Data("synthetic b".utf8).write(to: fileB)
        var chooserRequests: [BrowserFileChooserRequest] = []
        BrowserFileChooserPresenter.shared.responder = { request in
            chooserRequests.append(request)
            return request.mode == .openMultiple ? [fileA, fileB] : nil
        }
        defer { BrowserFileChooserPresenter.shared.responder = nil }
        _ = await evaluate("document.getElementById('files').click(); 1", tab)
        let names = await value("Array.from(document.getElementById('files').files).map(f => f.name).join(',')", tab,
                                equals: "upload-a.txt,upload-b.txt")
        let chooser = chooserRequests.first
        check("essentials.file-chooser", chooser?.mode == .openMultiple && chooser?.acceptTypes.contains("image/*") == true
              && chooser?.acceptTypes.contains(".txt") == true && names == "upload-a.txt,upload-b.txt",
              ["mode": chooser.map { "\($0.mode)" } ?? "none", "acceptTypes": chooser?.acceptTypes ?? [],
               "acceptExtensions": chooser?.acceptExtensions.count ?? 0, "pageFiles": names ?? "none"])
        // Accept a real directory through Orbit's confirmation, then reject a fresh selection.
        let folder = uploads.appendingPathComponent("upload-folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try? Data("root content".utf8).write(to: folder.appendingPathComponent("root.txt"))
        try? Data("child content".utf8).write(to: nested.appendingPathComponent("child.txt"))
        BrowserFileChooserPresenter.shared.responder = { request in
            chooserRequests.append(request)
            return request.mode == .openFolder ? [folder] : nil
        }
        let resolutionsBefore = fileResolutions.count
        let folderBefore = chooserRequests.count
        let confirmationsBefore = presented.filter { $0 == "folderUpload" }.count
        _ = await evaluate("window.__folderChanges = 0; document.getElementById('folder').onchange = () => window.__folderChanges++; document.getElementById('folder').click(); 1", tab)
        let uploadAsk = await dialog(tab, .folderUpload)
        center.respond(for: key, accept: true)
        let acceptedCount = await value("String(document.getElementById('folder').files.length)", tab, equals: "2")
        _ = await evaluate("Promise.all(Array.from(document.getElementById('folder').files).map(async f => [f.name, f.webkitRelativePath, await f.text()].join('|'))).then(rows => window.__folderRows = rows.sort().join(';')); 1", tab)
        let expectedRows = "child.txt|upload-folder/nested/child.txt|child content;root.txt|upload-folder/root.txt|root content"
        let rows = await value("window.__folderRows", tab, equals: expectedRows)
        let acceptedChanges = await evaluate("String(window.__folderChanges)", tab)
        check("essentials.folder-upload-accepted", uploadAsk != nil && acceptedCount == "2" && rows == expectedRows
              && acceptedChanges == "1" && Array(fileResolutions.dropFirst(resolutionsBefore)) == ["1"] && chooserRequests.count == folderBefore + 1
              && presented.filter { $0 == "folderUpload" }.count == confirmationsBefore + 1,
              ["pageFileList": rows ?? "none", "fileCount": acceptedCount ?? "none", "changeEvents": acceptedChanges ?? "none",
               "callbackCounts": Array(fileResolutions.dropFirst(resolutionsBefore)),
               "confirmations": presented.filter { $0 == "folderUpload" }.count - confirmationsBefore])
        _ = await evaluate("document.getElementById('folder').value = ''; document.getElementById('folder').click(); 1", tab)
        let rejectAsk = await dialog(tab, .folderUpload)
        center.respond(for: key, accept: false)
        try? await Task.sleep(for: .seconds(1))
        let rejectedCount = await evaluate("String(document.getElementById('folder').files.length)", tab)
        let rejectedChanges = await evaluate("String(window.__folderChanges)", tab)
        check("essentials.folder-upload-rejected", rejectAsk != nil && rejectedCount == "0" && rejectedChanges == "1"
              && Array(fileResolutions.dropFirst(resolutionsBefore)) == ["1", "0"]
              && chooserRequests.count == folderBefore + 2 && center.presentedDialog(for: key) == nil,
              ["fileCount": rejectedCount ?? "none", "changeEvents": rejectedChanges ?? "none", "asked": rejectAsk != nil,
               "callbackCounts": Array(fileResolutions.dropFirst(resolutionsBefore))])

        guard !finished else { return }
        // 5. Context menu: a right click reaches Orbit with Chrome's parameters; commands go back for that document.
        var observed: (request: BrowserContextMenuRequest, groups: [[BrowserPageContextMenuModel.Item]])?
        window.pageInteraction.menuObserver = { request, groups in observed = (request, groups) }
        defer { window.pageInteraction.menuObserver = nil }
        func rightClick(_ x: Int, _ y: Int) async {
            for type in ["mousePressed", "mouseReleased"] {
                _ = await tab.devToolsCall("Input.dispatchMouseEvent",
                                           params: #"{"type":"\#(type)","x":\#(x),"y":\#(y),"button":"right","clickCount":1}"#)
            }
        }
        await rightClick(40, 32)
        let linkMenu = await until(10) { observed }
        let linked = essentialsPage("linked")
        let offered = tab.openContextMenuCommands ?? [:]
        let openTabsBefore = window.session.snapshot?.tabs.count ?? 0
        if linkMenu != nil { window.performPageContextCommand(.pageOpenLinkInNewTab) }
        if let request = linkMenu?.request { tab.contextMenuDidClose(request) }
        await window.session.waitForPendingCommands()
        let openedLink = window.session.snapshot?.tabs.contains { $0.url == linked } == true
        check("essentials.context-menu-link", linkMenu?.request.linkURL == linked
              && linkMenu?.groups.first?.map(\.command) == [.pageOpenLinkInNewTab, .pageOpenLinkInSplitView]
              && offered["IDC_CONTENT_CONTEXT_SAVELINKAS"] != nil && openedLink
              && window.session.selectedSurface === tab,
              ["linkURL": linkMenu?.request.linkURL?.absoluteString ?? "none", "chromeCommands": offered.keys.sorted(),
               "groups": linkMenu?.groups.map { $0.map(\.command.rawValue) } ?? [], "openedInBackground": openedLink,
               "tabsBefore": openTabsBefore])

        observed = nil
        _ = await evaluate("const f = document.getElementById('field'); f.focus(); f.setSelectionRange(0, 0); 1", tab)
        await rightClick(60, 92)
        let editMenu = await until(10) { observed }
        if editMenu?.request.availableCommands.contains(.selectAll) == true { window.performPageContextCommand(.pageSelectAll) }
        let selection = await value("[document.getElementById('field').selectionStart, document.getElementById('field').selectionEnd].join(',')",
                                    tab, equals: "0,4")
        check("essentials.context-menu-editable", editMenu?.request.isEditable == true && selection == "0,4",
              ["editable": editMenu?.request.isEditable ?? false,
               "commands": editMenu.map { $0.request.availableCommands.map(\.rawValue).sorted() } ?? [],
               "selectionAfterSelectAll": selection ?? "none"])

        guard !finished else { return }
        // 6. Repeated logical fullscreen transitions and exact CEF callback ordering.
        var toggles = 0
        var fullscreenCallbacks: [Bool] = []
        let previousEvents = tab.onEngineEvent
        tab.onEngineEvent = { name, fields in
            previousEvents?(name, fields)
            if name == "fullscreen" { fullscreenCallbacks.append(fields["fullscreen"] == "true") }
        }
        window.toggleNativeFullScreen = { _ in toggles += 1 }
        defer {
            window.toggleNativeFullScreen = { $0.toggleFullScreen(nil) }
            tab.onEngineEvent = previousEvents
        }
        tab.focusDocument()
        let active = await until(5) { tab.tabIdentity?.isActive == true }
        for cycle in 1...3 {
            _ = await evaluate("window.__fs = 'pending'; document.getElementById('box').requestFullscreen().then(() => window.__fs = 'entered', e => window.__fs = 'error:' + e.name); 1", tab)
            let entered = await value("window.__fs", tab, equals: "entered")
            let layout = await until(5) { window.elementFullscreenSurfaceKey == key && tab.isElementFullscreen }
            check("essentials.fullscreen-enter-\(cycle)", active && entered == "entered" && layout && !window.isSidebarVisible
                  && fullscreenCallbacks == Array(repeating: [true, false], count: cycle - 1).flatMap { $0 } + [true],
                  ["promise": entered ?? "none", "orbitLayout": layout, "callbacks": fullscreenCallbacks])
            _ = await evaluate("window.__fsExit = 'pending'; document.exitFullscreen().then(() => window.__fsExit = 'done', e => window.__fsExit = 'error:' + e.name); 1", tab)
            let exited = await value("window.__fsExit", tab, equals: "done")
            let empty = await value("String(document.fullscreenElement === null)", tab, equals: "true")
            let restored = await until(5) { window.elementFullscreenSurfaceKey == nil && window.isSidebarVisible && !tab.isElementFullscreen }
            check("essentials.fullscreen-exit-\(cycle)", exited == "done" && empty == "true" && restored
                  && fullscreenCallbacks == Array(repeating: [true, false], count: cycle).flatMap { $0 },
                  ["promise": exited ?? "none", "pageElementNull": empty ?? "none", "layoutRestored": restored,
                   "callbacks": fullscreenCallbacks, "nativeToggles": toggles])
        }
        _ = await evaluate("document.getElementById('box').requestFullscreen().then(() => window.__escapeReady = true); 1", tab)
        _ = await value("String(window.__escapeReady)", tab, equals: "true")
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            let routing = window.surface(tab, willSendKeyToPage: escape)
            let kept: Bool = if case .browser = routing { true } else { false }
            let empty = await value("String(document.fullscreenElement === null)", tab, equals: "true")
            let restored = await until(5) { window.elementFullscreenSurfaceKey == nil && window.isSidebarVisible }
            check("essentials.fullscreen-escape", kept && empty == "true" && restored && fullscreenCallbacks == [true, false, true, false, true, false, true, false],
                  ["escapeKeptByBrowser": kept, "pageElementNull": empty ?? "none", "callbacks": fullscreenCallbacks])
        }

        guard !finished else { return }
        // 7. Application links: never silent, never automatic.
        let gate = BrowserExternalProtocolGate.shared
        var opened: [String] = []
        let previous = (gate.applicationName, gate.opener)
        gate.applicationName = { ["mailto", "tel"].contains($0.scheme ?? "") ? "Synthetic Mail" : nil }
        gate.opener = { opened.append($0.scheme ?? "") }
        defer { gate.applicationName = previous.0; gate.opener = previous.1 }
        tab.navigate(to: dialogs)
        _ = await until(10) { tab.navigationState.committedURL == dialogs && !tab.navigationState.isLoading }
        _ = await evaluate("document.getElementById('mail').click(); 1", tab)
        let mailAsk = await dialog(tab, .externalProtocol)
        let beforeOpen = opened
        center.respond(for: key, accept: true)
        let mailOpened = await until(5) { opened == ["mailto"] }
        _ = await evaluate("document.getElementById('tel').click(); 1", tab)
        let telAsk = await dialog(tab, .externalProtocol)
        center.respond(for: key, accept: false)
        try? await Task.sleep(for: .milliseconds(500))
        check("essentials.external-protocol", mailAsk?.title == "Open Synthetic Mail?" && beforeOpen.isEmpty && mailOpened
              && telAsk != nil && opened == ["mailto"] && tab.navigationState.committedURL == dialogs,
              ["mailtoAsked": mailAsk != nil, "openedBeforeConsent": !beforeOpen.isEmpty, "opened": opened,
               "telCancelled": telAsk != nil, "pageStayed": tab.navigationState.committedURL == dialogs])

        guard !finished else { return }
        // 8. A JavaScript dialog of a Peek document is shown over the Peek, not over the tab below.
        let peekURL = essentialsPage("linked")
        if let peeked = window.openPeek(peekURL), await until(15, { peeked.navigationState.committedURL == peekURL }) {
            _ = await evaluate("setTimeout(() => { alert('orbit-peek'); window.__peek = 'done'; }, 0); 1", peeked)
            let peekAlert = await dialog(peeked, .alert)
            let overPeek = overlayShown(on: peeked), overTab = overlayShown(on: tab)
            center.respond(for: ObjectIdentifier(peeked), accept: true)
            let peekDone = await value("window.__peek", peeked, equals: "done")
            check("essentials.peek-dialog", peekAlert != nil && overPeek && !overTab && peekDone == "done",
                  ["overPeek": overPeek, "overTab": overTab])
            window.dismissPeek(animated: false)
            _ = await until(5) { !window.peek.isPresented }
        } else {
            record("essentials.peek-dialog", "failed", ["reason": "Peek did not open"])
        }

        // 9. Certificate errors: Chrome's interstitial is an HTML page of the tab (no Views).
        if let tls = tlsFixture {
            let secure = URL(string: "/essentials/secure", relativeTo: tls)!.absoluteURL
            window.openTab(url: secure)
            let secureTab = await until(10) { window.session.selectedSurface.flatMap { $0.currentURL == secure ? $0 : nil } }
            if let secureTab {
                essentialTabs.append(secureTab)
                let title = await value("document.title", secureTab, equals: "Privacy error", 15)
                let text = await evaluate("document.body ? document.body.innerText.includes('Your connection is not private') : false",
                                          secureTab)
                check("essentials.certificate-interstitial", title == "Privacy error" && text == "true",
                      ["title": title ?? "none", "interstitialText": text ?? "none"])
            } else {
                record("essentials.certificate-interstitial", "failed", ["reason": "no secure tab"])
            }
        } else {
            record("essentials.certificate-interstitial", "not-run", ["reason": "no TLS fixture"])
        }

        // 10. A crashed renderer: Orbit's crashed page, then Reload. Chrome's sad tab dereferences a
        // missing BrowserView in hosted mode (sad_tab_controller.cc): only with the essentials patch.
        if engine.essentialsLevel >= 1 {
            let crashURL = essentialsPage("linked")
            window.openTab(url: crashURL)
            if let crashing = await committed(window, crashURL) {
                essentialTabs.append(crashing)
                // A different site keeps its renderer independent of the deliberately crashed one.
                let survivorURL = URL(string: crashURL.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!
                window.openTab(url: survivorURL)
                let survivor = await committed(window, survivorURL)
                if let survivor { essentialTabs.append(survivor) }
                let beforeSurvivor = if let survivor { await evaluate("window.__survived = 1; String(window.__survived)", survivor) } else { nil as String? }
                if let occurrence = window.session.occurrenceID(for: crashing) { window.session.selectOccurrence(occurrence) }
                let isolateBefore = await crashing.devToolsCall("Runtime.getIsolateId")
                _ = await evaluate("window.__preCrashMarker = 'old renderer'; 1", crashing)
                let browserPID = ProcessInfo.processInfo.processIdentifier
                _ = await crashing.devToolsCall("Page.crash", timeout: .seconds(2))
                let crashedShown = await until(15) { center.isCrashedPageShown(for: ObjectIdentifier(crashing)) }
                let termination = crashing.rendererTermination
                let duringSurvivor = if let survivor { await evaluate("String(++window.__survived)", survivor) } else { nil as String? }
                center.reloadCrashedPage(for: ObjectIdentifier(crashing))
                let reloaded = await until(20) { crashing.rendererTermination == nil && crashing.navigationState.committedURL == crashURL
                                                 && !crashing.navigationState.isLoading }
                let title = await value("document.title", crashing, equals: "essentials-linked")
                let body = await evaluate("document.body.innerText", crashing)
                let marker = await evaluate("typeof window.__preCrashMarker", crashing)
                let isolateAfter = await crashing.devToolsCall("Runtime.getIsolateId")
                let freshIsolate = isolateBefore.0 && isolateAfter.0 && isolateBefore.1 != isolateAfter.1
                let afterSurvivor = if let survivor { await evaluate("String(++window.__survived)", survivor) } else { nil as String? }
                let overlayGone = !center.isCrashedPageShown(for: ObjectIdentifier(crashing))
                check("essentials.renderer-crash", crashedShown && termination != nil && reloaded && overlayGone
                      && title == "essentials-linked" && body?.contains("Linked synthetic page.") == true
                      && marker == "undefined" && freshIsolate && beforeSurvivor == "1" && duringSurvivor == "2" && afterSurvivor == "3"
                      && ProcessInfo.processInfo.processIdentifier == browserPID,
                      ["crashedPage": crashedShown, "termination": termination?.rawValue ?? "none", "reloaded": reloaded,
                       "browserPID": browserPID, "freshIsolate": freshIsolate, "oldMarkerGone": marker == "undefined",
                       "freshContent": title ?? "none", "overlayGone": overlayGone,
                       "survivorBefore": beforeSurvivor ?? "none", "survivorDuring": duringSurvivor ?? "none", "survivorAfter": afterSurvivor ?? "none",
                       "isolateBefore": String(decoding: isolateBefore.1, as: UTF8.self),
                       "isolateAfter": String(decoding: isolateAfter.1, as: UTF8.self)])
            } else {
                record("essentials.renderer-crash", "failed", ["reason": "fixture did not commit"])
            }
        } else {
            record("essentials.renderer-crash", "patch-required",
                   ["essentialsLevel": 0, "reason": "SadTabController without BrowserView crashes the browser; not exercised"])
        }

        // 11. Commands whose UI is a real window or modal panel: capability and routing only here.
        check("essentials.page-commands-available", engine.capabilities.contains(.devTools) && engine.capabilities.contains(.printing)
              && engine.capabilities.contains(.beforeUnloadOnClose) && engine.capabilities.contains(.pageContextMenus)
              && window.canPerformPageCommand(.print) && window.canPerformPageCommand(.showDevTools) && !tab.hasDevTools,
              ["essentialsLevel": Int(engine.essentialsLevel), "note": "DevTools window and print panel: visible validation"])
        check("essentials.no-pending-requests", center.presentedDialog(for: key) == nil && !overlayShown(on: tab),
              ["presented": presented])
    }
}
