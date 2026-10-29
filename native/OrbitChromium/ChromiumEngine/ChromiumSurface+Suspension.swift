import BrowserEngine
import BrowserShell
import OrbitChromiumBridge
import Foundation

extension ChromiumSurface {
    public var allowsSuspension: Bool { canSuspendDocument }
    /// Native lifecycle vetoes run first. r11 cannot rule out script-modified form values,
    /// so eligible candidates still need a value-only check in each isolated frame at sweep
    /// time. No persistent renderer observer is installed; field content stays in the renderer.
    public func captureStateForSuspension() async -> BrowserSuspensionState? {
        guard canSuspendDocument, let url = navigationState.committedURL,
              ["http", "https"].contains(url.scheme) else { return refuseSuspension("native-protection") }
        let generation = documentGeneration
        let nativeDocument = pagePerformance?.lifecycle()?.documentID
        let (ok, data) = await suspensionDevToolsCall("Page.getFrameTree")
        guard ok, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = json["frameTree"] as? [String: Any] else { return refuseSuspension("frame-tree") }
        func frames(_ tree: [String: Any]) -> [String] {
            guard let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String else { return [] }
            return [id] + (tree["childFrames"] as? [[String: Any]] ?? []).flatMap(frames)
        }
        let ids = frames(tree)
        guard !ids.isEmpty else { return refuseSuspension("no-frames") }
        onEngineEvent?("suspension-value-fallback", ["frames": String(ids.count), "cdpCalls": String(1 + 2 * ids.count)])
        var scroll: (Double, Double) = (0, 0)
        for (index, id) in ids.enumerated() {
            guard let context = await suspensionWorld(frameID: id) else { return refuseSuspension("isolated-world") }
            guard let state = await evaluateSuspension(Self.suspensionCheck, context: context) else { return refuseSuspension("document-check") }
            if index == 0, state["documentURL"] as? String != url.absoluteString { return refuseSuspension("wrong-document") }
            guard state["safe"] as? Bool == true else { return refuseSuspension(state["reason"] as? String ?? "edited-or-playing") }
            if index == 0 {
                guard let x = state["x"] as? Double, let y = state["y"] as? Double,
                      x.isFinite, y.isFinite else { return refuseSuspension("scroll-state") }
                scroll = (x, y)
            }
        }
        let size = ACRNavigationHistory(token, nil, 0)
        guard size > 0, size < 1_048_576 else { return refuseSuspension("history-size") }
        var bytes = [CChar](repeating: 0, count: Int(size) + 1)
        guard ACRNavigationHistory(token, &bytes, bytes.count) == size,
              let json = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: Int(size))) as? [String: Any],
              let entries = json["entries"] as? [String], let historyIndex = json["currentIndex"] as? Int else { return refuseSuspension("history-read") }
        let history = entries.compactMap(URL.init(string:))
        guard history.count == entries.count, history.indices.contains(historyIndex), history[historyIndex] == url else { return refuseSuspension("history-state") }
        guard canSuspendDocument, documentGeneration == generation,
              pagePerformance?.lifecycle()?.documentID == nativeDocument, navigationState.committedURL == url else { return refuseSuspension("changed-document") }
        return BrowserSuspensionState(url: url, documentGeneration: generation, scrollX: scroll.0, scrollY: scroll.1,
                                      history: history, historyIndex: historyIndex)
    }

    private func refuseSuspension(_ reason: String) -> BrowserSuspensionState? {
        onEngineEvent?("suspension-refused", ["reason": reason])
        return nil
    }

    private var canSuspendDocument: Bool {
        !isDisposed && isReady && !navigationState.isLoading && !isProtectedFromSuspension && !isSuspended
    }

    private func suspensionDevToolsCall(_ method: String, params: String = "") async -> (Bool, Data) {
        onEngineEvent?("suspension-cdp-call", ["method": method])
        return await devToolsCall(method, params: params)
    }

    private func suspensionWorld(frameID: String) async -> Int? {
        let params: [String: Any] = ["frameId": frameID, "worldName": "OrbitSuspension"]
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let (ok, result) = await suspensionDevToolsCall("Page.createIsolatedWorld", params: text)
        guard ok, let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else { return nil }
        return json["executionContextId"] as? Int
    }

    private func evaluateSuspension(_ expression: String, context: Int) async -> [String: Any]? {
        let params: [String: Any] = ["expression": expression, "contextId": context, "returnByValue": true]
        guard let data = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let (ok, result) = await suspensionDevToolsCall("Runtime.evaluate", params: text)
        guard ok, let json = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              json["exceptionDetails"] == nil, let remote = json["result"] as? [String: Any] else { return nil }
        return remote["value"] as? [String: Any]
    }

    private static let suspensionCheck = #"""
    (() => {
      const roots = [document];
      let changedField = false;
      for (let i=0; i<roots.length; ++i) {
        for (const element of roots[i].querySelectorAll('*')) {
          if (element.shadowRoot) roots.push(element.shadowRoot);
          if (element instanceof HTMLInputElement) {
            const valueInput = !['hidden','checkbox','radio','button','submit','reset','range','color'].includes(element.type);
            changedField ||= (valueInput && element.value !== element.defaultValue) || !!element.files?.length;
          } else if (element instanceof HTMLTextAreaElement) {
            changedField ||= element.value !== element.defaultValue;
          }
        }
      }
      return {safe:!changedField, x:scrollX, y:scrollY,documentURL:location.href,
        reason:changedField?'changed-field':'safe'};
    })()
    """#

    func observePageLifecycle() {
        guard lifecycleObservation == nil, let performance = pagePerformance else { return }
        // Register synchronously before the first document can start playback or be edited.
        let changes = performance.changes()
        lifecycleObservation = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled, let self, !self.isDisposed else { return }
                if change.event == .closed { return }
                if change.event == .discarded || change.state?.state == .discarded {
                    // Buffered events may outlive a native activation. Read current state so
                    // a queued discard cannot put an already-restored document back to sleep.
                    if performance.lifecycle()?.state == .discarded, !self.isSuspended {
                        self.isSuspended = true
                        self.onEngineEvent?("suspension-discarded", ["initiator": change.initiator == .nativePolicy ? "native" : "embedder"])
                    }
                }
                self.onChange?()
            }
        }
    }

    /// Chromium owns page state and history restoration, including cache-only POST recovery.
    public func restoreAfterSuspension(_ state: BrowserSuspensionState) async {}

    public func suspendInPlace() -> BrowserSurfaceSuspensionResult {
        guard canSuspendDocument else { return .refused }
        isSuspended = true
        guard ACRDiscardTab(token) == 1 else { isSuspended = false; return .refused }
        onEngineEvent?("suspension-discarded", [:])
        return .suspended
    }

    func resumeDiscardedTab() {
        guard isSuspended, !isDisposed else { return }
        guard ACRRestoreDiscardedTab(token) == 1 else { return }
        isSuspended = false
        onEngineEvent?("suspension-restored", [:])
    }
}

extension ChromiumSurface {
    public var supportsSuspensionPaint: Bool { true }

    public func prepareSuspensionPaint() async -> Bool {
        guard !isDisposed else { return false }
        if suspensionPaintEnabled { return true }
        let (ok, data) = await devToolsCall("Page.getFrameTree")
        guard ok, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = object["frameTree"] as? [String: Any], let frame = tree["frame"] as? [String: Any],
              let id = frame["id"] as? String else { return false }
        suspensionMainFrame = id
        suspensionLoader = frame["loaderId"] as? String
        let (enabled, _) = await devToolsCall("Page.setLifecycleEventsEnabled", params: #"{"enabled":true}"#)
        suspensionPaintEnabled = enabled && !isDisposed
        return suspensionPaintEnabled
    }

    func receiveSuspensionPaint(method: String, payload: Data) {
        guard suspensionPaintEnabled, method == "Page.frameNavigated" || method == "Page.lifecycleEvent",
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        if method == "Page.frameNavigated", let frame = object["frame"] as? [String: Any], frame["parentId"] == nil {
            suspensionMainFrame = frame["id"] as? String
            suspensionLoader = frame["loaderId"] as? String
            suspensionPaintGeneration = nil
            suspensionPaintTask?.cancel()
        } else if method == "Page.lifecycleEvent", object["name"] as? String == "firstContentfulPaint",
                  object["frameId"] as? String == suspensionMainFrame,
                  let loader = object["loaderId"] as? String, loader == suspensionLoader {
            let generation = documentGeneration
            suspensionPaintTask?.cancel()
            suspensionPaintTask = Task { [weak self] in
                guard let self else { return }
                // FCP is renderer paint, not scanout. Give the native compositor two frame
                // opportunities before exposing it; the shell also has a bounded timeout.
                let (ok, _) = await devToolsCall("Runtime.evaluate", params: #"{"expression":"new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(()=>r(true))))","awaitPromise":true,"returnByValue":true}"#)
                guard ok, !Task.isCancelled, !isDisposed, documentGeneration == generation,
                      suspensionLoader == loader else { return }
                suspensionPaintGeneration = generation
                onEngineEvent?("suspension-content-painted", ["generation": String(generation)])
                onChange?()
            }
        }
    }
}
