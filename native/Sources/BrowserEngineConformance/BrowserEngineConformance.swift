import AppKit
import BrowserCore
import BrowserEngine
import BrowserShell

/// Engine-independent acceptance checks that every `BrowserEngine` adapter must pass, runnable
/// without a visible window. Returns human-readable failures; empty means conformance. Adapters
/// run it from their own test target (WebKit in OrbitTests, Chromium in its laboratory bundle).
/// The checks are behavioural: engine work is awaited until the engine confirms it (bounded
/// waits), profile isolation is proven with site data through `conformanceProbe`, and engines with
/// web content (every kind but `.synthetic`) are driven against a loopback fixture server that
/// counts the requests it really receives: refusal without request, resumption without replay,
/// popup POST with its body and opener, native download to completion, find and snapshot of a
/// real document, keyboard input reaching the page after `focusDocument()`. The run consumes the
/// engine: it ends with `shutdown()` and requires every surface it disposed to report
/// `isTeardownComplete`.
@MainActor
public enum BrowserEngineConformance {
    static let isolationOrigin = URL(string: "https://isolation.conformance.test/")!
    /// Probe expression returning the keys the current document received (fixture pages record
    /// them; the synthetic engine answers from its document responder).
    public static let typedKeysScript = "window.__orbitKeys"

    public static func check<Engine: BrowserEngine>(_ engine: Engine) async -> [String] {
        var failures: [String] = []
        func require(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let capabilities = engine.capabilities
        require(!capabilities.contains(.printing) || engine is any BrowserPagePrinting<Engine.Surface>,
                "the printing capability requires the page printing service")
        let hostsWebContent = engine.kind != .synthetic
        var server: ConformanceFixtureServer?
        if hostsWebContent {
            do {
                let started = try ConformanceFixtureServer()
                try await started.start()
                server = started
            } catch {
                return ["the loopback fixture server could not start: \(error)"]
            }
        }
        defer { server?.stop() }
        func page(_ id: String) -> URL {
            server?.page(id) ?? URL(string: "https://conformance.test/\(id)")!
        }
        var created: [Engine.Surface] = []
        func make(_ profileID: ProfileID, _ delegate: ConformanceDelegate<Engine.Surface>) -> Engine.Surface {
            let surface = engine.makeSurface(profileID: profileID, delegate: delegate)
            created.append(surface)
            return surface
        }

        // Declared profile identities.
        let first = ProfileID()
        let second = ProfileID()
        let firstProfile = engine.profile(for: first)
        require(firstProfile.profileID == first, "profile(for:) must describe the requested profile")
        require(engine.profile(for: first) == firstProfile, "a profile must keep one store for the engine's lifetime")
        require(engine.profile(for: second).profileID == second, "distinct profiles must resolve to distinct stores")
        if !capabilities.contains(.persistentProfiles) {
            require(firstProfile.persistence == .ephemeral, "persistent profiles require the persistentProfiles capability")
        }

        // Commands issued right after creation, before readiness, run in call order.
        let early = ConformanceDelegate<Engine.Surface>()
        let earlySurface = make(first, early)
        let earlyA = page("early-a"), earlyB = page("early-b")
        earlySurface.navigate(to: earlyA)
        earlySurface.navigate(to: earlyB)
        require(await eventually { earlySurface.navigationState.committedURL == earlyB },
                "commands issued before readiness must run, the last navigation winning")
        await settle()
        require(earlySurface.navigationState.committedURL == earlyB, "an earlier queued navigation must not commit after a later one")
        if let a = early.commitURLs.firstIndex(of: earlyA), let b = early.commitURLs.firstIndex(of: earlyB) {
            require(a < b, "queued navigations must commit in call order")
        }
        if let server { require(server.count("/page?id=early-b") == 1, "a queued navigation must emit exactly one request") }
        earlySurface.dispose()

        // Creation never loads and never calls back before the caller's first command.
        let creator = ConformanceDelegate<Engine.Surface>()
        let surface = make(first, creator)
        require(creator.events.isEmpty, "makeSurface must not deliver delegate events")
        require(surface.delegate === creator, "makeSurface must bind the given delegate")
        require(surface.profileID == first, "a surface must be bound to the profile it was created in")
        require(surface.hostView.superview == nil, "the engine must not place a new host view itself")
        require(surface.placement == .detached, "a new surface must start detached")
        require(!surface.isDisposed, "a new surface must be live")
        require(await eventually { surface.isReady }, "a new surface must become ready")
        await settle()
        require(creator.events.isEmpty && creator.actionURLs.isEmpty,
                "a new surface must not load or ask for policy before its first navigation")
        require(surface.navigationState.committedURL == nil, "a new surface must not commit a document by itself")
        require(abs(surface.pageZoom - 1) < 0.000_001, "a new surface must start at actual size")

        // The delegate is re-bindable and policy goes through the decision seam.
        let receiver = ConformanceDelegate<Engine.Surface>()
        surface.delegate = receiver
        require(surface.delegate === receiver, "delegate must be re-bindable")
        let initialGeneration = surface.documentGeneration
        let firstDocument = page("first")
        surface.navigate(to: firstDocument)
        require(await eventually { receiver.events.contains("commit") }, "a navigation must commit through the current delegate")
        require(creator.events.isEmpty && creator.actionURLs.isEmpty, "events must reach only the current delegate")
        require(receiver.actionURLs.contains(firstDocument), "a navigation must ask the delegate for its action policy")
        let canSuspend = capabilities.contains(.suspendablePolicyDecisions)
        require(receiver.suspensionOffers.allSatisfy { $0 == canSuspend },
                "policy decisions must offer suspension exactly when suspendablePolicyDecisions is advertised")
        require(surface.documentGeneration != initialGeneration, "a committed document must advance documentGeneration")
        require(surface.navigationState.committedURL == firstDocument, "navigationState must report the committed document")
        // Navigation metadata (CONTRACT-R2): a shell navigation is typed, a GET without body, in place.
        if let typed = receiver.actions.last(where: { $0.url == firstDocument }) {
            require(typed.kind == .typed, "a navigate(to:) request must report kind .typed (got \(typed.kind))")
            require(typed.httpMethod == "GET", "a navigation must report its HTTP method")
            require(typed.hasBody != true, "a GET navigation must not report a body")
            require(typed.isUserGesture != true, "a shell navigation is not a page user gesture")
            require(typed.disposition == .currentTab && typed.isMainFrame != false,
                    "a main-frame navigation must report the current tab")
        }
        if capabilities.contains(.navigationResponsePolicy) {
            require(receiver.responseURLs.contains(firstDocument),
                    "an engine with navigationResponsePolicy must ask about the main-frame response before commit")
        } else {
            require(receiver.responseURLs.isEmpty, "only engines with navigationResponsePolicy may ask about responses")
        }

        // History traversal and reload are reported as such.
        let secondDocument = page("second")
        surface.navigate(to: secondDocument)
        require(await eventually { surface.navigationState.committedURL == secondDocument }, "a second navigation must commit")
        let actionsBeforeBack = receiver.actions.count
        let commitsBeforeBack = receiver.count("commit")
        receiver.actionPolicy = .cancel
        surface.goBack()
        require(await eventually { receiver.actions.count > actionsBeforeBack },
                "a cached history traversal must ask for navigation policy")
        await settle()
        require(surface.navigationState.committedURL == secondDocument && receiver.count("commit") == commitsBeforeBack,
                "a refused history traversal must keep the current document")
        receiver.actionPolicy = .allow
        surface.goBack()
        require(await eventually { surface.navigationState.committedURL == firstDocument }, "goBack must return to the previous document")
        require(receiver.actions.contains { $0.kind == .backForward && $0.url == firstDocument },
                "a history traversal must report kind .backForward")
        surface.goForward()
        require(await eventually { surface.navigationState.committedURL == secondDocument },
                "goForward must restore the next document")
        require(receiver.actions.contains { $0.kind == .backForward && $0.url == secondDocument },
                "a forward traversal must report kind .backForward")
        surface.goBack()
        require(await eventually { surface.navigationState.committedURL == firstDocument },
                "a repeated back traversal must return to the first document")
        let commitsBeforeReload = receiver.count("commit")
        surface.reload()
        require(await eventually { receiver.count("commit") > commitsBeforeReload }, "reload must commit the document again")
        require(receiver.actions.contains { $0.kind == .reload && $0.url == firstDocument }, "a reload must report kind .reload")

        // Zoom is defined for a committed document and confirmed by the engine.
        surface.performZoom(.increase)
        require(await eventually { surface.pageZoom > 1 }, "zoom in must increase the factor")
        surface.performZoom(.reset)
        require(await eventually { abs(surface.pageZoom - 1) < 0.000_001 }, "zoom reset must restore actual size")

        // A cancelled decision ends the navigation before any request; nothing replays it.
        receiver.actionPolicy = .cancel
        let commitsBeforeRefusal = receiver.count("commit")
        let refused = page("refused")
        surface.navigate(to: refused)
        require(await eventually { receiver.actionURLs.contains(refused) }, "a navigation must ask for policy before loading")
        await settle()
        require(receiver.count("commit") == commitsBeforeRefusal, "a cancelled navigation must not commit")
        require(receiver.actionURLs.filter { $0 == refused }.count == 1, "a cancelled navigation must not be replayed")
        require(surface.navigationState.committedURL == firstDocument, "a cancelled navigation must keep the committed document")
        if let server { require(server.count("/page?id=refused") == 0, "a cancelled navigation must not emit a request") }
        receiver.actionPolicy = .allow

        // Engines that suspend hold the original request until the answer, then resume it once.
        if canSuspend {
            let suspendedDocument = page("suspended")
            receiver.suspendNextAction = true
            surface.navigate(to: suspendedDocument)
            require(await eventually { receiver.suspended != nil }, "a suspendable engine must accept a suspended decision")
            await settle()
            require(surface.navigationState.committedURL == firstDocument, "a suspended navigation must not commit before its answer")
            receiver.suspended?.decide(.allow)
            require(await eventually { surface.navigationState.committedURL == suspendedDocument },
                    "a resumed navigation must commit the original request")
            require(receiver.actionURLs.filter { $0 == suspendedDocument }.count == 1, "a resumed navigation must not be replayed")
            if let server { require(server.count("/page?id=suspended") == 1, "a resumed navigation must emit exactly one request") }
        }

        // `.download` converts the original request only with navigationDownloadConversion.
        let converted = server?.url("/convert?id=convert") ?? page("convert")
        receiver.actionPolicy = .download
        receiver.keepsDownloads = true
        let downloadsBeforeConversion = receiver.downloads.count
        let commitsBeforeConversion = receiver.count("commit")
        surface.navigate(to: converted)
        if capabilities.contains(.navigationDownloadConversion) {
            require(await eventually { receiver.downloads.count > downloadsBeforeConversion },
                    "a .download answer must become a download with navigationDownloadConversion")
            if let server {
                require(await eventually { server.count("/convert?id=convert") > 0 }, "a converted navigation must fetch its request")
            }
            await settle()
            require(receiver.count("commit") == commitsBeforeConversion, "a converted navigation must not commit")
            if let server { require(server.count("/convert?id=convert") == 1, "a converted navigation must not be replayed") }
            for download in receiver.downloads.dropFirst(downloadsBeforeConversion) { download.cancel() }
        } else {
            require(await eventually { surface.navigationState.committedURL == converted },
                    "without navigationDownloadConversion a .download answer must behave as .allow")
            require(receiver.downloads.count == downloadsBeforeConversion,
                    "without navigationDownloadConversion a .download answer must not start a download")
        }
        receiver.actionPolicy = .allow
        receiver.keepsDownloads = false

        // A live move keeps the document: no reload, no new events, same generation.
        if capabilities.contains(.liveSurfaceTransfer) {
            let origin = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
            let destination = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
            origin.addSubview(surface.hostView)
            await settle()
            let generation = surface.documentGeneration
            let committed = surface.navigationState.committedURL
            let previousEvents = receiver.events.count
            let mover = ConformanceDelegate<Engine.Surface>()
            surface.delegate = mover
            surface.hostView.removeFromSuperview()
            destination.addSubview(surface.hostView)
            await settle()
            require(mover.events.isEmpty && receiver.events.count == previousEvents, "a live move must not reload the document")
            require(surface.documentGeneration == generation && surface.navigationState.committedURL == committed,
                    "a live move must keep the document")
            surface.hostView.removeFromSuperview()
            surface.delegate = receiver
        }

        let probe = engine.conformanceProbe
        if let server, let probe {
            // A link activated in the page reports its kind; a same-document change reports no commit.
            let linkSource = page("link-source")
            surface.navigate(to: linkSource)
            require(await eventually { surface.navigationState.committedURL == linkSource }, "the link fixture must commit")
            _ = try? await probe.evaluateScript("document.getElementById('link').click()", in: surface)
            let linked = server.page("linked")
            require(await eventually { surface.navigationState.committedURL == linked }, "a clicked link must navigate")
            require(receiver.actions.contains { $0.url == linked }, "a clicked link must ask for its action policy")
            if let link = receiver.actions.last(where: { $0.url == linked }) {
                require(link.kind == .linkActivation, "a clicked link must report kind .linkActivation (got \(link.kind))")
                require(link.disposition == .currentTab, "a same-tab link must report the current tab")
                require(link.isUserGesture != false, "a link clicked with a user gesture must not report its absence")
            }
            let generation = surface.documentGeneration
            let commits = receiver.count("commit")
            _ = try? await probe.evaluateScript("history.pushState({}, '', '/page?id=pushed')", in: surface)
            let pushed = server.page("pushed")
            require(await eventually { receiver.sameDocument.contains { $0.url == pushed } },
                    "a pushState navigation must be reported as a same-document navigation")
            require(receiver.sameDocument.last?.kind == .historyState, "pushState must report kind .historyState")
            _ = try? await probe.evaluateScript("location.hash = 'conformance-fragment'", in: surface)
            require(await eventually { receiver.sameDocument.contains { $0.url.fragment == "conformance-fragment" } },
                    "a fragment navigation must be reported as a same-document navigation")
            require(receiver.sameDocument.last?.kind == .fragment, "a fragment change must report kind .fragment")
            await settle()
            require(receiver.count("commit") == commits && surface.documentGeneration == generation,
                    "a same-document navigation must not commit a new document")
            require(surface.navigationState.url?.fragment == "conformance-fragment",
                    "navigationState must show the same-document address")
        }

        // Focus reaches the document: first responder inside the host view, and a key press
        // delivered through the window reaches the page.
        let focusPage = page("focus")
        surface.navigate(to: focusPage)
        require(await eventually { surface.navigationState.committedURL == focusPage }, "the focus fixture must commit")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = content
        surface.hostView.frame = content.bounds
        content.addSubview(surface.hostView)
        require(surface.focusDocument(), "focusDocument must succeed for a host view in a window")
        require(await eventually { responder(window.firstResponder, isInside: surface.hostView) },
                "focusDocument must move first responder into the host view")
        if let probe {
            await settle()
            // A whole key press: the key-up also leaves AppKit's current event in a neutral state for
            // the rest of the process (menu validation reads `NSApp.currentEvent`).
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let key = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: "k",
                                              charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40) {
                    window.sendEvent(key)
                }
            }
            let reached = await eventually {
                await ((try? probe.evaluateScript(typedKeysScript, in: surface)) ?? nil)?.contains("k") == true
            }
            require(reached, "a key press after focusDocument must reach the document")
        }

        // Find and snapshot succeed on a real document.
        if hostsWebContent {
            let found = FindResult()
            surface.performFind(BrowserFindRequest(token: UUID(), documentGeneration: surface.documentGeneration,
                                                   query: "conformance-needle", forward: true, matchCase: false,
                                                   selectMatch: true)) { update in
                if update.final { found.update = update }
            }
            require(await eventually { found.update != nil }, "find must report a final result")
            require(found.update?.matchFound == true && found.update?.error == nil, "find must locate text of the document")
            if capabilities.contains(.exactFindCount) {
                require(found.update?.count == 1, "exactFindCount must report the exact total")
            }
            surface.stopFinding(clearSelection: true)
        }
        if capabilities.contains(.snapshots) {
            let generation = surface.documentGeneration
            do {
                let snapshot = try await surface.captureSnapshot(BrowserSnapshotRequest(width: 320, documentGeneration: generation))
                require(snapshot.documentGeneration == generation, "a snapshot must report the generation it shows")
                require(snapshot.image.width > 0 && snapshot.image.height > 0, "a snapshot must contain an image")
            } catch {
                failures.append("a snapshot of the visible document must succeed: \(error)")
            }
        }
        surface.hostView.removeFromSuperview()
        require(!surface.focusDocument(), "focusDocument must fail without a window")
        window.close()

        // Snapshots target one document generation.
        do {
            _ = try await surface.captureSnapshot(BrowserSnapshotRequest(documentGeneration: surface.documentGeneration &+ 1))
            failures.append("a snapshot of another document generation must fail")
        } catch {
            let expected: BrowserEngineError = capabilities.contains(.snapshots) ? .documentChanged : .unsupportedOperation
            require(error as? BrowserEngineError == expected, "a snapshot of another document generation must fail with \(expected)")
        }

        if let server, let probe {
            // A popup keeps its opener and the original POST, sent exactly once.
            let popupDelegate = ConformanceDelegate<Engine.Surface>()
            receiver.newTargetDelegate = popupDelegate
            _ = try? await probe.evaluateScript("document.getElementById('post').submit()", in: surface)
            require(await eventually(timeout: .seconds(10)) {
                        receiver.createdTargets.first.map { $0.navigationState.committedURL != nil } == true },
                    "a form posted to a named target must open and commit a new surface")
            require(!receiver.newTargetRequests.isEmpty, "a form posted to a named target must request a new target")
            if let request = receiver.newTargetRequests.first {
                require(request.kind == .formSubmission, "a form posted to a named target must report kind .formSubmission")
                require(request.httpMethod == "POST", "a posted new target must report method POST")
                require(request.hasBody == true, "a posted new target must report its body")
                require(request.disposition != .currentTab, "a new target must not report the current tab")
            }
            if let popup = receiver.createdTargets.first {
                created.append(popup)
                require(popup.profileID == surface.profileID, "a new target must inherit the source profile")
                require(server.count("/posted", method: "POST") == 1, "a popup POST must be sent exactly once")
                require(server.requests.contains { $0.target == "/posted" && $0.body == ConformanceFixtureServer.postBody },
                        "a popup POST must carry its original body")
                let opener = try? await probe.evaluateScript("String(window.opener !== null)", in: popup)
                require(opener == "true", "a named-target popup must keep its opener")
                popup.dispose()
            }
            let targetsBeforeGET = receiver.createdTargets.count
            _ = try? await probe.evaluateScript("""
                (() => { const form = document.createElement('form');
                  form.method = 'GET'; form.action = '/page'; form.target = 'conformance-get-target';
                  document.body.append(form); form.submit(); })()
                """, in: surface)
            require(await eventually {
                receiver.createdTargets.count > targetsBeforeGET && receiver.createdTargets.last?.navigationState.committedURL != nil
            }, "a GET form target must open and commit a new surface")
            if receiver.createdTargets.count > targetsBeforeGET, let popup = receiver.createdTargets.last {
                created.append(popup)
                if let request = receiver.newTargetRequests.last {
                    require(request.kind == .formSubmission && request.httpMethod == "GET" && request.hasBody == false,
                            "a GET form target must report its own form kind and bodyless GET")
                }
                popup.dispose()
            }
            receiver.newTargetDelegate = nil

            // The engine decides a native download itself, without a policy answer, and completes it
            // once adopted, synchronously as the shell does, by a real download coordinator.
            let downloadRun = DownloadRun(profileID: first)
            receiver.adoptDownload = { downloadRun.adopt($0) }
            let commitsBeforeDownload = receiver.count("commit")
            surface.navigate(to: server.url("/download"))
            require(await eventually { downloadRun.download != nil },
                    "an attachment response must be reported through didStartDownload")
            if let download = downloadRun.download {
                require(download.suggestedFilename == "conformance.txt", "a download must report its suggested filename")
                if let failure = await downloadRun.waitForFile() { failures.append(failure) }
                require(receiver.count("commit") == commitsBeforeDownload, "a download must not commit a document")
                require(server.count("/download") == 1, "a download must emit exactly one request")
            }
            receiver.adoptDownload = nil
            downloadRun.finish()
        }

        // Isolation is proven with real site data, through each surface's own store.
        if let probe {
            let sibling = make(first, creator)
            let stranger = make(second, creator)
            let marker = "conformance-\(UUID().uuidString)"
            do {
                try await probe.writeSiteDataMarker(marker, for: isolationOrigin, through: surface)
                let shared = try await probe.readSiteDataMarker(for: isolationOrigin, through: sibling)
                require(shared == marker, "surfaces of one profile must share site data")
                let leaked = try await probe.readSiteDataMarker(for: isolationOrigin, through: stranger)
                require(leaked == nil, "distinct profiles must not share site data")
                try await probe.writeSiteDataMarker("other-\(marker)", for: isolationOrigin, through: stranger)
                let kept = try await probe.readSiteDataMarker(for: isolationOrigin, through: surface)
                require(kept == marker, "site data written in one profile must not change another profile")
            } catch {
                failures.append("the isolation probe failed: \(error)")
            }
            sibling.dispose()
            stranger.dispose()
        } else {
            failures.append("an engine must provide a conformanceProbe")
        }

        if !capabilities.contains(.audioMuting) {
            do {
                try surface.setAudioMuted(true)
                failures.append("setAudioMuted must throw without the audioMuting capability")
            } catch {
                require(error as? BrowserEngineError == .unsupportedOperation,
                        "missing audio muting must be reported as unsupportedOperation")
            }
        }

        failures += await checkProfileRemoval(engine)

        // Disposal is synchronous for the shell and final.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        host.addSubview(surface.hostView)
        var disposals = 0
        surface.onDispose = { disposals += 1 }
        surface.dispose()
        surface.dispose()
        require(disposals == 1, "dispose must be idempotent and notify exactly once")
        require(surface.isDisposed, "a disposed surface must report it")
        require(surface.hostView.superview == nil, "dispose must detach the host view")
        let eventsAtDisposal = receiver.events.count
        surface.navigate(to: firstDocument)
        await settle()
        require(receiver.events.count == eventsAtDisposal, "a disposed surface must not deliver events")
        do {
            _ = try await surface.captureSnapshot(BrowserSnapshotRequest())
            failures.append("a disposed surface must not produce a snapshot")
        } catch {
            let expected: BrowserEngineError = capabilities.contains(.snapshots) ? .surfaceDisposed : .unsupportedOperation
            require(error as? BrowserEngineError == expected, "snapshot of a disposed surface must fail with \(expected)")
        }
        require(await surface.requestMediaState() == BrowserMediaState(),
                "a disposed surface must report unknown media state")

        // Shutdown returns only after every native close completed, as the engine reports it.
        for surface in created { surface.dispose() }
        let shutdown = Completion()
        Task { @MainActor in
            await engine.shutdown()
            shutdown.isDone = true
        }
        require(await eventually(timeout: .seconds(15)) { shutdown.isDone }, "shutdown must complete once every surface is disposed")
        if shutdown.isDone {
            require(created.allSatisfy(\.isTeardownComplete),
                    "shutdown must return only after every disposed surface reports isTeardownComplete")
        }
        return failures
    }

    /// Standalone profile-cleanup acceptance used by both the full harness and focused tests.
    public static func checkProfileRemoval<Engine: BrowserEngine>(_ engine: Engine) async -> [String] {
        guard engine.capabilities.contains(.profileRemoval), let probe = engine.conformanceProbe else {
            return ["profile removal requires profileRemoval and a conformance probe"]
        }
        let first = ProfileID(), other = ProfileID()
        let delegate = ConformanceDelegate<Engine.Surface>()
        let target = engine.makeSurface(profileID: first, delegate: delegate)
        let preserved = engine.makeSurface(profileID: other, delegate: delegate)
        var owned = [target, preserved]
        defer { for surface in owned { surface.dispose() } }
        do {
            try await probe.writeSiteDataMarker("delete", for: isolationOrigin, through: target)
            try await probe.writeSiteDataMarker("keep", for: isolationOrigin, through: preserved)
            do {
                try await engine.removeProfile(first)
                return ["removeProfile must reject live surfaces"]
            } catch BrowserEngineError.profileInUse { }
            target.dispose()
            guard await eventually({ target.isTeardownComplete }) else { return ["profile removal native teardown timed out"] }
            // Bound native cleanup just as the rest of this harness bounds engine operations.
            let done = Completion()
            var failure: (any Error)?
            let removal = Task { @MainActor in
                do { try await engine.removeProfile(first); try await engine.removeProfile(first) }
                catch { failure = error }
                done.isDone = true
            }
            guard await eventually(timeout: .seconds(15), { done.isDone }) else {
                removal.cancel()
                return ["removeProfile timed out"]
            }
            if failure != nil { return ["removeProfile failed for a disposed or already removed profile"] }
            let fresh = engine.makeSurface(profileID: first, delegate: delegate)
            owned.append(fresh)
            guard try await probe.readSiteDataMarker(for: isolationOrigin, through: fresh) == nil else {
                return ["removed profile data survived reopening"]
            }
            guard try await probe.readSiteDataMarker(for: isolationOrigin, through: preserved) == "keep" else {
                return ["profile removal changed another profile's data"]
            }
            for surface in owned { surface.dispose() }
            guard await eventually({ owned.allSatisfy(\.isTeardownComplete) }) else { return ["profile probe teardown timed out"] }
            try await engine.removeProfile(first)
            try await engine.removeProfile(other)
            return []
        } catch { return ["profile removal conformance operation failed"] }
    }

    /// Adopts one reported download into a real `BrowserDownloadCoordinator`, writing to a
    /// temporary directory, and waits for the file.
    @MainActor
    final class DownloadRun {
        let profileID: ProfileID
        let coordinator = BrowserDownloadCoordinator()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-conformance-\(UUID().uuidString)", isDirectory: true)
        private(set) var download: (any BrowserEngineDownload)?
        private var key: BrowserDownloadKey?
        private var registrationError: (any Error)?

        init(profileID: ProfileID) { self.profileID = profileID }

        func adopt(_ download: any BrowserEngineDownload) {
            guard self.download == nil else { download.cancel(); return }
            self.download = download
            let directory = directory
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let transfer = download.makeTransfer { filename in directory.appendingPathComponent(filename) }
                let registration = try coordinator.register(owner: BrowserDownloadOwner(profileID: profileID),
                                                            transfer: transfer,
                                                            suggestedFilename: download.suggestedFilename,
                                                            sourceURL: download.sourceURL)
                transfer.attach(registration)
                key = registration.key
            } catch {
                registrationError = error
                download.cancel()
            }
        }

        func waitForFile() async -> String? {
            if let registrationError { return "a download could not be registered: \(registrationError)" }
            guard let key else { return "a download was not registered" }
            let ended = await eventually(timeout: .seconds(10)) { self.coordinator.snapshot(for: key)?.state.isTerminal == true }
            let state = coordinator.snapshot(for: key)?.state
            guard ended, state == .complete else {
                return "a download must complete (state: \(String(describing: state)))"
            }
            let file = directory.appendingPathComponent("conformance.txt")
            guard (try? String(contentsOf: file, encoding: .utf8)) == ConformanceFixtureServer.downloadBody else {
                return "a completed download must write the response body to its destination"
            }
            return nil
        }

        func finish() {
            coordinator.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Polls a condition the engine confirms asynchronously, bounded so a missing confirmation
    /// fails instead of hanging the suite.
    static func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Lets queued engine work run before asserting that something did not happen.
    static func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    static func responder(_ responder: NSResponder?, isInside view: NSView) -> Bool {
        guard let responderView = responder as? NSView else { return false }
        return responderView === view || responderView.isDescendant(of: view)
    }

    @MainActor
    final class Completion {
        var isDone = false
    }

    @MainActor
    final class FindResult {
        var update: BrowserFindUpdate?
    }
}

/// Records delegate traffic and answers policy questions synchronously unless asked to suspend.
@MainActor
final class ConformanceDelegate<Surface: BrowserEngineSurface>: BrowserEngineSurfaceDelegate {
    var events: [String] = []
    var actions: [BrowserNavigationAction] = []
    var actionURLs: [URL?] { actions.map(\.url) }
    var sameDocument: [BrowserSameDocumentNavigation] = []
    var newTargetRequests: [BrowserNewSurfaceRequest] = []
    var responseURLs: [URL?] = []
    var commitURLs: [URL] = []
    var suspensionOffers: [Bool] = []
    var actionPolicy: BrowserNavigationActionPolicy = .allow
    var suspendNextAction = false
    var suspended: BrowserPolicyDecision<BrowserNavigationActionPolicy>?
    var downloads: [any BrowserEngineDownload] = []
    /// Keep reported downloads for the harness instead of cancelling them.
    var keepsDownloads = false
    /// Adopts reported downloads synchronously, as the shell's coordinator does.
    var adoptDownload: ((any BrowserEngineDownload) -> Void)?
    /// Accept new targets and make them report to this delegate.
    var newTargetDelegate: ConformanceDelegate?
    var createdTargets: [Surface] = []

    func count(_ event: String) -> Int { events.filter { $0 == event }.count }

    func surfaceDidStartNavigation(_ surface: Surface) { events.append("start") }
    func surfaceDidCommitNavigation(_ surface: Surface) {
        events.append("commit")
        if let url = surface.navigationState.committedURL { commitURLs.append(url) }
    }
    func surfaceDidFinishNavigation(_ surface: Surface) { events.append("finish") }
    func surfaceDidFailNavigation(_ surface: Surface) { events.append("fail") }
    func surface(_ surface: Surface, didNavigateWithinDocument navigation: BrowserSameDocumentNavigation) {
        sameDocument.append(navigation)
    }

    func surface(_ surface: Surface, decidePolicyFor action: BrowserNavigationAction,
                 decision: BrowserPolicyDecision<BrowserNavigationActionPolicy>) {
        actions.append(action)
        suspensionOffers.append(decision.canSuspend)
        if suspendNextAction, decision.suspend() {
            suspendNextAction = false
            suspended = decision
            return
        }
        decision.decide(actionPolicy)
    }

    func surface(_ surface: Surface, decidePolicyFor response: BrowserNavigationResponse,
                 decision: BrowserPolicyDecision<BrowserNavigationResponsePolicy>) {
        if response.isForMainFrame { responseURLs.append(response.response.url) }
        suspensionOffers.append(decision.canSuspend)
        decision.decide(.allow)
    }

    func surface(_ surface: Surface, createSurfaceFor request: BrowserNewSurfaceRequest,
                 make: () -> Surface) -> Surface? {
        newTargetRequests.append(request)
        guard let newTargetDelegate else { return nil }
        let child = make()
        child.delegate = newTargetDelegate
        createdTargets.append(child)
        return child
    }

    func surfaceDidRequestClose(_ surface: Surface) { events.append("close-request") }

    func surface(_ surface: Surface, didStartDownload download: any BrowserEngineDownload) {
        downloads.append(download)
        if let adoptDownload { adoptDownload(download) } else if !keepsDownloads { download.cancel() }
    }
}
