import AppKit
import OrbitChromiumBridge
import BrowserCore
import BrowserEngine
import ChromiumEngine
import Foundation

// ENG-X2.1 hidden scenarios on the patched CEF: one shell window, one hosted Chrome-style tab
// (D-chrome). On the stock SDK (ACRPatchLevel() == 0) they record "not-attempted". Synthetic
// loopback fixtures only; the window is never ordered in (HiddenGuard blocks and witnesses it).

enum X2Options {
    /// `ORBIT_LAB_X2_ONLY=1` (set by `scripts/orbit-chromium-x2.py run --x2-only`): conformance
    /// harness, then the hosted scenarios only, for debug iterations.
    static var hostedOnly: Bool { ProcessInfo.processInfo.environment["ORBIT_LAB_X2_ONLY"] == "1" }
}

extension Laboratory {
    /// Hosted scenarios (patched CEF only). Hidden mode is enforced and witnessed by the lab's
    /// HiddenGuard (X1-R2) for the whole run.
    func x2Phase(_ profile: ProfileID) async {
        await hostedScenarios(profile)
    }

    func hostedScenarios(_ profile: ProfileID) async {
        let level = engine.patchLevel
        extra["patchLevel"] = Int(level)
        ledger.event("x2-patch-level", ["level": String(level)])
        guard level >= 1 else {
            ledger.record("x2.hosted-tab", "not-attempted", ["reason": "stock CEF: ACRPatchLevel() == 0"])
            return
        }
        guard arguments.extensionLoaded else {
            ledger.record("x2.hosted-tab", "not-attempted", ["reason": "run without --load-extension"])
            return
        }
        let profileB = ProfileID()
        await hostedCloseDuringPending(profileB)
        hiddenAudit("before-hosted")
        let windowsBefore = NSApp.windows.count
        let window = makeHiddenWindow("Orbit lab X2 hosted")
        guard let engineWindow = engine.makeWindow(for: window) else {
            ledger.record("x2.hosted-tab", "failed", ["reason": "ACRCreateWindow refused"])
            return
        }
        guard let tab = engine.makeTabSurface(profileID: profile, in: engineWindow, delegate: delegate) else {
            ledger.record("x2.hosted-tab", "failed", ["reason": "ACRCreateTabSurface refused"])
            engineWindow.close()
            return
        }
        tab.onEngineEvent = { [ledger] name, fields in ledger.event("hosted-" + name, fields) }
        place(tab, in: window.contentView!)
        surfaces.append(tab)
        let created = await until(10) { tab.isBrowserCreated }
        let identity = tab.tabIdentity
        let contentView = tab.engineContentView
        ledger.check("x2.hosted-tab.created", created && tab.runtimeStyle == 2 && identity?.isHosted == true
                     && contentView?.isDescendant(of: tab.hostView) == true && engineWindow.logicalBrowserCount == 1, [
            "runtimeStyle": tab.runtimeStyle == 2 ? "chrome" : tab.runtimeStyle == 1 ? "alloy" : "none",
            "tabID": Int(identity?.tabID ?? -2), "windowID": Int(identity?.windowID ?? -2),
            "index": Int(identity?.index ?? -2), "active": identity?.isActive ?? false,
            "logicalBrowsers": engineWindow.logicalBrowserCount,
            "contentViewClass": contentView.map { String(describing: type(of: $0)) } ?? "nil",
            "contentViewInHostView": contentView?.isDescendant(of: tab.hostView) ?? false,
            "appKitWindowsAdded": NSApp.windows.count - windowsBefore - 1])
        hiddenAudit("after-hosted-create")

        // Extension identity: the 19 EngineGate probes from a hosted tab. The "chrome-native-"
        // case prefix makes the worker also check that the window holds exactly this tab and
        // report its tab context.
        let reports = arguments.root.appendingPathComponent("reports")
        tab.navigate(to: url("/page?case=chrome-native-hosted-a"))
        let reportURL = reports.appendingPathComponent("chrome-native-hosted-a.json")
        let arrived = await until(25) { FileManager.default.fileExists(atPath: reportURL.path) }
        var evidence: [String: Any] = ["reportArrived": arrived, "profile": "persistent custom context A",
                                       "runtimeStyle": tab.runtimeStyle == 2 ? "chrome" : "alloy"]
        let after = tab.tabIdentity
        if arrived, let data = try? Data(contentsOf: reportURL),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = report["results"] as? [[String: Any]] {
            let failed = results.filter { ($0["passed"] as? Bool) != true }
            let context = report["tabContext"] as? [String: Any]
            let reportedTab = (context?["tabID"] as? NSNumber)?.int32Value
            let reportedWindow = (context?["windowID"] as? NSNumber)?.int32Value
            evidence["passed"] = results.count - failed.count
            evidence["total"] = results.count
            evidence["failedProbes"] = failed.map { "\($0["name"] ?? "?"): \($0["detail"] ?? "")" }
            evidence["extensionTabContext"] = context ?? [:]
            evidence["bridgeTabID"] = Int(after?.tabID ?? -2)
            evidence["bridgeWindowID"] = Int(after?.windowID ?? -2)
            let identityMatches = reportedTab != nil && reportedTab == after?.tabID && reportedWindow == after?.windowID
            evidence["identityMatchesBridge"] = identityMatches
            ledger.record("x2.hosted-tab.mv3-probes", failed.isEmpty && results.count == 19 && identityMatches
                          ? "proven" : "partial", evidence)
        } else {
            ledger.record("x2.hosted-tab.mv3-probes", "failed", evidence)
        }
        hiddenAudit("after-hosted-probes")

        await hostedProfiles(tab, profileB, engineWindow, window)

        await hostedFocusAndInput(tab, window)
        await hostedAccessibility(tab)

        // Chrome style admits the extensions WebUI that Alloy refuses (X2-EXT-MANAGEMENT).
        tab.navigate(to: URL(string: "chrome://extensions/")!)
        _ = await until(5) { tab.navigationState.committedURL?.scheme == "chrome" && !tab.navigationState.isLoading }
        ledger.record("x2.hosted-tab.management-webui",
                      tab.navigationState.committedURL?.absoluteString.hasPrefix("chrome://extensions") == true
                          ? "proven" : "failed",
                      ["committed": tab.navigationState.committedURL?.absoluteString ?? "nil"])
        hiddenAudit("after-hosted-webui")

        // Closing the registration inside the shell's popup callback forces
        // hosted preparation to fail. It must abort, never create an Alloy tab.
        await hostedPopupPreparationFailure(tab, engineWindow, window)

        // Closing the last tab closes the logical Browser; the shell window stays.
        tab.dispose()
        let closed = await until(10) { !tab.isBrowserCreated }
        let browserGone = await until(5) { engineWindow.logicalBrowserCount == 0 }
        engineWindow.close()
        ledger.check("x2.hosted-tab.close", closed && browserGone && !window.isVisible, [
            "closed": closed, "logicalBrowsersAfterClose": engineWindow.logicalBrowserCount,
            "shellWindowKept": window.contentView != nil])
        window.close()
        hiddenAudit("after-hosted")
    }

    func hostedCloseDuringPending(_ profile: ProfileID) async {
        let window = makeHiddenWindow("Orbit lab pending hosted close")
        guard let registration = engine.makeWindow(for: window) else {
            ledger.record("x2.hosted-tab.close-during-pending", "failed", ["reason": "window registration refused"])
            window.close()
            return
        }
        let liveBefore = engine.liveNativeTokens.count
        let pendingBefore = bridgeDiagnostics()["pendingCreations"] ?? -1
        guard let pending = engine.makeTabSurface(profileID: profile, in: registration, delegate: delegate) else {
            ledger.record("x2.hosted-tab.close-during-pending", "failed", ["reason": "creation refused before pending"])
            registration.close()
            window.close()
            return
        }
        var events: [String] = []
        pending.onEngineEvent = { name, _ in events.append(name) }
        let wasPending = pending.isCreationPending && !pending.isBrowserCreated
        registration.close()
        await engine.profileReady(profile)
        _ = await until(5) { !pending.isCreationPending }
        await pause(0.3)
        let drained = engine.liveNativeTokens.count == liveBefore &&
            bridgeDiagnostics()["pendingCreations"] == pendingBefore
        ledger.check("x2.hosted-tab.close-during-pending", wasPending && drained &&
                     events.filter { $0 == "create-aborted" }.count == 1 && !events.contains("created") &&
                     !pending.isBrowserCreated && pending.isDisposed, [
            "acceptedAsPending": wasPending, "events": events, "pendingDrained": drained,
            "runtimeStyle": Int(pending.runtimeStyle), "bridge": bridgeDiagnostics()])
        pending.dispose()
        window.close()
        hiddenAudit("after-hosted-pending-close")
    }

    func hostedProfiles(_ tabA: ChromiumSurface, _ profileB: ProfileID,
                        _ registration: ChromiumEngineWindow, _ window: NSWindow) async {
        _ = await evaluate(tabA, "localStorage.setItem('x2.profile', 'A'); true")
        guard let tabB = engine.makeTabSurface(profileID: profileB, in: registration, delegate: delegate) else {
            ledger.record("x2.hosted-tab.profile-isolation", "failed", ["reason": "profile B creation refused"])
            return
        }
        place(tabB, in: window.contentView!)
        surfaces.append(tabB)
        _ = await until(10) { tabB.isBrowserCreated }
        tabB.navigate(to: url("/page?case=chrome-native-hosted-profileB-a"))
        let reportURL = arguments.root.appendingPathComponent("reports/chrome-native-hosted-profileB-a.json")
        let arrived = await until(25) { FileManager.default.fileExists(atPath: reportURL.path) }
        var probesPass = false
        if arrived, let data = try? Data(contentsOf: reportURL),
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = report["results"] as? [[String: Any]],
           let context = report["tabContext"] as? [String: Any] {
            probesPass = results.count == 19 && results.allSatisfy { ($0["passed"] as? Bool) == true } &&
                (context["tabID"] as? NSNumber)?.int32Value == tabB.tabIdentity?.tabID &&
                (context["windowID"] as? NSNumber)?.int32Value == tabB.tabIdentity?.windowID
        }
        let beforeB = await evaluate(tabB, "localStorage.getItem('x2.profile') === null") as? Bool
        _ = await evaluate(tabB, "localStorage.setItem('x2.profile', 'B'); true")
        let valueA = await evaluate(tabA, "localStorage.getItem('x2.profile')") as? String
        let valueB = await evaluate(tabB, "localStorage.getItem('x2.profile')") as? String
        let a = tabA.tabIdentity, b = tabB.tabIdentity
        ledger.check("x2.hosted-tab.profile-isolation", probesPass && beforeB == true &&
                     valueA == "A" && valueB == "B" && a?.windowToken == b?.windowToken &&
                     a?.windowID != nil && b?.windowID != nil && a?.windowID != b?.windowID &&
                     a?.tabID != b?.tabID && registration.logicalBrowserCount == 2, [
            "profileBMV3Probes19of19": probesPass, "profileBSawNoProfileAStorage": beforeB ?? false,
            "storageA": valueA ?? "nil", "storageB": valueB ?? "nil",
            "windowIDA": Int(a?.windowID ?? -1), "windowIDB": Int(b?.windowID ?? -1),
            "logicalBrowsersInSameNSWindow": registration.logicalBrowserCount])
        tabB.dispose()
        _ = await until(8) { !tabB.isBrowserCreated && registration.logicalBrowserCount == 1 }
        hiddenAudit("after-hosted-profile-isolation")
    }

    func hostedPopupPreparationFailure(_ opener: ChromiumSurface,
                                       _ registration: ChromiumEngineWindow, _ window: NSWindow) async {
        opener.navigate(to: url("/page?case=hosted-popup-preparation"))
        _ = await committed(opener, "hosted-popup-preparation")
        var child: ChromiumSurface?
        var events: [String] = []
        delegate.onNewSurface = { created in
            child = created
            place(created, in: window.contentView!)
            created.onEngineEvent = { name, _ in events.append(name) }
            registration.close()
        }
        _ = await evaluate(opener, "window.open('/page?case=hosted-refused-child'); 1", gesture: true)
        _ = await until(5) { events.contains("create-aborted") }
        delegate.onNewSurface = nil
        ledger.check("x2.hosted-tab.popup-preparation-failure", child != nil &&
                     events.filter { $0 == "create-aborted" }.count == 1 && !events.contains("created") &&
                     child?.isDisposed == true && child?.isBrowserCreated == false &&
                     bridgeDiagnostics()["pendingCreations"] == 0 && bridgeDiagnostics()["pendingPopups"] == 0, [
            "events": events, "runtimeStyle": Int(child?.runtimeStyle ?? -1), "bridge": bridgeDiagnostics()])
        child?.dispose()
        hiddenAudit("after-hosted-popup-preparation-failure")
    }

    /// Hidden focus and IME smoke tests. The window is never key: keyboard focus inside AppKit
    /// and the IME entry points (NSTextInputClient of RenderWidgetHostViewCocoa) are exercised,
    /// not real key events or the system input method UI (GUI slot).
    func hostedFocusAndInput(_ tab: ChromiumSurface, _ window: NSWindow) async {
        _ = await evaluate(tab, "document.getElementById('field').value = ''; true")
        let focused = tab.focusDocument()
        await pause(0.3)
        let responder = window.firstResponder as? NSView
        let responderClass = responder.map { String(describing: type(of: $0)) } ?? "nil"
        let inTab = responder?.isDescendant(of: tab.hostView) == true
        let identity = tab.tabIdentity
        let hasFocus = await evaluate(tab, "document.hasFocus()") as? Bool
        ledger.check("x2.hosted-tab.focus", focused && inTab && identity?.isActive == true, [
            "firstResponderClass": responderClass, "firstResponderInHostView": inTab,
            "activeInTabStrip": identity?.isActive ?? false,
            "documentHasFocus": hasFocus.map(String.init) ?? "nil",
            "note": "hidden window is never key; document.hasFocus() is informational"])

        _ = await evaluate(tab, "document.getElementById('field').focus(); document.activeElement.id")
        guard let client = responder as? (NSView & NSTextInputClient) else {
            ledger.record("x2.hosted-tab.ime", "failed", ["reason": "first responder is not an NSTextInputClient",
                                                         "firstResponderClass": responderClass])
            return
        }
        client.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        await pause(0.3)
        let marked = client.hasMarkedText()
        let composing = await evaluate(tab, "document.getElementById('field').value") as? String
        client.insertText("漢", replacementRange: NSRange(location: NSNotFound, length: 0))
        await pause(0.3)
        let committed = await evaluate(tab, "document.getElementById('field').value") as? String
        ledger.check("x2.hosted-tab.ime", committed == "漢", [
            "markedTextAfterSetMarkedText": marked, "valueWhileComposing": composing ?? "nil",
            "valueAfterInsertText": committed ?? "nil",
            "path": "RenderWidgetHostViewCocoa NSTextInputClient setMarkedText/insertText (no system IME UI)"])
    }

    /// Hidden accessibility smoke test: the AppKit accessibility tree below the shell view must
    /// expose the page's web area, and the web area's ancestors must lead back to the shell view
    /// (no Views hierarchy in between).
    func hostedAccessibility(_ tab: ChromiumSurface) async {
        func webArea(below element: Any, depth: Int = 0) -> NSObject? {
            guard depth < 12, let object = element as? NSObject else { return nil }
            if object.responds(to: NSSelectorFromString("accessibilityRole")),
               (object.value(forKey: "accessibilityRole") as? String) == "AXWebArea" {
                return object
            }
            guard object.responds(to: NSSelectorFromString("accessibilityChildren")) else { return nil }
            let children = (object.value(forKey: "accessibilityChildren") as? [Any]) ?? []
            for child in children { if let found = webArea(below: child, depth: depth + 1) { return found } }
            return nil
        }
        let enabled = tab.setNativeAccessibility(true)
        var area: NSObject?
        _ = await until(5) {
            area = webArea(below: tab.hostView)
            return area != nil
        }
        var chain: [String] = []
        var reachesHost = false
        var cursor: Any? = area?.value(forKey: "accessibilityParent")
        while let node = cursor as? NSObject, chain.count < 12 {
            chain.append(String(describing: type(of: node)))
            if node === tab.hostView || node === tab.hostView.window { reachesHost = true; break }
            guard node.responds(to: NSSelectorFromString("accessibilityParent")) else { break }
            cursor = node.value(forKey: "accessibilityParent")
        }
        let title = area?.value(forKey: "accessibilityTitle") as? String
        ledger.record("x2.hosted-tab.accessibility", area != nil && reachesHost ? "proven" : area != nil ? "partial" : "failed", [
            "accessibilityEnabled": enabled, "webAreaFound": area != nil, "webAreaTitle": title ?? "nil",
            "parentChain": chain,
            "parentChainReachesHostView": reachesHost,
            "note": "AppKit accessibility API queried in-process; VoiceOver itself is a GUI-slot check"])
    }
}
