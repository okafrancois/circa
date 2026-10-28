import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import BrowserEngineConformance
import BrowserShell
import ChromiumEngine
import CryptoKit
import Foundation

// Hidden ENG-X1 laboratory: measures the stock-SDK ChromiumEngine against the BrowserEngine
// contract. Synthetic loopback fixtures only; no window is ordered in or activated.

guard let arguments = LabArguments.parse() else {
    FileHandle.standardError.write(Data("orbit-chromium-lab preflight=rejected\n".utf8))
    exit(64)
}

@MainActor
final class Laboratory {
    let arguments: LabArguments
    let ledger: LabLedger
    let runtime = ChromiumRuntime.shared
    var engine: ChromiumBrowserEngine!
    var delegate: RecorderDelegate!
    lazy var windowA = makeHiddenWindow("Orbit lab A")
    lazy var windowB = makeHiddenWindow("Orbit lab B")
    var surfaces: [ChromiumSurface] = []
    var extra: [String: Any] = [:]
    /// Surfaces of an engine that is never shut down: the bridge quit must close them.
    var quitProbe: (engine: ChromiumBrowserEngine, delegate: RecorderDelegate, surfaces: [ChromiumSurface])?
    /// Quit-stall mode: CEF host views kept alive outside any window, so that their browsers can
    /// never reach OnBeforeClose.
    var stalledViews: [NSView] = []
    private(set) var abortReason: String?

    init(arguments: LabArguments) {
        self.arguments = arguments
        ledger = LabLedger(root: arguments.root)
    }

    func url(_ path: String) -> URL { URL(string: arguments.origin + path)! }

    func surface(_ profile: ProfileID, in window: NSWindow, _ path: String? = nil) -> ChromiumSurface {
        let surface = engine.makeSurface(profileID: profile, delegate: delegate)
        surface.onEngineEvent = { [ledger] name, fields in ledger.event("engine-" + name, fields) }
        place(surface, in: window.contentView!)
        surfaces.append(surface)
        if let path { surface.navigate(to: url(path)) }
        return surface
    }

    func committed(_ surface: ChromiumSurface, _ fragment: String, _ seconds: Double = 10) async -> Bool {
        await until(seconds) {
            surface.navigationState.committedURL?.absoluteString.contains(fragment) == true
                && !surface.navigationState.isLoading
        }
    }

    var visibleInputRegistration: ChromiumEngineWindow?
    var visibleInputWindow: NSWindow?
    var visibleInputAudit: VisibleInputAudit?

    var finished = false

    /// Ends the run: disposes every lab surface, shuts the main engine down (unless aborting,
    /// when scenarios may still be running), records the bridge and hidden-monitor state, writes
    /// the results, then asks the bridge to quit. The quit itself is judged by the runner (exit
    /// status 75/76 and `quit-stalled` failures).
    func finish(abortReason: String? = nil) async {
        guard !finished else { return }
        finished = true
        if arguments.visibleInputOnly { visibleInputWindow?.orderOut(nil) }
        if let abortReason {
            self.abortReason = abortReason
            ledger.record("lab.aborted", "failed", ["reason": abortReason])
        }
        for surface in surfaces where !surface.isDisposed { surface.dispose() }
        for surface in delegate?.createdSurfaces ?? [] where !surface.isDisposed { surface.dispose() }
        if abortReason == nil, let engine {
            let outcome = await engine.shutdown(timeout: .seconds(10))
            ledger.check("lifecycle.engine-shutdown", outcome.isCompleted && engine.liveNativeTokens.isEmpty, [
                "outcome": "\(outcome)", "liveNativeTokens": engine.liveNativeTokens.count])
        }
        extra["bridgeBeforeQuit"] = bridgeDiagnostics()
        extra["quitProbeLeftLive"] = quitProbe?.surfaces.filter { !$0.isDisposed }.count ?? 0
        if arguments.visibleInputOnly {
            visibleInputRegistration?.close()
            visibleInputWindow?.orderOut(nil)
            visibleInputWindow?.close()
            visibleInputAudit?.stop()
            ledger.check("visible.input.audit", visibleInputAudit?.isValid == true,
                         visibleInputAudit?.summary ?? ["reason": "audit was not started"])
            extra["auditMode"] = "visible-input"
            extra["hiddenPassed"] = false
        } else {
            let monitor = HiddenGuard.shared
            ledger.check("hidden.monitor", monitor.violations.isEmpty && monitor.blockedAttempts.isEmpty
                         && monitor.ticks > 0 && monitor.cgSamples > 0, monitor.summary)
        }
        ledger.write(to: arguments.root.appendingPathComponent("results.json"), extra: extra)
        ledger.event("lab-finished", ["aborted": abortReason ?? ""])
        runtime.requestQuit()
    }

    func run() async {
        ledger.event("lab-start")
        runtime.trace = { [ledger] name, fields in ledger.event("runtime-" + name, fields) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(240))
            guard !self.finished else { return }
            self.ledger.record("lab.watchdog", "failed", ["reason": "scenario did not finish within 240 s"])
            await self.finish(abortReason: "watchdog")
        }
        if let restored = arguments.restoreProfile {
            await restore(ProfileID(restored))
            await finish()
            return
        }
        if arguments.visibleInputOnly {
            await visibleInputScenario()
            await finish()
            return
        }
        if arguments.quitStallOnly {
            await armQuitStall()
            await finish()
            return
        }
        await conformance()
        engine = ChromiumBrowserEngine(persistence: .persistent)
        delegate = RecorderDelegate(ledger: ledger)
        let profileA = ProfileID(), profileB = ProfileID()
        extra["profileA"] = profileA.rawValue.uuidString
        extra["origin"] = arguments.origin
        _ = engine.profile(for: profileA)
        _ = engine.profile(for: profileB)
        await engine.profileReady(profileA)
        await engine.profileReady(profileB)
        if X2Options.hostedOnly { await x2Phase(profileA); hiddenAudit("final"); await finish(); return }
        let main = await hostingAndNavigation(profileA)
        await navigationPolicy(main)
        await find(profileA)
        await zoom(profileA, profileB)
        await profiles(profileA, profileB)
        await snapshot(main)
        await popups(main)
        await transfer(profileA)
        await media(main)
        await downloads(profileA)
        await preReadyOrdering(readyProfile: profileA)
        await permissions(profileA)
        await popupAbort(profileA)
        await shutdownTracking(readyProfile: profileA)
        await extensionProbes(profileA, profileB)
        await x2Phase(profileA)
        await leavePageClosedBrowserForQuit(profileA)
        hiddenAudit("final")
        await finish()
    }

    // MARK: Scenarios

    func conformance() async {
        // Fresh engine: profiles are created and used immediately, as in the harness.
        let probe = ChromiumBrowserEngine(persistence: .persistent)
        let failures = await BrowserEngineConformance.check(probe)
        ledger.check("conformance.harness", failures.isEmpty, ["failures": failures])
        let blankEngine = ChromiumBrowserEngine(persistence: .persistent)
        let readyProfile = ProfileID()
        _ = blankEngine.profile(for: readyProfile)
        await blankEngine.profileReady(readyProfile)
        let quiet = RecorderDelegate(ledger: ledger)
        let blank = blankEngine.makeSurface(profileID: readyProfile, delegate: quiet)
        let created = blank.isBrowserCreated
        blank.onEngineEvent = { [ledger] name, fields in ledger.event("blank-" + name, fields) }
        blank.performZoom(.increase)
        _ = await until(2) { blank.pageZoom > 1 }
        let zoomed = blank.pageZoom
        blank.performZoom(.reset)
        blank.dispose()
        ledger.record("conformance.zoom-on-initial-blank-document", zoomed > 1 ? "proven" : "failed",
                      ["browserCreatedSynchronously": created, "factorAfterIncrease": zoomed])
    }

    func hostingAndNavigation(_ profile: ProfileID) async -> ChromiumSurface {
        let surface = surface(profile, in: windowA, "/page?case=nav-a")
        let createdSync = surface.isBrowserCreated
        let loaded = await committed(surface, "case=nav-a")
        let browserView = surface.hostView.subviews.first
        ledger.check("hosting.alloy-in-nsview", loaded && surface.runtimeStyle == 1, [
            "createdSynchronously": createdSync, "runtimeStyle": surface.runtimeStyle == 1 ? "alloy" : "chrome",
            "browserViewClass": browserView.map { String(describing: type(of: $0)) } ?? "none",
            "browserViewParentIsHostView": browserView?.superview === surface.hostView,
            "hostViewWindowIsShellWindow": surface.hostView.window === windowA])
        let firstTitle = surface.navigationState.title
        surface.navigate(to: url("/page?case=nav-b"))
        let requestedBeforeCommit = surface.currentURL?.absoluteString.contains("nav-b") == true
        let second = await committed(surface, "case=nav-b")
        let back = surface.navigationState.canGoBack
        let backURL = surface.goBack()
        let wentBack = await committed(surface, "case=nav-a")
        let forwardAvailable = surface.navigationState.canGoForward
        let forwardURL = surface.goForward()
        let wentForward = await committed(surface, "case=nav-b")
        let generationBefore = surface.findDocumentGeneration
        surface.reload()
        let reloaded = await until(8) { surface.findDocumentGeneration > generationBefore && !surface.navigationState.isLoading }
        let favicon = await until(4) { surface.navigationState.faviconURL != nil }
        let counts = delegate.count(surface)
        ledger.check("policy.synchronous-decision-seam", delegate.asyncPolicyCalls > 0
                     && delegate.suspensionOffered.allSatisfy { !$0 } && delegate.responsePolicyCalls == 0, [
            "actionQuestions": delegate.asyncPolicyCalls, "suspensionOffered": delegate.suspensionOffered.contains(true),
            "responsePolicyQuestions": delegate.responsePolicyCalls,
            "note": "no response-policy callback exists on stock CEF; Chromium decides render vs download itself"])
        ledger.check("navigation.observation", loaded && second && wentBack && wentForward && reloaded
                     && back && forwardAvailable && firstTitle == "Synthetic nav-a"
                     && backURL?.absoluteString.contains("nav-a") == true
                     && forwardURL?.absoluteString.contains("nav-b") == true, [
            "titleA": firstTitle ?? "", "titleB": surface.navigationState.title ?? "",
            "pendingCurrentURLBeforeCommit": requestedBeforeCommit,
            "canGoBack": back, "goBackReturned": backURL?.absoluteString ?? "",
            "canGoForward": forwardAvailable, "goForwardReturned": forwardURL?.absoluteString ?? "",
            "reloadAdvancedGeneration": reloaded,
            "starts": counts.starts, "commits": counts.commits, "finishes": counts.finishes,
            "failures": counts.failures])
        ledger.check("navigation.favicon", favicon, ["faviconURL": surface.navigationState.faviconURL?.absoluteString ?? ""])
        return surface
    }

    func navigationPolicy(_ surface: ChromiumSurface) async {
        var decided: [String] = []
        delegate.actionPolicy = { action in
            let target = action.url?.absoluteString ?? ""
            decided.append(target)
            return target.contains("blocked-nav") ? .cancel : .allow
        }
        let before = surface.navigationState.committedURL
        let failuresBefore = delegate.count(surface).failures
        surface.navigate(to: url("/page?case=blocked-nav"))
        await pause(1.5)
        let blocked = surface.navigationState.committedURL == before
        ledger.check("policy.synchronous-cancel", blocked && decided.contains { $0.contains("blocked-nav") }, [
            "decisions": decided.count, "committedUnchanged": blocked,
            "failCallbacks": delegate.count(surface).failures - failuresBefore,
            "currentURLAfter": surface.currentURL?.absoluteString ?? ""])
        surface.navigate(to: url("/page?case=allowed-nav"))
        let allowed = await committed(surface, "allowed-nav")
        ledger.check("policy.synchronous-allow", allowed)
        delegate.actionPolicy = nil

        guard arguments.asyncHold else {
            ledger.record("policy.async-hold-measurement", "not-attempted", ["reason": "run without --lab-async-hold"])
            return
        }
        var holds: [String] = []
        runtime.asyncNavigationHold = { _, target in
            let value = target?.absoluteString ?? ""
            holds.append(value)
            if value.contains("hold-cancel") { return .cancel }
            if value.contains("hold-allow") { try? await Task.sleep(for: .milliseconds(600)) }
            return .allow
        }
        let started = Date()
        surface.navigate(to: url("/page?case=hold-allow"))
        let heldCommit = await committed(surface, "hold-allow")
        let latency = Date().timeIntervalSince(started)
        let committedBefore = surface.navigationState.committedURL
        let failures = delegate.count(surface).failures
        surface.navigate(to: url("/page?case=hold-cancel"))
        await pause(1.5)
        ledger.check("policy.async-hold-resource-load", heldCommit && latency >= 0.6
                     && surface.navigationState.committedURL == committedBefore, [
            "holds": holds.count, "allowLatencySeconds": latency,
            "cancelLeftCommittedUnchanged": surface.navigationState.committedURL == committedBefore,
            "cancelFailCallbacks": delegate.count(surface).failures - failures,
            "scope": "network-backed main-frame requests only (CefResourceRequestHandler, IO thread)"])
        runtime.asyncNavigationHold = nil
    }

    func find(_ profile: ProfileID) async {
        let surface = surface(profile, in: windowA, "/page?case=find")
        guard await committed(surface, "case=find") else { ledger.record("find.exact-count", "failed", ["reason": "load"]); return }
        func run(_ select: Bool, forward: Bool = true) async -> BrowserFindUpdate? {
            var last: BrowserFindUpdate?
            let request = BrowserFindRequest(token: UUID(), documentGeneration: surface.findDocumentGeneration,
                                             query: "needle", forward: forward, matchCase: false, selectMatch: select)
            surface.performFind(request) { last = $0 }
            _ = await until(5) { last?.final == true }
            return last
        }
        let count = await run(false)
        let first = await run(true)
        let second = await run(true)
        let back = await run(true, forward: false)
        surface.stopFinding(clearSelection: true)
        ledger.check("find.exact-count", count?.count == 3 && first?.activeOrdinal == 1 && second?.activeOrdinal == 2
                     && back?.activeOrdinal == 1, [
            "countOnly": ["count": count?.count ?? -1, "ordinal": count?.activeOrdinal ?? -1],
            "select1": ["count": first?.count ?? -1, "ordinal": first?.activeOrdinal ?? -1],
            "select2": ["count": second?.count ?? -1, "ordinal": second?.activeOrdinal ?? -1],
            "back": ["count": back?.count ?? -1, "ordinal": back?.activeOrdinal ?? -1]])
        surface.dispose()
    }

    func zoom(_ profileA: ProfileID, _ profileB: ProfileID) async {
        let first = surface(profileA, in: windowA, "/page?case=zoom-1")
        _ = await committed(first, "zoom-1")
        first.performZoom(.increase)
        let raised = first.pageZoom
        let sibling = surface(profileA, in: windowB, "/page?case=zoom-2")
        _ = await committed(sibling, "zoom-2")
        let other = surface(profileB, in: windowB, "/page?case=zoom-3")
        _ = await committed(other, "zoom-3")
        ledger.check("zoom.native-site-zoom", raised > 1.05 && abs(sibling.pageZoom - raised) < 0.001
                     && abs(other.pageZoom - 1) < 0.001, [
            "raised": raised, "sameProfileSameHost": sibling.pageZoom, "otherProfileSameHost": other.pageZoom])
        first.performZoom(.reset)
        ledger.check("zoom.reset", abs(first.pageZoom - 1) < 0.001, ["factor": first.pageZoom])
        [first, sibling, other].forEach { $0.dispose() }
    }

    func profiles(_ profileA: ProfileID, _ profileB: ProfileID) async {
        let tokenA = engine.profileToken(for: profileA), tokenB = engine.profileToken(for: profileB)
        var buffer = [CChar](repeating: 0, count: 4096)
        let pathA = ACRProfileCachePath(tokenA, &buffer, buffer.count) >= 0 ? String(nulTerminated: buffer) : ""
        let pathB = ACRProfileCachePath(tokenB, &buffer, buffer.count) >= 0 ? String(nulTerminated: buffer) : ""
        let a = surface(profileA, in: windowA, "/page?case=isolation-a")
        let b = surface(profileB, in: windowB, "/page?case=isolation-b")
        _ = await committed(a, "isolation-a")
        _ = await committed(b, "isolation-b")
        _ = await evaluate(a, "localStorage.setItem('orbit','A'); document.cookie='orbit=A; path=/'; 1")
        let bBefore = await evaluate(b, "JSON.stringify([localStorage.getItem('orbit'), document.cookie])") as? String
        _ = await evaluate(b, "localStorage.setItem('orbit','B'); document.cookie='orbit=B; path=/'; 1")
        let a2 = surface(profileA, in: windowB, "/page?case=isolation-a2")
        _ = await committed(a2, "isolation-a2")
        let aAfter = await evaluate(a2, "JSON.stringify([localStorage.getItem('orbit'), document.cookie])") as? String
        let ephemeralEngine = ChromiumBrowserEngine(persistence: .ephemeral)
        let profileC = ProfileID()
        _ = ephemeralEngine.profile(for: profileC)
        await ephemeralEngine.profileReady(profileC)
        let c = ephemeralEngine.makeSurface(profileID: profileC, delegate: delegate)
        place(c, in: windowB.contentView!)
        c.navigate(to: url("/page?case=isolation-c"))
        _ = await committed(c, "isolation-c")
        let cRead = await evaluate(c, "JSON.stringify([localStorage.getItem('orbit'), document.cookie])") as? String
        let tokenC = ephemeralEngine.profileToken(for: profileC)
        let pathC = ACRProfileCachePath(tokenC, &buffer, buffer.count) >= 0 ? String(nulTerminated: buffer) : "?"
        ledger.check("profiles.isolation", bBefore == #"[null,""]"# && aAfter == #"["A","orbit=A"]"#
                     && cRead == #"[null,""]"# && ACRProfilesShareStorage(tokenA, tokenB) == 0
                     && !pathA.isEmpty && pathA != pathB && pathA.hasPrefix(runtime.rootCachePath + "/profile-"), [
            "profileBFirstRead": bBefore ?? "nil", "profileASecondSurfaceRead": aAfter ?? "nil",
            "ephemeralProfileRead": cRead ?? "nil", "sharing": ACRProfilesShareStorage(tokenA, tokenB),
            "distinctPaths": pathA != pathB, "ephemeralCachePathEmpty": pathC.isEmpty,
            "pathsUnderRoot": pathA.hasPrefix(runtime.rootCachePath) && pathB.hasPrefix(runtime.rootCachePath)])
        [a, b, a2, c].forEach { $0.dispose() }
    }

    func snapshot(_ surface: ChromiumSurface) async {
        let started = Date()
        var evidence: [String: Any] = [:]
        do {
            let image = try await surface.captureSnapshot(BrowserSnapshotRequest(documentGeneration: surface.documentGeneration)).image
            evidence["seconds"] = Date().timeIntervalSince(started)
            evidence["size"] = "\(image.width)x\(image.height)"
            evidence["distinctSampledColors"] = distinctColors(image)
            let scaled = try await surface.captureSnapshot(BrowserSnapshotRequest(width: 400)).image
            do {
                _ = try await surface.captureSnapshot(BrowserSnapshotRequest(documentGeneration: surface.documentGeneration &+ 1))
                evidence["staleGenerationRejected"] = false
            } catch {
                evidence["staleGenerationRejected"] = (error as? BrowserEngineError) == .documentChanged
            }
            evidence["scaledWidth"] = scaled.width
            savePNG(image, "snapshot-hidden-window.png")
            ledger.check("snapshot.hidden-window", image.width > 0 && (evidence["distinctSampledColors"] as? Int ?? 0) > 1
                         && scaled.width == 400 && evidence["staleGenerationRejected"] as? Bool == true, evidence)
        } catch {
            evidence["error"] = "\(error)"
            evidence["seconds"] = Date().timeIntervalSince(started)
            ledger.record("snapshot.hidden-window", "failed", evidence)
        }
    }

    func distinctColors(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var colors = Set<UInt32>()
        let step = max(1, image.height / 40)
        for y in stride(from: 0, to: image.height, by: step) {
            for x in stride(from: 0, to: image.width, by: max(1, image.width / 40)) {
                let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
                colors.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            }
        }
        return colors.count
    }

    func savePNG(_ image: CGImage, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: arguments.root.appendingPathComponent(name))
    }

    func popups(_ source: ChromiumSurface) async {
        delegate.onNewSurface = { [windowB] created in place(created, in: windowB.contentView!) }
        let before = delegate.createdSurfaces.count
        _ = await evaluate(source, "window.__child = window.open('/page?case=popup-child'); 1", gesture: true)
        let popupCreated = await until(6) { self.delegate.createdSurfaces.count > before }
        guard popupCreated, let child = delegate.createdSurfaces.last else {
            ledger.record("popups.window-open", "failed", ["requests": delegate.newSurfaceRequests.count])
            return
        }
        let loaded = await committed(child, "popup-child")
        let opener = await evaluate(child, "window.opener ? window.opener.location.search : null") as? String
        let profileKept = child.profileID == source.profileID
        ledger.check("popups.window-open", loaded && (opener?.hasPrefix("?case=") ?? false) && profileKept, [
            "openerSearch": opener ?? "nil", "sameProfile": profileKept,
            "runtimeStyle": child.runtimeStyle == 1 ? "alloy" : "chrome",
            "childHostWindowIsShellWindow": child.hostView.window === windowB])
        _ = await evaluate(source, "window.__child.close(); 1", gesture: true)
        let closeRequested = await until(4) { self.delegate.closeRequests.contains(ObjectIdentifier(child)) }
        ledger.check("popups.window-close-request", closeRequested && !child.isDisposed, [
            "closeRequestDelivered": closeRequested, "surfaceStillLiveUntilShellDisposes": !child.isDisposed])
        child.dispose()
        let closedNatively = await until(4) { !child.isBrowserCreated }
        ledger.check("lifecycle.dispose-closes-browser", closedNatively)

        // Modified link activation (Cmd-click analogue) and target=_blank.
        let requests = delegate.newSurfaceRequests.count
        _ = await evaluate(source, """
            (() => { const a = document.getElementById('plain');
              a.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, metaKey: true})); return 1; })()
            """, gesture: true)
        _ = await until(4) { self.delegate.newSurfaceRequests.count > requests }
        let modified = delegate.newSurfaceRequests.dropFirst(requests).first
        _ = await evaluate(source, "document.getElementById('blank').click(); 1", gesture: true)
        _ = await until(4) { self.delegate.newSurfaceRequests.count > requests + 1 }
        let blank = delegate.newSurfaceRequests.count > requests + 1 ? delegate.newSurfaceRequests.last : nil
        let blankChild = delegate.createdSurfaces.last
        var blankOpener: Any? = nil
        if let blankChild, blankChild !== child {
            _ = await committed(blankChild, "blank-child")
            blankOpener = await evaluate(blankChild, "window.opener === null ? 'null' : 'present'")
        }
        ledger.record("popups.modified-click", modified?.modifiers.contains(.command) == true ? "proven" : "failed", [
            "modifiers": modified.map { Int($0.modifiers.rawValue) } ?? -1,
            "note": "routed through OnOpenURLFromTab: new browser, fresh request, no opener"])
        ledger.record("popups.target-blank", blank != nil ? "proven" : "failed", [
            "modifiers": blank.map { Int($0.modifiers.rawValue) } ?? -1, "opener": blankOpener as? String ?? "nil"])
    }

    func transfer(_ profile: ProfileID) async {
        let surface = surface(profile, in: windowA, "/page?case=transfer")
        guard await committed(surface, "case=transfer") else { ledger.record("transfer.between-windows", "failed"); return }
        _ = await evaluate(surface, "window.__orbitMarker = 'live-' + performance.timeOrigin; document.getElementById('field').value = 'typed'; 1")
        let marker = await evaluate(surface, "window.__orbitMarker") as? String
        let generation = surface.findDocumentGeneration
        let commits = delegate.count(surface).commits
        let browserID = surface.browserID

        place(surface, in: windowB.contentView!)
        surface.hostDidChange(hidden: false)
        await pause(0.5)
        let markerB = await evaluate(surface, "window.__orbitMarker") as? String
        let fieldB = await evaluate(surface, "document.getElementById('field').value") as? String
        let browserViewWindowB = surface.hostView.subviews.first?.window === windowB
        let snapshotB = (try? await surface.captureSnapshot(BrowserSnapshotRequest())) != nil

        // Peek-like detached container, then a Little Orbit-like window.
        let floating = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        place(surface, in: floating)
        surface.hostDidChange(hidden: true)
        await pause(0.3)
        let markerDetached = await evaluate(surface, "window.__orbitMarker") as? String
        let windowC = makeHiddenWindow("Orbit lab little")
        place(surface, in: windowC.contentView!)
        surface.hostDidChange(hidden: false)
        await pause(0.5)
        let markerC = await evaluate(surface, "window.__orbitMarker") as? String
        if let snapshot = try? await surface.captureSnapshot(BrowserSnapshotRequest()) { savePNG(snapshot.image, "snapshot-after-transfer.png") }
        // Owner change: the receiving container becomes the delegate (Peek promotion, Little Orbit).
        let newOwner = RecorderDelegate(ledger: ledger)
        surface.delegate = newOwner
        surface.navigate(to: url("/page?case=transfer-after"))
        let navigatesAfter = await committed(surface, "transfer-after")
        let newOwnerCommits = newOwner.count(surface).commits
        let oldOwnerCommitsAfterSwap = delegate.count(surface).commits - commits
        let live = marker != nil && markerB == marker && markerDetached == marker && markerC == marker
        let noReload = generation == surface.findDocumentGeneration - 1 && oldOwnerCommitsAfterSwap == 0
        ledger.check("transfer.between-windows", live && noReload && fieldB == "typed" && browserViewWindowB
                     && browserID == surface.browserID && navigatesAfter && newOwnerCommits == 1, [
            "documentStatePreserved": live, "formStatePreserved": fieldB == "typed",
            "noNewDocumentDuringMoves": noReload, "sameBrowserID": browserID == surface.browserID,
            "browserViewFollowedHostView": browserViewWindowB, "snapshotAfterMove": snapshotB,
            "navigatesAfterMoves": navigatesAfter, "newOwnerReceivedCommit": newOwnerCommits == 1,
            "oldOwnerEventsAfterSwap": oldOwnerCommitsAfterSwap,
            "method": "NSView reparent of the shell container + NotifyMoveOrResizeStarted/WasResized/WasHidden"])
        surface.dispose()
        windowC.close()
    }

    func media(_ surface: ChromiumSurface) async {
        do {
            try surface.setAudioMuted(true)
            let muted = await surface.requestMediaState()
            try surface.setAudioMuted(false)
            let unmuted = await surface.requestMediaState()
            ledger.check("media.audio-muting", muted.isAudioMuted == true && unmuted.isAudioMuted == false, [
                "mutedReadback": muted.isAudioMuted.map { "\($0)" } ?? "nil",
                "audible": "nil: no public audibility API in CEF 156 include/"])
        } catch {
            ledger.record("media.audio-muting", "failed", ["error": "\(error)"])
        }
        ledger.record("media.audible-state", "failed", ["reason": "no audible/IsAudible symbol in the CEF 156 include/ tree"])
        ledger.record("media.playback-state", "failed", ["reason": "no media session/playback query in the public CEF API"])
    }

    func downloads(_ profile: ProfileID) async {
        let coordinator = BrowserDownloadCoordinator()
        let directory = arguments.root.appendingPathComponent("downloads")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var registrations: [String: BrowserDownloadRegistration] = [:]
        var transfers: [String: any BrowserEngineDownloadTransfer] = [:]
        var currentCase = ""
        delegate.onDownload = { surface, download in
            let name = currentCase
            let transfer = download.makeTransfer { suggested in
                let folder = directory.appendingPathComponent(UUID().uuidString)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                         attributes: [.posixPermissions: 0o700])
                return folder.appendingPathComponent(suggested)
            }
            guard let registration = try? coordinator.register(
                owner: BrowserDownloadOwner(profileID: surface.profileID), transfer: transfer,
                suggestedFilename: download.suggestedFilename, sourceURL: download.sourceURL) else {
                download.cancel(); return
            }
            transfer.attach(registration)
            registrations[name] = registration
            transfers[name] = transfer
        }
        func state(_ name: String) -> BrowserDownloadSnapshot? {
            registrations[name].flatMap { coordinator.snapshot(for: $0.key) }
        }
        func begin(_ name: String, on surface: ChromiumSurface) async -> Bool {
            currentCase = name
            surface.navigate(to: url("/download?case=\(name)"))
            return await until(6) { registrations[name] != nil }
        }
        func act(_ name: String, _ action: BrowserDownloadAction) async -> Bool {
            var outcome: Result<Void, BrowserDownloadError>?
            transfers[name]?.perform(action) { outcome = $0 }
            _ = await until(2) { outcome != nil }
            if case .success = outcome { return true }
            return false
        }
        let source = surface(profile, in: windowA, "/page?case=downloads")
        _ = await committed(source, "case=downloads")

        let normal = await begin("normal", on: source)
        _ = await until(20) { state("normal")?.state.isTerminal == true }
        let normalSnapshot = state("normal")
        let normalExpected = await expectedDownloadSHA256("normal")
        let normalActual = sha256(of: normalSnapshot?.destinationURL)
        ledger.check("downloads.complete", normal && normalSnapshot?.state == .complete
                     && normalSnapshot?.fileAvailability == .available
                     && normalExpected != nil && normalActual == normalExpected, [
            "state": normalSnapshot?.state.rawValue ?? "none", "received": normalSnapshot?.receivedBytes ?? -1,
            "availability": normalSnapshot?.fileAvailability.rawValue ?? "none",
            "sha256Matches": normalExpected != nil && normalActual == normalExpected,
            "sha256": normalActual ?? "none", "expectedSHA256": normalExpected ?? "none"])

        let slow = await begin("slow", on: source)
        _ = await until(5) { (state("slow")?.receivedBytes ?? 0) > 0 && state("slow")?.state == .running }
        let paused = await act("slow", .pause)
        let pausedSeen = await until(4) { state("slow")?.state == .paused }
        let atPause = state("slow")?.receivedBytes ?? 0
        await pause(0.8)
        let stable = (state("slow")?.receivedBytes ?? 0) == atPause
        let resumed = await act("slow", .resume)
        _ = await until(40) { state("slow")?.state.isTerminal == true }
        let slowExpected = await expectedDownloadSHA256("slow")
        let slowActual = sha256(of: state("slow")?.destinationURL)
        ledger.check("downloads.pause-resume", slow && paused && pausedSeen && atPause > 0 && stable && resumed
                     && state("slow")?.state == .complete && slowExpected != nil && slowActual == slowExpected, [
            "pauseAccepted": paused, "pausedObserved": pausedSeen, "bytesAtPause": atPause,
            "bytesStableWhilePaused": stable, "resumeAccepted": resumed,
            "final": state("slow")?.state.rawValue ?? "none", "received": state("slow")?.receivedBytes ?? -1,
            "sha256Matches": slowExpected != nil && slowActual == slowExpected,
            "sha256": slowActual ?? "none", "expectedSHA256": slowExpected ?? "none"])

        let cancelStarted = await begin("slow-cancel", on: source)
        _ = await until(5) { (state("slow-cancel")?.receivedBytes ?? 0) > 0 }
        let cancelAccepted = await act("slow-cancel", .cancel)
        _ = await until(5) { state("slow-cancel")?.state.isTerminal == true }
        ledger.check("downloads.cancel", cancelStarted && cancelAccepted && state("slow-cancel")?.state == .cancelled, [
            "final": state("slow-cancel")?.state.rawValue ?? "none"])

        let closeSource = surface(profile, in: windowB, "/page?case=downloads-close")
        _ = await committed(closeSource, "downloads-close")
        let closeStarted = await begin("slow-source-close", on: closeSource)
        _ = await until(5) { (state("slow-source-close")?.receivedBytes ?? 0) > 0 }
        closeSource.dispose()
        _ = await until(10) { state("slow-source-close")?.state.isTerminal == true }
        await pause(0.5)
        await pause(2)
        let leftover = state("slow-source-close")?.destinationURL.map { url -> String in
            let folder = url.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.isEmpty ? "folder empty (partial deleted)" : names.map { name in
                let size = BrowserDownloadPaths.regularFileSize(folder.appendingPathComponent(name)) ?? -1
                return "\(name.hasSuffix(".crdownload") ? "*.crdownload" : "destination"):\(size)"
            }.joined(separator: ",")
        } ?? "no destination"
        ledger.check("downloads.survive-source-close", closeStarted && state("slow-source-close")?.state == .complete, [
            "destinationFolder": leftover,
            "failure": state("slow-source-close")?.failure?.rawValue ?? "none",
            "final": state("slow-source-close")?.state.rawValue ?? "none",
            "received": state("slow-source-close")?.receivedBytes ?? -1,
            "registry": "X2-DL-SURVIVE-CLOSE"])

        var policyDecided = false
        delegate.actionPolicy = { action in
            guard action.url?.absoluteString.contains("case=policy") == true else { return .allow }
            policyDecided = true
            return .download
        }
        currentCase = "policy"
        source.navigate(to: url("/page?case=policy"))
        let policyDownload = await until(6) { registrations["policy"] != nil }
        delegate.actionPolicy = nil
        // CONTRACT-R2: without navigationDownloadConversion a .download answer behaves as .allow;
        // the adapter no longer replays the URL with StartDownload.
        ledger.record("downloads.policy-download", policyDownload ? "failed" : "proven", [
            "policyDecided": policyDecided, "downloadOffered": policyDownload,
            "note": "no conversion on stock CEF: .download behaves as .allow, no StartDownload replay"])
        coordinator.shutdown()
        source.dispose()
    }

    func extensionProbes(_ profileA: ProfileID, _ profileB: ProfileID) async {
        guard arguments.extensionLoaded else {
            ledger.record("extensions.mv3-probes", "not-attempted", ["reason": "run without --load-extension"])
            return
        }
        let reports = arguments.root.appendingPathComponent("reports")
        let probe = surface(profileA, in: windowA, "/page?case=alloy-host-a")
        let reportA = reports.appendingPathComponent("alloy-host-a.json")
        let arrived = await until(25) { FileManager.default.fileExists(atPath: reportA.path) }
        var evidence: [String: Any] = ["profile": "persistent custom context A", "reportArrived": arrived,
                                       "runtimeStyle": probe.runtimeStyle == 1 ? "alloy" : "chrome"]
        if arrived, let data = try? Data(contentsOf: reportA),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = report["results"] as? [[String: Any]] {
            let failed = results.filter { ($0["passed"] as? Bool) != true }
            evidence["passed"] = results.count - failed.count
            evidence["total"] = results.count
            evidence["failedProbes"] = failed.map { "\($0["name"] ?? "?"): \($0["detail"] ?? "")" }
            ledger.record("extensions.mv3-probes", failed.isEmpty ? "proven" : "partial", evidence)
        } else {
            ledger.record("extensions.mv3-probes", "failed", evidence)
        }
        let managementFailures = delegate.count(probe).failures
        probe.navigate(to: URL(string: "chrome://extensions/")!)
        await pause(2)
        ledger.record("extensions.management-webui", probe.navigationState.committedURL?.scheme == "chrome" ? "proven" : "failed", [
            "committed": probe.navigationState.committedURL?.absoluteString ?? "nil",
            "failCallbacks": delegate.count(probe).failures - managementFailures])
        probe.dispose()
        hiddenAudit("after-management-probe")
        let defaultProfile = ProfileID()
        _ = engine.laboratoryProfileUsingGlobalContext(defaultProfile)
        let defaultToken = engine.profileToken(for: defaultProfile)
        var defaultReady = false
        Task { @MainActor in await self.engine.profileReady(defaultProfile); defaultReady = true }
        _ = await until(5) { defaultReady }
        ledger.event("global-context-profile", ["ready": String(defaultReady),
                                               "sharesWithA": String(ACRProfilesShareStorage(defaultToken, engine.profileToken(for: profileA)))])
        hiddenAudit("before-global-probe")
        let defaultProbe = surface(defaultProfile, in: windowB, "/page?case=alloy-host-default")
        let reportDefault = reports.appendingPathComponent("alloy-host-default.json")
        let defaultArrived = await until(25) { FileManager.default.fileExists(atPath: reportDefault.path) }
        var defaultEvidence: [String: Any] = ["profile": "CefRequestContext::GetGlobalContext()",
                                              "reportArrived": defaultArrived,
                                              "runtimeStyle": defaultProbe.runtimeStyle == 1 ? "alloy" : "chrome"]
        if defaultArrived, let data = try? Data(contentsOf: reportDefault),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = report["results"] as? [[String: Any]] {
            let failed = results.filter { ($0["passed"] as? Bool) != true }
            defaultEvidence["passed"] = results.count - failed.count
            defaultEvidence["total"] = results.count
            defaultEvidence["failedProbes"] = failed.map { "\($0["name"] ?? "?"): \($0["detail"] ?? "")" }
            ledger.record("extensions.mv3-probes-global-context", failed.isEmpty ? "proven" : "partial", defaultEvidence)
        } else {
            ledger.record("extensions.mv3-probes-global-context", "failed", defaultEvidence)
        }
        defaultProbe.dispose()
        hiddenAudit("after-global-probe")
    }

    func restore(_ profile: ProfileID) async {
        engine = ChromiumBrowserEngine(persistence: .persistent)
        delegate = RecorderDelegate(ledger: ledger)
        _ = engine.profile(for: profile)
        await engine.profileReady(profile)
        let surface = surface(profile, in: windowA, "/page?case=restore")
        let loaded = await committed(surface, "case=restore")
        let read = await evaluate(surface, "JSON.stringify([localStorage.getItem('orbit'), document.cookie])") as? String
        _ = await committed(surface, "case=restore")
        surface.performZoom(.reset)
        ledger.check("profiles.persistence-after-relaunch", loaded && read == #"["A","orbit=A"]"#, [
            "read": read ?? "nil", "note": "session cookie kept: persist_session_cookies=1 for persistent profiles"])
        hiddenAudit("restore")
        surface.dispose()
    }

    func hiddenAudit(_ phase: String) {
        let visibleWindows = NSApp.windows.filter(\.isVisible)
        let visible = visibleWindows.count
        let flags: [String: Any] = ["visibleWindows": visible,
                                    "visibleWindowClasses": visibleWindows.map { String(describing: type(of: $0)) }, "appActive": NSApp.isActive,
                                    "keyWindow": NSApp.keyWindow != nil, "mainWindow": NSApp.mainWindow != nil,
                                    "activationPolicy": NSApp.activationPolicy().rawValue]
        let monitor = HiddenGuard.shared
        var evidence = flags
        evidence["monitorViolations"] = monitor.violations.count
        evidence["blockedAttempts"] = monitor.blockedAttempts.count
        ledger.check("hidden.audit-" + phase, visible == 0 && !NSApp.isActive && NSApp.keyWindow == nil
                     && monitor.violations.isEmpty, evidence)
    }

    // MARK: R2 scenarios

    func sha256(of url: URL?) -> String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The fixture's own digest of a synthetic download (independent of the engine).
    func expectedDownloadSHA256(_ name: String) async -> String? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: url("/download-sha256?case=\(name)")),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Commands before `OnAfterCreated` (finding 6): fresh disk profiles are still initializing,
    /// so CreateBrowserSync refuses them and the browser is created asynchronously.
    func preReadyOrdering(readyProfile: ProfileID) async {
        // One fresh disk profile for every pending surface (each profile adds CefShutdown work).
        let freshProfile = ProfileID()
        _ = engine.profile(for: freshProfile)
        func pendingSurface() -> (surface: ChromiumSurface, commits: () -> [String]) {
            let surface = surface(freshProfile, in: windowA)
            var commits: [String] = []
            surface.onEngineEvent = { [ledger] name, fields in
                ledger.event("ready-" + name, fields)
                if name == "commit" { commits.append(fields["url"] ?? "") }
            }
            return (surface, { commits })
        }
        let sequence = "navigate(A); navigate(B); reload(); navigate(C); stopLoading(); navigate(D)"
        func play(_ surface: ChromiumSurface, _ tag: String) {
            surface.navigate(to: url("/page?case=eq-\(tag)-a"))
            surface.navigate(to: url("/page?case=eq-\(tag)-b"))
            surface.reload()
            surface.navigate(to: url("/page?case=eq-\(tag)-c"))
            surface.stopLoading()
            surface.navigate(to: url("/page?case=eq-\(tag)-d"))
        }
        func letters(_ commits: [String], _ tag: String) -> [String] {
            commits.compactMap { $0.components(separatedBy: "case=eq-\(tag)-").last.flatMap { $0.count == 1 ? $0 : nil } }
        }

        // Every command is issued in this turn, while the four browsers are still being created.
        let stop = pendingSurface(), zoom = pendingSurface(), order = pendingSurface(), queued = pendingSurface()
        let pendingAtCommands = [stop, zoom, order, queued].map { !$0.surface.isReady }
        stop.surface.navigate(to: url("/page?case=preready-stopped"))
        stop.surface.stopLoading()
        zoom.surface.navigate(to: url("/page?case=preready-zoom"))
        zoom.surface.performZoom(.increase)
        order.surface.navigate(to: url("/page?case=preready-first"))
        order.surface.navigate(to: url("/page?case=preready-second"))
        try? order.surface.setAudioMuted(true)
        play(queued.surface, "queued")
        let mutedBeforeReady = await order.surface.requestMediaState().isAudioMuted

        let stopReady = await until(10) { stop.surface.isReady }
        await pause(2)
        let stoppedCommitted = stop.commits().contains { $0.contains("preready-stopped") }
        ledger.check("ready.queue-navigate-then-stop", pendingAtCommands[0] && stopReady && !stoppedCommitted, [
            "pendingAtCommands": pendingAtCommands[0], "becameReady": stopReady, "stoppedDocumentCommitted": stoppedCommitted,
            "commits": stop.commits().count, "before": "R1 kept only the last navigation and ignored stopLoading()"])

        let zoomCommitted = await committed(zoom.surface, "preready-zoom")
        _ = await until(3) { zoom.surface.pageZoom > 1.05 }
        let factor = zoom.surface.pageZoom
        ledger.check("ready.queue-navigate-then-zoom", pendingAtCommands[1] && zoomCommitted && factor > 1.05, [
            "pendingAtCommands": pendingAtCommands[1], "committed": zoomCommitted, "factorAfterCommit": factor,
            "before": "R1 replayed zooms before the navigation, on the blank document"])
        zoom.surface.performZoom(.reset)

        let second = await committed(order.surface, "preready-second")
        await pause(1)
        let muted = await order.surface.requestMediaState().isAudioMuted
        let firstCommitted = order.commits().contains { $0.contains("preready-first") }
        ledger.check("ready.queue-order", pendingAtCommands[2] && second && !firstCommitted && muted == true
                     && mutedBeforeReady == true, [
            "pendingAtCommands": pendingAtCommands[2], "lastNavigationCommitted": second,
            "supersededNavigationCommitted": firstCommitted, "commits": order.commits(),
            "mutedBeforeReady": mutedBeforeReady.map { "\($0)" } ?? "nil", "mutedAfterReplay": muted.map { "\($0)" } ?? "nil"])

        // Equivalence: the queued sequence behaves as the same calls on a ready browser.
        _ = await committed(queued.surface, "eq-queued-d")
        let ready = surface(readyProfile, in: windowA)
        var readyCommits: [String] = []
        ready.onEngineEvent = { [ledger] name, fields in
            ledger.event("eq-ready-" + name, fields)
            if name == "commit" { readyCommits.append(fields["url"] ?? "") }
        }
        let readyWasReady = ready.isReady
        play(ready, "ready")
        _ = await committed(ready, "eq-ready-d")
        await pause(1)
        let readyLetters = letters(readyCommits, "ready"), queuedLetters = letters(queued.commits(), "queued")
        ledger.check("ready.queue-equivalent-to-ready-calls", readyWasReady && pendingAtCommands[3]
                     && !readyLetters.isEmpty && readyLetters == queuedLetters, [
            "sequence": sequence, "readyCommits": readyLetters, "queuedCommits": queuedLetters,
            "readySurfaceWasReady": readyWasReady, "queuedSurfaceWasPending": pendingAtCommands[3]])
        [stop.surface, zoom.surface, order.surface, ready, queued.surface].forEach { $0.dispose() }
    }

    /// Permission requests (finding 3), with synthetic capture devices only.
    func permissions(_ profile: ProfileID) async {
        guard arguments.fakeMediaDevices else {
            ledger.record("permissions.media-grant-deny", "not-attempted", ["reason": "run without fake media devices"])
            return
        }
        let page = surface(profile, in: windowA, "/page?case=permission")
        guard await committed(page, "case=permission") else {
            ledger.record("permissions.media-grant-deny", "failed", ["reason": "load"])
            return
        }
        let request = "navigator.mediaDevices.getUserMedia({video: true}).then(m => { window.__stream = m; "
            + "return 'granted:' + m.getVideoTracks().length; }).catch(e => 'error:' + e.name)"
        delegate.permissionHandler = { _, _ in try? await Task.sleep(for: .milliseconds(200)); return .grant }
        let requestsBefore = delegate.permissionRequests.count
        let granted = await evaluate(page, request, gesture: true) as? String
        await pause(0.3)  // OnMediaAccessChange follows the grant.
        let media = await page.requestMediaState()
        _ = await evaluate(page, "window.__stream && window.__stream.getTracks().forEach(t => t.stop()); 1")
        delegate.permissionHandler = { _, _ in .deny }
        let denied = await evaluate(page, request, gesture: true) as? String
        let kinds = delegate.permissionRequests.dropFirst(requestsBefore).map { "\($0.kind)" }
        ledger.check("permissions.media-grant-deny", granted == "granted:1" && denied?.hasPrefix("error:") == true, [
            "granted": granted ?? "nil", "denied": denied ?? "nil", "kinds": kinds,
            "cameraStateWhileGranted": "\(media.camera)", "devices": "--use-fake-device-for-media-stream (synthetic)"])

        // Dispose while the delegate holds the request, with every Swift reference released.
        var arrived = false, answered = false
        delegate.permissionHandler = { _, _ in
            arrived = true
            try? await Task.sleep(for: .milliseconds(1200))
            answered = true
            return .grant
        }
        var held: ChromiumSurface? = surface(profile, in: windowA, "/page?case=permission-held")
        _ = await committed(held!, "permission-held")
        weak let weakHeld = held
        _ = await evaluate(held!, "navigator.mediaDevices.getUserMedia({video: true}).then(() => 0, () => 0); 1", gesture: true)
        let requested = await until(4) { arrived }
        surfaces.removeAll { $0 === held }
        held!.dispose()
        held = nil
        let afterDispose = bridgeDiagnostics()["permissions"] ?? -1
        _ = await until(4) { answered }
        await pause(0.3)
        let releasedAfterAnswer = weakHeld == nil
        ledger.check("permissions.dispose-while-delegate-holds-request", requested && answered && afterDispose == 0
                     && bridgeDiagnostics()["permissions"] == 0 && releasedAfterAnswer, [
            "delegateReceived": requested, "delegateAnsweredAfterDispose": answered,
            "bridgePendingAfterDispose": afterDispose, "surfaceReleasedAfterAnswer": releasedAfterAnswer,
            "before": "R1 captured the surface weakly and force-unwrapped it; dispose() left the request pending"])

        // Dispose synchronously when the request reaches the adapter, before the delegate runs.
        var delegateCalls = 0
        delegate.permissionHandler = { _, _ in delegateCalls += 1; return .grant }
        var early: ChromiumSurface? = surface(profile, in: windowA, "/page?case=permission-early")
        _ = await committed(early!, "permission-early")
        surfaces.removeAll { $0 === early }
        var disposedOnArrival = false
        early!.onEngineEvent = { [ledger, weak early] name, fields in
            ledger.event("permission-early-" + name, fields)
            if name == "permission-request", let early { disposedOnArrival = true; early.dispose() }
        }
        weak let weakEarly = early
        _ = await evaluate(early!, "navigator.mediaDevices.getUserMedia({video: true}).then(() => 0, () => 0); 1", gesture: true)
        _ = await until(4) { disposedOnArrival }
        early = nil
        await pause(0.5)
        ledger.check("permissions.dispose-on-arrival", disposedOnArrival && delegateCalls == 0
                     && bridgeDiagnostics()["permissions"] == 0, [
            "disposedOnArrival": disposedOnArrival, "delegateCallsAfterDispose": delegateCalls,
            "bridgePending": bridgeDiagnostics()["permissions"] ?? -1, "surfaceReleased": weakEarly == nil])
        delegate.permissionHandler = nil
        page.dispose()
    }

    /// Popup creation abandoned mid-way (finding 4): the opener closes during creation, or the
    /// shell refuses the target. No pending creation may remain, and no native token stays live.
    func popupAbort(_ profile: ProfileID) async {
        var evidence: [String: Any] = [:]
        var allClean = true
        for variant in ["opener-disposed-inside-OnBeforePopup", "opener-disposed-next-turn", "no-user-gesture",
                        "target-refused"] {
            let opener = surface(profile, in: windowA, "/page?case=popup-opener")
            guard await committed(opener, "popup-opener") else { allClean = false; continue }
            let liveBefore = engine.liveNativeTokens.count
            var child: ChromiumSurface?
            var childEvents: [String] = []
            delegate.acceptNewSurfaces = variant != "target-refused"
            delegate.onNewSurface = { [ledger, windowB] created in
                place(created, in: windowB.contentView!)
                child = created
                created.onEngineEvent = { name, fields in
                    ledger.event("popup-abort-" + name, fields)
                    childEvents.append(name)
                }
                if variant == "opener-disposed-inside-OnBeforePopup" { opener.dispose() }
                else if variant == "opener-disposed-next-turn" {
                    DispatchQueue.main.async { MainActor.assumeIsolated { opener.dispose() } }
                }
            }
            let requests = delegate.newSurfaceRequests.count
            // Without a gesture, Chrome's popup blocker may refuse after OnBeforePopup allowed it.
            _ = await evaluate(opener, "window.open('/page?case=popup-abort-child'); 1", gesture: variant != "no-user-gesture")
            let offered = await until(4) { self.delegate.newSurfaceRequests.count > requests }
            await pause(1.5)
            if !opener.isDisposed { opener.dispose() }
            _ = await until(8) {
                opener.isDisposed && !opener.isBrowserCreated
                    && (child.map { $0.isDisposed || $0.isBrowserCreated } ?? true)
            }
            // A popup may legitimately survive its opener: the shell then disposes it.
            let survived = child.map { !$0.isDisposed && $0.isBrowserCreated } ?? false
            if let child, survived { child.dispose() }
            _ = await until(8) { child.map { !$0.isBrowserCreated && !$0.isCreationPending } ?? true }
            await pause(0.5)
            let diagnostics = bridgeDiagnostics()
            let liveAfter = engine.liveNativeTokens.count
            let path = childEvents.contains("create-aborted") ? "create-aborted"
                : survived ? "created-survived-opener" : childEvents.contains("closed") ? "created-then-closed"
                : child == nil ? (offered ? "target-refused-by-shell" : "not-offered-to-shell") : "unresolved"
            let clean = diagnostics["pendingCreations"] == 0 && diagnostics["pendingPopups"] == 0
                && liveAfter == liveBefore - 1 && path != "unresolved"
                && (child.map { $0.isDisposed && !$0.isBrowserCreated } ?? true)
            allClean = allClean && clean
            evidence[variant] = ["path": path, "childEvents": childEvents, "bridge": diagnostics,
                                 "liveNativeTokensBefore": liveBefore, "liveNativeTokensAfter": liveAfter, "clean": clean]
            surfaces.removeAll { $0 === opener }
        }
        delegate.acceptNewSurfaces = true
        delegate.onNewSurface = nil
        evidence["abortedCreationsTotal"] = bridgeDiagnostics()["abortedCreations"] ?? -1
        ledger.check("popups.abort-cleanup", allClean, evidence)
    }

    /// `shutdown()` follows native closes, not Swift references (finding 2).
    func shutdownTracking(readyProfile: ProfileID) async {
        let tracked = ChromiumBrowserEngine(persistence: .persistent)
        let quiet = RecorderDelegate(ledger: ledger)
        let profile = ProfileID()
        _ = tracked.profile(for: profile)  // Still initializing: creation is asynchronous.
        var surface: ChromiumSurface? = tracked.makeSurface(profileID: profile, delegate: quiet)
        weak let weakSurface = surface
        place(surface!, in: windowB.contentView!)
        surface!.navigate(to: url("/page?case=shutdown-tracking"))
        let pendingAtDispose = surface!.isCreationPending
        surface!.dispose()
        surface = nil
        let released = weakSurface == nil
        let liveAfterRelease = tracked.liveNativeTokens.count
        var failures: [ChromiumShutdownOutcome] = []
        tracked.onShutdownFailure = { failures.append($0) }
        let early = await tracked.shutdown(timeout: .zero)
        let late = await tracked.shutdown(timeout: .seconds(10))
        ledger.check("lifecycle.shutdown-tracks-native-closes", released && liveAfterRelease == 1 && !early.isCompleted
                     && failures.count == 1 && late.isCompleted && tracked.isShutDown && tracked.liveNativeTokens.isEmpty, [
            "creationPendingAtDispose": pendingAtDispose, "swiftSurfaceReleased": released,
            "liveNativeTokensAfterRelease": liveAfterRelease, "zeroTimeoutOutcome": "\(early)",
            "failureCallbacks": failures.count, "finalOutcome": "\(late)", "engineUnusable": tracked.isShutDown,
            "before": "R1 tracked weak Swift references: a released surface vanished before its CEF close"])

        // Ready browser: dispose, release, shut down.
        // Same profile as the main engine: the identical path shares its CEF browser context.
        let readyEngine = ChromiumBrowserEngine(persistence: .persistent)
        _ = readyEngine.profile(for: readyProfile)
        await readyEngine.profileReady(readyProfile)
        var live: ChromiumSurface? = readyEngine.makeSurface(profileID: readyProfile, delegate: quiet)
        place(live!, in: windowB.contentView!)
        live!.navigate(to: url("/page?case=shutdown-ready"))
        _ = await committed(live!, "shutdown-ready")
        live!.dispose()
        live = nil
        let liveAfterDispose = readyEngine.liveNativeTokens.count
        let outcome = await readyEngine.shutdown(timeout: .seconds(10))
        ledger.check("lifecycle.shutdown-after-release", outcome.isCompleted && readyEngine.liveNativeTokens.isEmpty, [
            "liveNativeTokensRightAfterDispose": liveAfterDispose, "outcome": "\(outcome)"])
    }

    /// Finding 1: a page-closed browser the shell never disposed, in an engine that is never shut
    /// down. ACRRequestQuit must destroy its view; the runner judges the quit (exit 0, no stall).
    func leavePageClosedBrowserForQuit(_ profile: ProfileID) async {
        let quitEngine = ChromiumBrowserEngine(persistence: .persistent)
        let probeDelegate = RecorderDelegate(ledger: ledger)
        probeDelegate.onNewSurface = { [windowB] created in place(created, in: windowB.contentView!) }
        _ = quitEngine.profile(for: profile)
        await quitEngine.profileReady(profile)
        let opener = quitEngine.makeSurface(profileID: profile, delegate: probeDelegate)
        opener.onEngineEvent = { [ledger] name, fields in ledger.event("quit-probe-" + name, fields) }
        place(opener, in: windowA.contentView!)
        opener.navigate(to: url("/page?case=quit-opener"))
        _ = await committed(opener, "quit-opener")
        _ = await evaluate(opener, "window.__child = window.open('/page?case=quit-child'); 1", gesture: true)
        _ = await until(6) { !probeDelegate.createdSurfaces.isEmpty }
        let child = probeDelegate.createdSurfaces.first
        if let child { _ = await committed(child, "quit-child") }
        _ = await evaluate(opener, "window.__child.close(); 1", gesture: true)
        let closeRequested = await until(4) { child.map { probeDelegate.closeRequests.contains(ObjectIdentifier($0)) } ?? false }
        quitProbe = (quitEngine, probeDelegate, [opener] + (child.map { [$0] } ?? []))
        ledger.check("lifecycle.page-closed-browser-left-for-quit", closeRequested && child?.isDisposed == false, [
            "closeRequestDelivered": closeRequested, "bridge": bridgeDiagnostics(),
            "verdict": "completed by the runner: exit status 0 and no quit-stalled failure"])
    }
}

extension Laboratory {
    /// CHROMIUM-APP-R2 (review H3). An Alloy browser is destroyed when its CEF host view is
    /// released; keeping that view alive outside every window means its close never completes. The
    /// engine owning it is never shut down. The bridge's bounded quit must then force the end of
    /// the loop (two stalls, "quit-forced") and CefShutdown must destroy the browser: the runner
    /// expects exit status 77 within the bound, CefShutdown returned and no process left.
    func armQuitStall() async {
        let stallEngine = ChromiumBrowserEngine(persistence: .persistent)
        let stallDelegate = RecorderDelegate(ledger: ledger)
        let profile = ProfileID()
        _ = stallEngine.profile(for: profile)
        await stallEngine.profileReady(profile)
        let stalled = stallEngine.makeSurface(profileID: profile, delegate: stallDelegate)
        stalled.onEngineEvent = { [ledger] name, fields in ledger.event("quit-stall-" + name, fields) }
        place(stalled, in: windowA.contentView!)
        stalled.navigate(to: url("/page?case=quit-stall"))
        let loaded = await committed(stalled, "quit-stall")
        let view = stalled.engineContentView
        if let view { stalledViews.append(view) }
        quitProbe = (stallEngine, stallDelegate, [stalled])
        ledger.check("lifecycle.quit-stall-armed", loaded && view != nil && stallEngine.surfaceMode == .alloy, [
            "committed": loaded, "hostViewRetained": view != nil, "bridge": bridgeDiagnostics(),
            "verdict": "completed by the runner: exit status 77, quit-forced, CefShutdown returned, no process left"])
    }
}

// Guard before CEF exists: no window of this process may be ordered on screen.
if !arguments.visibleInputOnly { HiddenGuard.shared.install() }
let laboratory = Laboratory(arguments: arguments)
HiddenGuard.shared.onEvent = { [ledger = laboratory.ledger] name, fields in ledger.event(name, fields) }
HiddenGuard.shared.onViolation = { kind, record in
    laboratory.ledger.event("hidden-violation-stop", record)
    Task { @MainActor in await laboratory.finish(abortReason: "hidden-violation:" + kind) }
}
// The runner's independent window witness sends SIGTERM: stop with a controlled shutdown.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    MainActor.assumeIsolated {
        laboratory.ledger.event("sigterm")
        Task { @MainActor in await laboratory.finish(abortReason: "sigterm (external window witness or runner)") }
    }
}
termination.resume()
let cache = arguments.root.appendingPathComponent("cache")
try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false,
                                         attributes: [.posixPermissions: 0o700])
let options = ChromiumRuntime.Options(
    rootCachePath: cache.path, keychainServiceName: "Orbit Chromium Synthetic Safe Storage",
    keychainAccountName: "Orbit Chromium Synthetic", hiddenApplication: !arguments.visibleInputOnly,
    asyncNavigationHold: arguments.asyncHold)
let status = ChromiumRuntime.shared.run(options: options) {
    if !arguments.visibleInputOnly { HiddenGuard.shared.startMonitoring() }
    Task { @MainActor in await laboratory.run() }
}
if !arguments.visibleInputOnly { HiddenGuard.shared.stopMonitoring() }
// 75: the quit stalled at least once; 76: the loop ended with live browsers; 77: the bounded quit
// forced the end of the loop; 3: aborted run.
let finalStatus = status != 0 ? status : laboratory.abortReason != nil ? 3 : 0
FileHandle.standardError.write(Data("orbit-chromium-lab exit=\(finalStatus) bridge=\(status) aborted=\(laboratory.abortReason ?? "no")\n".utf8))
exit(finalStatus)
